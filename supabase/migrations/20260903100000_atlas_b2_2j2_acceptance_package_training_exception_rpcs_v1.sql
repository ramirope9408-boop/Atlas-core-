-- ATLAS B2.2J.2
-- RPC gobernadas de paquete de aceptacion, capacitacion y excepciones.
-- Corte: 2026-09-03
--
-- Alcance:
-- - materializa un paquete ligado a manifest, plan/run y G03 vigentes;
-- - registra y completa capacitaciones con evidencia verificable;
-- - registra defectos/excepciones y gobierna su resolucion;
-- - entrega el paquete solo con G03 vigente, capacitacion completa y
--   cero defectos criticos abiertos;
-- - preserva idempotencia, concurrencia optimista, eventos y auditoria;
-- - no registra la aceptacion final, no decide G04, no emite certificados
--   y no habilita ACTIVE.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_acceptance_packages'
     ) is null
     or to_regclass(
       'public.atlas_installation_acceptance_requirements'
     ) is null
     or to_regclass(
       'public.atlas_installation_training_records'
     ) is null
     or to_regclass(
       'public.atlas_installation_exception_records'
     ) is null
     or to_regclass(
       'public.atlas_installation_acceptance_events'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_g03_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_g03_approval_evidence_matches_readiness_v1(jsonb,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_acceptance_evidence_reference_is_safe(text)'
     ) is null then
    raise exception 'B2.2J.2 requiere B2.2J.1 instalado y certificado';
  end if;

  if exists (
    select 1
    from public.atlas_installation_acceptance_packages
  ) or exists (
    select 1
    from public.atlas_installation_training_records
  ) or exists (
    select 1
    from public.atlas_installation_exception_records
  ) then
    raise exception
      'B2.2J.2 requiere ledgers J1 vacios para instalar columnas de concurrencia';
  end if;
end;
$$;

alter table public.atlas_installation_acceptance_packages
  add column request_sha256 text;
alter table public.atlas_installation_acceptance_packages
  add column state_version bigint not null default 1;
alter table public.atlas_installation_acceptance_packages
  add column delivery_request_id uuid;
alter table public.atlas_installation_acceptance_packages
  add column delivery_request_sha256 text;
alter table public.atlas_installation_acceptance_packages
  add column delivery_evidence_reference text;
alter table public.atlas_installation_acceptance_packages
  add column delivery_evidence_sha256 text;
alter table public.atlas_installation_acceptance_packages
  add column delivered_by_user_id uuid;

alter table public.atlas_installation_acceptance_packages
  alter column request_sha256 set not null;

alter table public.atlas_installation_acceptance_packages
  add constraint atlas_acceptance_packages_request_sha256_check
  check (request_sha256 ~ '^[0-9a-f]{64}$');
alter table public.atlas_installation_acceptance_packages
  add constraint atlas_acceptance_packages_state_version_check
  check (state_version >= 1);
alter table public.atlas_installation_acceptance_packages
  add constraint atlas_acceptance_packages_delivery_request_key
  unique (installation_id, delivery_request_id);
alter table public.atlas_installation_acceptance_packages
  add constraint atlas_acceptance_packages_delivered_by_fkey
  foreign key (delivered_by_user_id)
  references auth.users(id)
  on delete restrict;
alter table public.atlas_installation_acceptance_packages
  add constraint atlas_acceptance_packages_delivery_check
  check (
    (
      package_status in ('DELIVERED', 'UNDER_CLIENT_REVIEW')
      and delivery_request_id is not null
      and delivery_request_sha256 ~ '^[0-9a-f]{64}$'
      and public.atlas_acceptance_evidence_reference_is_safe(
        delivery_evidence_reference
      )
      and delivery_evidence_sha256 ~ '^[0-9a-f]{64}$'
      and delivered_by_user_id is not null
      and delivered_at is not null
    )
    or package_status not in ('DELIVERED', 'UNDER_CLIENT_REVIEW')
  );

alter table public.atlas_installation_training_records
  add column request_sha256 text;
alter table public.atlas_installation_training_records
  add column state_version bigint not null default 1;
alter table public.atlas_installation_training_records
  add column completion_request_id uuid;
alter table public.atlas_installation_training_records
  add column completion_request_sha256 text;

alter table public.atlas_installation_training_records
  alter column request_sha256 set not null;

alter table public.atlas_installation_training_records
  add constraint atlas_training_records_request_sha256_check
  check (request_sha256 ~ '^[0-9a-f]{64}$');
alter table public.atlas_installation_training_records
  add constraint atlas_training_records_state_version_check
  check (state_version >= 1);
alter table public.atlas_installation_training_records
  add constraint atlas_training_records_completion_request_key
  unique (installation_id, completion_request_id);
alter table public.atlas_installation_training_records
  add constraint atlas_training_records_completion_request_check
  check (
    (
      training_status = 'COMPLETED'
      and completion_request_id is not null
      and completion_request_sha256 ~ '^[0-9a-f]{64}$'
    )
    or training_status <> 'COMPLETED'
  );

alter table public.atlas_installation_exception_records
  add column request_sha256 text;
alter table public.atlas_installation_exception_records
  add column state_version bigint not null default 1;
alter table public.atlas_installation_exception_records
  add column resolution_request_id uuid;
alter table public.atlas_installation_exception_records
  add column resolution_request_sha256 text;
alter table public.atlas_installation_exception_records
  add column resolution_reason_code text;
alter table public.atlas_installation_exception_records
  add column resolved_by_user_id uuid;
alter table public.atlas_installation_exception_records
  add column resolved_at timestamptz;
alter table public.atlas_installation_exception_records
  add column resolution_evidence_reference text;
alter table public.atlas_installation_exception_records
  add column resolution_evidence_sha256 text;

alter table public.atlas_installation_exception_records
  alter column request_sha256 set not null;

alter table public.atlas_installation_exception_records
  add constraint atlas_exception_records_request_sha256_check
  check (request_sha256 ~ '^[0-9a-f]{64}$');
alter table public.atlas_installation_exception_records
  add constraint atlas_exception_records_state_version_check
  check (state_version >= 1);
alter table public.atlas_installation_exception_records
  add constraint atlas_exception_records_resolution_request_key
  unique (installation_id, resolution_request_id);
alter table public.atlas_installation_exception_records
  add constraint atlas_exception_records_resolved_by_fkey
  foreign key (resolved_by_user_id)
  references auth.users(id)
  on delete restrict;
alter table public.atlas_installation_exception_records
  add constraint atlas_exception_records_resolution_check
  check (
    (
      exception_status = 'OPEN'
      and resolution_request_id is null
      and resolution_request_sha256 is null
      and resolution_reason_code is null
      and resolved_by_user_id is null
      and resolved_at is null
      and resolution_evidence_reference is null
      and resolution_evidence_sha256 is null
    )
    or (
      exception_status in (
        'REMEDIATED', 'ACCEPTED_RISK', 'REJECTED'
      )
      and resolution_request_id is not null
      and resolution_request_sha256 ~ '^[0-9a-f]{64}$'
      and resolution_reason_code ~ '^[A-Z][A-Z0-9_]*$'
      and resolved_by_user_id is not null
      and resolved_at is not null
      and public.atlas_acceptance_evidence_reference_is_safe(
        resolution_evidence_reference
      )
      and resolution_evidence_sha256 ~ '^[0-9a-f]{64}$'
    )
    or exception_status = 'SUPERSEDED'
  );

create or replace function
public.atlas_acceptance_platform_role_for_permission(
  p_permission_code text
)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select membership.role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code = p_permission_code
  where membership.user_id = auth.uid()
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1
$$;

create or replace function
public.atlas_acceptance_current_user_is_client_owner(
  p_empresa_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.atlas_internal_memberships as membership
    join public.atlas_internal_roles as role_definition
      on role_definition.role_code = membership.role_code
     and role_definition.active
    where membership.empresa_id = p_empresa_id
      and membership.user_id = auth.uid()
      and membership.role_code = 'OWNER'
      and membership.status = 'ACTIVE'
  )
$$;

revoke all on function
public.atlas_acceptance_platform_role_for_permission(text)
from public, anon, authenticated;
revoke all on function
public.atlas_acceptance_current_user_is_client_owner(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_acceptance_platform_role_for_permission(text)
to service_role;
grant execute on function
public.atlas_acceptance_current_user_is_client_owner(uuid)
to service_role;

create or replace function
public.atlas_materialize_installation_acceptance_package(
  p_installation_id uuid,
  p_request_id uuid,
  p_expected_installation_version bigint,
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
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_installation_acceptance_packages%rowtype;
  v_created public.atlas_installation_acceptance_packages%rowtype;
  v_manifest public.atlas_installation_manifests%rowtype;
  v_plan public.atlas_installation_test_plans%rowtype;
  v_run public.atlas_installation_test_runs%rowtype;
  v_g03_gate public.atlas_installation_gates%rowtype;
  v_g03_approval public.atlas_installation_approvals%rowtype;
  v_readiness jsonb;
  v_requirements_payload jsonb;
  v_package_payload jsonb;
  v_request_payload jsonb;
  v_event_payload jsonb;
  v_request_sha256 text;
  v_package_sha256 text;
  v_acceptance_version integer;
  v_now timestamptz := clock_timestamp();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_PREPARE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACCEPTANCE_PREPARE_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'ACCEPTANCE_PACKAGE_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_PACKAGE_REQUEST_V1',
    'installation_id', p_installation_id,
    'expected_installation_version',
      p_expected_installation_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  select package.*
  into v_existing
  from public.atlas_installation_acceptance_packages as package
  where package.installation_id = v_installation.id
    and package.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256
       or v_existing.metadata->'request_contract' <>
         v_request_payload then
      raise exception using
        errcode = '22023',
        message =
          'ACCEPTANCE_PACKAGE_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'acceptance_package_id', v_existing.id,
      'acceptance_code', v_existing.acceptance_code,
      'acceptance_version', v_existing.acceptance_version,
      'package_status', v_existing.package_status,
      'state_version', v_existing.state_version,
      'package_sha256', v_existing.package_sha256,
      'next_action', 'REGISTER_TRAINING_AND_EXCEPTIONS'
    );
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if not (
    v_installation.current_state_code = 'FINAL_APPROVAL'
    or (
      v_installation.current_state_code = 'PAUSED'
      and v_installation.resume_state_code = 'FINAL_APPROVAL'
    )
  ) then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_FINAL_APPROVAL';
  end if;

  if exists (
    select 1
    from public.atlas_installation_acceptance_packages as package
    where package.installation_id = v_installation.id
      and package.package_status in (
        'DRAFT', 'READY_FOR_DELIVERY', 'DELIVERED',
        'UNDER_CLIENT_REVIEW', 'CHANGES_REQUIRED'
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'OPEN_ACCEPTANCE_PACKAGE_ALREADY_EXISTS';
  end if;

  v_readiness :=
    public.atlas_compute_installation_g03_readiness(
      v_installation.id
    );

  if not coalesce((v_readiness->>'ready')::boolean, false) then
    raise exception using
      errcode = '42501',
      message = 'ACCEPTANCE_PACKAGE_CURRENT_G03_REQUIRED',
      detail = jsonb_build_object(
        'readiness_code', v_readiness->>'code',
        'blockers', coalesce(v_readiness->'blockers', '[]'::jsonb)
      )::text;
  end if;

  select gate_record.*
  into v_g03_gate
  from public.atlas_installation_gates as gate_record
  where gate_record.installation_id = v_installation.id
    and gate_record.gate_code = 'G03'
    and gate_record.status = 'APPROVED'
    and gate_record.platform_approved
  limit 1;

  if not found then
    raise exception using
      errcode = '42501', message = 'APPROVED_G03_GATE_REQUIRED';
  end if;

  select approval.*
  into v_g03_approval
  from public.atlas_installation_approvals as approval
  where approval.gate_id = v_g03_gate.id
    and approval.gate_code = 'G03'
    and approval.gate_version = v_g03_gate.gate_version
    and approval.authority_type = 'PLATFORM'
    and approval.decision = 'APPROVED'
    and approval.actor_role_code = 'ATLAS_SECURITY_REVIEWER'
  order by approval.created_at desc, approval.id desc
  limit 1;

  if not found
     or not public.atlas_g03_approval_evidence_matches_readiness_v1(
       v_g03_approval.evidence,
       v_readiness
     ) then
    raise exception using
      errcode = '42501',
      message = 'CURRENT_BOUND_G03_APPROVAL_REQUIRED';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_test_plans as plan
  where plan.id = (v_readiness->>'test_plan_id')::uuid
    and plan.installation_id = v_installation.id
    and plan.empresa_id = v_installation.empresa_id
    and plan.plan_status = 'PASSED'
    and plan.plan_sha256 = v_readiness->>'plan_sha256';

  if not found then
    raise exception using
      errcode = '42501', message = 'CURRENT_PASSED_TEST_PLAN_REQUIRED';
  end if;

  select run.*
  into v_run
  from public.atlas_installation_test_runs as run
  where run.id = (v_readiness->>'test_run_id')::uuid
    and run.test_plan_id = v_plan.id
    and run.installation_id = v_installation.id
    and run.empresa_id = v_installation.empresa_id
    and run.run_status = 'PASSED'
    and run.evidence_root_sha256 =
      v_readiness->>'evidence_root_sha256';

  if not found then
    raise exception using
      errcode = '42501', message = 'CURRENT_PASSED_TEST_RUN_REQUIRED';
  end if;

  select manifest.*
  into v_manifest
  from public.atlas_installation_manifests as manifest
  where manifest.id = v_plan.source_manifest_id
    and manifest.installation_id = v_installation.id
    and manifest.empresa_id = v_installation.empresa_id
    and manifest.manifest_sha256 =
      v_readiness->>'source_manifest_sha256'
    and manifest.manifest_status in ('VALIDATED', 'APPROVED');

  if not found then
    raise exception using
      errcode = '42501', message = 'CURRENT_MANIFEST_BINDING_REQUIRED';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'requirement_code', definition.requirement_code,
      'source_domain', definition.source_domain,
      'implementation_block', definition.implementation_block,
      'objective_requirement', definition.objective_requirement,
      'requires_platform_confirmation',
        definition.requires_platform_confirmation,
      'requires_client_confirmation',
        definition.requires_client_confirmation,
      'waiver_allowed', definition.waiver_allowed
    )
    order by definition.sort_order
  )
  into v_requirements_payload
  from public.atlas_installation_acceptance_requirement_definitions
    as definition
  where definition.active;

  if jsonb_array_length(v_requirements_payload) <> 8 then
    raise exception using
      errcode = '55000',
      message = 'CANONICAL_G04_REQUIREMENT_SET_CHANGED';
  end if;

  select coalesce(max(package.acceptance_version), 0) + 1
  into v_acceptance_version
  from public.atlas_installation_acceptance_packages as package
  where package.installation_id = v_installation.id;

  v_package_payload := jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_ACCEPTANCE_V1',
    'materialization_contract_version',
      'B2_ACCEPTANCE_PACKAGE_MATERIALIZATION_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'acceptance_version', v_acceptance_version,
    'installation_version', v_installation.version,
    'source_manifest_id', v_manifest.id,
    'source_manifest_sha256', v_manifest.manifest_sha256,
    'source_test_plan_id', v_plan.id,
    'source_test_plan_sha256', v_plan.plan_sha256,
    'source_test_run_id', v_run.id,
    'source_test_evidence_root_sha256',
      v_run.evidence_root_sha256,
    'source_g03_gate_id', v_g03_gate.id,
    'source_g03_gate_version', v_g03_gate.gate_version,
    'source_g03_approval_id', v_g03_approval.id,
    'source_g03_readiness_sha256',
      v_readiness->>'readiness_sha256',
    'requirements', v_requirements_payload,
    'certificate_issuance_enabled', false,
    'active_transition_enabled', false
  );
  v_package_sha256 := public.atlas_normalization_sha256(
    v_package_payload::text
  );

  v_actor_role_code :=
    public.atlas_acceptance_platform_role_for_permission(
      'INSTALLATION_ACCEPTANCE_PREPARE'
    );

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'ACCEPTANCE_PACKAGE_ACTOR_ROLE_NOT_FOUND';
  end if;

  insert into public.atlas_installation_acceptance_packages (
    installation_id,
    empresa_id,
    acceptance_code,
    acceptance_version,
    acceptance_contract_version,
    package_status,
    expected_installation_version,
    source_manifest_id,
    source_manifest_sha256,
    source_test_plan_id,
    source_test_run_id,
    source_test_plan_sha256,
    source_test_evidence_root_sha256,
    source_g03_gate_id,
    source_g03_gate_version,
    source_g03_readiness_sha256,
    acceptance_contract_id,
    package_payload,
    package_sha256,
    request_sha256,
    state_version,
    created_by_user_id,
    idempotency_key,
    metadata,
    created_at,
    updated_at
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    format(
      'B2-ACC-%s-V%s',
      upper(substr(replace(v_installation.id::text, '-', ''), 1, 12)),
      v_acceptance_version
    ),
    v_acceptance_version,
    'B2_INSTALLATION_ACCEPTANCE_V1',
    'DRAFT',
    v_installation.version,
    v_manifest.id,
    v_manifest.manifest_sha256,
    v_plan.id,
    v_run.id,
    v_plan.plan_sha256,
    v_run.evidence_root_sha256,
    v_g03_gate.id,
    v_g03_gate.gate_version,
    v_readiness->>'readiness_sha256',
    null,
    v_package_payload,
    v_package_sha256,
    v_request_sha256,
    1,
    v_actor_user_id,
    p_request_id,
    jsonb_build_object(
      'request_contract', v_request_payload,
      'request_metadata', p_metadata,
      'source_g03_approval_id', v_g03_approval.id
    ),
    v_now,
    v_now
  )
  returning * into v_created;

  insert into public.atlas_installation_acceptance_requirements (
    acceptance_package_id,
    installation_id,
    empresa_id,
    requirement_code,
    requirement_status,
    evidence_kind,
    evidence_reference,
    evidence_sha256,
    verification_payload,
    verified_by_user_id,
    verified_at,
    metadata,
    created_at,
    updated_at
  )
  select
    v_created.id,
    v_created.installation_id,
    v_created.empresa_id,
    definition.requirement_code,
    case
      when definition.requirement_code in (
        'FUNCTIONAL_CASES_APPROVED',
        'SECURITY_TESTS_APPROVED'
      ) then 'SATISFIED'
      else 'PENDING'
    end,
    case
      when definition.requirement_code in (
        'FUNCTIONAL_CASES_APPROVED',
        'SECURITY_TESTS_APPROVED'
      ) then 'TEST_READINESS'
      else null
    end,
    case
      when definition.requirement_code in (
        'FUNCTIONAL_CASES_APPROVED',
        'SECURITY_TESTS_APPROVED'
      ) then format(
        'gate://%s/G03/%s',
        v_installation.id,
        v_g03_gate.gate_version
      )
      else null
    end,
    case
      when definition.requirement_code in (
        'FUNCTIONAL_CASES_APPROVED',
        'SECURITY_TESTS_APPROVED'
      ) then v_readiness->>'readiness_sha256'
      else null
    end,
    case
      when definition.requirement_code in (
        'FUNCTIONAL_CASES_APPROVED',
        'SECURITY_TESTS_APPROVED'
      ) then jsonb_build_object(
        'contract_version', 'B2_ACCEPTANCE_REQUIREMENT_EVIDENCE_V1',
        'requirement_code', definition.requirement_code,
        'test_plan_id', v_plan.id,
        'test_run_id', v_run.id,
        'test_evidence_root_sha256', v_run.evidence_root_sha256,
        'g03_gate_id', v_g03_gate.id,
        'g03_gate_version', v_g03_gate.gate_version,
        'g03_readiness_sha256',
          v_readiness->>'readiness_sha256'
      )
      else '{}'::jsonb
    end,
    case
      when definition.requirement_code in (
        'FUNCTIONAL_CASES_APPROVED',
        'SECURITY_TESTS_APPROVED'
      ) then v_actor_user_id
      else null
    end,
    case
      when definition.requirement_code in (
        'FUNCTIONAL_CASES_APPROVED',
        'SECURITY_TESTS_APPROVED'
      ) then v_now
      else null
    end,
    jsonb_build_object(
      'definition_snapshot', jsonb_build_object(
        'source_domain', definition.source_domain,
        'implementation_block', definition.implementation_block,
        'objective_requirement', definition.objective_requirement,
        'requires_platform_confirmation',
          definition.requires_platform_confirmation,
        'requires_client_confirmation',
          definition.requires_client_confirmation,
        'waiver_allowed', definition.waiver_allowed
      )
    ),
    v_now,
    v_now
  from public.atlas_installation_acceptance_requirement_definitions
    as definition
  where definition.active;

  if (
    select count(*)
    from public.atlas_installation_acceptance_requirements as requirement
    where requirement.acceptance_package_id = v_created.id
  ) <> 8 then
    raise exception using
      errcode = '55000',
      message = 'ACCEPTANCE_REQUIREMENT_MATERIALIZATION_INCOMPLETE';
  end if;

  v_event_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_EVENT_V1',
    'acceptance_package_id', v_created.id,
    'acceptance_version', v_created.acceptance_version,
    'package_sha256', v_created.package_sha256,
    'request_sha256', v_created.request_sha256,
    'source_manifest_sha256', v_created.source_manifest_sha256,
    'source_test_plan_sha256', v_created.source_test_plan_sha256,
    'source_test_evidence_root_sha256',
      v_created.source_test_evidence_root_sha256,
    'source_g03_readiness_sha256',
      v_created.source_g03_readiness_sha256,
    'materialized_requirements', 8,
    'initially_satisfied_requirements', 2
  );

  insert into public.atlas_installation_acceptance_events (
    acceptance_package_id,
    installation_id,
    empresa_id,
    entity_type,
    entity_id,
    event_code,
    from_status,
    to_status,
    actor_user_id,
    actor_role_code,
    executor_code,
    reason_code,
    request_id,
    acceptance_version,
    evidence_reference,
    evidence_sha256,
    event_payload,
    metadata
  )
  values (
    v_created.id,
    v_created.installation_id,
    v_created.empresa_id,
    'PACKAGE',
    v_created.id,
    'ACCEPTANCE_PACKAGE_MATERIALIZED',
    null,
    'DRAFT',
    v_actor_user_id,
    v_actor_role_code,
    'B2_ACCEPTANCE_ENGINE',
    'G03_APPROVED_AND_BOUND',
    p_request_id,
    v_created.acceptance_version,
    format(
      'acceptance://%s/package/%s',
      v_created.installation_id,
      v_created.id
    ),
    v_created.package_sha256,
    v_event_payload,
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_internal_audit_log (
    empresa_id,
    user_id,
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
    'INSTALLATION_ACCEPTANCE_PACKAGE_MATERIALIZED',
    'B2_ACCEPTANCE_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'installation_id', v_created.installation_id,
      'request_id', p_request_id,
      'request_sha256', v_created.request_sha256
    ),
    jsonb_build_object(
      'acceptance_package_id', v_created.id,
      'acceptance_version', v_created.acceptance_version,
      'package_sha256', v_created.package_sha256,
      'requirements', 8
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_ACCEPTANCE_PACKAGE_MATERIALIZED',
    'installation_id', v_created.installation_id,
    'acceptance_package_id', v_created.id,
    'acceptance_code', v_created.acceptance_code,
    'acceptance_version', v_created.acceptance_version,
    'package_status', v_created.package_status,
    'state_version', v_created.state_version,
    'package_sha256', v_created.package_sha256,
    'materialized_requirements', 8,
    'satisfied_requirements', 2,
    'pending_requirements', 6,
    'certificate_issued', false,
    'active_enabled', false,
    'next_action', 'REGISTER_TRAINING_AND_EXCEPTIONS'
  );
end;
$$;

create or replace function
public.atlas_register_installation_training_record(
  p_acceptance_package_id uuid,
  p_training_code text,
  p_audience_scope jsonb,
  p_subject_scope text[],
  p_scheduled_at timestamptz,
  p_training_details jsonb,
  p_request_id uuid,
  p_expected_installation_version bigint,
  p_expected_package_state_version bigint,
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
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_installation_training_records%rowtype;
  v_created public.atlas_installation_training_records%rowtype;
  v_request_payload jsonb;
  v_training_payload jsonb;
  v_event_payload jsonb;
  v_request_sha256 text;
  v_training_sha256 text;
  v_training_version integer;
  v_now timestamptz := clock_timestamp();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_PREPARE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACCEPTANCE_PREPARE_FORBIDDEN';
  end if;

  if p_acceptance_package_id is null
     or p_training_code is null
     or p_training_code !~ '^TRN-[A-Z0-9_-]+$'
     or length(p_training_code) not between 8 and 100
     or p_audience_scope is null
     or jsonb_typeof(p_audience_scope) <> 'object'
     or p_audience_scope = '{}'::jsonb
     or p_subject_scope is null
     or cardinality(p_subject_scope) < 1
     or not public.atlas_text_array_has_unique_values(p_subject_scope)
     or p_scheduled_at is null
     or p_training_details is null
     or jsonb_typeof(p_training_details) <> 'object'
     or p_training_details = '{}'::jsonb
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_expected_package_state_version is null
     or p_expected_package_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_audience_scope
     )
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_training_details
     )
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'TRAINING_REGISTRATION_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_TRAINING_REGISTRATION_REQUEST_V1',
    'acceptance_package_id', p_acceptance_package_id,
    'training_code', p_training_code,
    'audience_scope', p_audience_scope,
    'subject_scope', to_jsonb(p_subject_scope),
    'scheduled_at', p_scheduled_at,
    'training_details', p_training_details,
    'expected_installation_version',
      p_expected_installation_version,
    'expected_package_state_version',
      p_expected_package_state_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select package.*
  into v_package
  from public.atlas_installation_acceptance_packages as package
  where package.id = p_acceptance_package_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'ACCEPTANCE_PACKAGE_NOT_FOUND';
  end if;

  select training.*
  into v_existing
  from public.atlas_installation_training_records as training
  where training.installation_id = v_package.installation_id
    and training.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'TRAINING_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'training_record_id', v_existing.id,
      'training_code', v_existing.training_code,
      'training_version', v_existing.training_version,
      'training_status', v_existing.training_status,
      'state_version', v_existing.state_version,
      'training_sha256', v_existing.training_sha256,
      'next_action', case
        when v_existing.training_status = 'COMPLETED'
          then 'SUBMIT_ACCEPTANCE_PACKAGE'
        else 'COMPLETE_TRAINING'
      end
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_package.installation_id
  for update;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_package.state_version <>
       p_expected_package_state_version then
    raise exception using
      errcode = '40001',
      message = 'ACCEPTANCE_PACKAGE_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'FINAL_APPROVAL'
     or v_package.package_status not in (
       'DRAFT', 'READY_FOR_DELIVERY'
     ) then
    raise exception using
      errcode = '22023',
      message = 'TRAINING_REGISTRATION_NOT_ALLOWED_IN_CURRENT_STATE';
  end if;

  select coalesce(max(training.training_version), 0) + 1
  into v_training_version
  from public.atlas_installation_training_records as training
  where training.acceptance_package_id = v_package.id
    and training.training_code = p_training_code;

  v_training_payload := jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_TRAINING_V1',
    'acceptance_package_id', v_package.id,
    'package_sha256', v_package.package_sha256,
    'installation_id', v_package.installation_id,
    'empresa_id', v_package.empresa_id,
    'training_code', p_training_code,
    'training_version', v_training_version,
    'audience_scope', p_audience_scope,
    'subject_scope', to_jsonb(p_subject_scope),
    'scheduled_at', p_scheduled_at,
    'training_details', p_training_details
  );
  v_training_sha256 := public.atlas_normalization_sha256(
    v_training_payload::text
  );

  v_actor_role_code :=
    public.atlas_acceptance_platform_role_for_permission(
      'INSTALLATION_ACCEPTANCE_PREPARE'
    );

  insert into public.atlas_installation_training_records (
    acceptance_package_id,
    installation_id,
    empresa_id,
    training_code,
    training_version,
    training_status,
    audience_scope,
    subject_scope,
    scheduled_at,
    delivered_by_user_id,
    training_payload,
    training_sha256,
    request_sha256,
    state_version,
    idempotency_key,
    metadata,
    created_at,
    updated_at
  )
  values (
    v_package.id,
    v_package.installation_id,
    v_package.empresa_id,
    p_training_code,
    v_training_version,
    'PLANNED',
    p_audience_scope,
    p_subject_scope,
    p_scheduled_at,
    v_actor_user_id,
    v_training_payload,
    v_training_sha256,
    v_request_sha256,
    1,
    p_request_id,
    jsonb_build_object(
      'request_contract', v_request_payload,
      'request_metadata', p_metadata
    ),
    v_now,
    v_now
  )
  returning * into v_created;

  v_event_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_EVENT_V1',
    'training_record_id', v_created.id,
    'training_code', v_created.training_code,
    'training_version', v_created.training_version,
    'training_sha256', v_created.training_sha256,
    'request_sha256', v_created.request_sha256
  );

  insert into public.atlas_installation_acceptance_events (
    acceptance_package_id, installation_id, empresa_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, reason_code,
    request_id, acceptance_version, evidence_reference,
    evidence_sha256, event_payload, metadata
  )
  values (
    v_package.id, v_package.installation_id, v_package.empresa_id,
    'TRAINING', v_created.id, 'TRAINING_REGISTERED', null, 'PLANNED',
    v_actor_user_id, v_actor_role_code, 'B2_ACCEPTANCE_ENGINE',
    'TRAINING_SCOPE_REGISTERED', p_request_id,
    v_package.acceptance_version,
    format(
      'training://%s/%s/%s',
      v_package.installation_id,
      v_created.training_code,
      v_created.training_version
    ),
    v_created.training_sha256, v_event_payload,
    jsonb_build_object('request_metadata', p_metadata)
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_TRAINING_REGISTERED',
    'acceptance_package_id', v_package.id,
    'training_record_id', v_created.id,
    'training_code', v_created.training_code,
    'training_version', v_created.training_version,
    'training_status', v_created.training_status,
    'state_version', v_created.state_version,
    'training_sha256', v_created.training_sha256,
    'next_action', 'COMPLETE_TRAINING'
  );
