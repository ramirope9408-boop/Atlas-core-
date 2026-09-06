-- ATLAS B2.2E.1
-- Nucleo juridico y contractual versionado por instalacion.
-- Corte: 2026-08-29
--
-- Prerrequisito: B2.2D.3 instalado y certificado.
--
-- Alcance deliberado:
-- - cataloga C01-C15 con aplicabilidad y gate objetivo;
-- - crea contratos/documentos versionados por expediente;
-- - separa aplicabilidad, ciclo documental y revision profesional;
-- - conserva eventos juridicos append-only;
-- - no habilita escritura hasta B2.2E.2;
-- - ningun texto se declara juridicamente definitivo sin revision profesional.

begin;

do $$
begin
  if to_regclass(
    'public.atlas_installation_diagnostic_decisions'
  ) is null
     or to_regprocedure(
       'public.atlas_decide_conditional_requirement(uuid,text,text,text,text,jsonb,uuid,integer,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception 'B2.2E.1 requiere B2.2D.3 instalado y certificado';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_LEGAL_READ',
    'Consultar documentos, versiones y eventos juridicos de instalacion.'
  ),
  (
    'INSTALLATION_LEGAL_MANAGE',
    'Registrar y revisar documentos juridicos mediante RPC gobernada.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_LEGAL_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_LEGAL_MANAGE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_LEGAL_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_LEGAL_MANAGE'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_LEGAL_READ'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_LEGAL_MANAGE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_LEGAL_READ')
on conflict (role_code, permission_code) do nothing;

