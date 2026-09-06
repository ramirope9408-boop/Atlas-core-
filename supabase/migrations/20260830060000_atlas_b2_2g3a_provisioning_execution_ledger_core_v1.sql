-- ATLAS B2.2G.3A
-- Nucleo del libro mayor de ejecucion y evidencias de aprovisionamiento.
-- Corte: 2026-08-30
--
-- Este bloque instala estructura y autoridad. No ejecuta pasos, no crea
-- recursos del tenant y no modifica la instalacion piloto de FingerFood.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_provisioning_plans'
     ) is null
     or to_regclass(
       'public.atlas_installation_provisioning_steps'
     ) is null
     or to_regclass(
       'public.atlas_installation_provisioning_events'
     ) is null
     or to_regprocedure(
       'public.atlas_run_installation_provisioning_preflight(uuid,uuid,bigint,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_platform_has_permission(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_set_updated_at()'
     ) is null
     or to_regprocedure(
       'public.atlas_block_provisioning_append_only_mutation()'
     ) is null then
    raise exception 'B2.2G.3A requiere B2.2G.2B instalado y certificado';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_PROVISIONING_EXECUTE',
    'Ejecutar pasos aprobados y registrar recursos y evidencias de aprovisionamiento.'
  ),
  (
    'INSTALLATION_PROVISIONING_COMPENSATE',
    'Ejecutar compensaciones gobernadas sobre recursos aprovisionados.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_PROVISIONING_EXECUTE'),
  ('ATLAS_OWNER', 'INSTALLATION_PROVISIONING_COMPENSATE'),
  (
    'ATLAS_IMPLEMENTATION_OPERATOR',
    'INSTALLATION_PROVISIONING_EXECUTE'
  ),
  (
    'ATLAS_IMPLEMENTATION_OPERATOR',
    'INSTALLATION_PROVISIONING_COMPENSATE'
  )
on conflict (role_code, permission_code) do nothing;

