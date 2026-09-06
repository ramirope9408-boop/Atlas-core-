-- ATLAS B2.2G.3C.2
-- RPC gobernadas de compensacion inversa de recursos aprovisionados.
-- Corte: 2026-09-02
--
-- Instala capacidad en dos fases. No inicia compensaciones, no crea recibos
-- y no modifica la instalacion piloto durante la migracion.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_request_installation_provisioning_rollback(uuid,uuid,bigint,bigint,text,jsonb,jsonb)'
     ) is null
     or to_regclass(
       'public.atlas_provisioning_operation_receipts'
     ) is null
     or to_regclass(
       'public.atlas_provisioned_resources'
     ) is null
     or to_regprocedure(
       'public.atlas_platform_has_permission(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception 'B2.2G.3C.2 requiere B2.2G.3C.1 instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_begin_installation_provisioning_compensation(
  p_provisioning_step_id uuid,
  p_request_id uuid,
  p_expected_step_state_version bigint,
  p_expected_resource_state_version bigint,
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
  v_resource public.atlas_provisioned_resources%rowtype;
  v_existing_event public.atlas_installation_provisioning_events%rowtype;
  v_compensation_strategy text;
  v_manual_reason_code text;
  v_plan_hash_valid boolean;
  v_attempt_number integer;
  v_new_step_state_version bigint;
  v_new_resource_state_version bigint;
  v_new_plan_state_version bigint;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_COMPENSATE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PROVISIONING_COMPENSATE_FORBIDDEN';
  end if;

  if p_provisioning_step_id is null
     or p_request_id is null
     or p_expected_step_state_version is null
     or p_expected_step_state_version < 1
     or p_expected_resource_state_version is null
     or p_expected_resource_state_version < 1
     or p_expected_plan_state_version is null
     or p_expected_plan_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_BEGIN_REQUIRED_FIELDS_INVALID';
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

  select resource.*
  into v_resource
  from public.atlas_provisioned_resources as resource
  where resource.provisioning_plan_id = v_plan.id
    and resource.provisioning_step_id = v_step.id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONED_RESOURCE_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.entity_type <> 'STEP'
       or v_existing_event.entity_id <> v_step.id
       or v_existing_event.event_code not in (
         'PROVISIONING_COMPENSATION_STARTED',
         'PROVISIONING_COMPENSATION_MANUAL_REVIEW_REQUIRED'
       )
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
             'expected_resource_state_version'
         )::bigint,
         0
       ) <> p_expected_resource_state_version
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
          'PROVISIONING_COMPENSATION_BEGIN_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_plan.installation_id,
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'provisioned_resource_id', v_resource.id,
      'compensation_request_id', p_request_id,
      'event_code', v_existing_event.event_code,
      'step_status', v_step.step_status,
      'compensation_status', v_step.compensation_status,
      'step_state_version', v_step.state_version,
      'resource_status', v_resource.resource_status,
      'resource_state_version', v_resource.state_version,
      'plan_status', v_plan.plan_status,
      'plan_state_version', v_plan.state_version
    );
  end if;

  if v_step.state_version <> p_expected_step_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_STEP_VERSION_CONFLICT';
  end if;

  if v_resource.state_version <>
     p_expected_resource_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONED_RESOURCE_VERSION_CONFLICT';
  end if;

  if v_plan.state_version <> p_expected_plan_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  if v_plan.plan_status <> 'ROLLBACK_REQUIRED' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_NOT_ROLLBACK_REQUIRED';
  end if;

  if v_resource.resource_status <> 'COMPENSATION_REQUIRED' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONED_RESOURCE_NOT_COMPENSATION_REQUIRED';
  end if;

  if v_step.compensation_status not in ('PENDING', 'FAILED')
     or v_step.step_status not in (
       'SUCCEEDED', 'FAILED', 'COMPENSATING'
     ) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_NOT_COMPENSATION_READY';
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
     or v_resource.installation_id <> v_installation.id
     or v_step.empresa_id <> v_installation.empresa_id
     or v_resource.empresa_id <> v_installation.empresa_id
     or v_plan.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_TENANT_MISMATCH';
  end if;

  if exists (
    select 1
    from public.atlas_installation_provisioning_steps as active_step
    where active_step.provisioning_plan_id = v_plan.id
      and active_step.id <> v_step.id
      and active_step.compensation_status = 'EXECUTING'
  ) then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_PLAN_HAS_ACTIVE_COMPENSATION';
  end if;

  if exists (
    select 1
    from public.atlas_installation_provisioning_steps
      as dependent_step
    join public.atlas_provisioned_resources
      as dependent_resource
      on dependent_resource.provisioning_plan_id = v_plan.id
     and dependent_resource.provisioning_step_id = dependent_step.id
    where dependent_step.provisioning_plan_id = v_plan.id
      and dependent_step.dependency_step_codes @>
        array[v_step.step_code]::text[]
      and dependent_resource.resource_status not in (
        'COMPENSATED', 'ARCHIVED'
      )
  ) then
    raise exception using
      errcode = '55000',
      message =
        'PROVISIONING_REVERSE_DEPENDENCIES_NOT_COMPENSATED';
  end if;

  select resource_record.value->>'compensation_strategy'
  into v_compensation_strategy
  from jsonb_array_elements(v_plan.plan_payload->'resources')
    as resource_record(value)
  where resource_record.value->>'resource_code' =
    v_step.resource_code
  limit 1;

  v_plan_hash_valid :=
    v_plan.plan_sha256 =
      public.atlas_normalization_sha256(v_plan.plan_payload::text);

  if not v_plan_hash_valid then
    v_manual_reason_code := 'PLAN_HASH_MISMATCH';
  elsif v_compensation_strategy is null
     or v_compensation_strategy not in (
       'DELETE_CREATED_RESOURCE',
       'RESTORE_PREVIOUS_VERSION',
       'REVOKE_AND_ARCHIVE',
       'MARK_INACTIVE',
       'MANUAL_REVIEW_REQUIRED',
       'NO_COMPENSATION_READ_ONLY'
     ) then
    v_manual_reason_code :=
      'COMPENSATION_STRATEGY_SNAPSHOT_INVALID';
  elsif v_compensation_strategy = 'MANUAL_REVIEW_REQUIRED' then
    v_manual_reason_code := 'COMPENSATION_STRATEGY_REQUIRES_HUMAN';
  end if;

  select coalesce(max(receipt.attempt_number), 0) + 1
  into v_attempt_number
  from public.atlas_provisioning_operation_receipts as receipt
  where receipt.provisioning_step_id = v_step.id
    and receipt.operation_phase = 'COMPENSATION';

  if v_attempt_number > 10 then
    v_manual_reason_code := 'COMPENSATION_MAX_ATTEMPTS_REACHED';
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
     'INSTALLATION_PROVISIONING_COMPENSATE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_COMPENSATION_ACTOR_ROLE_NOT_FOUND';
  end if;

  v_new_step_state_version := v_step.state_version + 1;
  v_new_resource_state_version := v_resource.state_version + 1;
  v_new_plan_state_version := v_plan.state_version + 1;

  if v_manual_reason_code is not null then
    update public.atlas_installation_provisioning_steps
    set
      step_status = 'COMPENSATING',
      state_version = v_new_step_state_version,
      compensation_status = 'MANUAL_REVIEW',
      metadata = (
        metadata
        - 'active_compensation_request_id'
        - 'active_compensation_attempt_number'
        - 'compensation_started_at'
      ) || jsonb_build_object(
        'manual_review_request_id', p_request_id,
        'manual_review_reason_code', v_manual_reason_code,
        'manual_review_requested_at', now()
      ),
      updated_at = now()
    where id = v_step.id
      and state_version = p_expected_step_state_version;

    if not found then
      raise exception using
        errcode = '40001',
        message = 'PROVISIONING_STEP_VERSION_CONFLICT';
    end if;

    update public.atlas_provisioned_resources
    set
      state_version = v_new_resource_state_version,
      metadata = metadata || jsonb_build_object(
        'manual_review_request_id', p_request_id,
        'manual_review_reason_code', v_manual_reason_code
      ),
      updated_at = now()
    where id = v_resource.id
      and state_version = p_expected_resource_state_version;

    if not found then
      raise exception using
        errcode = '40001',
        message = 'PROVISIONED_RESOURCE_VERSION_CONFLICT';
    end if;

    update public.atlas_installation_provisioning_plans
    set
      state_version = v_new_plan_state_version,
      metadata = (
        metadata
        - 'active_compensation_step_id'
        - 'active_compensation_request_id'
      ) || jsonb_build_object(
        'manual_review_step_id', v_step.id,
        'manual_review_request_id', p_request_id,
        'manual_review_reason_code', v_manual_reason_code
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
      'PROVISIONING_COMPENSATION_MANUAL_REVIEW_REQUIRED',
      v_step.compensation_status,
      'MANUAL_REVIEW',
      v_actor_user_id,
      v_actor_role_code,
      'La compensacion requiere una decision humana antes de continuar.',
      p_request_id,
      jsonb_build_object(
        'expected_step_state_version',
          p_expected_step_state_version,
        'resulting_step_state_version',
          v_new_step_state_version,
        'expected_resource_state_version',
          p_expected_resource_state_version,
        'resulting_resource_state_version',
          v_new_resource_state_version,
        'expected_plan_state_version',
          p_expected_plan_state_version,
        'resulting_plan_state_version',
          v_new_plan_state_version,
        'expected_installation_version',
          p_expected_installation_version,
        'compensation_strategy', v_compensation_strategy,
        'manual_review_reason_code', v_manual_reason_code,
        'plan_hash_valid', v_plan_hash_valid
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
      'INSTALLATION_PROVISIONING_COMPENSATION_MANUAL_REVIEW_REQUIRED',
      'B2_PROVISIONING_ENGINE',
      'REQUESTED',
      jsonb_build_object(
        'provisioning_plan_id', v_plan.id,
        'provisioning_step_id', v_step.id,
        'provisioned_resource_id', v_resource.id,
        'request_id', p_request_id
      ),
      jsonb_build_object(
        'manual_review_reason_code', v_manual_reason_code,
        'compensation_strategy', v_compensation_strategy,
        'plan_hash_valid', v_plan_hash_valid
      ),
      null
    );

    return jsonb_build_object(
      'ok', false,
      'code', 'PROVISIONING_COMPENSATION_MANUAL_REVIEW_REQUIRED',
      'installation_id', v_installation.id,
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'provisioned_resource_id', v_resource.id,
      'compensation_request_id', p_request_id,
      'compensation_strategy', v_compensation_strategy,
      'manual_review_reason_code', v_manual_reason_code,
      'step_status', 'COMPENSATING',
      'compensation_status', 'MANUAL_REVIEW',
      'step_state_version', v_new_step_state_version,
      'resource_status', v_resource.resource_status,
      'resource_state_version', v_new_resource_state_version,
      'plan_status', v_plan.plan_status,
      'plan_state_version', v_new_plan_state_version,
      'installation_version', v_installation.version,
      'next_action', 'HUMAN_REVIEW_COMPENSATION'
    );
  end if;

  update public.atlas_installation_provisioning_steps
  set
    step_status = 'COMPENSATING',
    state_version = v_new_step_state_version,
    compensation_status = 'EXECUTING',
    last_error_code = null,
    last_error_message = null,
    completed_at = null,
    metadata = metadata || jsonb_build_object(
      'active_compensation_request_id', p_request_id,
      'active_compensation_attempt_number', v_attempt_number,
      'compensation_started_at', now()
    ),
    updated_at = now()
  where id = v_step.id
    and state_version = p_expected_step_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_STEP_VERSION_CONFLICT';
  end if;

  update public.atlas_provisioned_resources
  set
    state_version = v_new_resource_state_version,
    metadata = metadata || jsonb_build_object(
      'active_compensation_request_id', p_request_id,
      'active_compensation_attempt_number', v_attempt_number,
      'compensation_strategy', v_compensation_strategy
    ),
    updated_at = now()
  where id = v_resource.id
    and state_version = p_expected_resource_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONED_RESOURCE_VERSION_CONFLICT';
  end if;

  update public.atlas_installation_provisioning_plans
  set
    state_version = v_new_plan_state_version,
    metadata = metadata || jsonb_build_object(
      'active_compensation_step_id', v_step.id,
      'active_compensation_request_id', p_request_id
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
    'PROVISIONING_COMPENSATION_STARTED',
    v_step.compensation_status,
    'EXECUTING',
    v_actor_user_id,
    v_actor_role_code,
    'Recurso reservado para una compensacion inversa gobernada.',
    p_request_id,
    jsonb_build_object(
      'expected_step_state_version',
        p_expected_step_state_version,
      'resulting_step_state_version',
        v_new_step_state_version,
      'expected_resource_state_version',
        p_expected_resource_state_version,
      'resulting_resource_state_version',
        v_new_resource_state_version,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'resulting_plan_state_version',
        v_new_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'attempt_number', v_attempt_number,
      'compensation_strategy', v_compensation_strategy,
      'configuration_sha256', v_resource.configuration_sha256,
      'plan_hash_valid', v_plan_hash_valid
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
    'INSTALLATION_PROVISIONING_COMPENSATION_STARTED',
    'B2_PROVISIONING_ENGINE',
    'REQUESTED',
    jsonb_build_object(
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'provisioned_resource_id', v_resource.id,
      'request_id', p_request_id,
      'attempt_number', v_attempt_number
    ),
    jsonb_build_object(
      'compensation_status', 'EXECUTING',
      'compensation_strategy', v_compensation_strategy,
      'step_state_version', v_new_step_state_version,
      'resource_state_version', v_new_resource_state_version,
      'plan_state_version', v_new_plan_state_version
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'PROVISIONING_COMPENSATION_STARTED',
    'installation_id', v_installation.id,
    'provisioning_plan_id', v_plan.id,
    'provisioning_step_id', v_step.id,
    'provisioned_resource_id', v_resource.id,
    'compensation_request_id', p_request_id,
    'step_status', 'COMPENSATING',
    'compensation_status', 'EXECUTING',
    'step_state_version', v_new_step_state_version,
    'resource_status', v_resource.resource_status,
    'resource_state_version', v_new_resource_state_version,
    'plan_status', v_plan.plan_status,
    'plan_state_version', v_new_plan_state_version,
    'installation_version', v_installation.version,
    'attempt_number', v_attempt_number,
    'max_attempts', 10,
    'compensation_contract', jsonb_build_object(
      'resource_code', v_resource.resource_code,
      'step_code', v_resource.step_code,
      'target_kind', v_resource.target_kind,
      'resource_locator', v_resource.resource_locator,
      'configuration_sha256', v_resource.configuration_sha256,
      'compensation_strategy', v_compensation_strategy
    ),
    'next_action', case
      when v_compensation_strategy = 'NO_COMPENSATION_READ_ONLY'
        then 'COMPLETE_AS_SKIPPED_WITH_VERIFICATION_EVIDENCE'
      else 'EXECUTE_COMPENSATION_VERIFY_AND_COMPLETE'
    end
  );
end;
$$;

create or replace function
public.atlas_complete_installation_provisioning_compensation(
  p_provisioning_step_id uuid,
  p_compensation_request_id uuid,
  p_request_id uuid,
  p_expected_step_state_version bigint,
  p_expected_resource_state_version bigint,
  p_expected_plan_state_version bigint,
  p_expected_installation_version bigint,
  p_outcome text,
  p_executor_code text,
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
  v_resource public.atlas_provisioned_resources%rowtype;
  v_begin_event public.atlas_installation_provisioning_events%rowtype;
  v_existing_event public.atlas_installation_provisioning_events%rowtype;
  v_existing_receipt public.atlas_provisioning_operation_receipts%rowtype;
  v_receipt public.atlas_provisioning_operation_receipts%rowtype;
  v_compensation_strategy text;
  v_attempt_number integer;
  v_output_sha256 text;
  v_completion_payload_sha256 text;
  v_new_step_state_version bigint;
  v_new_resource_state_version bigint;
  v_new_plan_state_version bigint;
  v_remaining_resources bigint;
  v_manual_review_steps bigint;
  v_attempts_exhausted boolean := false;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_COMPENSATE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PROVISIONING_COMPENSATE_FORBIDDEN';
  end if;

  if p_provisioning_step_id is null
     or p_compensation_request_id is null
     or p_request_id is null
     or p_compensation_request_id = p_request_id
     or p_expected_step_state_version is null
     or p_expected_step_state_version < 1
     or p_expected_resource_state_version is null
     or p_expected_resource_state_version < 1
     or p_expected_plan_state_version is null
     or p_expected_plan_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_outcome not in ('SUCCEEDED', 'FAILED', 'SKIPPED')
     or p_executor_code is null
     or p_executor_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_executor_code) not between 3 and 80
     or p_result_payload is null
     or jsonb_typeof(p_result_payload) <> 'object'
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb
     or nullif(btrim(p_evidence->>'evidence_reference'), '') is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_result_payload)
     or public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_COMPLETE_REQUIRED_FIELDS_INVALID';
  end if;

  if p_outcome = 'SUCCEEDED'
     and (
       p_result_payload->>'verification_status' <> 'VERIFIED'
       or nullif(
         btrim(p_evidence->>'verification_reference'), ''
       ) is null
       or p_error_code is not null
       or p_error_message is not null
     ) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_SUCCESS_NOT_VERIFIED';
  end if;

  if p_outcome = 'SKIPPED'
     and (
       p_result_payload->>'verification_status' <>
         'NOT_APPLICABLE_VERIFIED'
       or nullif(
         btrim(p_evidence->>'verification_reference'), ''
       ) is null
       or p_error_code is not null
       or p_error_message is not null
     ) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_SKIP_NOT_VERIFIED';
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
      message = 'PROVISIONING_COMPENSATION_FAILURE_PAYLOAD_INVALID';
  end if;

  v_completion_payload_sha256 :=
    public.atlas_normalization_sha256(
      jsonb_build_object(
        'provisioning_step_id', p_provisioning_step_id,
        'compensation_request_id', p_compensation_request_id,
        'completion_request_id', p_request_id,
        'expected_step_state_version',
          p_expected_step_state_version,
        'expected_resource_state_version',
          p_expected_resource_state_version,
        'expected_plan_state_version',
          p_expected_plan_state_version,
        'expected_installation_version',
          p_expected_installation_version,
        'outcome', p_outcome,
        'executor_code', p_executor_code,
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

  select resource.*
  into v_resource
  from public.atlas_provisioned_resources as resource
  where resource.provisioning_plan_id = v_plan.id
    and resource.provisioning_step_id = v_step.id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONED_RESOURCE_NOT_FOUND';
  end if;

  select receipt.*
  into v_existing_receipt
  from public.atlas_provisioning_operation_receipts as receipt
  where receipt.provisioning_plan_id = v_plan.id
    and receipt.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_receipt.provisioning_step_id <> v_step.id
       or v_existing_receipt.operation_phase <> 'COMPENSATION'
       or v_existing_receipt.outcome <> p_outcome
       or v_existing_receipt.executor_code <> p_executor_code
       or coalesce(
         v_existing_receipt.evidence->>'compensation_request_id',
         ''
       ) <> p_compensation_request_id::text
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
             'expected_resource_state_version'
         )::bigint,
         0
       ) <> p_expected_resource_state_version
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
          'PROVISIONING_COMPENSATION_COMPLETE_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', v_existing_receipt.outcome in ('SUCCEEDED', 'SKIPPED'),
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_plan.installation_id,
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'provisioned_resource_id', v_resource.id,
      'operation_receipt_id', v_existing_receipt.id,
      'outcome', v_existing_receipt.outcome,
      'step_status', v_step.step_status,
      'compensation_status', v_step.compensation_status,
      'step_state_version', v_step.state_version,
      'resource_status', v_resource.resource_status,
      'resource_state_version', v_resource.state_version,
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
        'PROVISIONING_COMPENSATION_COMPLETE_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  end if;

  if v_step.state_version <> p_expected_step_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_STEP_VERSION_CONFLICT';
  end if;

  if v_resource.state_version <>
     p_expected_resource_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONED_RESOURCE_VERSION_CONFLICT';
  end if;

  if v_plan.state_version <> p_expected_plan_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  if v_step.step_status <> 'COMPENSATING'
     or v_step.compensation_status <> 'EXECUTING' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_STEP_NOT_COMPENSATING';
  end if;

  if coalesce(
       v_step.metadata->>'active_compensation_request_id',
       ''
     ) <> p_compensation_request_id::text
     or coalesce(
       v_resource.metadata->>'active_compensation_request_id',
       ''
     ) <> p_compensation_request_id::text then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_REQUEST_MISMATCH';
  end if;

  select event_record.*
  into v_begin_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.request_id = p_compensation_request_id
    and event_record.entity_type = 'STEP'
    and event_record.entity_id = v_step.id
    and event_record.event_code = 'PROVISIONING_COMPENSATION_STARTED'
  limit 1;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_COMPENSATION_BEGIN_EVENT_REQUIRED';
  end if;

  if v_plan.plan_status <> 'ROLLBACK_REQUIRED' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_NOT_ROLLBACK_REQUIRED';
  end if;

  if v_resource.resource_status <> 'COMPENSATION_REQUIRED' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONED_RESOURCE_NOT_COMPENSATION_REQUIRED';
  end if;

  if v_plan.plan_sha256 <>
     public.atlas_normalization_sha256(v_plan.plan_payload::text) then
    raise exception using
      errcode = '55000',
      message =
        'PROVISIONING_COMPENSATION_PLAN_HASH_MISMATCH_MANUAL_REVIEW_REQUIRED';
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
     or v_resource.installation_id <> v_installation.id
     or v_step.empresa_id <> v_installation.empresa_id
     or v_resource.empresa_id <> v_installation.empresa_id
     or v_plan.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_TENANT_MISMATCH';
  end if;

  v_compensation_strategy :=
    v_begin_event.evidence->>'compensation_strategy';
  v_attempt_number := coalesce(
    (v_begin_event.evidence->>'attempt_number')::integer,
    0
  );

  if v_attempt_number not between 1 and 10 then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_ATTEMPT_INVALID';
  end if;

  if p_outcome = 'SKIPPED'
     and v_compensation_strategy <>
       'NO_COMPENSATION_READ_ONLY' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_COMPENSATION_SKIP_NOT_ALLOWED';
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
     'INSTALLATION_PROVISIONING_COMPENSATE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_COMPENSATION_ACTOR_ROLE_NOT_FOUND';
  end if;

  v_output_sha256 := case
    when p_outcome in ('SUCCEEDED', 'SKIPPED') then
      public.atlas_normalization_sha256(p_result_payload::text)
    else null
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
    'COMPENSATION',
    v_attempt_number,
    p_outcome,
    p_executor_code,
    v_actor_user_id,
    v_actor_role_code,
    p_request_id,
    v_resource.configuration_sha256,
    v_output_sha256,
    v_resource.resource_locator,
    p_result_payload,
    p_evidence || jsonb_build_object(
      'compensation_request_id', p_compensation_request_id,
      'expected_step_state_version',
        p_expected_step_state_version,
      'expected_resource_state_version',
        p_expected_resource_state_version,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'begin_event_id', v_begin_event.id,
      'compensation_strategy', v_compensation_strategy
    ),
    case when p_outcome = 'FAILED' then p_error_code else null end,
    case when p_outcome = 'FAILED' then p_error_message else null end,
    v_begin_event.created_at,
    now(),
    p_metadata || jsonb_build_object(
      'completion_payload_sha256', v_completion_payload_sha256
    )
  )
  returning * into v_receipt;

  v_attempts_exhausted :=
    p_outcome = 'FAILED' and v_attempt_number >= 10;
  v_new_resource_state_version := v_resource.state_version + 1;

  update public.atlas_provisioned_resources
  set
    resource_status = case
      when p_outcome in ('SUCCEEDED', 'SKIPPED')
        then 'COMPENSATED'
      else 'COMPENSATION_REQUIRED'
    end,
    state_version = v_new_resource_state_version,
    last_receipt_id = v_receipt.id,
    compensated_at = case
      when p_outcome in ('SUCCEEDED', 'SKIPPED') then now()
      else compensated_at
    end,
    metadata = (
      metadata
      - 'active_compensation_request_id'
      - 'active_compensation_attempt_number'
    ) || jsonb_build_object(
      'last_compensation_request_id', p_request_id,
      'last_compensation_receipt_id', v_receipt.id,
      'last_compensation_outcome', p_outcome,
      'last_compensation_output_sha256', v_output_sha256
    ),
    updated_at = now()
  where id = v_resource.id
    and state_version = p_expected_resource_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONED_RESOURCE_VERSION_CONFLICT';
  end if;

  v_new_step_state_version := v_step.state_version + 1;

  update public.atlas_installation_provisioning_steps
  set
    step_status = case
      when p_outcome in ('SUCCEEDED', 'SKIPPED')
        then 'COMPENSATED'
      else 'FAILED'
    end,
    state_version = v_new_step_state_version,
    compensation_status = case
      when p_outcome in ('SUCCEEDED', 'SKIPPED') then 'COMPLETED'
      when v_attempts_exhausted then 'MANUAL_REVIEW'
      else 'FAILED'
    end,
    result_payload = p_result_payload,
    evidence = p_evidence || jsonb_build_object(
      'operation_receipt_id', v_receipt.id,
      'compensation_output_sha256', v_output_sha256,
      'compensation_strategy', v_compensation_strategy
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
      - 'active_compensation_request_id'
      - 'active_compensation_attempt_number'
      - 'compensation_started_at'
    ) || jsonb_build_object(
      'last_compensation_completion_request_id', p_request_id,
      'last_compensation_receipt_id', v_receipt.id,
      'compensation_attempts_exhausted', v_attempts_exhausted
    ),
    updated_at = now()
  where id = v_step.id
    and state_version = p_expected_step_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_STEP_VERSION_CONFLICT';
  end if;

  select count(*)
  into v_remaining_resources
  from public.atlas_provisioned_resources as resource
  where resource.provisioning_plan_id = v_plan.id
    and resource.resource_status = 'COMPENSATION_REQUIRED';

  select count(*)
  into v_manual_review_steps
  from public.atlas_installation_provisioning_steps as step
  where step.provisioning_plan_id = v_plan.id
    and step.compensation_status = 'MANUAL_REVIEW';

  v_new_plan_state_version := v_plan.state_version + 1;

  update public.atlas_installation_provisioning_plans
  set
    state_version = v_new_plan_state_version,
    metadata = (
      metadata
      - 'active_compensation_step_id'
      - 'active_compensation_request_id'
    ) || jsonb_build_object(
      'last_compensated_step_id', v_step.id,
      'last_compensation_completion_request_id', p_request_id,
      'last_compensation_outcome', p_outcome,
      'remaining_compensation_resources', v_remaining_resources,
      'manual_review_compensation_steps', v_manual_review_steps
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
        then 'PROVISIONING_COMPENSATION_SUCCEEDED'
      when p_outcome = 'SKIPPED'
        then 'PROVISIONING_COMPENSATION_SKIPPED'
      else 'PROVISIONING_COMPENSATION_FAILED'
    end,
    'EXECUTING',
    case
      when p_outcome in ('SUCCEEDED', 'SKIPPED') then 'COMPLETED'
      when v_attempts_exhausted then 'MANUAL_REVIEW'
      else 'FAILED'
    end,
    v_actor_user_id,
    v_actor_role_code,
    case
      when p_outcome = 'SUCCEEDED'
        then 'Compensacion completada y verificada con evidencia.'
      when p_outcome = 'SKIPPED'
        then 'Compensacion no aplicable verificada y documentada.'
      else 'Compensacion fallida con recibo y error gobernado.'
    end,
    p_request_id,
    jsonb_build_object(
      'compensation_request_id', p_compensation_request_id,
      'operation_receipt_id', v_receipt.id,
      'attempt_number', v_attempt_number,
      'expected_step_state_version',
        p_expected_step_state_version,
      'resulting_step_state_version',
        v_new_step_state_version,
      'expected_resource_state_version',
        p_expected_resource_state_version,
      'resulting_resource_state_version',
        v_new_resource_state_version,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'resulting_plan_state_version',
        v_new_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'compensation_strategy', v_compensation_strategy,
      'compensation_output_sha256', v_output_sha256,
      'verification_reference',
        p_evidence->>'verification_reference',
      'remaining_compensation_resources', v_remaining_resources,
      'manual_review_compensation_steps', v_manual_review_steps,
      'attempts_exhausted', v_attempts_exhausted
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
    'INSTALLATION_PROVISIONING_COMPENSATION_COMPLETED',
    'B2_PROVISIONING_ENGINE',
    case
      when p_outcome in ('SUCCEEDED', 'SKIPPED') then 'COMPLETED'
      else 'FAILED'
    end,
    jsonb_build_object(
      'provisioning_plan_id', v_plan.id,
      'provisioning_step_id', v_step.id,
      'provisioned_resource_id', v_resource.id,
      'compensation_request_id', p_compensation_request_id,
      'completion_request_id', p_request_id,
      'attempt_number', v_attempt_number,
      'executor_code', p_executor_code
    ),
    jsonb_build_object(
      'outcome', p_outcome,
      'operation_receipt_id', v_receipt.id,
      'resource_status', case
        when p_outcome in ('SUCCEEDED', 'SKIPPED')
          then 'COMPENSATED'
        else 'COMPENSATION_REQUIRED'
      end,
      'remaining_compensation_resources', v_remaining_resources,
      'manual_review_compensation_steps', v_manual_review_steps
    ),
    case
      when p_outcome = 'FAILED' then p_error_message
      else null
    end
  );

  return jsonb_build_object(
    'ok', p_outcome in ('SUCCEEDED', 'SKIPPED'),
    'code', case
      when p_outcome = 'SUCCEEDED'
        then 'PROVISIONING_COMPENSATION_SUCCEEDED'
      when p_outcome = 'SKIPPED'
        then 'PROVISIONING_COMPENSATION_SKIPPED'
      else 'PROVISIONING_COMPENSATION_FAILED'
    end,
    'installation_id', v_installation.id,
    'provisioning_plan_id', v_plan.id,
    'provisioning_step_id', v_step.id,
    'provisioned_resource_id', v_resource.id,
    'compensation_request_id', p_compensation_request_id,
    'completion_request_id', p_request_id,
    'operation_receipt_id', v_receipt.id,
    'outcome', p_outcome,
    'step_status', case
      when p_outcome in ('SUCCEEDED', 'SKIPPED')
        then 'COMPENSATED'
      else 'FAILED'
    end,
    'compensation_status', case
      when p_outcome in ('SUCCEEDED', 'SKIPPED') then 'COMPLETED'
      when v_attempts_exhausted then 'MANUAL_REVIEW'
      else 'FAILED'
    end,
    'step_state_version', v_new_step_state_version,
    'resource_status', case
      when p_outcome in ('SUCCEEDED', 'SKIPPED')
        then 'COMPENSATED'
      else 'COMPENSATION_REQUIRED'
    end,
    'resource_state_version', v_new_resource_state_version,
    'plan_status', v_plan.plan_status,
    'plan_state_version', v_new_plan_state_version,
    'installation_version', v_installation.version,
    'attempt_number', v_attempt_number,
    'max_attempts', 10,
    'remaining_compensation_resources', v_remaining_resources,
    'manual_review_compensation_steps', v_manual_review_steps,
    'next_action', case
      when p_outcome = 'FAILED' and v_attempts_exhausted
        then 'HUMAN_REVIEW_COMPENSATION'
      when p_outcome = 'FAILED'
        then 'RETRY_COMPENSATION'
      when v_remaining_resources = 0
           and v_manual_review_steps = 0
        then 'FINALIZE_ROLLBACK_WITH_HUMAN_APPROVAL'
      else 'COMPENSATE_NEXT_RESOURCE_IN_REVERSE_ORDER'
    end
  );
end;
$$;

revoke all on function
public.atlas_begin_installation_provisioning_compensation(
  uuid, uuid, bigint, bigint, bigint, bigint, jsonb
)
  from public, anon, authenticated;
grant execute on function
public.atlas_begin_installation_provisioning_compensation(
  uuid, uuid, bigint, bigint, bigint, bigint, jsonb
)
  to authenticated, service_role;

revoke all on function
public.atlas_complete_installation_provisioning_compensation(
  uuid, uuid, uuid, bigint, bigint, bigint, bigint,
  text, text, jsonb, jsonb, text, text, jsonb
)
  from public, anon, authenticated;
grant execute on function
public.atlas_complete_installation_provisioning_compensation(
  uuid, uuid, uuid, bigint, bigint, bigint, bigint,
  text, text, jsonb, jsonb, text, text, jsonb
)
  to authenticated, service_role;

comment on function
public.atlas_begin_installation_provisioning_compensation(
  uuid, uuid, bigint, bigint, bigint, bigint, jsonb
) is
  'B2: reserva compensaciones en orden inverso o escala a revision humana.';

comment on function
public.atlas_complete_installation_provisioning_compensation(
  uuid, uuid, uuid, bigint, bigint, bigint, bigint,
  text, text, jsonb, jsonb, text, text, jsonb
) is
  'B2: registra recibo, verificacion y resultado gobernado de compensacion.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2G3C2_REVERSE_COMPENSATION_RPCS_INSTALLED',
  'next_action', 'CERTIFY_G3C2_REVERSE_COMPENSATION_GUARDS',
  'compensation_rpcs', 2,
  'two_phase_compensation_enabled', true,
  'reverse_dependency_enforcement_enabled', true,
  'single_active_compensation_enabled', true,
  'plan_snapshot_strategy_binding_enabled', true,
  'compensation_verification_required', true,
  'compensation_receipts_enabled', true,
  'compensation_retry_limit', 10,
  'manual_review_escalation_enabled', true,
  'plan_hash_manual_escalation_enabled', true,
  'terminal_rollback_transition_enabled', false,
  'terminal_human_approval_preserved', true,
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
