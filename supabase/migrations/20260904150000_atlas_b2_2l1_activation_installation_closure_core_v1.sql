-- ATLAS B2.2L.1
-- Nucleo de activacion y cierre de instalacion.
-- Corte: 2026-09-04
--
-- Modela requisitos, autorizacion final, cierre y eventos append-only.
-- No autoriza, no activa, no modifica G04 y no crea datos del piloto.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_verify_installation_certificate_history_integrity(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_g04_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_enforce_g04_active_transition_readiness()'
     ) is null
     or to_regclass(
       'public.atlas_installation_certificates'
     ) is null
     or to_regclass(
       'public.atlas_installation_acceptance_requirements'
     ) is null then
    raise exception
      'B2.2L.1 requiere B2.2K.4C instalado y certificado';
  end if;

  if to_regclass(
       'public.atlas_installation_activation_requirement_definitions'
     ) is not null
     or to_regclass(
       'public.atlas_installation_activation_authorizations'
     ) is not null
     or to_regclass(
       'public.atlas_installation_activation_closures'
     ) is not null
     or to_regclass(
       'public.atlas_installation_activation_events'
     ) is not null then
    raise exception
      'B2.2L.1 detecto estructuras de activacion previas; reconciliar antes de instalar';
  end if;
end;
$$;

