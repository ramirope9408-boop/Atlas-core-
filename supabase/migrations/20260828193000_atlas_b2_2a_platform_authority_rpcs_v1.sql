-- ATLAS B2.2A.2
-- Autoridad de plataforma y RPCs gobernadas del expediente de instalacion.
-- Corte: 2026-08-28
--
-- Prerrequisito:
--   20260828190000_atlas_b2_2a_installation_core_v1.sql
--
-- Principios:
-- - la autoridad tecnica de Atlas se separa de la membresia del cliente;
-- - ningun OWNER de cliente se convierte automaticamente en operador Atlas;
-- - el primer ATLAS_OWNER se habilita mediante bootstrap unico y gobernado;
-- - las escrituras se realizan exclusivamente mediante RPC SECURITY DEFINER;
-- - los RPC son idempotentes y registran eventos append-only.

begin;

do $$
begin
  if to_regclass('public.atlas_installations') is null
     or to_regclass('public.atlas_installation_state_events') is null
     or to_regclass('public.atlas_installation_state_transitions') is null then
    raise exception 'B2.2A.2 requiere B2.2A.1 instalado';
  end if;

  if to_regclass('public.atlas_internal_roles') is null
     or to_regclass('public.atlas_internal_permissions') is null
     or to_regclass('public.atlas_internal_role_permissions') is null
     or to_regclass('public.atlas_internal_memberships') is null then
    raise exception 'B2.2A.2 requiere el RBAC interno canonico de Atlas';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  ('INSTALLATION_READ', 'Consultar expedientes de instalacion administrados por Atlas.'),
  ('INSTALLATION_CREATE', 'Crear expedientes de instalacion mediante RPC gobernada.'),
  ('INSTALLATION_TRANSITION', 'Ejecutar transiciones autorizadas del expediente de instalacion.'),
  ('PLATFORM_STAFF_MANAGE', 'Administrar membresias internas del personal de plataforma Atlas.')
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_roles (
  role_code,
  display_name,
  description,
  priority,
  active
)
values
  ('ATLAS_OWNER', 'Atlas Owner', 'Autoridad propietaria global de la plataforma Atlas.', 1, true),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'Atlas Implementation Operator', 'Opera expedientes e instalaciones empresariales.', 20, true),
  ('ATLAS_LEGAL_REVIEWER', 'Atlas Legal Reviewer', 'Revisa requisitos juridicos y contractuales.', 30, true),
  ('ATLAS_SECURITY_REVIEWER', 'Atlas Security Reviewer', 'Revisa seguridad, aislamiento e integraciones.', 30, true),
  ('ATLAS_SUPPORT_OPERATOR', 'Atlas Support Operator', 'Consulta instalaciones para soporte y estabilizacion.', 40, true)
