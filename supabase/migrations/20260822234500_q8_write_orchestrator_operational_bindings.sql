-- ============================================================
-- ATLAS / VALENTINA — Q8
-- Governed operational bindings and WRITE input resolution
-- Canonical schema captured from the certified remote database.
-- Q1–Q7 contracts are dependencies and are not redefined here.
-- ============================================================

begin;

set local search_path = public, pg_catalog;

create table public.atlas_internal_operational_bindings (
  "id" uuid default gen_random_uuid() not null,
  "empresa_id" uuid not null,
  "conversation_id" uuid not null,
  "source_message_id" uuid,
  "agent_code" text not null,
  "tool_code" text not null,
  "resource_type" text not null,
  "resource_id" uuid not null,
  "binding_status" text default 'ACTIVE'::text not null,
  "binding_source" text not null,
  "created_by" uuid,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  "expires_at" timestamp with time zone,
  "consumed_at" timestamp with time zone,
  "metadata" jsonb default '{}'::jsonb not null,
  constraint "atlas_internal_operational_bindings_agent_code_chk" CHECK (NULLIF(TRIM(BOTH FROM agent_code), ''::text) IS NOT NULL),
  constraint "atlas_internal_operational_bindings_binding_source_chk" CHECK (binding_source = ANY (ARRAY['SYSTEM'::text, 'USER_SELECTION'::text, 'WORKFLOW'::text, 'CONTROLLED_FIXTURE'::text])),
  constraint "atlas_internal_operational_bindings_consumed_chk" CHECK (binding_status = 'CONSUMED'::text AND consumed_at IS NOT NULL OR binding_status <> 'CONSUMED'::text),
  constraint "atlas_internal_operational_bindings_conversation_id_fkey" FOREIGN KEY (conversation_id) REFERENCES atlas_internal_conversations(id),
  constraint "atlas_internal_operational_bindings_empresa_id_fkey" FOREIGN KEY (empresa_id) REFERENCES empresas(id),
  constraint "atlas_internal_operational_bindings_expiry_chk" CHECK (expires_at IS NULL OR expires_at > created_at),
  constraint "atlas_internal_operational_bindings_pkey" PRIMARY KEY (id),
  constraint "atlas_internal_operational_bindings_resource_type_chk" CHECK (NULLIF(TRIM(BOTH FROM resource_type), ''::text) IS NOT NULL),
  constraint "atlas_internal_operational_bindings_source_message_id_fkey" FOREIGN KEY (source_message_id) REFERENCES atlas_internal_messages(id),
  constraint "atlas_internal_operational_bindings_status_chk" CHECK (binding_status = ANY (ARRAY['ACTIVE'::text, 'CONSUMED'::text, 'REVOKED'::text, 'EXPIRED'::text])),
  constraint "atlas_internal_operational_bindings_tool_code_fkey" FOREIGN KEY (tool_code) REFERENCES atlas_internal_tool_catalog(tool_code)
);

alter table public.atlas_internal_operational_bindings owner to postgres;

CREATE UNIQUE INDEX atlas_internal_operational_bindings_active_conversation_tool_un ON public.atlas_internal_operational_bindings USING btree (empresa_id, conversation_id, tool_code) WHERE ((binding_status = 'ACTIVE'::text) AND (source_message_id IS NULL));

CREATE UNIQUE INDEX atlas_internal_operational_bindings_active_message_tool_uniq ON public.atlas_internal_operational_bindings USING btree (empresa_id, source_message_id, tool_code) WHERE ((binding_status = 'ACTIVE'::text) AND (source_message_id IS NOT NULL));

CREATE INDEX atlas_internal_operational_bindings_resolver_idx ON public.atlas_internal_operational_bindings USING btree (empresa_id, conversation_id, tool_code, binding_status, created_at DESC);

CREATE INDEX atlas_internal_operational_bindings_resource_idx ON public.atlas_internal_operational_bindings USING btree (empresa_id, resource_type, resource_id);

CREATE INDEX atlas_internal_operational_bindings_source_message_idx ON public.atlas_internal_operational_bindings USING btree (source_message_id) WHERE (source_message_id IS NOT NULL);

alter table public.atlas_internal_operational_bindings enable row level security;