create table if not exists public.atlas_legal_document_definitions (
  document_code text primary key,
  display_name text not null,
  description text not null,
  document_category text not null,
  default_applicability text not null,
  target_gate_code text,
  lifecycle_stage text not null,
  professional_review_required boolean not null default true,
  legal_finality text not null
    default 'DRAFT_PENDING_PROFESSIONAL_REVIEW',
  active boolean not null default true,
  sort_order integer not null,
  applicability_rule jsonb not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_legal_definitions_code_check
    check (document_code ~ '^C(0[1-9]|1[0-5])$'),
  constraint atlas_legal_definitions_category_check
    check (
      document_category in (
        'COMMERCIAL',
        'MASTER_AGREEMENT',
        'SCOPE',
        'IMPLEMENTATION',
        'DATA_PROTECTION',
        'SECURITY',
        'SUPPORT',
        'ACCEPTABLE_USE',
        'CHANNELS',
        'VOICE',
        'CONFIDENTIALITY',
        'ACCEPTANCE',
        'CERTIFICATION',
        'CHANGE_ORDER',
        'EXIT'
      )
    ),
  constraint atlas_legal_definitions_applicability_check
    check (
      default_applicability in (
        'REQUIRED',
        'CONDITIONAL',
        'POST_ACTIVATION'
      )
    ),
  constraint atlas_legal_definitions_gate_check
    check (target_gate_code is null or target_gate_code in ('G01', 'G04')),
  constraint atlas_legal_definitions_stage_check
    check (
      lifecycle_stage in (
        'CONTRACTING',
        'IMPLEMENTATION',
        'ACCEPTANCE',
        'POST_ACTIVATION',
        'EXIT'
      )
    ),
  constraint atlas_legal_definitions_finality_check
    check (legal_finality = 'DRAFT_PENDING_PROFESSIONAL_REVIEW'),
  constraint atlas_legal_definitions_order_check
    check (sort_order between 1 and 15),
  constraint atlas_legal_definitions_rule_check
    check (
      jsonb_typeof(applicability_rule) = 'object'
      and applicability_rule <> '{}'::jsonb
      and nullif(btrim(applicability_rule->>'reason'), '') is not null
    ),
  constraint atlas_legal_definitions_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

insert into public.atlas_legal_document_definitions (
  document_code,
  display_name,
  description,
  document_category,
  default_applicability,
  target_gate_code,
  lifecycle_stage,
  professional_review_required,
  legal_finality,
  active,
  sort_order,
  applicability_rule,
  metadata
)
values
  ('C01', 'Propuesta comercial o cotizacion', 'Alcance, precio, vigencia, pagos, supuestos y exclusiones.', 'COMMERCIAL', 'REQUIRED', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 1, jsonb_build_object('reason', 'Define la oferta economica y funcional aceptada.'), '{}'::jsonb),
  ('C02', 'Contrato marco de servicios tecnologicos', 'Contrato principal entre Atlas y la empresa cliente.', 'MASTER_AGREEMENT', 'REQUIRED', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 2, jsonb_build_object('reason', 'Gobierna la relacion juridica principal.'), '{}'::jsonb),
  ('C03', 'Orden de servicio o anexo de alcance', 'Productos, agentes, canales, integraciones y entregables contratados.', 'SCOPE', 'REQUIRED', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 3, jsonb_build_object('reason', 'Delimita el alcance especifico por cliente.'), '{}'::jsonb),
  ('C04', 'Anexo de implementacion e instalacion', 'Gates, prerrequisitos, tiempos, pruebas, pausas y rollback.', 'IMPLEMENTATION', 'REQUIRED', 'G01', 'IMPLEMENTATION', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 4, jsonb_build_object('reason', 'Regula el proceso tecnico de incorporacion.'), '{}'::jsonb),
  ('C05', 'Acuerdo de tratamiento de datos DPA', 'Roles, instrucciones, medidas, subencargados y salida de datos.', 'DATA_PROTECTION', 'CONDITIONAL', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 5, jsonb_build_object('reason', 'Aplica cuando Atlas trata datos por cuenta del cliente.', 'condition', 'PROCESSOR_ROLE_APPLIES'), '{}'::jsonb),
  ('C06', 'Anexo de seguridad de la informacion', 'Controles, accesos, aislamiento, incidentes y continuidad.', 'SECURITY', 'REQUIRED', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 6, jsonb_build_object('reason', 'Documenta responsabilidades y controles de seguridad.'), '{}'::jsonb),
  ('C07', 'SLA y politica de soporte', 'Horarios, severidades, objetivos, exclusiones y escalamiento.', 'SUPPORT', 'REQUIRED', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 7, jsonb_build_object('reason', 'Define el servicio y soporte comprometido.'), '{}'::jsonb),
  ('C08', 'Politica de uso aceptable e IA', 'Usos permitidos, transparencia, supervision y prohibiciones.', 'ACCEPTABLE_USE', 'REQUIRED', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 8, jsonb_build_object('reason', 'Gobierna el uso seguro y licito de la automatizacion.'), '{}'::jsonb),
  ('C09', 'Anexo de canales y proveedores', 'Titularidad, terceros, costos, bloqueos, portabilidad y desconexion.', 'CHANNELS', 'CONDITIONAL', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 9, jsonb_build_object('reason', 'Aplica cuando se conectan canales o proveedores externos.', 'condition', 'EXTERNAL_CHANNEL_OR_PROVIDER_ENABLED'), '{}'::jsonb),
  ('C10', 'Anexo de voz, llamadas y comunicaciones', 'Consentimientos, horarios, grabacion, retencion y consumos.', 'VOICE', 'CONDITIONAL', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 10, jsonb_build_object('reason', 'Aplica cuando se contratan voz o llamadas.', 'condition', 'VOICE_OR_CALLS_ENABLED'), '{}'::jsonb),
  ('C11', 'Acuerdo de confidencialidad NDA', 'Protege informacion tecnica, comercial y secretos empresariales.', 'CONFIDENTIALITY', 'CONDITIONAL', 'G01', 'CONTRACTING', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 11, jsonb_build_object('reason', 'Aplica cuando el riesgo o intercambio previo exige confidencialidad separada.', 'condition', 'SEPARATE_NDA_REQUIRED'), '{}'::jsonb),
  ('C12', 'Acta de entrega, pruebas y aceptacion', 'Entregables, resultados, observaciones, defectos y aceptacion.', 'ACCEPTANCE', 'REQUIRED', 'G04', 'ACCEPTANCE', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 12, jsonb_build_object('reason', 'Registra la aceptacion verificable del resultado.'), '{}'::jsonb),
  ('C13', 'Certificado de instalacion Atlas', 'Version, capacidades, gates, evidencias y restricciones.', 'CERTIFICATION', 'REQUIRED', 'G04', 'ACCEPTANCE', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 13, jsonb_build_object('reason', 'Certifica tecnicamente la instalacion concluida.'), '{}'::jsonb),
  ('C14', 'Orden de cambio', 'Impactos, costos, aprobadores, version y reversión.', 'CHANGE_ORDER', 'POST_ACTIVATION', null, 'POST_ACTIVATION', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 14, jsonb_build_object('reason', 'Se genera cuando un cambio material altera el alcance aprobado.', 'condition', 'MATERIAL_CHANGE_REQUESTED'), '{}'::jsonb),
  ('C15', 'Acta de suspension, terminacion y salida', 'Revocacion, desconexion, exportacion, retencion y eliminacion.', 'EXIT', 'POST_ACTIVATION', null, 'EXIT', true, 'DRAFT_PENDING_PROFESSIONAL_REVIEW', true, 15, jsonb_build_object('reason', 'Se genera ante suspension, terminacion o salida.'), '{}'::jsonb)
on conflict (document_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  document_category = excluded.document_category,
  default_applicability = excluded.default_applicability,
  target_gate_code = excluded.target_gate_code,
  lifecycle_stage = excluded.lifecycle_stage,
  professional_review_required = excluded.professional_review_required,
  legal_finality = excluded.legal_finality,
  active = excluded.active,
  sort_order = excluded.sort_order,
  applicability_rule = excluded.applicability_rule,
  metadata = excluded.metadata,
  updated_at = now();

create table if not exists public.atlas_installation_contracts (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  document_code text not null,
  document_version integer not null,
  applicability_status text not null,
  lifecycle_status text not null default 'PENDING',
  professional_review_status text not null default 'PENDING',
  source_file_id uuid,
  document_payload jsonb not null,
  content_sha256 text not null,
  effective_from timestamptz,
  effective_until timestamptz,
  reviewed_by_user_id uuid,
  reviewed_at timestamptz,
  signed_by_user_id uuid,
  signed_at timestamptz,
  signature_method text,
  signature_evidence jsonb not null default '{}'::jsonb,
  supersedes_contract_id uuid,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_contracts_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_installation_contracts_version_key
    unique (installation_id, document_code, document_version),
  constraint atlas_installation_contracts_hash_key
    unique (installation_id, document_code, content_sha256),
  constraint atlas_installation_contracts_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_contracts_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_contracts_definition_fkey
    foreign key (document_code)
    references public.atlas_legal_document_definitions(document_code)
    on delete restrict,
  constraint atlas_installation_contracts_source_file_fkey
    foreign key (source_file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_installation_contracts_reviewed_by_fkey
    foreign key (reviewed_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_contracts_signed_by_fkey
    foreign key (signed_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_contracts_supersedes_fkey
    foreign key (supersedes_contract_id)
    references public.atlas_installation_contracts(id)
    on delete restrict,
  constraint atlas_installation_contracts_created_by_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_contracts_version_check
    check (document_version >= 1),
  constraint atlas_installation_contracts_applicability_check
    check (
      applicability_status in (
        'REQUIRED',
        'CONDITIONAL',
        'NOT_APPLICABLE',
        'POST_ACTIVATION'
      )
    ),
  constraint atlas_installation_contracts_lifecycle_check
    check (
      lifecycle_status in (
        'PENDING',
        'DRAFT',
        'UNDER_REVIEW',
        'READY_FOR_SIGNATURE',
        'SIGNED',
        'REJECTED',
        'SUPERSEDED'
      )
    ),
  constraint atlas_installation_contracts_professional_review_check
    check (
      professional_review_status in (
        'PENDING',
        'IN_REVIEW',
        'REQUIRES_CHANGES',
        'APPROVED'
      )
      and (
        (
          professional_review_status = 'PENDING'
          and reviewed_by_user_id is null
          and reviewed_at is null
        )
        or (
          professional_review_status <> 'PENDING'
          and reviewed_by_user_id is not null
          and reviewed_at is not null
        )
      )
    ),
  constraint atlas_installation_contracts_signed_check
    check (
      (
        lifecycle_status = 'SIGNED'
        and professional_review_status = 'APPROVED'
        and source_file_id is not null
        and signed_by_user_id is not null
        and signed_at is not null
        and nullif(btrim(signature_method), '') is not null
        and signature_evidence <> '{}'::jsonb
      )
      or (
        lifecycle_status = 'SUPERSEDED'
        and (
          (
            signed_by_user_id is null
            and signed_at is null
            and signature_method is null
            and signature_evidence = '{}'::jsonb
          )
          or (
            professional_review_status = 'APPROVED'
            and source_file_id is not null
            and signed_by_user_id is not null
            and signed_at is not null
            and nullif(btrim(signature_method), '') is not null
            and signature_evidence <> '{}'::jsonb
          )
        )
      )
      or (
        lifecycle_status not in ('SIGNED', 'SUPERSEDED')
        and signed_by_user_id is null
        and signed_at is null
        and signature_method is null
        and signature_evidence = '{}'::jsonb
      )
    ),
  constraint atlas_installation_contracts_signature_readiness_check
    check (
      lifecycle_status <> 'READY_FOR_SIGNATURE'
      or professional_review_status = 'APPROVED'
    ),
  constraint atlas_installation_contracts_not_applicable_check
    check (
      applicability_status <> 'NOT_APPLICABLE'
      or lifecycle_status in ('PENDING', 'SUPERSEDED')
    ),
  constraint atlas_installation_contracts_sha256_check
    check (content_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_installation_contracts_payload_check
    check (
      jsonb_typeof(document_payload) = 'object'
      and document_payload <> '{}'::jsonb
      and document_payload ?& array[
        'document_code',
        'document_version'
      ]
      and document_payload->>'document_code' = document_code
      and document_payload->>'document_version' = document_version::text
      and not public.atlas_jsonb_has_forbidden_secret_key(document_payload)
    ),
  constraint atlas_installation_contracts_signature_evidence_check
    check (
      jsonb_typeof(signature_evidence) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(signature_evidence)
    ),
  constraint atlas_installation_contracts_validity_check
    check (
      effective_until is null
      or effective_from is null
      or effective_until > effective_from
    ),
  constraint atlas_installation_contracts_no_self_supersede_check
    check (supersedes_contract_id is null or supersedes_contract_id <> id),
  constraint atlas_installation_contracts_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create table if not exists public.atlas_installation_contract_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  contract_id uuid not null,
  document_code text not null,
  event_code text not null,
  from_lifecycle_status text,
  to_lifecycle_status text not null,
  from_review_status text,
  to_review_status text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  reason text not null,
  request_id uuid not null,
  document_version integer not null,
  content_sha256 text not null,
  evidence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_contract_events_request_key
    unique (contract_id, request_id),
  constraint atlas_contract_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_contract_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_contract_events_contract_fkey
    foreign key (contract_id)
    references public.atlas_installation_contracts(id)
    on delete restrict,
  constraint atlas_contract_events_definition_fkey
    foreign key (document_code)
    references public.atlas_legal_document_definitions(document_code)
    on delete restrict,
  constraint atlas_contract_events_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_contract_events_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_contract_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_contract_events_lifecycle_check
    check (
      to_lifecycle_status in (
        'PENDING',
        'DRAFT',
        'UNDER_REVIEW',
        'READY_FOR_SIGNATURE',
        'SIGNED',
        'REJECTED',
        'SUPERSEDED'
      )
      and (
        from_lifecycle_status is null
        or from_lifecycle_status in (
          'PENDING',
          'DRAFT',
          'UNDER_REVIEW',
          'READY_FOR_SIGNATURE',
          'SIGNED',
          'REJECTED',
          'SUPERSEDED'
        )
      )
    ),
  constraint atlas_contract_events_review_check
    check (
      to_review_status in (
        'PENDING',
        'IN_REVIEW',
        'REQUIRES_CHANGES',
        'APPROVED'
      )
      and (
        from_review_status is null
        or from_review_status in (
          'PENDING',
          'IN_REVIEW',
          'REQUIRES_CHANGES',
          'APPROVED'
        )
      )
    ),
  constraint atlas_contract_events_reason_check
    check (length(btrim(reason)) >= 10),
  constraint atlas_contract_events_version_check
    check (document_version >= 1),
  constraint atlas_contract_events_sha256_check
    check (content_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_contract_events_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
    ),
  constraint atlas_contract_events_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index if not exists idx_atlas_contracts_installation_status
  on public.atlas_installation_contracts (
    installation_id,
    lifecycle_status,
    professional_review_status,
    document_code
  );

create index if not exists idx_atlas_contracts_gate_ready
  on public.atlas_installation_contracts (
    installation_id,
    applicability_status,
    lifecycle_status,
    document_version desc
  );

create index if not exists idx_atlas_contract_events_timeline
  on public.atlas_installation_contract_events (
    installation_id,
    contract_id,
    created_at desc
  );

create or replace function public.atlas_block_contract_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_CONTRACT_EVENTS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_contract_event_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_contract_event_mutation()
  to service_role;

drop trigger if exists trg_atlas_contract_events_append_only
  on public.atlas_installation_contract_events;
create trigger trg_atlas_contract_events_append_only
before update or delete on public.atlas_installation_contract_events
for each row execute function public.atlas_block_contract_event_mutation();

drop trigger if exists trg_atlas_legal_definitions_updated_at
  on public.atlas_legal_document_definitions;
create trigger trg_atlas_legal_definitions_updated_at
before update on public.atlas_legal_document_definitions
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_installation_contracts_updated_at
  on public.atlas_installation_contracts;
create trigger trg_atlas_installation_contracts_updated_at
before update on public.atlas_installation_contracts
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_legal_document_definitions
  enable row level security;
alter table public.atlas_installation_contracts
  enable row level security;
alter table public.atlas_installation_contract_events
  enable row level security;

revoke all on table public.atlas_legal_document_definitions
  from anon, authenticated;
revoke all on table public.atlas_installation_contracts
  from anon, authenticated;
revoke all on table public.atlas_installation_contract_events
  from anon, authenticated;

grant select on table public.atlas_legal_document_definitions
  to authenticated;
grant select on table public.atlas_installation_contracts
  to authenticated;
grant select on table public.atlas_installation_contract_events
  to authenticated;

grant all on table public.atlas_legal_document_definitions
  to service_role;
grant all on table public.atlas_installation_contracts
  to service_role;
grant all on table public.atlas_installation_contract_events
  to service_role;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_legal_document_definitions'
      and policyname = 'atlas_legal_document_definitions_read'
  ) then
    execute $policy$
      create policy atlas_legal_document_definitions_read
        on public.atlas_legal_document_definitions
        for select to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_contracts'
      and policyname = 'atlas_installation_contracts_read'
  ) then
    execute $policy$
      create policy atlas_installation_contracts_read
        on public.atlas_installation_contracts
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_contract_events'
      and policyname = 'atlas_installation_contract_events_read'
  ) then
    execute $policy$
      create policy atlas_installation_contract_events_read
        on public.atlas_installation_contract_events
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_legal_document_definitions is
  'B2: catalogo C01-C15; borradores sujetos a revision juridica y contable profesional.';

comment on table public.atlas_installation_contracts is
  'B2: documentos juridicos versionados por expediente, con hash, vigencia, revision y firma.';

comment on table public.atlas_installation_contract_events is
  'B2: historial juridico append-only por documento y version.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2E1_LEGAL_CONTRACTUAL_CORE_INSTALLED',
  'next_block', 'B2.2E.2_CONTRACT_REGISTRATION_REVIEW_AND_SIGNATURE_RPCS',
  'legal_document_definitions', (
    select count(*)
    from public.atlas_legal_document_definitions
    where active = true
  ),
  'g01_document_definitions', (
    select count(*)
    from public.atlas_legal_document_definitions
    where active = true
      and target_gate_code = 'G01'
  ),
  'g04_document_definitions', (
    select count(*)
    from public.atlas_legal_document_definitions
    where active = true
      and target_gate_code = 'G04'
  ),
  'conditional_or_post_activation', (
    select count(*)
    from public.atlas_legal_document_definitions
    where active = true
      and default_applicability in ('CONDITIONAL', 'POST_ACTIVATION')
  ),
  'legal_tables_rls', (
    select count(*)
    from pg_class as c
    where c.oid in (
      'public.atlas_legal_document_definitions'::regclass,
      'public.atlas_installation_contracts'::regclass,
      'public.atlas_installation_contract_events'::regclass
    )
      and c.relrowsecurity = true
  ),
  'legal_permission_mappings', (
    select count(*)
    from public.atlas_internal_role_permissions
    where permission_code in (
      'INSTALLATION_LEGAL_READ',
      'INSTALLATION_LEGAL_MANAGE'
    )
  ),
  'contract_records', (
    select count(*)
    from public.atlas_installation_contracts
  ),
  'contract_event_records', (
    select count(*)
    from public.atlas_installation_contract_events
  ),
  'contract_write_rpcs', 0,
  'direct_authenticated_write', false,
  'professional_review_required', true,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  )
) as result;
