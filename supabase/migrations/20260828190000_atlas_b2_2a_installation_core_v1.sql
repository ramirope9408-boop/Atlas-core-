-- ATLAS B2.2A.1
-- Expediente de instalacion y maquina de estados (schema base).
-- Corte: 2026-08-28
--
-- Esta migracion es deliberadamente interna:
-- - crea catalogos, expediente y bitacora de estados;
-- - no concede escritura directa a anon/authenticated;
-- - no crea aun RPCs de operacion ni autoridad de operadores Atlas;
-- - no modifica ni elimina estructuras existentes.

begin;

do $$
begin
  if to_regclass('public.empresas') is null then
    raise exception 'B2.2A requiere public.empresas';
  end if;

  if to_regclass('auth.users') is null then
    raise exception 'B2.2A requiere auth.users';
  end if;

  if not exists (
    select 1
    from pg_proc as p
    join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'atlas_set_updated_at'
  ) then
    raise exception 'B2.2A requiere public.atlas_set_updated_at()';
  end if;
end;
$$;

create table if not exists public.atlas_installation_states (
  state_code text primary key,
  display_name text not null,
  description text,
  state_category text not null,
  phase_order integer not null,
  is_terminal boolean not null default false,
  is_resumable boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_states_code_check
    check (state_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_installation_states_category_check
    check (state_category in ('PHASE', 'CONTROL', 'OPERATIONAL', 'TERMINAL')),
  constraint atlas_installation_states_phase_order_check
    check (phase_order >= 0)
);

create table if not exists public.atlas_installation_state_transitions (
  from_state_code text not null,
  to_state_code text not null,
  transition_code text not null,
  transition_kind text not null,
  requires_reason boolean not null default false,
  requires_approval boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_state_transitions_pkey
    primary key (from_state_code, to_state_code),
  constraint atlas_installation_state_transitions_code_key
    unique (transition_code),
  constraint atlas_installation_state_transitions_from_fkey
    foreign key (from_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_installation_state_transitions_to_fkey
    foreign key (to_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_installation_state_transitions_code_check
    check (transition_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_installation_state_transitions_kind_check
    check (transition_kind in ('FORWARD', 'REVIEW_RETURN', 'CONTROL', 'RECOVERY', 'TERMINAL')),
  constraint atlas_installation_state_transitions_distinct_check
    check (from_state_code <> to_state_code)
);

create table if not exists public.atlas_installations (
  id uuid primary key default gen_random_uuid(),
  installation_code text not null unique,
  empresa_id uuid,
  manifest_version text not null default 'B2_V1',
  current_state_code text not null default 'DRAFT',
  resume_state_code text,
  implementation_tier text not null default 'STANDARD',
  company_legal_name text not null,
  company_trade_name text,
  country_code text not null default 'CO',
  city text,
  timezone text not null default 'America/Bogota',
  currency_code text not null default 'COP',
  client_owner_user_id uuid,
  responsible_atlas_user_id uuid,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  version bigint not null default 1,
  target_activation_at timestamptz,
  activated_at timestamptz,
  risk_summary jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installations_empresa_id_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installations_current_state_fkey
    foreign key (current_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_installations_resume_state_fkey
    foreign key (resume_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_installations_client_owner_fkey
    foreign key (client_owner_user_id)
    references auth.users(id)
    on delete set null,
  constraint atlas_installations_responsible_atlas_user_fkey
    foreign key (responsible_atlas_user_id)
    references auth.users(id)
    on delete set null,
  constraint atlas_installations_created_by_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installations_creator_idempotency_key
    unique (created_by_user_id, idempotency_key),
  constraint atlas_installations_code_check
    check (installation_code ~ '^B2-[A-Z0-9-]+$'),
  constraint atlas_installations_manifest_version_check
    check (manifest_version ~ '^B2_V[0-9]+$'),
  constraint atlas_installations_tier_check
    check (implementation_tier in ('STANDARD', 'INTERMEDIATE', 'SPECIAL')),
  constraint atlas_installations_company_legal_name_check
    check (length(btrim(company_legal_name)) >= 2),
  constraint atlas_installations_country_code_check
    check (country_code ~ '^[A-Z]{2}$'),
  constraint atlas_installations_currency_code_check
    check (currency_code ~ '^[A-Z]{3}$'),
  constraint atlas_installations_timezone_check
    check (length(btrim(timezone)) >= 3),
  constraint atlas_installations_version_check
    check (version >= 1),
  constraint atlas_installations_resume_state_check
    check (resume_state_code is null or resume_state_code <> current_state_code),
  constraint atlas_installations_risk_summary_object_check
    check (jsonb_typeof(risk_summary) = 'object'),
  constraint atlas_installations_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create table if not exists public.atlas_installation_state_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid,
  event_code text not null,
  from_state_code text,
  to_state_code text not null,
  actor_user_id uuid not null,
  actor_role_code text,
  reason text,
  request_id uuid not null,
  installation_version bigint not null,
  evidence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_installation_state_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_state_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_state_events_from_state_fkey
    foreign key (from_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_installation_state_events_to_state_fkey
    foreign key (to_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_installation_state_events_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_state_events_request_key
    unique (installation_id, request_id),
  constraint atlas_installation_state_events_version_key
    unique (installation_id, installation_version),
  constraint atlas_installation_state_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_installation_state_events_version_check
    check (installation_version >= 1),
  constraint atlas_installation_state_events_evidence_object_check
    check (jsonb_typeof(evidence) = 'object'),
  constraint atlas_installation_state_events_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

insert into public.atlas_installation_states (
  state_code,
  display_name,
  description,
  state_category,
  phase_order,
  is_terminal,
  is_resumable,
  active
)
values
  ('DRAFT', 'Borrador', 'Expediente preliminar editable.', 'PHASE', 10, false, false, true),
  ('PACKAGE_RECEIVED', 'Paquete recibido', 'Paquete recibido y registrado.', 'PHASE', 20, false, false, true),
  ('SECURITY_VALIDATION', 'Validacion de seguridad', 'Archivos y fuentes bajo validacion de seguridad.', 'PHASE', 30, false, false, true),
  ('LEGAL_REVIEW', 'Revision juridica', 'Identidad, autorizaciones y documentos bajo revision.', 'PHASE', 40, false, false, true),
  ('LEGAL_APPROVED', 'Juridica aprobada', 'Gate juridico aprobado.', 'PHASE', 50, false, false, true),
  ('DATA_NORMALIZATION', 'Normalizacion de datos', 'Informacion en extraccion y normalizacion.', 'PHASE', 60, false, false, true),
  ('CLIENT_REVIEW', 'Revision del cliente', 'Vista previa pendiente de revision del cliente.', 'PHASE', 70, false, false, true),
  ('DATA_APPROVED', 'Datos aprobados', 'Version canonica aprobada.', 'PHASE', 80, false, false, true),
  ('PROVISIONING', 'Aprovisionamiento', 'Tenant y recursos en aprovisionamiento.', 'PHASE', 90, false, false, true),
  ('INTEGRATION_SETUP', 'Configuracion de integraciones', 'Adaptadores e integraciones en configuracion.', 'PHASE', 100, false, false, true),
  ('TESTING', 'Pruebas', 'Pruebas funcionales, tecnicas y de seguridad.', 'PHASE', 110, false, false, true),
  ('FINAL_APPROVAL', 'Aprobacion final', 'Resultados pendientes de aceptacion final.', 'PHASE', 120, false, false, true),
  ('ACTIVE', 'Activo', 'Tenant autorizado para operacion.', 'OPERATIONAL', 130, false, false, true),
  ('OBSERVED', 'En observacion', 'Operacion limitada bajo vigilancia reforzada.', 'OPERATIONAL', 140, false, true, true),
  ('PAUSED', 'Pausado', 'Ejecucion detenida de forma gobernada.', 'CONTROL', 900, false, true, true),
  ('FAILED', 'Fallido', 'Ejecucion fallida con evidencia y posibilidad de reparacion.', 'CONTROL', 910, false, true, true),
  ('ROLLED_BACK', 'Revertido', 'Instalacion revertida con evidencia.', 'TERMINAL', 990, true, false, true),
  ('CANCELLED', 'Cancelado', 'Expediente cancelado.', 'TERMINAL', 1000, true, false, true)
on conflict (state_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  state_category = excluded.state_category,
  phase_order = excluded.phase_order,
  is_terminal = excluded.is_terminal,
  is_resumable = excluded.is_resumable,
  active = excluded.active,
  updated_at = now();

insert into public.atlas_installation_state_transitions (
  from_state_code,
  to_state_code,
  transition_code,
  transition_kind,
  requires_reason,
  requires_approval,
  active
)
values
  ('DRAFT', 'PACKAGE_RECEIVED', 'RECEIVE_PACKAGE', 'FORWARD', false, false, true),
  ('PACKAGE_RECEIVED', 'SECURITY_VALIDATION', 'START_SECURITY_VALIDATION', 'FORWARD', false, false, true),
  ('SECURITY_VALIDATION', 'LEGAL_REVIEW', 'START_LEGAL_REVIEW', 'FORWARD', false, false, true),
  ('LEGAL_REVIEW', 'LEGAL_APPROVED', 'APPROVE_LEGAL', 'FORWARD', false, true, true),
  ('LEGAL_APPROVED', 'DATA_NORMALIZATION', 'START_DATA_NORMALIZATION', 'FORWARD', false, false, true),
  ('DATA_NORMALIZATION', 'CLIENT_REVIEW', 'SUBMIT_CLIENT_REVIEW', 'FORWARD', false, false, true),
  ('CLIENT_REVIEW', 'DATA_APPROVED', 'APPROVE_DATA', 'FORWARD', false, true, true),
  ('CLIENT_REVIEW', 'DATA_NORMALIZATION', 'RETURN_DATA_CORRECTION', 'REVIEW_RETURN', true, false, true),
  ('DATA_APPROVED', 'PROVISIONING', 'START_PROVISIONING', 'FORWARD', false, false, true),
  ('PROVISIONING', 'INTEGRATION_SETUP', 'START_INTEGRATION_SETUP', 'FORWARD', false, false, true),
  ('INTEGRATION_SETUP', 'TESTING', 'START_TESTING', 'FORWARD', false, false, true),
  ('TESTING', 'FINAL_APPROVAL', 'SUBMIT_FINAL_APPROVAL', 'FORWARD', false, false, true),
  ('FINAL_APPROVAL', 'ACTIVE', 'ACTIVATE_TENANT', 'FORWARD', false, true, true),
  ('FINAL_APPROVAL', 'TESTING', 'RETURN_TEST_CORRECTION', 'REVIEW_RETURN', true, false, true),
  ('ACTIVE', 'OBSERVED', 'START_OBSERVATION', 'CONTROL', true, false, true),
  ('OBSERVED', 'ACTIVE', 'COMPLETE_OBSERVATION', 'RECOVERY', true, true, true)
on conflict (from_state_code, to_state_code) do update
set
  transition_code = excluded.transition_code,
  transition_kind = excluded.transition_kind,
  requires_reason = excluded.requires_reason,
  requires_approval = excluded.requires_approval,
  active = excluded.active,
  updated_at = now();

with pause_sources(state_code) as (
  values
    ('PACKAGE_RECEIVED'),
    ('SECURITY_VALIDATION'),
    ('LEGAL_REVIEW'),
    ('LEGAL_APPROVED'),
    ('DATA_NORMALIZATION'),
    ('CLIENT_REVIEW'),
    ('DATA_APPROVED'),
    ('PROVISIONING'),
    ('INTEGRATION_SETUP'),
    ('TESTING'),
    ('FINAL_APPROVAL'),
    ('ACTIVE'),
    ('OBSERVED'),
    ('FAILED')
)
insert into public.atlas_installation_state_transitions (
  from_state_code,
  to_state_code,
  transition_code,
  transition_kind,
  requires_reason,
  requires_approval,
  active
)
select
  state_code,
  'PAUSED',
  state_code || '_TO_PAUSED',
  'CONTROL',
  true,
  false,
  true
from pause_sources
on conflict (from_state_code, to_state_code) do update
set
  transition_code = excluded.transition_code,
  transition_kind = excluded.transition_kind,
  requires_reason = excluded.requires_reason,
  requires_approval = excluded.requires_approval,
  active = excluded.active,
  updated_at = now();

with failure_sources(state_code) as (
  values
    ('SECURITY_VALIDATION'),
    ('DATA_NORMALIZATION'),
    ('PROVISIONING'),
    ('INTEGRATION_SETUP'),
    ('TESTING'),
    ('OBSERVED')
)
insert into public.atlas_installation_state_transitions (
  from_state_code,
  to_state_code,
  transition_code,
  transition_kind,
  requires_reason,
  requires_approval,
  active
)
select
  state_code,
  'FAILED',
  state_code || '_TO_FAILED',
  'CONTROL',
  true,
  false,
  true
from failure_sources
on conflict (from_state_code, to_state_code) do update
set
  transition_code = excluded.transition_code,
  transition_kind = excluded.transition_kind,
  requires_reason = excluded.requires_reason,
  requires_approval = excluded.requires_approval,
  active = excluded.active,
  updated_at = now();

with cancellation_sources(state_code) as (
  values
    ('DRAFT'),
    ('PACKAGE_RECEIVED'),
    ('SECURITY_VALIDATION'),
    ('LEGAL_REVIEW'),
    ('LEGAL_APPROVED'),
    ('DATA_NORMALIZATION'),
    ('CLIENT_REVIEW'),
    ('DATA_APPROVED'),
    ('PAUSED'),
    ('FAILED')
)
insert into public.atlas_installation_state_transitions (
  from_state_code,
  to_state_code,
  transition_code,
  transition_kind,
  requires_reason,
  requires_approval,
  active
)
select
  state_code,
  'CANCELLED',
  state_code || '_TO_CANCELLED',
  'TERMINAL',
  true,
  true,
  true
from cancellation_sources
on conflict (from_state_code, to_state_code) do update
set
  transition_code = excluded.transition_code,
  transition_kind = excluded.transition_kind,
  requires_reason = excluded.requires_reason,
  requires_approval = excluded.requires_approval,
  active = excluded.active,
  updated_at = now();

with rollback_sources(state_code) as (
  values
    ('PROVISIONING'),
    ('INTEGRATION_SETUP'),
    ('TESTING'),
    ('FINAL_APPROVAL'),
    ('FAILED')
)
insert into public.atlas_installation_state_transitions (
  from_state_code,
  to_state_code,
  transition_code,
  transition_kind,
  requires_reason,
  requires_approval,
  active
)
select
  state_code,
  'ROLLED_BACK',
  state_code || '_TO_ROLLED_BACK',
  'TERMINAL',
  true,
  true,
  true
from rollback_sources
on conflict (from_state_code, to_state_code) do update
set
  transition_code = excluded.transition_code,
  transition_kind = excluded.transition_kind,
  requires_reason = excluded.requires_reason,
  requires_approval = excluded.requires_approval,
  active = excluded.active,
  updated_at = now();

create index if not exists idx_atlas_installations_empresa_state
  on public.atlas_installations (empresa_id, current_state_code, updated_at desc);

create index if not exists idx_atlas_installations_creator
  on public.atlas_installations (created_by_user_id, created_at desc);

create index if not exists idx_atlas_installations_state
  on public.atlas_installations (current_state_code, updated_at desc);

create index if not exists idx_atlas_installation_state_events_timeline
  on public.atlas_installation_state_events (installation_id, installation_version desc);

create index if not exists idx_atlas_installation_state_events_empresa
  on public.atlas_installation_state_events (empresa_id, created_at desc);

drop trigger if exists trg_atlas_installation_states_updated_at
  on public.atlas_installation_states;
create trigger trg_atlas_installation_states_updated_at
before update on public.atlas_installation_states
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_installation_state_transitions_updated_at
  on public.atlas_installation_state_transitions;
create trigger trg_atlas_installation_state_transitions_updated_at
before update on public.atlas_installation_state_transitions
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_installations_updated_at
  on public.atlas_installations;
create trigger trg_atlas_installations_updated_at
before update on public.atlas_installations
for each row execute function public.atlas_set_updated_at();

create or replace function public.atlas_block_installation_state_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_STATE_EVENTS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_installation_state_event_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_installation_state_event_mutation()
  to service_role;

drop trigger if exists trg_atlas_installation_state_events_append_only
  on public.atlas_installation_state_events;
create trigger trg_atlas_installation_state_events_append_only
before update or delete on public.atlas_installation_state_events
for each row execute function public.atlas_block_installation_state_event_mutation();

alter table public.atlas_installation_states enable row level security;
alter table public.atlas_installation_state_transitions enable row level security;
alter table public.atlas_installations enable row level security;
alter table public.atlas_installation_state_events enable row level security;

revoke all on table public.atlas_installation_states from anon, authenticated;
revoke all on table public.atlas_installation_state_transitions from anon, authenticated;
revoke all on table public.atlas_installations from anon, authenticated;
revoke all on table public.atlas_installation_state_events from anon, authenticated;

grant select on table public.atlas_installation_states to authenticated;
grant select on table public.atlas_installation_state_transitions to authenticated;

grant all on table public.atlas_installation_states to service_role;
grant all on table public.atlas_installation_state_transitions to service_role;
grant all on table public.atlas_installations to service_role;
grant all on table public.atlas_installation_state_events to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_states'
      and policyname = 'atlas_installation_states_authenticated_read'
  ) then
    execute $policy$
      create policy atlas_installation_states_authenticated_read
        on public.atlas_installation_states
        for select
        to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_state_transitions'
      and policyname = 'atlas_installation_transitions_authenticated_read'
  ) then
    execute $policy$
      create policy atlas_installation_transitions_authenticated_read
        on public.atlas_installation_state_transitions
        for select
        to authenticated
        using (active = true)
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_installation_states is
  'B2: catalogo versionable de estados canonicos del expediente de instalacion.';

comment on table public.atlas_installation_state_transitions is
  'B2: matriz explicita de transiciones permitidas. La autoridad se instala en B2.2A.2.';

comment on table public.atlas_installations is
  'B2: agregado raiz del expediente de instalacion empresarial.';

comment on table public.atlas_installation_state_events is
  'B2: bitacora append-only e idempotente de cambios de estado.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2A1_SCHEMA_INSTALLED',
  'states', (
    select count(*)
    from public.atlas_installation_states
    where active = true
  ),
  'transitions', (
    select count(*)
    from public.atlas_installation_state_transitions
    where active = true
  ),
  'installations', (
    select count(*)
    from public.atlas_installations
  ),
  'events', (
    select count(*)
    from public.atlas_installation_state_events
  ),
  'direct_authenticated_write', false,
  'next_block', 'B2.2A.2_PLATFORM_AUTHORITY_AND_RPCS'
) as result;