revoke all on table public.atlas_internal_operational_bindings from public;
revoke all on table public.atlas_internal_operational_bindings from anon;
revoke all on table public.atlas_internal_operational_bindings from authenticated;
revoke all on table public.atlas_internal_operational_bindings from service_role;

grant select, insert, update, delete, truncate, references, trigger on table public.atlas_internal_operational_bindings to postgres;
grant select, insert, update, delete, truncate, references, trigger on table public.atlas_internal_operational_bindings to service_role;

CREATE OR REPLACE FUNCTION public.atlas_internal_bind_operational_resource(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_tool_code text, p_resource_type text, p_resource_id uuid, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();

  v_tool_code text;
  v_resource_type text;

  v_required_permission text;

  v_existing_binding
    public.atlas_internal_operational_bindings%rowtype;

  v_binding
    public.atlas_internal_operational_bindings%rowtype;

begin

  -- ==========================================================
  -- 1. AUTENTICACIÓN
  -- ==========================================================

  if v_user_id is null then
    raise exception 'ATLAS_AUTH_REQUIRED';
  end if;

  -- ==========================================================
  -- 2. NORMALIZACIÓN
  -- ==========================================================

  v_tool_code :=
    upper(trim(coalesce(p_tool_code, '')));

  v_resource_type :=
    upper(trim(coalesce(p_resource_type, '')));

  if v_tool_code = '' then
    raise exception 'ATLAS_OPERATIONAL_BINDING_TOOL_REQUIRED';
  end if;

  if v_resource_type = '' then
    raise exception 'ATLAS_OPERATIONAL_BINDING_RESOURCE_TYPE_REQUIRED';
  end if;

  if p_resource_id is null then
    raise exception 'ATLAS_OPERATIONAL_BINDING_RESOURCE_ID_REQUIRED';
  end if;

  if p_expires_at is not null
     and p_expires_at <= now()
  then
    raise exception 'ATLAS_OPERATIONAL_BINDING_INVALID_EXPIRY';
  end if;

  if p_metadata is not null
     and jsonb_typeof(p_metadata) <> 'object'
  then
    raise exception 'ATLAS_OPERATIONAL_BINDING_METADATA_INVALID';
  end if;

  -- ==========================================================
  -- 3. ACCESO A EMPRESA
  -- ==========================================================

  if not public.atlas_internal_has_empresa_access(
    p_empresa_id
  ) then
    raise exception 'ATLAS_EMPRESA_ACCESS_DENIED';
  end if;

  if not public.atlas_internal_has_permission(
    p_empresa_id,
    'INTERNAL_CHAT_USE'
  ) then
    raise exception 'ATLAS_INTERNAL_CHAT_ACCESS_DENIED';
  end if;

  -- ==========================================================
  -- 4. CONVERSACIÓN CANÓNICA
  --
  -- FOR UPDATE serializa cambios de contexto operacional
  -- dentro de la misma conversación.
  -- ==========================================================

  perform 1
  from public.atlas_internal_conversations c
  where c.id = p_conversation_id
    and c.empresa_id = p_empresa_id
    and c.status = 'OPEN'
  for update;

  if not found then
    raise exception 'ATLAS_INTERNAL_CONVERSATION_NOT_FOUND';
  end if;

  -- ==========================================================
  -- 5. MENSAJE FUENTE OPCIONAL
  -- ==========================================================

  if p_source_message_id is not null then

    if not exists (
      select 1
      from public.atlas_internal_messages m
      where m.id = p_source_message_id
        and m.empresa_id = p_empresa_id
        and m.conversation_id = p_conversation_id
        and m.actor_type = 'USER'
        and m.direction = 'INBOUND'
    ) then
      raise exception 'ATLAS_INVALID_SOURCE_MESSAGE';
    end if;

  end if;

  -- ==========================================================
  -- 6. TOOL CANÓNICO Y PERMISO
  -- ==========================================================

  select tc.required_permission
  into v_required_permission
  from public.atlas_internal_tool_catalog tc
  where upper(tc.tool_code) = v_tool_code
    and tc.active = true;

  if not found then
    raise exception 'ATLAS_OPERATIONAL_BINDING_TOOL_NOT_AVAILABLE';
  end if;

  if v_required_permission is null
     or not public.atlas_internal_has_permission(
       p_empresa_id,
       v_required_permission
     )
  then
    raise exception 'ATLAS_OPERATIONAL_BINDING_PERMISSION_DENIED';
  end if;

  -- ==========================================================
  -- 7. CONTRATO TOOL → RESOURCE
  --
  -- Q8 comienza con QUOTE_CREATE.
  -- Las herramientas futuras deberán añadir aquí su contrato
  -- explícito. Nunca aceptamos tipos arbitrarios.
  -- ==========================================================

  if v_tool_code = 'ATLAS_QUOTE_CREATE_INTERNAL' then

    if v_resource_type <> 'QUOTE_BUILDER' then
      raise exception
        'ATLAS_OPERATIONAL_BINDING_RESOURCE_TYPE_MISMATCH';
    end if;

    if not exists (
      select 1
      from public.atlas_quote_builders qb
      where qb.id = p_resource_id
        and qb.empresa_id = p_empresa_id
        and qb.status = 'READY_FOR_QUOTE'
    ) then
      raise exception
        'ATLAS_OPERATIONAL_BINDING_QUOTE_BUILDER_NOT_AVAILABLE';
    end if;

  else

    raise exception
      'ATLAS_OPERATIONAL_BINDING_TOOL_CONTRACT_NOT_IMPLEMENTED';

  end if;

  -- ==========================================================
  -- 8. IDEMPOTENCIA
  --
  -- Si el mismo binding ya está activo dentro del mismo
  -- alcance, lo devolvemos sin crear otro registro.
  -- ==========================================================

  select b.*
  into v_existing_binding
  from public.atlas_internal_operational_bindings b
  where b.empresa_id = p_empresa_id
    and b.conversation_id = p_conversation_id
    and b.tool_code = v_tool_code
    and b.binding_status = 'ACTIVE'
    and b.resource_type = v_resource_type
    and b.resource_id = p_resource_id
    and b.source_message_id
          is not distinct from p_source_message_id
    and (
      b.expires_at is null
      or b.expires_at > now()
    )
  limit 1;

  if found then

    return jsonb_build_object(
      'binding_id',
        v_existing_binding.id,

      'empresa_id',
        v_existing_binding.empresa_id,

      'conversation_id',
        v_existing_binding.conversation_id,

      'source_message_id',
        v_existing_binding.source_message_id,

      'tool_code',
        v_existing_binding.tool_code,

      'resource_type',
        v_existing_binding.resource_type,

      'resource_id',
        v_existing_binding.resource_id,

      'binding_status',
        v_existing_binding.binding_status,

      'binding_source',
        v_existing_binding.binding_source,

      'idempotent_replay',
        true,

      'safe_to_continue',
        true
    );

  end if;

  -- ==========================================================
  -- 9. REVOCAR EL BINDING ANTERIOR DEL MISMO ALCANCE
  -- ==========================================================

  update public.atlas_internal_operational_bindings b
  set
    binding_status = 'REVOKED',
    updated_at = now(),
    metadata =
      coalesce(b.metadata, '{}'::jsonb)
      ||
      jsonb_build_object(
        'revoked_reason',
          'REPLACED_BY_NEW_BINDING',

        'revoked_at',
          now(),

        'revoked_by',
          v_user_id
      )
  where b.empresa_id = p_empresa_id
    and b.conversation_id = p_conversation_id
    and b.tool_code = v_tool_code
    and b.binding_status = 'ACTIVE'
    and b.source_message_id
          is not distinct from p_source_message_id;

  -- ==========================================================
  -- 10. CREAR BINDING GOBERNADO
  -- ==========================================================

  insert into public.atlas_internal_operational_bindings (
    empresa_id,
    conversation_id,
    source_message_id,
    agent_code,
    tool_code,
    resource_type,
    resource_id,
    binding_status,
    binding_source,
    created_by,
    expires_at,
    metadata
  )
  values (
    p_empresa_id,
    p_conversation_id,
    p_source_message_id,
    'VALENTINA',
    v_tool_code,
    v_resource_type,
    p_resource_id,
    'ACTIVE',
    'USER_SELECTION',
    v_user_id,
    p_expires_at,
    coalesce(p_metadata, '{}'::jsonb)
    ||
    jsonb_build_object(
      'binder_version',
        'INTERNAL_OPERATIONAL_BINDER_V1'
    )
  )
  returning *
  into v_binding;

  -- ==========================================================
  -- 11. CONTRATO FINAL
  -- ==========================================================

  return jsonb_build_object(
    'binding_id',
      v_binding.id,

    'empresa_id',
      v_binding.empresa_id,

    'conversation_id',
      v_binding.conversation_id,

    'source_message_id',
      v_binding.source_message_id,

    'agent_code',
      v_binding.agent_code,

    'tool_code',
      v_binding.tool_code,

    'resource_type',
      v_binding.resource_type,

    'resource_id',
      v_binding.resource_id,

    'binding_status',
      v_binding.binding_status,

    'binding_source',
      v_binding.binding_source,

    'expires_at',
      v_binding.expires_at,

    'idempotent_replay',
      false,

    'safe_to_continue',
      true
  );

end;
$function$;

alter function public.atlas_internal_bind_operational_resource(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_tool_code text, p_resource_type text, p_resource_id uuid, p_expires_at timestamp with time zone, p_metadata jsonb) owner to postgres;
revoke all on function public.atlas_internal_bind_operational_resource(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_tool_code text, p_resource_type text, p_resource_id uuid, p_expires_at timestamp with time zone, p_metadata jsonb) from public;
revoke all on function public.atlas_internal_bind_operational_resource(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_tool_code text, p_resource_type text, p_resource_id uuid, p_expires_at timestamp with time zone, p_metadata jsonb) from anon;
grant execute on function public.atlas_internal_bind_operational_resource(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_tool_code text, p_resource_type text, p_resource_id uuid, p_expires_at timestamp with time zone, p_metadata jsonb) to postgres;
grant execute on function public.atlas_internal_bind_operational_resource(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_tool_code text, p_resource_type text, p_resource_id uuid, p_expires_at timestamp with time zone, p_metadata jsonb) to authenticated;
grant execute on function public.atlas_internal_bind_operational_resource(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_tool_code text, p_resource_type text, p_resource_id uuid, p_expires_at timestamp with time zone, p_metadata jsonb) to service_role;

CREATE OR REPLACE FUNCTION public.atlas_internal_resolve_tool_input(p_decision_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();

  v_decision
    public.atlas_internal_agent_decisions%rowtype;

  v_binding
    public.atlas_internal_operational_bindings%rowtype;

  v_quote_builder
    public.atlas_quote_builders%rowtype;

  v_existing_cotizacion_id uuid;
  v_existing_catalogo_id uuid;
  v_existing_medio_pago_id uuid;

  v_catalogo_id uuid;
  v_catalog_count integer := 0;

  v_medio_pago_id uuid := null;

  v_binding_scope text;

  v_input_payload jsonb;

begin

  -- ==========================================================
  -- 1. AUTENTICACIÓN
  -- ==========================================================

  if v_user_id is null then
    raise exception 'ATLAS_AUTH_REQUIRED';
  end if;

  if p_decision_id is null then
    raise exception 'ATLAS_DECISION_ID_REQUIRED';
  end if;

  -- ==========================================================
  -- 2. DECISIÓN CANÓNICA
  -- ==========================================================

  select d.*
  into v_decision
  from public.atlas_internal_agent_decisions d
  where d.id = p_decision_id;

  if not found then
    raise exception 'ATLAS_INTERNAL_DECISION_NOT_FOUND';
  end if;

  -- ==========================================================
  -- 3. PROPIEDAD Y ACCESO
  -- ==========================================================

  if v_decision.user_id is distinct from v_user_id then
    raise exception 'ATLAS_DECISION_USER_MISMATCH';
  end if;

  if not public.atlas_internal_has_empresa_access(
    v_decision.empresa_id
  ) then
    raise exception 'ATLAS_EMPRESA_ACCESS_DENIED';
  end if;

  if not public.atlas_internal_has_permission(
    v_decision.empresa_id,
    'INTERNAL_CHAT_USE'
  ) then
    raise exception 'ATLAS_INTERNAL_CHAT_ACCESS_DENIED';
  end if;

  if not exists (
    select 1
    from public.atlas_internal_conversations c
    where c.id = v_decision.conversation_id
      and c.empresa_id = v_decision.empresa_id
      and c.status = 'OPEN'
  ) then
    raise exception 'ATLAS_INTERNAL_CONVERSATION_NOT_FOUND';
  end if;

  -- ==========================================================
  -- 4. DECISIÓN SEGURA PARA EJECUTAR
  -- ==========================================================

  if coalesce(v_decision.tool_required, false) = false then
    raise exception 'ATLAS_DECISION_TOOL_NOT_REQUIRED';
  end if;

  if coalesce(v_decision.permission_granted, false) = false then
    raise exception 'ATLAS_DECISION_PERMISSION_NOT_GRANTED';
  end if;

  if coalesce(v_decision.clarification_required, false) = true then
    raise exception 'ATLAS_DECISION_CLARIFICATION_REQUIRED';
  end if;

  if upper(
    coalesce(
      v_decision.decision_metadata ->> 'validation_status',
      ''
    )
  ) <> 'VALID'
  then
    raise exception 'ATLAS_DECISION_NOT_VALID';
  end if;

  if not public.atlas_internal_has_permission(
    v_decision.empresa_id,
    v_decision.permission_required
  ) then
    raise exception 'ATLAS_DECISION_PERMISSION_REVOKED';
  end if;

  -- ==========================================================
  -- 5. CONTRATO Q8: QUOTE_CREATE
  -- ==========================================================

  if upper(coalesce(v_decision.intent_code, ''))
       <> 'QUOTE_CREATE'
  then
    raise exception 'ATLAS_TOOL_INPUT_RESOLVER_INTENT_NOT_IMPLEMENTED';
  end if;

  if upper(coalesce(v_decision.selected_tool_code, ''))
       <> 'ATLAS_QUOTE_CREATE_INTERNAL'
  then
    raise exception 'ATLAS_TOOL_INPUT_RESOLVER_TOOL_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.atlas_internal_tool_catalog tc
    where tc.tool_code = 'ATLAS_QUOTE_CREATE_INTERNAL'
      and tc.active = true
      and tc.required_permission =
        v_decision.permission_required
  ) then
    raise exception 'ATLAS_TOOL_INPUT_RESOLVER_TOOL_NOT_AVAILABLE';
  end if;

  -- ==========================================================
  -- 6. VALIDAR MENSAJE FUENTE DE LA DECISIÓN
  -- ==========================================================

  if v_decision.source_message_id is not null
     and not exists (
       select 1
       from public.atlas_internal_messages m
       where m.id = v_decision.source_message_id
         and m.empresa_id = v_decision.empresa_id
         and m.conversation_id =
           v_decision.conversation_id
         and m.actor_type = 'USER'
         and m.direction = 'INBOUND'
     )
  then
    raise exception 'ATLAS_INVALID_SOURCE_MESSAGE';
  end if;

  -- ==========================================================
  -- 7. RESOLVER BINDING
  --
  -- Prioridad:
  -- 1. Binding exacto del mensaje.
  -- 2. Contexto activo de la conversación.
  --
  -- Los índices únicos impiden múltiples candidatos activos
  -- dentro del mismo alcance.
  -- ==========================================================

  if v_decision.source_message_id is not null then

    select b.*
    into v_binding
    from public.atlas_internal_operational_bindings b
    where b.empresa_id = v_decision.empresa_id
      and b.conversation_id =
        v_decision.conversation_id
      and b.source_message_id =
        v_decision.source_message_id
      and b.agent_code = v_decision.agent_code
      and b.tool_code =
        v_decision.selected_tool_code
      and b.binding_status = 'ACTIVE'
      and (
        b.expires_at is null
        or b.expires_at > now()
      )
    limit 1;

    if found then
      v_binding_scope := 'SOURCE_MESSAGE';
    end if;

  end if;

  if v_binding.id is null then

    select b.*
    into v_binding
    from public.atlas_internal_operational_bindings b
    where b.empresa_id = v_decision.empresa_id
      and b.conversation_id =
        v_decision.conversation_id
      and b.source_message_id is null
      and b.agent_code = v_decision.agent_code
      and b.tool_code =
        v_decision.selected_tool_code
      and b.binding_status = 'ACTIVE'
      and (
        b.expires_at is null
        or b.expires_at > now()
      )
    limit 1;

    if found then
      v_binding_scope := 'CONVERSATION';
    end if;

  end if;

  if v_binding.id is null then
    raise exception 'ATLAS_OPERATIONAL_BINDING_NOT_FOUND';
  end if;

  -- ==========================================================
  -- 8. VALIDAR TIPO DE RECURSO
  -- ==========================================================

  if v_binding.resource_type <> 'QUOTE_BUILDER' then
    raise exception 'ATLAS_OPERATIONAL_BINDING_RESOURCE_TYPE_MISMATCH';
  end if;

  -- ==========================================================
  -- 9. VALIDAR QUOTE BUILDER REAL
  -- ==========================================================

  select qb.*
  into v_quote_builder
  from public.atlas_quote_builders qb
  where qb.id = v_binding.resource_id
    and qb.empresa_id = v_decision.empresa_id;

  if not found then
    raise exception 'ATLAS_QUOTE_BUILDER_NOT_FOUND';
  end if;

  if v_quote_builder.status <> 'READY_FOR_QUOTE' then
    raise exception 'ATLAS_QUOTE_BUILDER_NOT_READY';
  end if;

  -- ==========================================================
  -- 10. REUTILIZAR MATERIALIZACIÓN EXISTENTE
  --
  -- Si el builder ya fue materializado, sus valores son la
  -- fuente canónica para replay.
  -- ==========================================================

  select
    c.id,
    c.catalogo_id,
    c.medio_pago_id
  into
    v_existing_cotizacion_id,
    v_existing_catalogo_id,
    v_existing_medio_pago_id
  from public.cotizaciones c
  where c.empresa_id = v_decision.empresa_id
    and c.quote_builder_id = v_quote_builder.id
    and c.deleted_at is null
  limit 1;

  if found then

    v_catalogo_id :=
      v_existing_catalogo_id;

    v_medio_pago_id :=
      v_existing_medio_pago_id;

    if v_catalogo_id is null then
      raise exception
        'ATLAS_EXISTING_QUOTE_CATALOG_MISSING';
    end if;

  else

    -- ========================================================
    -- 11. RESOLVER CATÁLOGO POR COBERTURA DE PRODUCTOS
    --
    -- Un catálogo es candidato solamente si:
    -- - pertenece a la empresa;
    -- - está publicado y vigente;
    -- - no está eliminado;
    -- - contiene todos los productos del builder.
    --
    -- Con cero productos, solo será seguro si la empresa tiene
    -- exactamente un catálogo publicado y vigente.
    -- ========================================================

    select
      count(*)::integer,
      min(candidate.catalogo_id)
    into
      v_catalog_count,
      v_catalogo_id
    from (
      select c.id as catalogo_id
      from public.catalogos c
      where c.empresa_id = v_decision.empresa_id
        and c.estado = 'published'
        and c.deleted_at is null
        and (
          c.vigente_desde is null
          or c.vigente_desde <= current_date
        )
        and (
          c.vigente_hasta is null
          or c.vigente_hasta >= current_date
        )
        and not exists (
          select 1
          from public.atlas_quote_line_items li
          where li.quote_builder_id =
            v_quote_builder.id
            and li.empresa_id =
              v_decision.empresa_id
            and not exists (
              select 1
              from public.catalogo_productos cp
              where cp.empresa_id =
                v_decision.empresa_id
                and cp.catalogo_id = c.id
                and cp.producto_padre_id =
                  li.producto_id
                and cp.visible = true
                and cp.deleted_at is null
            )
        )
    ) candidate;

    if v_catalog_count = 0 then
      raise exception
        'ATLAS_QUOTE_CATALOG_NOT_RESOLVED';
    end if;

    if v_catalog_count > 1 then
      raise exception
        'ATLAS_QUOTE_CATALOG_AMBIGUOUS';
    end if;

    -- No inventamos un medio de pago.
    v_medio_pago_id := null;

  end if;

  -- ==========================================================
  -- 12. VALIDACIÓN TENANT DEL CATÁLOGO
  -- ==========================================================

  if not exists (
    select 1
    from public.catalogos c
    where c.id = v_catalogo_id
      and c.empresa_id = v_decision.empresa_id
      and c.deleted_at is null
  ) then
    raise exception 'ATLAS_QUOTE_CATALOG_INVALID';
  end if;

  -- ==========================================================
  -- 13. VALIDACIÓN DEL MEDIO DE PAGO CUANDO EXISTA
  -- ==========================================================

  if v_medio_pago_id is not null
     and not exists (
       select 1
       from public.medios_pago mp
       where mp.id = v_medio_pago_id
         and mp.empresa_id =
           v_decision.empresa_id
         and mp.activo = true
         and mp.deleted_at is null
     )
  then
    raise exception 'ATLAS_QUOTE_PAYMENT_METHOD_INVALID';
  end if;

  -- ==========================================================
  -- 14. PAYLOAD CANÓNICO
  --
  -- La llave se deriva de la decisión; no viene del LLM.
  -- ==========================================================

  v_input_payload :=
    jsonb_build_object(
      'quote_builder_id',
        v_quote_builder.id,

      'catalogo_id',
        v_catalogo_id,

      'medio_pago_id',
        v_medio_pago_id,

      'idempotency_key',
        'INTERNAL_QUOTE_CREATE:' ||
        p_decision_id::text
    );

  -- ==========================================================
  -- 15. CONTRATO FINAL DEL RESOLVER
  -- ==========================================================

  return jsonb_build_object(
    'resolution_status',
      'RESOLVED',

    'safe_to_continue',
      true,

    'resolver_version',
      'INTERNAL_TOOL_INPUT_RESOLVER_V1',

    'decision_id',
      v_decision.id,

    'empresa_id',
      v_decision.empresa_id,

    'conversation_id',
      v_decision.conversation_id,

    'source_message_id',
      v_decision.source_message_id,

    'intent_code',
      v_decision.intent_code,

    'tool_code',
      v_decision.selected_tool_code,

    'binding_id',
      v_binding.id,

    'binding_scope',
      v_binding_scope,

    'resource_type',
      v_binding.resource_type,

    'resource_id',
      v_binding.resource_id,

    'existing_cotizacion_id',
      v_existing_cotizacion_id,

    'input_payload',
      v_input_payload
  );

end;
$function$;

alter function public.atlas_internal_resolve_tool_input(p_decision_id uuid) owner to postgres;
revoke all on function public.atlas_internal_resolve_tool_input(p_decision_id uuid) from public;
revoke all on function public.atlas_internal_resolve_tool_input(p_decision_id uuid) from anon;
grant execute on function public.atlas_internal_resolve_tool_input(p_decision_id uuid) to postgres;
grant execute on function public.atlas_internal_resolve_tool_input(p_decision_id uuid) to authenticated;
grant execute on function public.atlas_internal_resolve_tool_input(p_decision_id uuid) to service_role;
CREATE OR REPLACE FUNCTION public.atlas_internal_prepare_resolved_tool_request(p_decision_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();

  v_resolution jsonb;
  v_input_payload jsonb;
  v_preparation jsonb;

begin

  -- ==========================================================
  -- 1. AUTENTICACIÓN
  -- ==========================================================

  if v_user_id is null then
    raise exception 'ATLAS_AUTH_REQUIRED';
  end if;

  if p_decision_id is null then
    raise exception 'ATLAS_DECISION_ID_REQUIRED';
  end if;

  -- ==========================================================
  -- 2. RESOLVER INPUT OPERACIONAL
  -- ==========================================================

  v_resolution :=
    public.atlas_internal_resolve_tool_input(
      p_decision_id
    );

  if coalesce(
       (v_resolution ->> 'safe_to_continue')::boolean,
       false
     ) is not true
  then
    raise exception 'ATLAS_TOOL_INPUT_RESOLUTION_NOT_SAFE';
  end if;

  if v_resolution ->> 'resolution_status'
       <> 'RESOLVED'
  then
    raise exception 'ATLAS_TOOL_INPUT_NOT_RESOLVED';
  end if;

  if v_resolution ->> 'decision_id'
       <> p_decision_id::text
  then
    raise exception 'ATLAS_TOOL_INPUT_DECISION_MISMATCH';
  end if;

  -- ==========================================================
  -- 3. EXTRAER PAYLOAD OPERACIONAL
  -- ==========================================================

  v_input_payload :=
    v_resolution -> 'input_payload';

  if v_input_payload is null
     or jsonb_typeof(v_input_payload) <> 'object'
     or v_input_payload = '{}'::jsonb
  then
    raise exception 'ATLAS_RESOLVED_INPUT_PAYLOAD_INVALID';
  end if;

  -- ==========================================================
  -- 4. CORRELACIÓN CANÓNICA PARA AUDITORÍA Y FINAL RESPONSE
  --
  -- Estos valores provienen de la decisión validada y del
  -- resolver gobernado. Nunca vienen del LLM como UUID libre.
  -- ==========================================================

  v_input_payload :=
    v_input_payload
    ||
    jsonb_build_object(
      'decision_id',
        p_decision_id,

      'intent_code',
        v_resolution ->> 'intent_code',

      'runtime_version',
        'INTERNAL_RESOLVED_TOOL_PREPARER_V2'
    );

  -- ==========================================================
  -- 5. DEFENSAS ESPECÍFICAS QUOTE_CREATE
  -- ==========================================================

  if v_resolution ->> 'tool_code'
       = 'ATLAS_QUOTE_CREATE_INTERNAL'
  then

    if nullif(
         v_input_payload ->> 'quote_builder_id',
         ''
       ) is null
    then
      raise exception 'ATLAS_RESOLVED_QUOTE_BUILDER_MISSING';
    end if;

    if nullif(
         v_input_payload ->> 'catalogo_id',
         ''
       ) is null
    then
      raise exception 'ATLAS_RESOLVED_CATALOG_MISSING';
    end if;

    if nullif(
         v_input_payload ->> 'idempotency_key',
         ''
       ) is null
    then
      raise exception 'ATLAS_RESOLVED_IDEMPOTENCY_KEY_MISSING';
    end if;

    if v_input_payload ->> 'decision_id'
         <> p_decision_id::text
    then
      raise exception 'ATLAS_RESOLVED_DECISION_CORRELATION_INVALID';
    end if;

    if v_input_payload ->> 'intent_code'
         <> 'QUOTE_CREATE'
    then
      raise exception 'ATLAS_RESOLVED_INTENT_CORRELATION_INVALID';
    end if;

  else

    raise exception
      'ATLAS_RESOLVED_TOOL_PREPARATION_NOT_IMPLEMENTED';

  end if;

  -- ==========================================================
  -- 6. DELEGAR PREPARACIÓN AL CONTRATO Q7
  -- ==========================================================

  v_preparation :=
    public.atlas_internal_prepare_tool_request(
      p_decision_id,
      v_input_payload
    );

  if nullif(
       v_preparation ->> 'tool_request_id',
       ''
     ) is null
  then
    raise exception 'ATLAS_TOOL_REQUEST_PREPARATION_FAILED';
  end if;

  if v_preparation ->> 'decision_id'
       <> p_decision_id::text
  then
    raise exception 'ATLAS_PREPARED_REQUEST_DECISION_MISMATCH';
  end if;

  if v_preparation ->> 'tool_code'
       <> v_resolution ->> 'tool_code'
  then
    raise exception 'ATLAS_PREPARED_REQUEST_TOOL_MISMATCH';
  end if;

  -- ==========================================================
  -- 7. RESPUESTA CANÓNICA
  -- ==========================================================

  return jsonb_build_object(
    'preparation_status',
      'PREPARED',

    'safe_to_continue',
      true,

    'runtime_version',
      'INTERNAL_RESOLVED_TOOL_PREPARER_V2',

    'decision_id',
      p_decision_id,

    'empresa_id',
      v_resolution -> 'empresa_id',

    'conversation_id',
      v_resolution -> 'conversation_id',

    'source_message_id',
      v_resolution -> 'source_message_id',

    'tool_code',
      v_resolution ->> 'tool_code',

    'binding_id',
      v_resolution -> 'binding_id',

    'binding_scope',
      v_resolution ->> 'binding_scope',

    'resource_type',
      v_resolution ->> 'resource_type',

    'resource_id',
      v_resolution -> 'resource_id',

    'input_payload',
      v_input_payload,

    'resolution',
      v_resolution,

    'tool_request',
      v_preparation,

    'tool_request_id',
      v_preparation -> 'tool_request_id',

    'request_reused',
      coalesce(
        (v_preparation ->> 'reused')::boolean,
        false
      )
  );

end;
$function$;

alter function public.atlas_internal_prepare_resolved_tool_request(p_decision_id uuid) owner to postgres;
revoke all on function public.atlas_internal_prepare_resolved_tool_request(p_decision_id uuid) from public;
revoke all on function public.atlas_internal_prepare_resolved_tool_request(p_decision_id uuid) from anon;
grant execute on function public.atlas_internal_prepare_resolved_tool_request(p_decision_id uuid) to postgres;
grant execute on function public.atlas_internal_prepare_resolved_tool_request(p_decision_id uuid) to authenticated;
grant execute on function public.atlas_internal_prepare_resolved_tool_request(p_decision_id uuid) to service_role;


commit;