end;
$$;

create or replace function
public.atlas_complete_installation_training_record(
  p_training_record_id uuid,
  p_completed_at timestamptz,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_completion_details jsonb,
  p_request_id uuid,
  p_expected_installation_version bigint,
  p_expected_training_state_version bigint,
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
  v_training public.atlas_installation_training_records%rowtype;
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_request_payload jsonb;
  v_event_payload jsonb;
  v_request_sha256 text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_PREPARE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACCEPTANCE_PREPARE_FORBIDDEN';
  end if;

  if p_training_record_id is null
     or p_completed_at is null
     or not public.atlas_acceptance_evidence_reference_is_safe(
       p_evidence_reference
     )
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_completion_details is null
     or jsonb_typeof(p_completion_details) <> 'object'
     or p_completion_details = '{}'::jsonb
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_training_state_version is null
     or p_expected_training_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_completion_details
     )
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'TRAINING_COMPLETION_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_TRAINING_COMPLETION_REQUEST_V1',
    'training_record_id', p_training_record_id,
    'completed_at', p_completed_at,
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', p_evidence_sha256,
    'completion_details', p_completion_details,
    'expected_installation_version',
      p_expected_installation_version,
    'expected_training_state_version',
      p_expected_training_state_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select training.*
  into v_training
  from public.atlas_installation_training_records as training
  where training.id = p_training_record_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'TRAINING_RECORD_NOT_FOUND';
  end if;

  if v_training.completion_request_id = p_request_id then
    if v_training.completion_request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'TRAINING_COMPLETION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'training_record_id', v_training.id,
      'training_status', v_training.training_status,
      'state_version', v_training.state_version,
      'evidence_sha256', v_training.evidence_sha256,
      'next_action', 'SUBMIT_ACCEPTANCE_PACKAGE'
    );
  end if;

  select package.*
  into v_package
  from public.atlas_installation_acceptance_packages as package
  where package.id = v_training.acceptance_package_id
  for update;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_training.installation_id
  for update;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_training.state_version <>
       p_expected_training_state_version then
    raise exception using
      errcode = '40001', message = 'TRAINING_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'FINAL_APPROVAL'
     or v_package.package_status not in (
       'DRAFT', 'READY_FOR_DELIVERY'
     )
     or v_training.training_status not in (
       'PLANNED', 'IN_PROGRESS'
     )
     or p_completed_at < v_training.scheduled_at then
    raise exception using
      errcode = '22023',
      message = 'TRAINING_COMPLETION_NOT_ALLOWED_IN_CURRENT_STATE';
  end if;

  v_actor_role_code :=
    public.atlas_acceptance_platform_role_for_permission(
      'INSTALLATION_ACCEPTANCE_PREPARE'
    );

  update public.atlas_installation_training_records
  set
    training_status = 'COMPLETED',
    started_at = coalesce(started_at, scheduled_at),
    completed_at = p_completed_at,
    delivered_by_user_id = v_actor_user_id,
    evidence_reference = p_evidence_reference,
    evidence_sha256 = p_evidence_sha256,
    completion_request_id = p_request_id,
    completion_request_sha256 = v_request_sha256,
    state_version = state_version + 1,
    metadata = metadata || jsonb_build_object(
      'completion_contract', v_request_payload,
      'completion_metadata', p_metadata
    ),
    updated_at = clock_timestamp()
  where id = v_training.id
  returning * into v_training;

  v_event_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_EVENT_V1',
    'training_record_id', v_training.id,
    'training_sha256', v_training.training_sha256,
    'completion_request_sha256',
      v_training.completion_request_sha256,
    'evidence_sha256', v_training.evidence_sha256,
    'completion_details', p_completion_details
  );

  insert into public.atlas_installation_acceptance_events (
    acceptance_package_id, installation_id, empresa_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, reason_code,
    request_id, acceptance_version, evidence_reference,
    evidence_sha256, event_payload, metadata
  )
  values (
    v_package.id, v_package.installation_id, v_package.empresa_id,
    'TRAINING', v_training.id, 'TRAINING_COMPLETED',
    'PLANNED', 'COMPLETED', v_actor_user_id, v_actor_role_code,
    'B2_ACCEPTANCE_ENGINE', 'TRAINING_EVIDENCE_VERIFIED',
    p_request_id, v_package.acceptance_version,
    p_evidence_reference, p_evidence_sha256, v_event_payload,
    jsonb_build_object('request_metadata', p_metadata)
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_TRAINING_COMPLETED',
    'acceptance_package_id', v_package.id,
    'training_record_id', v_training.id,
    'training_status', v_training.training_status,
    'state_version', v_training.state_version,
    'training_sha256', v_training.training_sha256,
    'evidence_sha256', v_training.evidence_sha256,
    'next_action', 'SUBMIT_ACCEPTANCE_PACKAGE'
  );