insert into public.atlas_internal_permissions(
  permission_code, description
)
values
  (
    'INSTALLATION_ACTIVATION_READ',
    'Consultar requisitos, autorizaciones y cierre de activacion.'
  ),
  (
    'INSTALLATION_ACTIVATION_AUTHORIZE',
    'Autorizar o rechazar el ingreso a ACTIVE sobre evidencia vigente.'
  ),
  (
    'INSTALLATION_ACTIVATION_EXECUTE',
    'Ejecutar la activacion previamente autorizada y registrar su cierre.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions(
  role_code, permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_ACTIVATION_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_ACTIVATION_AUTHORIZE'),
  ('ATLAS_OWNER', 'INSTALLATION_ACTIVATION_EXECUTE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_ACTIVATION_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_ACTIVATION_EXECUTE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_ACTIVATION_READ'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_ACTIVATION_READ')
on conflict (role_code, permission_code) do nothing;

create or replace function
public.atlas_activation_evidence_reference_is_safe(
  p_reference text
)
returns boolean
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select
    length(p_reference) between 12 and 500
    and p_reference = btrim(p_reference)
    and p_reference !~ '[[:space:]?#@=]'
    and p_reference ~
      '^(activation|acceptance|certificate|gate|audit|support|commercial)://[A-Za-z0-9][A-Za-z0-9._:/-]+$'
$$;

revoke all on function
public.atlas_activation_evidence_reference_is_safe(text)
from public, anon, authenticated;
grant execute on function
public.atlas_activation_evidence_reference_is_safe(text)
to service_role;

create table
public.atlas_installation_activation_requirement_definitions (
  requirement_code text primary key,
  display_name text not null,
  description text not null,
  source_domain text not null,
  derivation_mode text not null,
  blocking boolean not null default true,
  sort_order integer not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_activation_requirement_code_check
    check (requirement_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_activation_requirement_text_check
    check (
      length(btrim(display_name)) between 5 and 160
      and length(btrim(description)) between 20 and 1000
    ),
  constraint atlas_activation_requirement_domain_check
    check (
      source_domain in (
        'G04', 'CERTIFICATE', 'DEFECT', 'GATES',
        'CLIENT_ACCEPTANCE', 'TECHNICAL_SECURITY',
        'COMMERCIAL', 'SUPPORT'
      )
    ),
  constraint atlas_activation_requirement_derivation_check
    check (
      derivation_mode in (
        'BACKEND_DERIVED', 'HUMAN_ATTESTED', 'HYBRID'
      )
    ),
  constraint atlas_activation_requirement_order_check
    check (sort_order between 1 and 100),
  constraint atlas_activation_requirement_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into
public.atlas_installation_activation_requirement_definitions (
  requirement_code, display_name, description, source_domain,
  derivation_mode, blocking, sort_order, active
)
values
  (
    'G04_READY_CURRENT',
    'G04 vigente y completo',
    'El gate final conserva sus ocho criterios, aprobaciones duales y evidencia vigentes.',
    'G04', 'BACKEND_DERIVED', true, 10, true
  ),
  (
    'EFFECTIVE_CERTIFICATE_VERIFIED',
    'Certificado efectivo verificado',
    'Existe exactamente un certificado efectivo, criptograficamente valido y vinculado al cierre.',
    'CERTIFICATE', 'BACKEND_DERIVED', true, 20, true
  ),
  (
    'ZERO_CRITICAL_DEFECTS',
    'Cero defectos criticos',
    'No existen defectos criticos abiertos, diferidos ni aceptados para iniciar operacion.',
    'DEFECT', 'BACKEND_DERIVED', true, 30, true
  ),
  (
    'ALL_GATES_APPROVED',
    'Gates completos y aprobados',
    'Los cuatro gates canonicos estan aprobados y sus decisiones conservan autoridad valida.',
    'GATES', 'BACKEND_DERIVED', true, 40, true
  ),
  (
    'CLIENT_ACCEPTANCE_CURRENT',
    'Aceptacion del cliente vigente',
    'La aceptacion del OWNER cliente corresponde al paquete, version y evidencia que seran activados.',
    'CLIENT_ACCEPTANCE', 'BACKEND_DERIVED', true, 50, true
  ),
  (
    'TECHNICAL_SECURITY_APPROVAL_CURRENT',
    'Aprobacion tecnica y de seguridad vigente',
    'Las aprobaciones tecnicas y de seguridad permanecen ligadas a las fuentes certificadas.',
    'TECHNICAL_SECURITY', 'BACKEND_DERIVED', true, 60, true
  ),
  (
    'COMMERCIAL_CONDITION_CURRENT',
    'Condicion comercial habilitante',
    'Atlas confirma de forma gobernada que la condicion comercial requerida permite la activacion.',
    'COMMERCIAL', 'HUMAN_ATTESTED', true, 70, true
  ),
  (
    'SUPPORT_PLAN_ASSIGNED',
    'Plan de soporte asignado',
    'La ventana de estabilizacion, el responsable y el plan de soporte inicial estan definidos.',
    'SUPPORT', 'HUMAN_ATTESTED', true, 80, true
  );

create table
public.atlas_installation_activation_authorizations (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  acceptance_package_id uuid not null,
  certificate_id uuid not null,
  g04_gate_id uuid not null,
  authorization_version integer not null,
  decision text not null,
  expected_installation_version bigint not null,
  source_g04_readiness_sha256 text not null,
  source_certificate_sha256 text not null,
  source_history_root_sha256 text not null,
  commercial_condition_code text not null,
  support_plan_code text not null,
  support_owner_user_id uuid not null,
  observation_window_hours integer not null,
  reason text not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  request_id uuid not null,
  request_sha256 text not null,
  authorized_by_user_id uuid not null,
  authorized_by_role_code text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_activation_authorizations_request_key
    unique (installation_id, request_id),
  constraint atlas_activation_authorizations_version_key
    unique (installation_id, authorization_version),
  constraint atlas_activation_authorizations_identity_key
    unique (id, installation_id, empresa_id),
  constraint atlas_activation_authorizations_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_activation_authorizations_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_activation_authorizations_package_fkey
    foreign key (
      acceptance_package_id, installation_id, empresa_id
    )
    references public.atlas_installation_acceptance_packages(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_activation_authorizations_certificate_fkey
    foreign key (certificate_id, installation_id, empresa_id)
    references public.atlas_installation_certificates(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_activation_authorizations_gate_fkey
    foreign key (g04_gate_id)
    references public.atlas_installation_gates(id)
    on delete restrict,
  constraint atlas_activation_authorizations_support_owner_fkey
    foreign key (support_owner_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_activation_authorizations_actor_fkey
    foreign key (authorized_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_activation_authorizations_role_fkey
    foreign key (authorized_by_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_activation_authorizations_decision_check
    check (
      decision in ('AUTHORIZED', 'REJECTED')
      and authorized_by_role_code = 'ATLAS_OWNER'
    ),
  constraint atlas_activation_authorizations_version_check
    check (
      authorization_version >= 1
      and expected_installation_version >= 1
    ),
  constraint atlas_activation_authorizations_hash_check
    check (
      source_g04_readiness_sha256 ~ '^[0-9a-f]{64}$'
      and source_certificate_sha256 ~ '^[0-9a-f]{64}$'
      and source_history_root_sha256 ~ '^[0-9a-f]{64}$'
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
      and request_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_activation_authorizations_codes_check
    check (
      commercial_condition_code ~ '^[A-Z][A-Z0-9_]*$'
      and support_plan_code ~ '^[A-Z][A-Z0-9_-]*$'
      and length(commercial_condition_code) between 5 and 100
      and length(support_plan_code) between 5 and 100
    ),
  constraint atlas_activation_authorizations_window_check
    check (observation_window_hours between 24 and 720),
  constraint atlas_activation_authorizations_reason_check
    check (length(btrim(reason)) between 10 and 2000),
  constraint atlas_activation_authorizations_evidence_check
    check (
      public.atlas_activation_evidence_reference_is_safe(
        evidence_reference
      )
    ),
  constraint atlas_activation_authorizations_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create unique index uq_atlas_activation_one_authorized
  on public.atlas_installation_activation_authorizations(
    installation_id
  )
  where decision = 'AUTHORIZED';

create index idx_atlas_activation_authorizations_timeline
  on public.atlas_installation_activation_authorizations(
    installation_id, authorization_version desc, created_at desc
  );

create table public.atlas_installation_activation_closures (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  activation_authorization_id uuid not null,
  acceptance_package_id uuid not null,
  certificate_id uuid not null,
  g04_gate_id uuid not null,
  activation_state_event_id uuid not null,
  closure_version integer not null,
  activated_installation_version bigint not null,
  final_state_code text not null,
  closure_contract_version text not null,
  source_authorization_sha256 text not null,
  source_certificate_sha256 text not null,
  source_history_root_sha256 text not null,
  closure_payload jsonb not null,
  closure_sha256 text not null,
  activated_at timestamptz not null,
  observation_window_ends_at timestamptz not null,
  closed_by_user_id uuid not null,
  closed_by_role_code text not null,
  request_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_activation_closures_installation_key
    unique (installation_id),
  constraint atlas_activation_closures_request_key
    unique (installation_id, request_id),
  constraint atlas_activation_closures_identity_key
    unique (id, installation_id, empresa_id),
  constraint atlas_activation_closures_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_activation_closures_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_activation_closures_authorization_fkey
    foreign key (
      activation_authorization_id, installation_id, empresa_id
    )
    references public.atlas_installation_activation_authorizations(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_activation_closures_package_fkey
    foreign key (
      acceptance_package_id, installation_id, empresa_id
    )
    references public.atlas_installation_acceptance_packages(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_activation_closures_certificate_fkey
    foreign key (certificate_id, installation_id, empresa_id)
    references public.atlas_installation_certificates(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_activation_closures_gate_fkey
    foreign key (g04_gate_id)
    references public.atlas_installation_gates(id)
    on delete restrict,
  constraint atlas_activation_closures_state_event_fkey
    foreign key (activation_state_event_id)
    references public.atlas_installation_state_events(id)
    on delete restrict,
  constraint atlas_activation_closures_actor_fkey
    foreign key (closed_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_activation_closures_role_fkey
    foreign key (closed_by_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_activation_closures_state_check
    check (
      closure_version = 1
      and activated_installation_version >= 2
      and final_state_code = 'ACTIVE'
      and closure_contract_version =
        'B2_INSTALLATION_ACTIVATION_CLOSURE_V1'
    ),
  constraint atlas_activation_closures_hash_check
    check (
      source_authorization_sha256 ~ '^[0-9a-f]{64}$'
      and source_certificate_sha256 ~ '^[0-9a-f]{64}$'
      and source_history_root_sha256 ~ '^[0-9a-f]{64}$'
      and closure_sha256 ~ '^[0-9a-f]{64}$'
      and closure_sha256 = public.atlas_normalization_sha256(
        closure_payload::text
      )
    ),
  constraint atlas_activation_closures_payload_check
    check (
      jsonb_typeof(closure_payload) = 'object'
      and closure_payload->>'contract_version' =
        closure_contract_version
      and closure_payload->>'closure_id' = id::text
      and closure_payload->>'installation_id' =
        installation_id::text
      and closure_payload->>'activation_authorization_id' =
        activation_authorization_id::text
      and closure_payload->>'certificate_id' = certificate_id::text
      and closure_payload->>'final_state_code' = final_state_code
      and not public.atlas_jsonb_has_forbidden_secret_key(
        closure_payload
      )
    ),
  constraint atlas_activation_closures_time_check
    check (
      activated_at >= created_at
      and observation_window_ends_at > activated_at
    ),
  constraint atlas_activation_closures_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_activation_closures_timeline
  on public.atlas_installation_activation_closures(
    empresa_id, activated_at desc
  );

create table public.atlas_installation_activation_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  activation_authorization_id uuid,
  activation_closure_id uuid,
  event_type text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  executor_code text not null,
  request_id uuid not null,
  installation_version bigint not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  event_payload jsonb not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_activation_events_request_key
    unique (installation_id, event_type, request_id),
  constraint atlas_activation_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_activation_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_activation_events_authorization_fkey
    foreign key (activation_authorization_id)
    references public.atlas_installation_activation_authorizations(id)
    on delete restrict,
  constraint atlas_activation_events_closure_fkey
    foreign key (activation_closure_id)
    references public.atlas_installation_activation_closures(id)
    on delete restrict,
  constraint atlas_activation_events_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_activation_events_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_activation_events_type_check
    check (
      event_type in (
        'AUTHORIZATION_RECORDED', 'AUTHORIZATION_REJECTED',
        'ACTIVATION_STARTED', 'ACTIVATED', 'CLOSURE_RECORDED',
        'ACTIVATION_FAILED', 'OBSERVATION_STARTED',
        'OBSERVATION_COMPLETED'
      )
    ),
  constraint atlas_activation_events_executor_check
    check (executor_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_activation_events_version_check
    check (installation_version >= 1),
  constraint atlas_activation_events_evidence_check
    check (
      public.atlas_activation_evidence_reference_is_safe(
        evidence_reference
      )
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
      and jsonb_typeof(event_payload) = 'object'
      and event_payload <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        event_payload
      )
    ),
  constraint atlas_activation_events_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_activation_events_timeline
  on public.atlas_installation_activation_events(
    installation_id, created_at desc, id desc
  );

create or replace function
public.atlas_block_activation_append_only_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'INSTALLATION_ACTIVATION_RECORD_APPEND_ONLY';
end;
$$;

revoke all on function
public.atlas_block_activation_append_only_mutation()
from public, anon, authenticated;
grant execute on function
public.atlas_block_activation_append_only_mutation()
to service_role;

create trigger trg_atlas_activation_authorizations_append_only
before update or delete
on public.atlas_installation_activation_authorizations
for each row execute function
public.atlas_block_activation_append_only_mutation();

create trigger trg_atlas_activation_closures_append_only
before update or delete
on public.atlas_installation_activation_closures
for each row execute function
public.atlas_block_activation_append_only_mutation();

create trigger trg_atlas_activation_events_append_only
before update or delete
on public.atlas_installation_activation_events
for each row execute function
public.atlas_block_activation_append_only_mutation();

create trigger trg_atlas_activation_requirement_definitions_updated_at
before update
on public.atlas_installation_activation_requirement_definitions
for each row execute function public.atlas_set_updated_at();

alter table
public.atlas_installation_activation_requirement_definitions
  enable row level security;
alter table public.atlas_installation_activation_authorizations
  enable row level security;
alter table public.atlas_installation_activation_closures
  enable row level security;
alter table public.atlas_installation_activation_events
  enable row level security;

revoke all on table
  public.atlas_installation_activation_requirement_definitions,
  public.atlas_installation_activation_authorizations,
  public.atlas_installation_activation_closures,
  public.atlas_installation_activation_events
from anon, authenticated;

grant select on table
  public.atlas_installation_activation_requirement_definitions,
  public.atlas_installation_activation_authorizations,
  public.atlas_installation_activation_closures,
  public.atlas_installation_activation_events
to authenticated;

grant all on table
  public.atlas_installation_activation_requirement_definitions,
  public.atlas_installation_activation_authorizations,
  public.atlas_installation_activation_closures,
  public.atlas_installation_activation_events
to service_role;

create policy atlas_activation_requirement_definitions_read
on public.atlas_installation_activation_requirement_definitions
for select to authenticated
using (active);

create policy atlas_activation_authorizations_read
on public.atlas_installation_activation_authorizations
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

create policy atlas_activation_closures_read
on public.atlas_installation_activation_closures
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

create policy atlas_activation_events_read
on public.atlas_installation_activation_events
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

comment on table
public.atlas_installation_activation_authorizations is
  'B2: decisiones finales append-only de Atlas para autorizar o rechazar ACTIVE sobre evidencia vigente.';
comment on table public.atlas_installation_activation_closures is
  'B2: cierre tecnico inmutable de una instalacion que ingreso validamente a ACTIVE.';
comment on table public.atlas_installation_activation_events is
  'B2: ledger append-only de autoridad, ejecucion, cierre y observacion de la activacion.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2L1_ACTIVATION_INSTALLATION_CLOSURE_CORE_INSTALLED',
  'next_block',
    'B2.2L.2_ACTIVATION_READINESS_AND_AUTHORIZATION_RPCS',
  'activation_tables_rls', 4,
  'activation_requirement_definitions', 8,
  'activation_permission_mappings', 7,
  'append_only_tables', 3,
  'activation_authorizations', (
    select count(*)
    from public.atlas_installation_activation_authorizations
  ),
  'activation_closures', (
    select count(*)
    from public.atlas_installation_activation_closures
  ),
  'activation_events', (
    select count(*)
    from public.atlas_installation_activation_events
  ),
  'activation_write_rpcs', 0,
  'dual_authority_g04_preserved', true,
  'atlas_owner_final_authority_required', true,
  'effective_certificate_required', true,
  'commercial_condition_required', true,
  'support_plan_required', true,
  'observation_window_modelled', true,
  'closure_hash_lineage_required', true,
  'active_transition_enabled', false,
  'g04_auto_approval_enabled', false,
  'direct_authenticated_write', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