create table if not exists
public.atlas_provisioning_operation_receipts (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  provisioning_plan_id uuid not null,
  provisioning_step_id uuid not null,
  resource_code text not null,
  step_code text not null,
  operation_phase text not null,
  attempt_number integer not null,
  outcome text not null,
  executor_code text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  request_id uuid not null,
  input_sha256 text not null,
  output_sha256 text,
  target_reference jsonb not null,
  result_payload jsonb not null,
  evidence jsonb not null,
  error_code text,
  error_message text,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_provisioning_receipts_attempt_key
    unique (
      provisioning_step_id,
      operation_phase,
      attempt_number
    ),
  constraint atlas_provisioning_receipts_request_key
    unique (provisioning_plan_id, request_id),
  constraint atlas_provisioning_receipts_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_provisioning_receipts_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_provisioning_receipts_plan_fkey
    foreign key (provisioning_plan_id)
    references public.atlas_installation_provisioning_plans(id)
    on delete restrict,
  constraint atlas_provisioning_receipts_step_fkey
    foreign key (provisioning_step_id)
    references public.atlas_installation_provisioning_steps(id)
    on delete restrict,
  constraint atlas_provisioning_receipts_resource_fkey
    foreign key (resource_code)
    references public.atlas_provisioning_resource_definitions(resource_code)
    on delete restrict,
  constraint atlas_provisioning_receipts_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_provisioning_receipts_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_provisioning_receipts_step_code_check
    check (step_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_provisioning_receipts_phase_check
    check (
      operation_phase in ('EXECUTION', 'VERIFICATION', 'COMPENSATION')
    ),
  constraint atlas_provisioning_receipts_attempt_check
    check (attempt_number between 1 and 10),
  constraint atlas_provisioning_receipts_outcome_check
    check (outcome in ('SUCCEEDED', 'FAILED', 'SKIPPED')),
  constraint atlas_provisioning_receipts_executor_check
    check (
      executor_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(executor_code) between 3 and 80
    ),
  constraint atlas_provisioning_receipts_hash_check
    check (
      input_sha256 ~ '^[0-9a-f]{64}$'
      and (
        output_sha256 is null
        or output_sha256 ~ '^[0-9a-f]{64}$'
      )
      and (outcome <> 'SUCCEEDED' or output_sha256 is not null)
    ),
  constraint atlas_provisioning_receipts_payload_check
    check (
      jsonb_typeof(target_reference) = 'object'
      and target_reference <> '{}'::jsonb
      and jsonb_typeof(result_payload) = 'object'
      and jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
      and nullif(
        btrim(evidence->>'evidence_reference'), ''
      ) is not null
      and jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(
        target_reference
      )
      and not public.atlas_jsonb_has_forbidden_secret_key(
        result_payload
      )
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    ),
  constraint atlas_provisioning_receipts_error_check
    check (
      (
        outcome = 'FAILED'
        and nullif(btrim(error_code), '') is not null
        and nullif(btrim(error_message), '') is not null
      )
      or (
        outcome in ('SUCCEEDED', 'SKIPPED')
        and error_code is null
        and error_message is null
      )
    ),
  constraint atlas_provisioning_receipts_timeline_check
    check (completed_at >= started_at)
);

create index if not exists idx_atlas_provisioning_receipts_timeline
  on public.atlas_provisioning_operation_receipts (
    provisioning_plan_id,
    provisioning_step_id,
    created_at desc,
    id desc
  );

create index if not exists idx_atlas_provisioning_receipts_outcome
  on public.atlas_provisioning_operation_receipts (
    installation_id,
    outcome,
    operation_phase,
    created_at desc
  );

create table if not exists
public.atlas_provisioned_resources (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  provisioning_plan_id uuid not null,
  provisioning_step_id uuid not null,
  resource_code text not null,
  step_code text not null,
  target_kind text not null,
  resource_status text not null,
  state_version bigint not null default 1,
  resource_locator jsonb not null,
  configuration_sha256 text not null,
  last_receipt_id uuid not null,
  idempotency_key uuid not null,
  created_by_user_id uuid not null,
  provisioned_at timestamptz not null,
  verified_at timestamptz,
  compensation_required_at timestamptz,
  compensated_at timestamptz,
  archived_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_provisioned_resources_step_key
    unique (provisioning_plan_id, provisioning_step_id),
  constraint atlas_provisioned_resources_code_key
    unique (provisioning_plan_id, step_code),
  constraint atlas_provisioned_resources_request_key
    unique (provisioning_plan_id, idempotency_key),
  constraint atlas_provisioned_resources_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_provisioned_resources_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_provisioned_resources_plan_fkey
    foreign key (provisioning_plan_id)
    references public.atlas_installation_provisioning_plans(id)
    on delete restrict,
  constraint atlas_provisioned_resources_step_fkey
    foreign key (provisioning_step_id)
    references public.atlas_installation_provisioning_steps(id)
    on delete restrict,
  constraint atlas_provisioned_resources_resource_fkey
    foreign key (resource_code)
    references public.atlas_provisioning_resource_definitions(resource_code)
    on delete restrict,
  constraint atlas_provisioned_resources_receipt_fkey
    foreign key (last_receipt_id)
    references public.atlas_provisioning_operation_receipts(id)
    on delete restrict,
  constraint atlas_provisioned_resources_creator_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_provisioned_resources_codes_check
    check (
      step_code ~ '^[A-Z][A-Z0-9_]*$'
      and target_kind ~ '^[A-Z][A-Z0-9_]*$'
    ),
  constraint atlas_provisioned_resources_status_check
    check (
      resource_status in (
        'PROVISIONED',
        'VERIFIED',
        'COMPENSATION_REQUIRED',
        'COMPENSATED',
        'ARCHIVED'
      )
    ),
  constraint atlas_provisioned_resources_version_check
    check (state_version >= 1),
  constraint atlas_provisioned_resources_locator_check
    check (
      jsonb_typeof(resource_locator) = 'object'
      and resource_locator <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        resource_locator
      )
      and configuration_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_provisioned_resources_timeline_check
    check (
      (verified_at is null or verified_at >= provisioned_at)
      and (
        compensation_required_at is null
        or compensation_required_at >= provisioned_at
      )
      and (
        compensated_at is null
        or (
          compensation_required_at is not null
          and compensated_at >= compensation_required_at
        )
      )
      and (
        archived_at is null
        or archived_at >= provisioned_at
      )
    ),
  constraint atlas_provisioned_resources_lifecycle_check
    check (
      (resource_status <> 'VERIFIED' or verified_at is not null)
      and (
        resource_status <> 'COMPENSATION_REQUIRED'
        or compensation_required_at is not null
      )
      and (
        resource_status <> 'COMPENSATED'
        or compensated_at is not null
      )
      and (
        resource_status <> 'ARCHIVED'
        or archived_at is not null
      )
    ),
  constraint atlas_provisioned_resources_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index if not exists idx_atlas_provisioned_resources_status
  on public.atlas_provisioned_resources (
    installation_id,
    resource_status,
    resource_code
  );

create index if not exists idx_atlas_provisioned_resources_plan
  on public.atlas_provisioned_resources (
    provisioning_plan_id,
    resource_code,
    state_version desc
  );

create or replace function
public.atlas_enforce_provisioned_resource_identity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.installation_id <> old.installation_id
     or new.empresa_id <> old.empresa_id
     or new.provisioning_plan_id <> old.provisioning_plan_id
     or new.provisioning_step_id <> old.provisioning_step_id
     or new.resource_code <> old.resource_code
     or new.step_code <> old.step_code
     or new.target_kind <> old.target_kind
     or new.resource_locator <> old.resource_locator
     or new.configuration_sha256 <> old.configuration_sha256
     or new.idempotency_key <> old.idempotency_key
     or new.created_by_user_id <> old.created_by_user_id
     or new.provisioned_at <> old.provisioned_at
     or new.created_at <> old.created_at then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONED_RESOURCE_IDENTITY_IMMUTABLE';
  end if;

  if new.state_version <> old.state_version + 1 then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONED_RESOURCE_VERSION_CONFLICT';
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_provisioned_resource_identity()
  from public, anon, authenticated;
grant execute on function
public.atlas_enforce_provisioned_resource_identity()
  to service_role;

drop trigger if exists trg_atlas_provisioning_receipts_append_only
  on public.atlas_provisioning_operation_receipts;
create trigger trg_atlas_provisioning_receipts_append_only
before update or delete
on public.atlas_provisioning_operation_receipts
for each row execute function
public.atlas_block_provisioning_append_only_mutation();

drop trigger if exists trg_atlas_provisioned_resource_identity
  on public.atlas_provisioned_resources;
create trigger trg_atlas_provisioned_resource_identity
before update on public.atlas_provisioned_resources
for each row execute function
public.atlas_enforce_provisioned_resource_identity();

drop trigger if exists trg_atlas_provisioned_resources_updated_at
  on public.atlas_provisioned_resources;
create trigger trg_atlas_provisioned_resources_updated_at
before update on public.atlas_provisioned_resources
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_provisioning_operation_receipts
  enable row level security;
alter table public.atlas_provisioned_resources
  enable row level security;

revoke all on table public.atlas_provisioning_operation_receipts
  from anon, authenticated;
revoke all on table public.atlas_provisioned_resources
  from anon, authenticated;

grant select on table public.atlas_provisioning_operation_receipts
  to authenticated;
grant select on table public.atlas_provisioned_resources
  to authenticated;

grant all on table public.atlas_provisioning_operation_receipts
  to service_role;
grant all on table public.atlas_provisioned_resources
  to service_role;

drop policy if exists
  atlas_provisioning_operation_receipts_platform_read
  on public.atlas_provisioning_operation_receipts;
create policy atlas_provisioning_operation_receipts_platform_read
on public.atlas_provisioning_operation_receipts
for select
to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_READ'
  )
);