end;
$$;

create or replace function
public.atlas_register_installation_exception(
  p_acceptance_package_id uuid,
  p_exception_code text,
  p_severity text,
  p_blocking boolean,
  p_client_acceptance_required boolean,
  p_source_test_result_id uuid,
  p_exception_details jsonb,
  p_request_id uuid,
  p_expected_installation_version bigint,
  p_expected_package_state_version bigint,
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
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_installation_exception_records%rowtype;
  v_created public.atlas_installation_exception_records%rowtype;
  v_request_payload jsonb;
  v_exception_payload jsonb;
  v_event_payload jsonb;
  v_request_sha256 text;
  v_exception_sha256 text;
  v_exception_version integer;
  v_now timestamptz := clock_timestamp();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_PREPARE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACCEPTANCE_PREPARE_FORBIDDEN';
  end if;

  if p_acceptance_package_id is null
     or p_exception_code is null
     or p_exception_code !~ '^EXC-[A-Z0-9_-]+$'
     or length(p_exception_code) not between 8 and 100
     or p_severity not in ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')
     or p_blocking is null
     or p_client_acceptance_required is null
     or (p_severity = 'CRITICAL' and not p_blocking)
     or p_exception_details is null
     or jsonb_typeof(p_exception_details) <> 'object'
     or p_exception_details = '{}'::jsonb
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_package_state_version is null
     or p_expected_package_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_exception_details
     )
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'EXCEPTION_REGISTRATION_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_EXCEPTION_REGISTRATION_REQUEST_V1',
    'acceptance_package_id', p_acceptance_package_id,
    'exception_code', p_exception_code,
    'severity', p_severity,
    'blocking', p_blocking,
    'client_acceptance_required', p_client_acceptance_required,
    'source_test_result_id', p_source_test_result_id,
    'exception_details', p_exception_details,
    'expected_installation_version',
      p_expected_installation_version,
    'expected_package_state_version',
      p_expected_package_state_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select package.*
  into v_package
  from public.atlas_installation_acceptance_packages as package
  where package.id = p_acceptance_package_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'ACCEPTANCE_PACKAGE_NOT_FOUND';
  end if;

  select exception_record.*
  into v_existing
  from public.atlas_installation_exception_records as exception_record
  where exception_record.installation_id = v_package.installation_id
    and exception_record.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'EXCEPTION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'exception_record_id', v_existing.id,
      'exception_code', v_existing.exception_code,
      'exception_version', v_existing.exception_version,
      'severity', v_existing.severity,
      'exception_status', v_existing.exception_status,
      'state_version', v_existing.state_version,
      'blocking', v_existing.blocking,
      'next_action', 'RESOLVE_EXCEPTION'
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_package.installation_id
  for update;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_package.state_version <>
       p_expected_package_state_version then
    raise exception using
      errcode = '40001',
      message = 'ACCEPTANCE_PACKAGE_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'FINAL_APPROVAL'
     or v_package.package_status not in (
       'DRAFT', 'READY_FOR_DELIVERY'
     ) then
    raise exception using
      errcode = '22023',
      message = 'EXCEPTION_REGISTRATION_NOT_ALLOWED_IN_CURRENT_STATE';
  end if;

  if p_source_test_result_id is not null
     and not exists (
       select 1
       from public.atlas_installation_test_results as result
       where result.id = p_source_test_result_id
         and result.test_run_id = v_package.source_test_run_id
         and result.test_plan_id = v_package.source_test_plan_id
         and result.installation_id = v_package.installation_id
         and result.empresa_id = v_package.empresa_id
     ) then
    raise exception using
      errcode = '22023',
      message = 'EXCEPTION_SOURCE_TEST_RESULT_MISMATCH';
  end if;

  select coalesce(max(exception_record.exception_version), 0) + 1
  into v_exception_version
  from public.atlas_installation_exception_records as exception_record
  where exception_record.acceptance_package_id = v_package.id
    and exception_record.exception_code = p_exception_code;

  v_exception_payload := jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_EXCEPTION_V1',
    'acceptance_package_id', v_package.id,
    'package_sha256', v_package.package_sha256,
    'installation_id', v_package.installation_id,
    'empresa_id', v_package.empresa_id,
    'exception_code', p_exception_code,
    'exception_version', v_exception_version,
    'severity', p_severity,
    'blocking', p_blocking,
    'client_acceptance_required', p_client_acceptance_required,
    'source_test_result_id', p_source_test_result_id,
    'exception_details', p_exception_details
  );
  v_exception_sha256 := public.atlas_normalization_sha256(
    v_exception_payload::text
  );

  v_actor_role_code :=
    public.atlas_acceptance_platform_role_for_permission(
      'INSTALLATION_ACCEPTANCE_PREPARE'
    );

  insert into public.atlas_installation_exception_records (
    acceptance_package_id,
    installation_id,
    empresa_id,
    exception_code,
    exception_version,
    severity,
    exception_status,
    blocking,
    client_acceptance_required,
    source_test_result_id,
    exception_payload,
    exception_sha256,
    request_sha256,
    state_version,
    idempotency_key,
    metadata,
    created_at,
    updated_at
  )
  values (
    v_package.id,
    v_package.installation_id,
    v_package.empresa_id,
    p_exception_code,
    v_exception_version,
    p_severity,
    'OPEN',
    p_blocking,
    p_client_acceptance_required,
    p_source_test_result_id,
    v_exception_payload,
    v_exception_sha256,
    v_request_sha256,
    1,
    p_request_id,
    jsonb_build_object(
      'request_contract', v_request_payload,
      'request_metadata', p_metadata
    ),
    v_now,
    v_now
  )
  returning * into v_created;

  v_event_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_EVENT_V1',
    'exception_record_id', v_created.id,
    'exception_code', v_created.exception_code,
    'exception_version', v_created.exception_version,
    'severity', v_created.severity,
    'blocking', v_created.blocking,
    'exception_sha256', v_created.exception_sha256,
    'request_sha256', v_created.request_sha256
  );

  insert into public.atlas_installation_acceptance_events (
    acceptance_package_id, installation_id, empresa_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, reason_code,
    request_id, acceptance_version, evidence_reference,
    evidence_sha256, event_payload, metadata
  )
  values (
    v_package.id, v_package.installation_id, v_package.empresa_id,
    'EXCEPTION', v_created.id, 'EXCEPTION_REGISTERED', null, 'OPEN',
    v_actor_user_id, v_actor_role_code, 'B2_ACCEPTANCE_ENGINE',
    'EXCEPTION_SCOPE_REGISTERED', p_request_id,
    v_package.acceptance_version,
    format(
      'exception://%s/%s/%s',
      v_package.installation_id,
      v_created.exception_code,
      v_created.exception_version
    ),
    v_created.exception_sha256, v_event_payload,
    jsonb_build_object('request_metadata', p_metadata)
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_EXCEPTION_REGISTERED',
    'acceptance_package_id', v_package.id,
    'exception_record_id', v_created.id,
    'exception_code', v_created.exception_code,
    'exception_version', v_created.exception_version,
    'severity', v_created.severity,
    'exception_status', v_created.exception_status,
    'state_version', v_created.state_version,
    'blocking', v_created.blocking,
    'critical_risk_acceptance_enabled', false,
    'next_action', 'RESOLVE_EXCEPTION'
  );