on conflict (role_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  priority = excluded.priority,
  active = excluded.active;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_CREATE'),
  ('ATLAS_OWNER', 'INSTALLATION_TRANSITION'),
  ('ATLAS_OWNER', 'PLATFORM_STAFF_MANAGE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_CREATE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_TRANSITION'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_READ'),
  ('ATLAS_SUPPORT_OPERATOR', 'INSTALLATION_READ')
on conflict (role_code, permission_code) do nothing;

create table if not exists public.atlas_platform_memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  role_code text not null,
  display_name text,
  status text not null default 'ACTIVE',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_platform_memberships_user_role_key
    unique (user_id, role_code),
  constraint atlas_platform_memberships_user_id_fkey
    foreign key (user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_platform_memberships_role_code_fkey
    foreign key (role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_platform_memberships_status_check
    check (status in ('ACTIVE', 'SUSPENDED', 'REVOKED')),
  constraint atlas_platform_memberships_role_scope_check
    check (role_code ~ '^ATLAS_[A-Z0-9_]+$'),
  constraint atlas_platform_memberships_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_atlas_platform_memberships_user_active
  on public.atlas_platform_memberships (user_id, status, role_code);

drop trigger if exists trg_atlas_platform_memberships_updated_at
  on public.atlas_platform_memberships;
create trigger trg_atlas_platform_memberships_updated_at
before update on public.atlas_platform_memberships
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_platform_memberships enable row level security;

revoke all on table public.atlas_platform_memberships from anon, authenticated;
grant select on table public.atlas_platform_memberships to authenticated;
grant all on table public.atlas_platform_memberships to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_platform_memberships'
      and policyname = 'atlas_platform_memberships_select_own'
  ) then
    execute $policy$
      create policy atlas_platform_memberships_select_own
        on public.atlas_platform_memberships
        for select
        to authenticated
        using (user_id = auth.uid())
    $policy$;
  end if;
end;
$$;

create or replace function public.atlas_platform_has_permission(
  p_permission_code text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.atlas_platform_memberships as pm
    join public.atlas_internal_roles as r
      on r.role_code = pm.role_code
     and r.active = true
    join public.atlas_internal_role_permissions as rp
      on rp.role_code = pm.role_code
    where pm.user_id = auth.uid()
      and pm.status = 'ACTIVE'
      and rp.permission_code = p_permission_code
  );
$$;

revoke all on function public.atlas_platform_has_permission(text)
  from public, anon;
grant execute on function public.atlas_platform_has_permission(text)
  to authenticated, service_role;

create or replace function public.atlas_bootstrap_platform_owner(
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_display_name text;
  v_existing public.atlas_platform_memberships%rowtype;
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_request_id is null then
    raise exception using
      errcode = '22023',
      message = 'REQUEST_ID_REQUIRED';
  end if;

  lock table public.atlas_platform_memberships in exclusive mode;

  select pm.*
  into v_existing
  from public.atlas_platform_memberships as pm
  where pm.user_id = v_user_id
    and pm.role_code = 'ATLAS_OWNER'
    and pm.status = 'ACTIVE'
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'platform_membership_id', v_existing.id,
      'user_id', v_existing.user_id,
      'role_code', v_existing.role_code,
      'status', v_existing.status
    );
  end if;

  if exists (
    select 1
    from public.atlas_platform_memberships as pm
    where pm.status = 'ACTIVE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'PLATFORM_ALREADY_BOOTSTRAPPED';
  end if;

  select im.display_name
  into v_display_name
  from public.atlas_internal_memberships as im
  where im.user_id = v_user_id
    and im.role_code = 'OWNER'
    and im.status = 'ACTIVE'
  order by im.created_at asc
  limit 1;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'ACTIVE_TENANT_OWNER_REQUIRED_FOR_BOOTSTRAP';
  end if;

  insert into public.atlas_platform_memberships (
    user_id,
    role_code,
    display_name,
    status,
    metadata
  )
  values (
    v_user_id,
    'ATLAS_OWNER',
    v_display_name,
    'ACTIVE',
    jsonb_build_object(
      'bootstrap_request_id', p_request_id,
      'bootstrap_version', 'B2_2A2_V1'
    )
  )
  returning * into v_existing;

  return jsonb_build_object(
    'ok', true,
    'code', 'PLATFORM_OWNER_BOOTSTRAPPED',
    'platform_membership_id', v_existing.id,
    'user_id', v_existing.user_id,
    'role_code', v_existing.role_code,
    'status', v_existing.status
  );
end;
$$;

revoke all on function public.atlas_bootstrap_platform_owner(uuid)
  from public, anon;
grant execute on function public.atlas_bootstrap_platform_owner(uuid)
  to authenticated, service_role;

create or replace function public.atlas_create_installation(
  p_empresa_id uuid,
  p_company_legal_name text,
  p_company_trade_name text,
  p_country_code text,
  p_city text,
  p_timezone text,
  p_currency_code text,
  p_implementation_tier text,
  p_client_owner_user_id uuid,
  p_request_id uuid,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_installation_id uuid := gen_random_uuid();
  v_installation_code text;
  v_company_legal_name text;
  v_company_trade_name text;
  v_country_code text;
  v_city text;
  v_timezone text;
  v_currency_code text;
  v_implementation_tier text;
  v_existing public.atlas_installations%rowtype;
  v_created public.atlas_installations%rowtype;
  v_empresa public.empresas%rowtype;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_CREATE') then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_CREATE_FORBIDDEN';
  end if;

  if p_request_id is null then
    raise exception using
      errcode = '22023',
      message = 'REQUEST_ID_REQUIRED';
  end if;

  if p_metadata is not null and jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'METADATA_MUST_BE_OBJECT';
  end if;

  select i.*
  into v_existing
  from public.atlas_installations as i
  where i.created_by_user_id = v_actor_user_id
    and i.idempotency_key = p_request_id
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.id,
      'installation_code', v_existing.installation_code,
      'empresa_id', v_existing.empresa_id,
      'state', v_existing.current_state_code,
      'version', v_existing.version
    );
  end if;

  if p_empresa_id is not null then
    select e.*
    into v_empresa
    from public.empresas as e
    where e.id = p_empresa_id
    limit 1;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'EMPRESA_NOT_FOUND';
    end if;
  end if;

  v_company_legal_name := coalesce(
    nullif(btrim(p_company_legal_name), ''),
    nullif(btrim(v_empresa.nombre), '')
  );

  if v_company_legal_name is null or length(v_company_legal_name) < 2 then
    raise exception using
      errcode = '22023',
      message = 'COMPANY_LEGAL_NAME_REQUIRED';
  end if;

  v_company_trade_name := coalesce(
    nullif(btrim(p_company_trade_name), ''),
    nullif(btrim(v_empresa.nombre_comercial), ''),
    v_company_legal_name
  );

  v_country_code := upper(coalesce(
    nullif(btrim(p_country_code), ''),
    case
      when length(nullif(btrim(v_empresa.pais), '')) = 2
        then btrim(v_empresa.pais)
      when upper(nullif(btrim(v_empresa.pais), '')) = 'COLOMBIA'
        then 'CO'
      else null
    end,
    'CO'
  ));

  v_city := coalesce(
    nullif(btrim(p_city), ''),
    nullif(btrim(v_empresa.ciudad), '')
  );

  v_timezone := coalesce(
    nullif(btrim(p_timezone), ''),
    nullif(btrim(v_empresa.zona_horaria), ''),
    'America/Bogota'
  );

  v_currency_code := upper(coalesce(
    nullif(btrim(p_currency_code), ''),
    'COP'
  ));

  v_implementation_tier := upper(coalesce(
    nullif(btrim(p_implementation_tier), ''),
    'STANDARD'
  ));

  if p_client_owner_user_id is not null
     and p_empresa_id is not null
     and not exists (
       select 1
       from public.atlas_internal_memberships as im
       where im.empresa_id = p_empresa_id
         and im.user_id = p_client_owner_user_id
         and im.role_code = 'OWNER'
         and im.status = 'ACTIVE'
     ) then
    raise exception using
      errcode = '22023',
      message = 'CLIENT_OWNER_MEMBERSHIP_NOT_ACTIVE';
  end if;

  select pm.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as pm
  join public.atlas_internal_roles as r
    on r.role_code = pm.role_code
  where pm.user_id = v_actor_user_id
    and pm.status = 'ACTIVE'
  order by r.priority asc, pm.created_at asc
  limit 1;

  v_installation_code := 'B2-'
    || to_char(clock_timestamp(), 'YYYYMMDD')
    || '-'
    || upper(substr(replace(v_installation_id::text, '-', ''), 1, 8));

  insert into public.atlas_installations (
    id,
    installation_code,
    empresa_id,
    manifest_version,
    current_state_code,
    resume_state_code,
    implementation_tier,
    company_legal_name,
    company_trade_name,
    country_code,
    city,
    timezone,
    currency_code,
    client_owner_user_id,
    responsible_atlas_user_id,
    created_by_user_id,
    idempotency_key,
    version,
    metadata
  )
  values (
    v_installation_id,
    v_installation_code,
    p_empresa_id,
    'B2_V1',
    'DRAFT',
    null,
    v_implementation_tier,
    v_company_legal_name,
    v_company_trade_name,
    v_country_code,
    v_city,
    v_timezone,
    v_currency_code,
    p_client_owner_user_id,
    v_actor_user_id,
    v_actor_user_id,
    p_request_id,
    1,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning * into v_created;

  insert into public.atlas_installation_state_events (
    installation_id,
    empresa_id,
    event_code,
    from_state_code,
    to_state_code,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    installation_version,
    evidence,
    metadata
  )
  values (
    v_created.id,
    v_created.empresa_id,
    'INSTALLATION_CREATED',
    null,
    'DRAFT',
    v_actor_user_id,
    v_actor_role_code,
    'Creacion gobernada del expediente B2',
    p_request_id,
    1,
    jsonb_build_object('manifest_version', v_created.manifest_version),
    '{}'::jsonb
  );

  if v_created.empresa_id is not null then
    insert into public.atlas_internal_audit_log (
      empresa_id,
      user_id,
      agent_code,
      conversation_id,
      action_type,
      tool_code,
      status,
      input_summary,
      output_summary,
      error_message
    )
    values (
      v_created.empresa_id,
      v_actor_user_id,
      null,
      null,
      'INSTALLATION_CREATED',
      'B2_INSTALLATION_CORE',
      'COMPLETED',
      jsonb_build_object(
        'request_id', p_request_id,
        'implementation_tier', v_created.implementation_tier
      ),
      jsonb_build_object(
        'installation_id', v_created.id,
        'installation_code', v_created.installation_code,
        'state', v_created.current_state_code,
        'version', v_created.version
      ),
      null
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CREATED',
    'installation_id', v_created.id,
    'installation_code', v_created.installation_code,
    'empresa_id', v_created.empresa_id,
    'state', v_created.current_state_code,
    'version', v_created.version
  );
end;
$$;

revoke all on function public.atlas_create_installation(
  uuid, text, text, text, text, text, text, text, uuid, uuid, jsonb
) from public, anon;
grant execute on function public.atlas_create_installation(
  uuid, text, text, text, text, text, text, text, uuid, uuid, jsonb
) to authenticated, service_role;

create or replace function public.atlas_transition_installation(
  p_installation_id uuid,
  p_to_state_code text,
  p_reason text,
  p_request_id uuid,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_target_state_code text := upper(btrim(p_to_state_code));
  v_installation public.atlas_installations%rowtype;
  v_transition public.atlas_installation_state_transitions%rowtype;
  v_existing_event public.atlas_installation_state_events%rowtype;
  v_from_state_code text;
  v_transition_code text;
  v_requires_reason boolean := false;
  v_requires_approval boolean := false;
  v_is_recovery boolean := false;
  v_new_resume_state_code text;
  v_new_version bigint;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TRANSITION') then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_TRANSITION_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or v_target_state_code is null
     or v_target_state_code = '' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_ID_TARGET_STATE_AND_REQUEST_ID_REQUIRED';
  end if;

  select i.*
  into v_installation
  from public.atlas_installations as i
  where i.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_NOT_FOUND';
  end if;

  v_from_state_code := v_installation.current_state_code;

  select ev.*
  into v_existing_event
  from public.atlas_installation_state_events as ev
  where ev.installation_id = p_installation_id
    and ev.request_id = p_request_id
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_installation.id,
      'state', v_existing_event.to_state_code,
      'version', v_existing_event.installation_version,
      'event_id', v_existing_event.id
    );
  end if;

  if p_expected_version is not null
     and p_expected_version <> v_installation.version then
    raise exception using
      errcode = '40001',
      message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code = v_target_state_code then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_IN_STATE',
      'installation_id', v_installation.id,
      'state', v_installation.current_state_code,
      'version', v_installation.version
    );
  end if;

  if exists (
    select 1
    from public.atlas_installation_states as s
    where s.state_code = v_installation.current_state_code
      and s.is_terminal = true
  ) then
    raise exception using
      errcode = '22023',
      message = 'TERMINAL_INSTALLATION_CANNOT_TRANSITION';
  end if;

  if not exists (
    select 1
    from public.atlas_installation_states as s
    where s.state_code = v_target_state_code
      and s.active = true
  ) then
    raise exception using
      errcode = '22023',
      message = 'TARGET_INSTALLATION_STATE_INVALID';
  end if;

  if v_installation.current_state_code in ('PAUSED', 'FAILED')
     and v_installation.resume_state_code = v_target_state_code then
    v_is_recovery := true;
    v_transition_code := 'RESUME_' || v_target_state_code;
    v_requires_reason := true;
    v_requires_approval := false;
  else
    select t.*
    into v_transition
    from public.atlas_installation_state_transitions as t
    where t.from_state_code = v_installation.current_state_code
      and t.to_state_code = v_target_state_code
      and t.active = true
    limit 1;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'INSTALLATION_TRANSITION_NOT_ALLOWED';
    end if;

    v_transition_code := v_transition.transition_code;
    v_requires_reason := v_transition.requires_reason;
    v_requires_approval := v_transition.requires_approval;
  end if;

  if v_requires_reason
     and nullif(btrim(p_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_TRANSITION_REASON_REQUIRED';
  end if;

  if v_requires_approval then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_APPROVAL_REQUIRED_B2_2B_PENDING';
  end if;

  if v_target_state_code in ('PAUSED', 'FAILED') then
    v_new_resume_state_code := coalesce(
      v_installation.resume_state_code,
      v_installation.current_state_code
    );
  elsif v_is_recovery
        or v_target_state_code in ('ROLLED_BACK', 'CANCELLED') then
    v_new_resume_state_code := null;
  else
    v_new_resume_state_code := v_installation.resume_state_code;
  end if;

  v_new_version := v_installation.version + 1;

  update public.atlas_installations
  set
    current_state_code = v_target_state_code,
    resume_state_code = v_new_resume_state_code,
    version = v_new_version,
    activated_at = case
      when v_target_state_code = 'ACTIVE'
        then coalesce(activated_at, now())
      else activated_at
    end,
    updated_at = now()
  where id = v_installation.id
  returning * into v_installation;

  select pm.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as pm
  join public.atlas_internal_roles as r
    on r.role_code = pm.role_code
  where pm.user_id = v_actor_user_id
    and pm.status = 'ACTIVE'
  order by r.priority asc, pm.created_at asc
  limit 1;

  insert into public.atlas_installation_state_events (
    installation_id,
    empresa_id,
    event_code,
    from_state_code,
    to_state_code,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    installation_version,
    evidence,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_transition_code,
    v_from_state_code,
    v_target_state_code,
    v_actor_user_id,
    v_actor_role_code,
    nullif(btrim(p_reason), ''),
    p_request_id,
    v_new_version,
    jsonb_build_object(
      'expected_version', p_expected_version,
      'recovery', v_is_recovery
    ),
    '{}'::jsonb
  );

  if v_installation.empresa_id is not null then
    insert into public.atlas_internal_audit_log (
      empresa_id,
      user_id,
      agent_code,
      conversation_id,
      action_type,
      tool_code,
      status,
      input_summary,
      output_summary,
      error_message
    )
    values (
      v_installation.empresa_id,
      v_actor_user_id,
      null,
      null,
      'INSTALLATION_STATE_TRANSITIONED',
      'B2_INSTALLATION_CORE',
      'COMPLETED',
      jsonb_build_object(
        'request_id', p_request_id,
        'to_state', v_target_state_code,
        'reason', nullif(btrim(p_reason), '')
      ),
      jsonb_build_object(
        'installation_id', v_installation.id,
        'state', v_installation.current_state_code,
        'version', v_installation.version
      ),
      null
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_TRANSITIONED',
    'installation_id', v_installation.id,
    'state', v_installation.current_state_code,
    'resume_state', v_installation.resume_state_code,
    'version', v_installation.version,
    'transition_code', v_transition_code
  );
end;
$$;

revoke all on function public.atlas_transition_installation(
  uuid, text, text, uuid, bigint
) from public, anon;
grant execute on function public.atlas_transition_installation(
  uuid, text, text, uuid, bigint
) to authenticated, service_role;

revoke all on table public.atlas_installations from anon, authenticated;
revoke all on table public.atlas_installation_state_events from anon, authenticated;
grant select on table public.atlas_installations to authenticated;
grant select on table public.atlas_installation_state_events to authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installations'
      and policyname = 'atlas_installations_platform_read'
  ) then
    execute $policy$
      create policy atlas_installations_platform_read
        on public.atlas_installations
        for select
        to authenticated
        using (public.atlas_platform_has_permission('INSTALLATION_READ'))
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_state_events'
      and policyname = 'atlas_installation_state_events_platform_read'
  ) then
    execute $policy$
      create policy atlas_installation_state_events_platform_read
        on public.atlas_installation_state_events
        for select
        to authenticated
        using (public.atlas_platform_has_permission('INSTALLATION_READ'))
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_platform_memberships is
  'B2: membresias globales del personal Atlas, separadas de los usuarios de cada tenant.';

comment on function public.atlas_platform_has_permission(text) is
  'B2: verifica permisos globales del personal Atlas para operaciones de plataforma.';

comment on function public.atlas_bootstrap_platform_owner(uuid) is
  'B2: bootstrap unico del primer ATLAS_OWNER a partir de un OWNER tenant activo.';

comment on function public.atlas_create_installation(
  uuid, text, text, text, text, text, text, text, uuid, uuid, jsonb
) is
  'B2: crea un expediente DRAFT de forma gobernada, idempotente y auditable.';

comment on function public.atlas_transition_installation(
  uuid, text, text, uuid, bigint
) is
  'B2: transiciona un expediente con bloqueo, version optimista, idempotencia y auditoria.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2A2_AUTHORITY_AND_RPCS_INSTALLED',
  'platform_roles', (
    select count(*)
    from public.atlas_internal_roles
    where role_code ~ '^ATLAS_[A-Z0-9_]+$'
      and active = true
  ),
  'platform_permissions', (
    select count(*)
    from public.atlas_internal_permissions
    where permission_code in (
      'INSTALLATION_READ',
      'INSTALLATION_CREATE',
      'INSTALLATION_TRANSITION',
      'PLATFORM_STAFF_MANAGE'
    )
  ),
  'platform_memberships', (
    select count(*)
    from public.atlas_platform_memberships
    where status = 'ACTIVE'
  ),
  'bootstrap_required', not exists (
    select 1
    from public.atlas_platform_memberships
    where role_code = 'ATLAS_OWNER'
      and status = 'ACTIVE'
  ),
  'direct_authenticated_write', false,
  'next_action', 'BOOTSTRAP_PLATFORM_OWNER'
) as result;