drop policy if exists atlas_provisioned_resources_platform_read
  on public.atlas_provisioned_resources;
create policy atlas_provisioned_resources_platform_read
on public.atlas_provisioned_resources
for select
to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_READ'
  )
);

comment on table public.atlas_provisioning_operation_receipts is
  'B2: recibos append-only por intento, fase, resultado y evidencia.';
comment on table public.atlas_provisioned_resources is
  'B2: libro mayor versionado de recursos materializados por plan y paso.';
comment on function
public.atlas_enforce_provisioned_resource_identity() is
  'B2: congela identidad tecnica y exige version consecutiva del recurso.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2G3A_PROVISIONING_EXECUTION_LEDGER_CORE_INSTALLED',
  'next_block',
    'B2.2G.3B_STEP_EXECUTION_AND_RESOURCE_REGISTRATION_RPCS',
  'execution_ledger_tables', 2,
  'execution_permission_roles', (
    select count(*)
    from public.atlas_internal_role_permissions
    where permission_code = 'INSTALLATION_PROVISIONING_EXECUTE'
      and role_code in (
        'ATLAS_OWNER', 'ATLAS_IMPLEMENTATION_OPERATOR'
      )
  ),
  'compensation_permission_roles', (
    select count(*)
    from public.atlas_internal_role_permissions
    where permission_code = 'INSTALLATION_PROVISIONING_COMPENSATE'
      and role_code in (
        'ATLAS_OWNER', 'ATLAS_IMPLEMENTATION_OPERATOR'
      )
  ),
  'operation_receipts', (
    select count(*)
    from public.atlas_provisioning_operation_receipts
  ),
  'provisioned_resources', (
    select count(*)
    from public.atlas_provisioned_resources
  ),
  'execution_write_rpcs', 0,
  'append_only_receipts_enabled', true,
  'resource_identity_immutable', true,
  'resource_optimistic_concurrency_enabled', true,
  'secret_bearing_payloads_blocked', true,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'direct_authenticated_write', false
) as result;