end;
$$;

create or replace function
public.atlas_resolve_installation_exception(
  p_exception_record_id uuid,
  p_resolution text,
  p_reason_code text,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_resolution_details jsonb,
  p_request_id uuid,
  p_expected_installation_version bigint,
  p_expected_exception_state_version bigint,
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
  v_exception public.atlas_installation_exception_records%rowtype;
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_request_payload jsonb;
  v_event_payload jsonb;
  v_request_sha256 text;
  v_is_client_owner boolean := false;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_exception_record_id is null
     or p_resolution not in (
       'REMEDIATED', 'ACCEPTED_RISK', 'REJECTED'
     )
     or p_reason_code is null
     or p_reason_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_reason_code) not between 5 and 100
     or not public.atlas_acceptance_evidence_reference_is_safe(
       p_evidence_reference
     )
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_resolution_details is null
     or jsonb_typeof(p_resolution_details) <> 'object'
     or p_resolution_details = '{}'::jsonb
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_exception_state_version is null
     or p_expected_exception_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_resolution_details
     )
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'EXCEPTION_RESOLUTION_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_EXCEPTION_RESOLUTION_REQUEST_V1',
    'exception_record_id', p_exception_record_id,
    'resolution', p_resolution,
    'reason_code', p_reason_code,
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', p_evidence_sha256,
    'resolution_details', p_resolution_details,
    'expected_installation_version',
      p_expected_installation_version,
    'expected_exception_state_version',
      p_expected_exception_state_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select exception_record.*
  into v_exception
  from public.atlas_installation_exception_records as exception_record
  where exception_record.id = p_exception_record_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'EXCEPTION_RECORD_NOT_FOUND';
  end if;

  if v_exception.resolution_request_id = p_request_id then
    if v_exception.resolution_request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'EXCEPTION_RESOLUTION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'exception_record_id', v_exception.id,
      'exception_status', v_exception.exception_status,
      'state_version', v_exception.state_version,
      'resolution_evidence_sha256',
        v_exception.resolution_evidence_sha256,
      'next_action', 'SUBMIT_ACCEPTANCE_PACKAGE'
    );
  end if;

  select package.*
  into v_package
  from public.atlas_installation_acceptance_packages as package
  where package.id = v_exception.acceptance_package_id
  for update;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_exception.installation_id
  for update;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_exception.state_version <>
       p_expected_exception_state_version then
    raise exception using
      errcode = '40001', message = 'EXCEPTION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'FINAL_APPROVAL'
     or v_package.package_status not in (
       'DRAFT', 'READY_FOR_DELIVERY'
     )
     or v_exception.exception_status <> 'OPEN' then
    raise exception using
      errcode = '22023',
      message = 'EXCEPTION_RESOLUTION_NOT_ALLOWED_IN_CURRENT_STATE';
  end if;

  if p_resolution = 'ACCEPTED_RISK' then
    if v_exception.severity = 'CRITICAL' then
      raise exception using
        errcode = '42501',
        message = 'CRITICAL_EXCEPTION_RISK_ACCEPTANCE_FORBIDDEN';
    end if;

    v_is_client_owner :=
      public.atlas_acceptance_current_user_is_client_owner(
        v_exception.empresa_id
      );

    if not v_is_client_owner then
      raise exception using
        errcode = '42501',
        message = 'EXCEPTION_RISK_ACCEPTANCE_REQUIRES_CLIENT_OWNER';
    end if;

    v_actor_role_code := 'OWNER';
  else
    if not public.atlas_platform_has_permission(
      'INSTALLATION_ACCEPTANCE_PREPARE'
    ) then
      raise exception using
        errcode = '42501',
        message = 'INSTALLATION_ACCEPTANCE_PREPARE_FORBIDDEN';
    end if;

    v_actor_role_code :=
      public.atlas_acceptance_platform_role_for_permission(
        'INSTALLATION_ACCEPTANCE_PREPARE'
      );
  end if;

  update public.atlas_installation_exception_records
  set
    exception_status = p_resolution,
    accepted_by_user_id = case
      when p_resolution = 'ACCEPTED_RISK' then v_actor_user_id
      else null
    end,
    accepted_at = case
      when p_resolution = 'ACCEPTED_RISK' then clock_timestamp()
      else null
    end,
    acceptance_evidence_reference = case
      when p_resolution = 'ACCEPTED_RISK'
        then p_evidence_reference
      else null
    end,
    acceptance_evidence_sha256 = case
      when p_resolution = 'ACCEPTED_RISK' then p_evidence_sha256
      else null
    end,
    resolution_request_id = p_request_id,
    resolution_request_sha256 = v_request_sha256,
    resolution_reason_code = p_reason_code,
    resolved_by_user_id = v_actor_user_id,
    resolved_at = clock_timestamp(),
    resolution_evidence_reference = p_evidence_reference,
    resolution_evidence_sha256 = p_evidence_sha256,
    state_version = state_version + 1,
    metadata = metadata || jsonb_build_object(
      'resolution_contract', v_request_payload,
      'resolution_metadata', p_metadata
    ),
    updated_at = clock_timestamp()
  where id = v_exception.id
  returning * into v_exception;

  v_event_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_EVENT_V1',
    'exception_record_id', v_exception.id,
    'exception_sha256', v_exception.exception_sha256,
    'resolution', v_exception.exception_status,
    'resolution_request_sha256',
      v_exception.resolution_request_sha256,
    'resolution_evidence_sha256',
      v_exception.resolution_evidence_sha256,
    'client_owner_authority', v_is_client_owner
  );

  insert into public.atlas_installation_acceptance_events (
    acceptance_package_id, installation_id, empresa_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, reason_code,
    request_id, acceptance_version, evidence_reference,
    evidence_sha256, event_payload, metadata
  )
  values (
    v_package.id, v_package.installation_id, v_package.empresa_id,
    'EXCEPTION', v_exception.id, 'EXCEPTION_RESOLVED',
    'OPEN', v_exception.exception_status,
    v_actor_user_id, v_actor_role_code, 'B2_ACCEPTANCE_ENGINE',
    p_reason_code, p_request_id, v_package.acceptance_version,
    p_evidence_reference, p_evidence_sha256, v_event_payload,
    jsonb_build_object('request_metadata', p_metadata)
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_EXCEPTION_RESOLVED',
    'acceptance_package_id', v_package.id,
    'exception_record_id', v_exception.id,
    'exception_status', v_exception.exception_status,
    'state_version', v_exception.state_version,
    'severity', v_exception.severity,
    'client_owner_authority', v_is_client_owner,
    'critical_risk_acceptance_enabled', false,
    'resolution_evidence_sha256',
      v_exception.resolution_evidence_sha256,
    'next_action', 'SUBMIT_ACCEPTANCE_PACKAGE'
  );
