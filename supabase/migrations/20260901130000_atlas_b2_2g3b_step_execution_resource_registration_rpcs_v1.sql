-- ATLAS B2.2G.3B
-- RPC gobernadas para iniciar/completar pasos y registrar recursos.
-- Corte: 2026-09-01
--
-- Instala capacidad de ejecucion en dos fases. No ejecuta pasos ni crea
-- recursos del tenant durante la migracion.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_provisioning_operation_receipts'
     ) is null
     or to_regclass(
       'public.atlas_provisioned_resources'
     ) is null
     or to_regprocedure(
       'public.atlas_run_installation_provisioning_preflight(uuid,uuid,bigint,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_g02_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception 'B2.2G.3B requiere B2.2G.3A instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_begin_installation_provisioning_step(
  p_provisioning_step_id uuid,
  p_request_id uuid,
  p_expected_step_state_version bigint,
  p_expected_plan_state_version bigint,
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
  v_plan_id uuid;
  v_step public.atlas_installation_provisioning_steps%rowtype;
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing_event public.atlas_installation_provisioning_events%rowtype;
  v_preflight_event public.atlas_installation_provisioning_events%rowtype;
  v_readiness jsonb;
  v_required_preflight_count bigint;
  v_passed_preflight_count bigint;
  v_new_step_state_version bigint;
  v_new_plan_state_version bigint;
  v_new_attempt_number integer;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_EXECUTE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PROVISIONING_EXECUTE_FORBIDDEN';
  end if;

  if p_provisioning_step_id is null
     or p_request_id is null
     or p_expected_step_state_version is null
     or p_expected_step_state_version < 1
     or p_expected_plan_state_version is null
     or p_expected_plan_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_BEGIN_REQUIRED_FIELDS_INVALID';
  end if;

  select step.provisioning_plan_id
  into v_plan_id
  from public.atlas_installation_provisioning_steps as step
  where step.id = p_provisioning_step_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_STEP_NOT_FOUND';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = v_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  select step.*
  into v_step
  from public.atlas_installation_provisioning_steps as step
  where step.id = p_provisioning_step_id
    and step.provisioning_plan_id = v_plan.id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_STEP_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <>
         'PROVISIONING_STEP_EXECUTION_STARTED'
       or v_existing_event.entity_type <> 'STEP'
       or v_existing_event.entity_id <> v_step.id
       or coalesce(
         (
           v_existing_event.evidence->>
             'expected_step_state_version'
         )::bigint,
         0
       ) <> p_expected_step_state_version
       or coalesce(
         (
           v_existing_event.evidence->>
             'expected_plan_state_version'
         )::bigint,
         0
       ) <> p_expected_plan_state_version
       or coalesce(
         (
           v_existing_event.evidence->>
             'expected_installation_version'
         )::bigint,
         0
       ) <> p_expected_installation_version
       or v_existing_event.metadata <> p_metadata then
      raise exception using
        errcode = '22023',
        message =
          'PROVISIONING_STEP_BEGIN_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_plan.installation_id,
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'execution_request_id', p_request_id,
      'step_status', v_existing_event.to_status,
      'step_state_version', coalesce(
        (
          v_existing_event.evidence->>
            'resulting_step_state_version'
        )::bigint,
        v_step.state_version
      ),
      'plan_state_version', coalesce(
        (
          v_existing_event.evidence->>
            'resulting_plan_state_version'
        )::bigint,
        v_plan.state_version
      ),
      'attempt_number', coalesce(
        (v_existing_event.evidence->>'attempt_number')::integer,
        v_step.attempt_count
      ),
      'executor_contract', jsonb_build_object(
        'resource_code', v_step.resource_code,
        'step_code', v_step.step_code,
        'operation_type', v_step.operation_type,
        'target_reference', v_step.target_reference,
        'input_payload', v_step.input_payload,
        'input_sha256', v_step.input_sha256
      )
    );
  end if;

  if v_step.state_version <> p_expected_step_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_STEP_VERSION_CONFLICT';
  end if;

  if v_plan.state_version <> p_expected_plan_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  if v_step.step_status not in ('PENDING', 'READY', 'FAILED') then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_NOT_EXECUTABLE';
  end if;

  if v_step.attempt_count >= v_step.max_attempts then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_MAX_ATTEMPTS_REACHED';
  end if;

  if v_plan.plan_status not in ('PREFLIGHT_PASSED', 'EXECUTING') then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_NOT_EXECUTABLE';
  end if;

  if exists (
    select 1
    from public.atlas_installation_provisioning_steps as active_step
    where active_step.provisioning_plan_id = v_plan.id
      and active_step.id <> v_step.id
      and active_step.step_status = 'EXECUTING'
  ) then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_PLAN_HAS_ACTIVE_STEP';
  end if;

  if v_plan.plan_sha256 <>
     public.atlas_normalization_sha256(v_plan.plan_payload::text) then
    raise exception using
      errcode = '22023', message = 'PROVISIONING_PLAN_HASH_MISMATCH';
  end if;

  if v_step.input_sha256 <>
     public.atlas_normalization_sha256(v_step.input_payload::text) then
    raise exception using
      errcode = '22023', message = 'PROVISIONING_STEP_INPUT_HASH_MISMATCH';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_plan.installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'PROVISIONING' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_PROVISIONING';
  end if;

  if v_step.installation_id <> v_installation.id
     or v_step.empresa_id <> v_installation.empresa_id
     or v_plan.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_EXECUTION_TENANT_MISMATCH';
  end if;

  select event_record.*
  into v_preflight_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.event_code = 'PROVISIONING_PREFLIGHT_COMPLETED'
    and event_record.to_status = 'PREFLIGHT_PASSED'
  order by event_record.created_at desc, event_record.id desc
  limit 1;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_PREFLIGHT_PASSED_EVENT_REQUIRED';
  end if;

  select count(*)
  into v_required_preflight_count
  from public.atlas_provisioning_preflight_definitions as definition
  where definition.active = true
    and definition.required = true;

  select count(*)
  into v_passed_preflight_count
  from public.atlas_provisioning_preflight_definitions as definition
  where definition.active = true
    and definition.required = true
    and exists (
      select 1
      from public.atlas_installation_preflight_results as result_record
      where result_record.provisioning_plan_id = v_plan.id
        and result_record.check_code = definition.check_code
        and result_record.outcome = 'PASSED'
        and result_record.evaluated_plan_state_version = coalesce(
          (
            v_preflight_event.evidence->>
              'resulting_plan_state_version'
          )::bigint,
          0
        )
        and result_record.evaluation_version = (
          select max(latest_result.evaluation_version)
          from public.atlas_installation_preflight_results
            as latest_result
          where latest_result.provisioning_plan_id = v_plan.id
            and latest_result.check_code = definition.check_code
        )
    );

  if v_required_preflight_count <> 14
     or v_passed_preflight_count <> v_required_preflight_count then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_PREFLIGHT_RESULTS_STALE_OR_INCOMPLETE';
  end if;

  v_readiness := public.atlas_compute_installation_g02_readiness(
    v_installation.id
  );

  if not coalesce((v_readiness->>'ready')::boolean, false)
     or (v_readiness->>'canonical_data_version_id')
       is distinct from v_plan.canonical_data_version_id::text
     or not exists (
       select 1
       from public.atlas_installation_gates as gate_record
       where gate_record.installation_id = v_installation.id
         and gate_record.gate_code = 'G02'
         and gate_record.status = 'APPROVED'
         and gate_record.client_approved = true
     ) then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_G02_STALE_OR_INCOMPLETE';
  end if;

  if exists (
    select 1
    from unnest(v_step.dependency_step_codes)
      as dependency(step_code)
    where not exists (
      select 1
      from public.atlas_installation_provisioning_steps
        as dependency_step
      where dependency_step.provisioning_plan_id = v_plan.id
        and dependency_step.step_code = dependency.step_code
        and dependency_step.step_status in ('SUCCEEDED', 'SKIPPED')
    )
  ) then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_STEP_DEPENDENCIES_NOT_SATISFIED';
  end if;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active = true
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code =
     'INSTALLATION_PROVISIONING_EXECUTE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_EXECUTION_ACTOR_ROLE_NOT_FOUND';
  end if;

  v_new_attempt_number := v_step.attempt_count + 1;
  v_new_step_state_version := v_step.state_version + 1;
  v_new_plan_state_version := v_plan.state_version + 1;

  update public.atlas_installation_provisioning_steps
  set
    step_status = 'EXECUTING',
    state_version = v_new_step_state_version,
    attempt_count = v_new_attempt_number,
    last_error_code = null,
    last_error_message = null,
    started_at = now(),
    completed_at = null,
    metadata = metadata || jsonb_build_object(
      'active_execution_request_id', p_request_id,
      'active_executor_user_id', v_actor_user_id,
      'active_attempt_number', v_new_attempt_number,
      'execution_started_at', now()
    ),
    updated_at = now()
  where id = v_step.id
    and state_version = p_expected_step_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_STEP_VERSION_CONFLICT';
  end if;

  update public.atlas_installation_provisioning_plans
  set
    plan_status = 'EXECUTING',
    state_version = v_new_plan_state_version,
    started_at = coalesce(started_at, now()),
    metadata = metadata || jsonb_build_object(
      'active_step_id', v_step.id,
      'active_execution_request_id', p_request_id
    ),
    updated_at = now()
  where id = v_plan.id
    and state_version = p_expected_plan_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  insert into public.atlas_installation_provisioning_events (
    installation_id,
    empresa_id,
    provisioning_plan_id,
    entity_type,
    entity_id,
    event_code,
    from_status,
    to_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    evidence,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_plan.id,
    'STEP',
    v_step.id,
    'PROVISIONING_STEP_EXECUTION_STARTED',
    v_step.step_status,
    'EXECUTING',
    v_actor_user_id,
    v_actor_role_code,
    'Paso reservado para un intento gobernado de aprovisionamiento.',
    p_request_id,
    jsonb_build_object(
      'expected_step_state_version',
        p_expected_step_state_version,
      'resulting_step_state_version',
        v_new_step_state_version,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'resulting_plan_state_version',
        v_new_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'attempt_number', v_new_attempt_number,
      'input_sha256', v_step.input_sha256,
      'preflight_event_id', v_preflight_event.id
    ),
    p_metadata
  );

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
    'INSTALLATION_PROVISIONING_STEP_STARTED',
    'B2_PROVISIONING_ENGINE',
    'REQUESTED',
    jsonb_build_object(
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'request_id', p_request_id,
      'attempt_number', v_new_attempt_number
    ),
    jsonb_build_object(
      'step_status', 'EXECUTING',
      'step_state_version', v_new_step_state_version,
      'plan_state_version', v_new_plan_state_version
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'PROVISIONING_STEP_EXECUTION_STARTED',
    'installation_id', v_installation.id,
    'provisioning_plan_id', v_plan.id,
    'provisioning_step_id', v_step.id,
    'execution_request_id', p_request_id,
    'step_status', 'EXECUTING',
    'step_state_version', v_new_step_state_version,
    'plan_state_version', v_new_plan_state_version,
    'installation_version', v_installation.version,
    'attempt_number', v_new_attempt_number,
    'max_attempts', v_step.max_attempts,
    'executor_contract', jsonb_build_object(
      'resource_code', v_step.resource_code,
      'step_code', v_step.step_code,
      'operation_type', v_step.operation_type,
      'target_reference', v_step.target_reference,
      'input_payload', v_step.input_payload,
      'input_sha256', v_step.input_sha256
    ),
    'next_action', 'EXECUTE_EXTERNAL_OPERATION_AND_COMPLETE_STEP'
  );
end;
$$;

create or replace function
public.atlas_complete_installation_provisioning_step(
  p_provisioning_step_id uuid,
  p_execution_request_id uuid,
  p_request_id uuid,
  p_expected_step_state_version bigint,
  p_expected_plan_state_version bigint,
  p_expected_installation_version bigint,
  p_outcome text,
  p_executor_code text,
  p_resource_locator jsonb,
  p_result_payload jsonb,
  p_evidence jsonb,
  p_error_code text,
  p_error_message text,
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
  v_plan_id uuid;
  v_step public.atlas_installation_provisioning_steps%rowtype;
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_begin_event public.atlas_installation_provisioning_events%rowtype;
  v_existing_event public.atlas_installation_provisioning_events%rowtype;
  v_existing_receipt public.atlas_provisioning_operation_receipts%rowtype;
  v_receipt public.atlas_provisioning_operation_receipts%rowtype;
  v_resource public.atlas_provisioned_resources%rowtype;
  v_resource_definition public.atlas_provisioning_resource_definitions%rowtype;
  v_readiness jsonb;
  v_output_sha256 text;
  v_receipt_target jsonb;
  v_new_step_state_version bigint;
  v_new_plan_state_version bigint;
  v_new_plan_status text;
  v_all_required_steps_succeeded boolean := false;
  v_attempts_exhausted boolean := false;
  v_completion_payload_sha256 text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_EXECUTE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PROVISIONING_EXECUTE_FORBIDDEN';
  end if;

  if p_provisioning_step_id is null
     or p_execution_request_id is null
     or p_request_id is null
     or p_execution_request_id = p_request_id
     or p_expected_step_state_version is null
     or p_expected_step_state_version < 1
     or p_expected_plan_state_version is null
     or p_expected_plan_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_outcome not in ('SUCCEEDED', 'FAILED')
     or p_executor_code is null
     or p_executor_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_executor_code) not between 3 and 80
     or p_resource_locator is null
     or jsonb_typeof(p_resource_locator) <> 'object'
     or p_result_payload is null
     or jsonb_typeof(p_result_payload) <> 'object'
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb
     or nullif(btrim(p_evidence->>'evidence_reference'), '') is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_resource_locator
     )
     or public.atlas_jsonb_has_forbidden_secret_key(p_result_payload)
     or public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_COMPLETE_REQUIRED_FIELDS_INVALID';
  end if;

  if p_outcome = 'SUCCEEDED'
     and (
       p_resource_locator = '{}'::jsonb
       or p_error_code is not null
       or p_error_message is not null
     ) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_SUCCESS_PAYLOAD_INVALID';
  end if;

  if p_outcome = 'FAILED'
     and (
       nullif(btrim(p_error_code), '') is null
       or nullif(btrim(p_error_message), '') is null
       or p_error_code !~ '^[A-Z][A-Z0-9_]*$'
       or length(p_error_code) > 120
       or length(p_error_message) > 2000
     ) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_FAILURE_PAYLOAD_INVALID';
  end if;

  v_completion_payload_sha256 :=
    public.atlas_normalization_sha256(
      jsonb_build_object(
        'provisioning_step_id', p_provisioning_step_id,
        'execution_request_id', p_execution_request_id,
        'completion_request_id', p_request_id,
        'expected_step_state_version',
          p_expected_step_state_version,
        'expected_plan_state_version',
          p_expected_plan_state_version,
        'expected_installation_version',
          p_expected_installation_version,
        'outcome', p_outcome,
        'executor_code', p_executor_code,
        'resource_locator', p_resource_locator,
        'result_payload', p_result_payload,
        'evidence', p_evidence,
        'error_code', p_error_code,
        'error_message', p_error_message,
        'metadata', p_metadata
      )::text
    );

  select step.provisioning_plan_id
  into v_plan_id
  from public.atlas_installation_provisioning_steps as step
  where step.id = p_provisioning_step_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_STEP_NOT_FOUND';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = v_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  select step.*
  into v_step
  from public.atlas_installation_provisioning_steps as step
  where step.id = p_provisioning_step_id
    and step.provisioning_plan_id = v_plan.id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_STEP_NOT_FOUND';
  end if;

  select receipt.*
  into v_existing_receipt
  from public.atlas_provisioning_operation_receipts as receipt
  where receipt.provisioning_plan_id = v_plan.id
    and receipt.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_receipt.provisioning_step_id <> v_step.id
       or v_existing_receipt.operation_phase <> 'EXECUTION'
       or v_existing_receipt.outcome <> p_outcome
       or v_existing_receipt.executor_code <> p_executor_code
       or coalesce(
         v_existing_receipt.evidence->>'execution_request_id',
         ''
       ) <> p_execution_request_id::text
       or coalesce(
         (
           v_existing_receipt.evidence->>
             'expected_step_state_version'
         )::bigint,
         0
       ) <> p_expected_step_state_version
       or coalesce(
         (
           v_existing_receipt.evidence->>
             'expected_plan_state_version'
         )::bigint,
         0
       ) <> p_expected_plan_state_version
       or coalesce(
         (
           v_existing_receipt.evidence->>
             'expected_installation_version'
         )::bigint,
         0
       ) <> p_expected_installation_version
       or coalesce(
         v_existing_receipt.metadata->>
           'completion_payload_sha256',
         ''
       ) <> v_completion_payload_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'PROVISIONING_STEP_COMPLETE_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    select resource.*
    into v_resource
    from public.atlas_provisioned_resources as resource
    where resource.provisioning_step_id = v_step.id
    limit 1;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_plan.installation_id,
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'receipt_id', v_existing_receipt.id,
      'resource_id', v_resource.id,
      'outcome', v_existing_receipt.outcome,
      'step_status', v_step.step_status,
      'step_state_version', v_step.state_version,
      'plan_status', v_plan.plan_status,
      'plan_state_version', v_plan.state_version
    );
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    raise exception using
      errcode = '22023',
      message =
        'PROVISIONING_STEP_COMPLETE_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  end if;

  if v_step.state_version <> p_expected_step_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_STEP_VERSION_CONFLICT';
  end if;

  if v_plan.state_version <> p_expected_plan_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  if v_step.step_status <> 'EXECUTING' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_NOT_EXECUTING';
  end if;

  if coalesce(
       v_step.metadata->>'active_execution_request_id',
       ''
     ) <> p_execution_request_id::text then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_EXECUTION_REQUEST_MISMATCH';
  end if;

  select event_record.*
  into v_begin_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.request_id = p_execution_request_id
    and event_record.entity_type = 'STEP'
    and event_record.entity_id = v_step.id
    and event_record.event_code =
      'PROVISIONING_STEP_EXECUTION_STARTED'
  limit 1;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_STEP_BEGIN_EVENT_REQUIRED';
  end if;

  if v_plan.plan_status <> 'EXECUTING' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_NOT_EXECUTING';
  end if;

  if v_plan.plan_sha256 <>
     public.atlas_normalization_sha256(v_plan.plan_payload::text) then
    raise exception using
      errcode = '22023', message = 'PROVISIONING_PLAN_HASH_MISMATCH';
  end if;

  if v_step.input_sha256 <>
     public.atlas_normalization_sha256(v_step.input_payload::text) then
    raise exception using
      errcode = '22023', message = 'PROVISIONING_STEP_INPUT_HASH_MISMATCH';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_plan.installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'PROVISIONING' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_PROVISIONING';
  end if;

  if v_step.installation_id <> v_installation.id
     or v_step.empresa_id <> v_installation.empresa_id
     or v_plan.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_EXECUTION_TENANT_MISMATCH';
  end if;

  v_readiness := public.atlas_compute_installation_g02_readiness(
    v_installation.id
  );

  if not coalesce((v_readiness->>'ready')::boolean, false)
     or (v_readiness->>'canonical_data_version_id')
       is distinct from v_plan.canonical_data_version_id::text
     or not exists (
       select 1
       from public.atlas_installation_gates as gate_record
       where gate_record.installation_id = v_installation.id
         and gate_record.gate_code = 'G02'
         and gate_record.status = 'APPROVED'
         and gate_record.client_approved = true
     ) then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_G02_STALE_OR_INCOMPLETE';
  end if;

  select definition.*
  into v_resource_definition
  from public.atlas_provisioning_resource_definitions as definition
  where definition.resource_code = v_step.resource_code
    and definition.active = true;

  if not found
     or v_resource_definition.operation_type <> v_step.operation_type then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_RESOURCE_DEFINITION_MISMATCH';
  end if;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active = true
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code =
     'INSTALLATION_PROVISIONING_EXECUTE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_EXECUTION_ACTOR_ROLE_NOT_FOUND';
  end if;

  v_output_sha256 := case
    when p_outcome = 'SUCCEEDED' then
      public.atlas_normalization_sha256(p_result_payload::text)
    else null
  end;

  v_receipt_target := case
    when p_outcome = 'SUCCEEDED' then p_resource_locator
    else v_step.target_reference
  end;

  insert into public.atlas_provisioning_operation_receipts (
    installation_id,
    empresa_id,
    provisioning_plan_id,
    provisioning_step_id,
    resource_code,
    step_code,
    operation_phase,
    attempt_number,
    outcome,
    executor_code,
    actor_user_id,
    actor_role_code,
    request_id,
    input_sha256,
    output_sha256,
    target_reference,
    result_payload,
    evidence,
    error_code,
    error_message,
    started_at,
    completed_at,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_plan.id,
    v_step.id,
    v_step.resource_code,
    v_step.step_code,
    'EXECUTION',
    v_step.attempt_count,
    p_outcome,
    p_executor_code,
    v_actor_user_id,
    v_actor_role_code,
    p_request_id,
    v_step.input_sha256,
    v_output_sha256,
    v_receipt_target,
    p_result_payload,
    p_evidence || jsonb_build_object(
      'execution_request_id', p_execution_request_id,
      'expected_step_state_version',
        p_expected_step_state_version,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'begin_event_id', v_begin_event.id
    ),
    case when p_outcome = 'FAILED' then p_error_code else null end,
    case when p_outcome = 'FAILED' then p_error_message else null end,
    v_step.started_at,
    now(),
    p_metadata || jsonb_build_object(
      'completion_payload_sha256', v_completion_payload_sha256
    )
  )
  returning * into v_receipt;

  if p_outcome = 'SUCCEEDED' then
    insert into public.atlas_provisioned_resources (
      installation_id,
      empresa_id,
      provisioning_plan_id,
      provisioning_step_id,
      resource_code,
      step_code,
      target_kind,
      resource_status,
      state_version,
      resource_locator,
      configuration_sha256,
      last_receipt_id,
      idempotency_key,
      created_by_user_id,
      provisioned_at,
      verified_at,
      metadata
    )
    values (
      v_installation.id,
      v_installation.empresa_id,
      v_plan.id,
      v_step.id,
      v_step.resource_code,
      v_step.step_code,
      v_resource_definition.target_kind,
      case
        when v_step.operation_type = 'VERIFY' then 'VERIFIED'
        else 'PROVISIONED'
      end,
      1,
      p_resource_locator,
      v_output_sha256,
      v_receipt.id,
      v_step.idempotency_key,
      v_actor_user_id,
      now(),
      case
        when v_step.operation_type = 'VERIFY' then now()
        else null
      end,
      jsonb_build_object(
        'executor_code', p_executor_code,
        'execution_request_id', p_execution_request_id,
        'completion_request_id', p_request_id
      )
    )
    returning * into v_resource;
  end if;

  v_new_step_state_version := v_step.state_version + 1;

  update public.atlas_installation_provisioning_steps
  set
    step_status = p_outcome,
    state_version = v_new_step_state_version,
    result_payload = p_result_payload,
    evidence = p_evidence || jsonb_build_object(
      'operation_receipt_id', v_receipt.id,
      'provisioned_resource_id', v_resource.id,
      'output_sha256', v_output_sha256
    ),
    last_error_code = case
      when p_outcome = 'FAILED' then p_error_code
      else null
    end,
    last_error_message = case
      when p_outcome = 'FAILED' then p_error_message
      else null
    end,
    completed_at = now(),
    metadata = (
      metadata
      - 'active_execution_request_id'
      - 'active_executor_user_id'
      - 'active_attempt_number'
      - 'execution_started_at'
    ) || jsonb_build_object(
      'last_completion_request_id', p_request_id,
      'last_operation_receipt_id', v_receipt.id
    ),
    updated_at = now()
  where id = v_step.id
    and state_version = p_expected_step_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_STEP_VERSION_CONFLICT';
  end if;

  v_attempts_exhausted :=
    p_outcome = 'FAILED'
    and v_step.attempt_count >= v_step.max_attempts;

  if p_outcome = 'SUCCEEDED' then
    select not exists (
      select 1
      from public.atlas_installation_provisioning_steps as pending_step
      where pending_step.provisioning_plan_id = v_plan.id
        and pending_step.required = true
        and pending_step.step_status <> 'SUCCEEDED'
    )
    into v_all_required_steps_succeeded;
  end if;

  v_new_plan_status := case
    when v_attempts_exhausted then 'ROLLBACK_REQUIRED'
    else 'EXECUTING'
  end;

  v_new_plan_state_version := v_plan.state_version + 1;

  update public.atlas_installation_provisioning_plans
  set
    plan_status = v_new_plan_status,
    state_version = v_new_plan_state_version,
    metadata = (
      metadata
      - 'active_step_id'
      - 'active_execution_request_id'
    ) || jsonb_build_object(
      'last_completed_step_id', v_step.id,
      'last_completion_request_id', p_request_id,
      'all_required_steps_succeeded',
        v_all_required_steps_succeeded,
      'rollback_required', v_attempts_exhausted
    ),
    updated_at = now()
  where id = v_plan.id
    and state_version = p_expected_plan_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  insert into public.atlas_installation_provisioning_events (
    installation_id,
    empresa_id,
    provisioning_plan_id,
    entity_type,
    entity_id,
    event_code,
    from_status,
    to_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    evidence,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_plan.id,
    'STEP',
    v_step.id,
    case
      when p_outcome = 'SUCCEEDED'
        then 'PROVISIONING_STEP_EXECUTION_SUCCEEDED'
      else 'PROVISIONING_STEP_EXECUTION_FAILED'
    end,
    'EXECUTING',
    p_outcome,
    v_actor_user_id,
    v_actor_role_code,
    case
      when p_outcome = 'SUCCEEDED'
        then 'Paso completado con recibo y recurso gobernado.'
      else 'Paso fallido con recibo, error y posibilidad de reintento.'
    end,
    p_request_id,
    jsonb_build_object(
      'execution_request_id', p_execution_request_id,
      'operation_receipt_id', v_receipt.id,
      'provisioned_resource_id', v_resource.id,
      'attempt_number', v_step.attempt_count,
      'expected_step_state_version',
        p_expected_step_state_version,
      'resulting_step_state_version',
        v_new_step_state_version,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'resulting_plan_state_version',
        v_new_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'input_sha256', v_step.input_sha256,
      'output_sha256', v_output_sha256,
      'all_required_steps_succeeded',
        v_all_required_steps_succeeded,
      'rollback_required', v_attempts_exhausted
    ),
    p_metadata
  );

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
    'INSTALLATION_PROVISIONING_STEP_COMPLETED',
    'B2_PROVISIONING_ENGINE',
    case
      when p_outcome = 'SUCCEEDED' then 'COMPLETED'
      else 'FAILED'
    end,
    jsonb_build_object(
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'execution_request_id', p_execution_request_id,
      'completion_request_id', p_request_id,
      'attempt_number', v_step.attempt_count,
      'executor_code', p_executor_code
    ),
    jsonb_build_object(
      'outcome', p_outcome,
      'operation_receipt_id', v_receipt.id,
      'provisioned_resource_id', v_resource.id,
      'plan_status', v_new_plan_status,
      'all_required_steps_succeeded',
        v_all_required_steps_succeeded
    ),
    case
      when p_outcome = 'FAILED' then p_error_message
      else null
    end
  );

  return jsonb_build_object(
    'ok', p_outcome = 'SUCCEEDED',
    'code', case
      when p_outcome = 'SUCCEEDED'
        then 'PROVISIONING_STEP_EXECUTION_SUCCEEDED'
      else 'PROVISIONING_STEP_EXECUTION_FAILED'
    end,
    'installation_id', v_installation.id,
    'provisioning_plan_id', v_plan.id,
    'provisioning_step_id', v_step.id,
    'execution_request_id', p_execution_request_id,
    'completion_request_id', p_request_id,
    'operation_receipt_id', v_receipt.id,
    'provisioned_resource_id', v_resource.id,
    'outcome', p_outcome,
    'step_status', p_outcome,
    'step_state_version', v_new_step_state_version,
    'plan_status', v_new_plan_status,
    'plan_state_version', v_new_plan_state_version,
    'installation_version', v_installation.version,
    'attempt_number', v_step.attempt_count,
    'max_attempts', v_step.max_attempts,
    'all_required_steps_succeeded',
      v_all_required_steps_succeeded,
    'rollback_required', v_attempts_exhausted,
    'next_action', case
      when v_all_required_steps_succeeded
        then 'FINALIZE_PROVISIONING_PLAN'
      when v_attempts_exhausted
        then 'START_GOVERNED_ROLLBACK'
      when p_outcome = 'FAILED'
        then 'RETRY_STEP'
      else 'EXECUTE_NEXT_READY_STEP'
    end
  );