end;
$$;

create or replace function
public.atlas_submit_installation_acceptance_package(
  p_acceptance_package_id uuid,
  p_delivery_evidence_reference text,
  p_delivery_evidence_sha256 text,
  p_delivery_details jsonb,
  p_request_id uuid,
  p_expected_installation_version bigint,
  p_expected_package_state_version bigint,
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
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_g03_gate public.atlas_installation_gates%rowtype;
  v_g03_approval public.atlas_installation_approvals%rowtype;
  v_readiness jsonb;
  v_request_payload jsonb;
  v_event_payload jsonb;
  v_training_evidence jsonb;
  v_exception_evidence jsonb;
  v_request_sha256 text;
  v_training_root_sha256 text;
  v_exception_root_sha256 text;
  v_completed_training_count integer;
  v_unfinished_training_count integer;
  v_exception_count integer;
  v_unresolved_exception_count integer;
  v_critical_exception_count integer;
  v_satisfied_count integer;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_PREPARE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACCEPTANCE_PREPARE_FORBIDDEN';
  end if;

  if p_acceptance_package_id is null
     or not public.atlas_acceptance_evidence_reference_is_safe(
       p_delivery_evidence_reference
     )
     or p_delivery_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_delivery_details is null
     or jsonb_typeof(p_delivery_details) <> 'object'
     or p_delivery_details = '{}'::jsonb
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_package_state_version is null
     or p_expected_package_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_delivery_details
     )
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'ACCEPTANCE_DELIVERY_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_DELIVERY_REQUEST_V1',
    'acceptance_package_id', p_acceptance_package_id,
    'delivery_evidence_reference', p_delivery_evidence_reference,
    'delivery_evidence_sha256', p_delivery_evidence_sha256,
    'delivery_details', p_delivery_details,
    'expected_installation_version',
      p_expected_installation_version,
    'expected_package_state_version',
      p_expected_package_state_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select package.*
  into v_package
  from public.atlas_installation_acceptance_packages as package
  where package.id = p_acceptance_package_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'ACCEPTANCE_PACKAGE_NOT_FOUND';
  end if;

  if v_package.delivery_request_id = p_request_id then
    if v_package.delivery_request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'ACCEPTANCE_DELIVERY_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'acceptance_package_id', v_package.id,
      'package_status', v_package.package_status,
      'state_version', v_package.state_version,
      'satisfied_requirements', 5,
      'pending_requirements', 3,
      'next_action', 'RECORD_CLIENT_ACCEPTANCE'
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_package.installation_id
  for update;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_package.state_version <>
       p_expected_package_state_version then
    raise exception using
      errcode = '40001',
      message = 'ACCEPTANCE_PACKAGE_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'FINAL_APPROVAL'
     or v_package.package_status not in (
       'DRAFT', 'READY_FOR_DELIVERY'
     ) then
    raise exception using
      errcode = '22023',
      message = 'ACCEPTANCE_DELIVERY_NOT_ALLOWED_IN_CURRENT_STATE';
  end if;

  v_readiness :=
    public.atlas_compute_installation_g03_readiness(
      v_installation.id
    );

  if not coalesce((v_readiness->>'ready')::boolean, false)
     or v_readiness->>'test_plan_id' <>
       v_package.source_test_plan_id::text
     or v_readiness->>'test_run_id' <>
       v_package.source_test_run_id::text
     or v_readiness->>'source_manifest_id' <>
       v_package.source_manifest_id::text
     or v_readiness->>'plan_sha256' <>
       v_package.source_test_plan_sha256
     or v_readiness->>'evidence_root_sha256' <>
       v_package.source_test_evidence_root_sha256
     or v_readiness->>'source_manifest_sha256' <>
       v_package.source_manifest_sha256
     or v_readiness->>'readiness_sha256' <>
       v_package.source_g03_readiness_sha256 then
    raise exception using
      errcode = '42501',
      message = 'ACCEPTANCE_PACKAGE_G03_BINDING_STALE';
  end if;

  select gate_record.*
  into v_g03_gate
  from public.atlas_installation_gates as gate_record
  where gate_record.id = v_package.source_g03_gate_id
    and gate_record.installation_id = v_installation.id
    and gate_record.gate_code = 'G03'
    and gate_record.gate_version = v_package.source_g03_gate_version
    and gate_record.status = 'APPROVED'
    and gate_record.platform_approved;

  select approval.*
  into v_g03_approval
  from public.atlas_installation_approvals as approval
  where approval.gate_id = v_g03_gate.id
    and approval.gate_code = 'G03'
    and approval.gate_version = v_g03_gate.gate_version
    and approval.authority_type = 'PLATFORM'
    and approval.decision = 'APPROVED'
  order by approval.created_at desc, approval.id desc
  limit 1;

  if v_g03_gate.id is null
     or v_g03_approval.id is null
     or not public.atlas_g03_approval_evidence_matches_readiness_v1(
       v_g03_approval.evidence,
       v_readiness
     ) then
    raise exception using
      errcode = '42501',
      message = 'ACCEPTANCE_PACKAGE_G03_APPROVAL_STALE';
  end if;

  select
    count(*) filter (
      where training.training_status = 'COMPLETED'
    )::integer,
    count(*) filter (
      where training.training_status in ('PLANNED', 'IN_PROGRESS')
    )::integer,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'training_record_id', training.id,
        'training_code', training.training_code,
        'training_version', training.training_version,
        'training_sha256', training.training_sha256,
        'evidence_sha256', training.evidence_sha256,
        'state_version', training.state_version
      ) order by training.training_code, training.training_version
    ) filter (
      where training.training_status = 'COMPLETED'
    ), '[]'::jsonb)
  into
    v_completed_training_count,
    v_unfinished_training_count,
    v_training_evidence
  from public.atlas_installation_training_records as training
  where training.acceptance_package_id = v_package.id
    and training.training_status <> 'SUPERSEDED';

  if v_completed_training_count < 1
     or v_unfinished_training_count > 0 then
    raise exception using
      errcode = '42501',
      message = 'ACCEPTANCE_TRAINING_INCOMPLETE';
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where exception_record.exception_status in ('OPEN', 'REJECTED')
    )::integer,
    count(*) filter (
      where exception_record.severity = 'CRITICAL'
        and exception_record.exception_status <> 'REMEDIATED'
    )::integer,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'exception_record_id', exception_record.id,
        'exception_code', exception_record.exception_code,
        'exception_version', exception_record.exception_version,
        'severity', exception_record.severity,
        'exception_status', exception_record.exception_status,
        'exception_sha256', exception_record.exception_sha256,
        'resolution_evidence_sha256',
          exception_record.resolution_evidence_sha256,
        'state_version', exception_record.state_version
      ) order by
        exception_record.severity,
        exception_record.exception_code,
        exception_record.exception_version
    ), '[]'::jsonb)
  into
    v_exception_count,
    v_unresolved_exception_count,
    v_critical_exception_count,
    v_exception_evidence
  from public.atlas_installation_exception_records
    as exception_record
  where exception_record.acceptance_package_id = v_package.id
    and exception_record.exception_status <> 'SUPERSEDED';

  if v_unresolved_exception_count > 0 then
    raise exception using
      errcode = '42501',
      message = 'ACCEPTANCE_EXCEPTIONS_UNRESOLVED';
  end if;

  if v_critical_exception_count > 0 then
    raise exception using
      errcode = '42501',
      message = 'ACCEPTANCE_CRITICAL_DEFECTS_PRESENT';
  end if;

  v_training_root_sha256 := public.atlas_normalization_sha256(
    jsonb_build_object(
      'contract_version', 'B2_TRAINING_EVIDENCE_ROOT_V1',
      'acceptance_package_id', v_package.id,
      'package_sha256', v_package.package_sha256,
      'training_records', v_training_evidence
    )::text
  );

  v_exception_root_sha256 := public.atlas_normalization_sha256(
    jsonb_build_object(
      'contract_version', 'B2_EXCEPTION_EVIDENCE_ROOT_V1',
      'acceptance_package_id', v_package.id,
      'package_sha256', v_package.package_sha256,
      'exception_records', v_exception_evidence
    )::text
  );

  update public.atlas_installation_acceptance_requirements
  set
    requirement_status = 'SATISFIED',
    evidence_kind = case requirement_code
      when 'ZERO_CRITICAL_DEFECTS' then 'DEFECT_REPORT'
      when 'EXCEPTIONS_ACCEPTED' then 'EXCEPTION_DECISION'
      when 'TRAINING_COMPLETED' then 'TRAINING_RECORD'
    end,
    evidence_reference = case requirement_code
      when 'ZERO_CRITICAL_DEFECTS' then format(
        'acceptance://%s/defects/%s',
        v_package.installation_id,
        v_package.id
      )
      when 'EXCEPTIONS_ACCEPTED' then format(
        'exception://%s/package/%s',
        v_package.installation_id,
        v_package.id
      )
      when 'TRAINING_COMPLETED' then format(
        'training://%s/package/%s',
        v_package.installation_id,
        v_package.id
      )
    end,
    evidence_sha256 = case requirement_code
      when 'ZERO_CRITICAL_DEFECTS' then v_exception_root_sha256
      when 'EXCEPTIONS_ACCEPTED' then v_exception_root_sha256
      when 'TRAINING_COMPLETED' then v_training_root_sha256
    end,
    verification_payload = case requirement_code
      when 'ZERO_CRITICAL_DEFECTS' then jsonb_build_object(
        'contract_version', 'B2_ACCEPTANCE_REQUIREMENT_EVIDENCE_V1',
        'requirement_code', requirement_code,
        'critical_open_count', v_critical_exception_count,
        'exception_evidence_root_sha256',
          v_exception_root_sha256
      )
      when 'EXCEPTIONS_ACCEPTED' then jsonb_build_object(
        'contract_version', 'B2_ACCEPTANCE_REQUIREMENT_EVIDENCE_V1',
        'requirement_code', requirement_code,
        'exception_count', v_exception_count,
        'unresolved_exception_count',
          v_unresolved_exception_count,
        'exception_evidence_root_sha256',
          v_exception_root_sha256
      )
      when 'TRAINING_COMPLETED' then jsonb_build_object(
        'contract_version', 'B2_ACCEPTANCE_REQUIREMENT_EVIDENCE_V1',
        'requirement_code', requirement_code,
        'completed_training_count',
          v_completed_training_count,
        'training_evidence_root_sha256',
          v_training_root_sha256
      )
    end,
    verified_by_user_id = v_actor_user_id,
    verified_at = clock_timestamp(),
    blocking_reason_code = null,
    updated_at = clock_timestamp()
  where acceptance_package_id = v_package.id
    and requirement_code in (
      'ZERO_CRITICAL_DEFECTS',
      'EXCEPTIONS_ACCEPTED',
      'TRAINING_COMPLETED'
    );

  select count(*)::integer
  into v_satisfied_count
  from public.atlas_installation_acceptance_requirements
  where acceptance_package_id = v_package.id
    and requirement_status = 'SATISFIED';

  if v_satisfied_count <> 5 then
    raise exception using
      errcode = '55000',
      message = 'ACCEPTANCE_DELIVERY_REQUIREMENT_SET_INCOMPLETE';
  end if;

  v_actor_role_code :=
    public.atlas_acceptance_platform_role_for_permission(
      'INSTALLATION_ACCEPTANCE_PREPARE'
    );

  update public.atlas_installation_acceptance_packages
  set
    package_status = 'DELIVERED',
    state_version = state_version + 1,
    delivery_request_id = p_request_id,
    delivery_request_sha256 = v_request_sha256,
    delivery_evidence_reference = p_delivery_evidence_reference,
    delivery_evidence_sha256 = p_delivery_evidence_sha256,
    delivered_by_user_id = v_actor_user_id,
    ready_at = coalesce(ready_at, clock_timestamp()),
    delivered_at = clock_timestamp(),
    metadata = metadata || jsonb_build_object(
      'delivery_contract', v_request_payload,
      'delivery_metadata', p_metadata,
      'training_evidence_root_sha256',
        v_training_root_sha256,
      'exception_evidence_root_sha256',
        v_exception_root_sha256
    ),
    updated_at = clock_timestamp()
  where id = v_package.id
  returning * into v_package;

  v_event_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_EVENT_V1',
    'acceptance_package_id', v_package.id,
    'package_sha256', v_package.package_sha256,
    'delivery_request_sha256',
      v_package.delivery_request_sha256,
    'delivery_evidence_sha256',
      v_package.delivery_evidence_sha256,
    'training_evidence_root_sha256',
      v_training_root_sha256,
    'exception_evidence_root_sha256',
      v_exception_root_sha256,
    'satisfied_requirements', v_satisfied_count,
    'pending_requirements', 8 - v_satisfied_count,
    'delivery_details', p_delivery_details
  );

  insert into public.atlas_installation_acceptance_events (
    acceptance_package_id, installation_id, empresa_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, reason_code,
    request_id, acceptance_version, evidence_reference,
    evidence_sha256, event_payload, metadata
  )
  values (
    v_package.id, v_package.installation_id, v_package.empresa_id,
    'PACKAGE', v_package.id, 'ACCEPTANCE_PACKAGE_DELIVERED',
    'DRAFT', 'DELIVERED', v_actor_user_id, v_actor_role_code,
    'B2_ACCEPTANCE_ENGINE', 'DELIVERY_REQUIREMENTS_VERIFIED',
    p_request_id, v_package.acceptance_version,
    p_delivery_evidence_reference, p_delivery_evidence_sha256,
    v_event_payload,
    jsonb_build_object('request_metadata', p_metadata)
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_ACCEPTANCE_PACKAGE_DELIVERED',
    'installation_id', v_package.installation_id,
    'acceptance_package_id', v_package.id,
    'package_status', v_package.package_status,
    'state_version', v_package.state_version,
    'package_sha256', v_package.package_sha256,
    'satisfied_requirements', v_satisfied_count,
    'pending_requirements', 8 - v_satisfied_count,
    'completed_training_records', v_completed_training_count,
    'exception_records', v_exception_count,
    'critical_open_exceptions', v_critical_exception_count,
    'training_evidence_root_sha256', v_training_root_sha256,
    'exception_evidence_root_sha256', v_exception_root_sha256,
    'client_acceptance_recorded', false,
    'g04_decided', false,
    'certificate_issued', false,
    'active_enabled', false,
    'next_action', 'RECORD_CLIENT_ACCEPTANCE'
  );
end;
$$;

revoke all on function
public.atlas_materialize_installation_acceptance_package(
  uuid, uuid, bigint, jsonb
)
from public, anon;
revoke all on function
public.atlas_register_installation_training_record(
  uuid, text, jsonb, text[], timestamptz, jsonb,
  uuid, bigint, bigint, jsonb
)
from public, anon;
revoke all on function
public.atlas_complete_installation_training_record(
  uuid, timestamptz, text, text, jsonb,
  uuid, bigint, bigint, jsonb
)
from public, anon;
revoke all on function
public.atlas_register_installation_exception(
  uuid, text, text, boolean, boolean, uuid, jsonb,
  uuid, bigint, bigint, jsonb
)
from public, anon;
revoke all on function
public.atlas_resolve_installation_exception(
  uuid, text, text, text, text, jsonb,
  uuid, bigint, bigint, jsonb
)
from public, anon;
revoke all on function
public.atlas_submit_installation_acceptance_package(
  uuid, text, text, jsonb, uuid, bigint, bigint, jsonb
)
from public, anon;

grant execute on function
public.atlas_materialize_installation_acceptance_package(
  uuid, uuid, bigint, jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_register_installation_training_record(
  uuid, text, jsonb, text[], timestamptz, jsonb,
  uuid, bigint, bigint, jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_complete_installation_training_record(
  uuid, timestamptz, text, text, jsonb,
  uuid, bigint, bigint, jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_register_installation_exception(
  uuid, text, text, boolean, boolean, uuid, jsonb,
  uuid, bigint, bigint, jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_resolve_installation_exception(
  uuid, text, text, text, text, jsonb,
  uuid, bigint, bigint, jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_submit_installation_acceptance_package(
  uuid, text, text, jsonb, uuid, bigint, bigint, jsonb
)
to authenticated, service_role;

comment on function
public.atlas_materialize_installation_acceptance_package(
  uuid, uuid, bigint, jsonb
) is
  'B2.2J.2: materializa paquete ligado a manifest, pruebas y aprobacion G03 vigentes.';
comment on function
public.atlas_register_installation_training_record(
  uuid, text, jsonb, text[], timestamptz, jsonb,
  uuid, bigint, bigint, jsonb
) is
  'B2.2J.2: registra capacitacion versionada sin declararla completada.';
comment on function
public.atlas_complete_installation_training_record(
  uuid, timestamptz, text, text, jsonb,
  uuid, bigint, bigint, jsonb
) is
  'B2.2J.2: completa capacitacion solo con evidencia segura e idempotente.';
comment on function
public.atlas_register_installation_exception(
  uuid, text, text, boolean, boolean, uuid, jsonb,
  uuid, bigint, bigint, jsonb
) is
  'B2.2J.2: registra defecto o excepcion con severidad, fuente y hash canonico.';
comment on function
public.atlas_resolve_installation_exception(
  uuid, text, text, text, text, jsonb,
  uuid, bigint, bigint, jsonb
) is
  'B2.2J.2: resuelve excepciones; riesgo no critico exige OWNER del cliente.';
comment on function
public.atlas_submit_installation_acceptance_package(
  uuid, text, text, jsonb, uuid, bigint, bigint, jsonb
) is
  'B2.2J.2: entrega paquete con G03 vigente, capacitacion completa y cero defectos criticos.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2J2_ACCEPTANCE_PACKAGE_TRAINING_EXCEPTION_RPCS_INSTALLED',
  'next_action', 'CERTIFY_J2_RPC_GUARDS',
  'acceptance_rpcs', 6,
  'authority_helpers', 2,
  'acceptance_package_records', (
    select count(*)
    from public.atlas_installation_acceptance_packages
  ),
  'training_records', (
    select count(*)
    from public.atlas_installation_training_records
  ),
  'exception_records', (
    select count(*)
    from public.atlas_installation_exception_records
  ),
  'acceptance_event_records', (
    select count(*)
    from public.atlas_installation_acceptance_events
  ),
  'g03_revalidation_enabled', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'client_owner_risk_authority_enabled', true,
  'critical_risk_acceptance_enabled', false,
  'training_evidence_required', true,
  'delivery_requires_five_requirements', true,
  'client_acceptance_rpc_enabled', false,
  'g04_decision_enabled', false,
  'certificate_issuance_enabled', false,
  'active_auto_transition_enabled', false,
  'credential_values_stored', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version,
  'direct_authenticated_write', false
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