end;
$$;

revoke all on function
public.atlas_begin_installation_provisioning_step(
  uuid, uuid, bigint, bigint, bigint, jsonb
)
  from public, anon, authenticated;
grant execute on function
public.atlas_begin_installation_provisioning_step(
  uuid, uuid, bigint, bigint, bigint, jsonb
)
  to authenticated, service_role;

revoke all on function
public.atlas_complete_installation_provisioning_step(
  uuid, uuid, uuid, bigint, bigint, bigint, text, text,
  jsonb, jsonb, jsonb, text, text, jsonb
)
  from public, anon, authenticated;
grant execute on function
public.atlas_complete_installation_provisioning_step(
  uuid, uuid, uuid, bigint, bigint, bigint, text, text,
  jsonb, jsonb, jsonb, text, text, jsonb
)
  to authenticated, service_role;

comment on function
public.atlas_begin_installation_provisioning_step(
  uuid, uuid, bigint, bigint, bigint, jsonb
) is
  'B2: reserva un paso tras revalidar plan, preflight, G02 y dependencias.';

comment on function
public.atlas_complete_installation_provisioning_step(
  uuid, uuid, uuid, bigint, bigint, bigint, text, text,
  jsonb, jsonb, jsonb, text, text, jsonb
) is
  'B2: sella resultado, recibo, recurso, evento y auditoria de un intento.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2G3B_STEP_EXECUTION_RESOURCE_REGISTRATION_RPCS_INSTALLED',
  'next_action', 'CERTIFY_G3B_EXECUTION_RPC_GUARDS',
  'execution_rpcs', 2,
  'two_phase_execution_enabled', true,
  'dependency_enforcement_enabled', true,
  'preflight_revalidation_enabled', true,
  'g02_revalidation_enabled', true,
  'plan_hash_revalidation_enabled', true,
  'step_input_hash_revalidation_enabled', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'retry_limits_enforced', true,
  'receipt_registration_enabled', true,
  'resource_registration_enabled', true,
  'rollback_escalation_enabled', true,
  'operation_receipts', (
    select count(*)
    from public.atlas_provisioning_operation_receipts
  ),
  'provisioned_resources', (
    select count(*)
    from public.atlas_provisioned_resources
  ),
  'provisioning_plans', (
    select count(*)
    from public.atlas_installation_provisioning_plans
  ),
  'provisioning_steps', (
    select count(*)
    from public.atlas_installation_provisioning_steps
  ),
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
