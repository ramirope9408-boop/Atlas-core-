-- ATLAS B2.2G.3C.1
-- Finalizacion exitosa y solicitud gobernada de rollback.
-- Corte: 2026-09-01
--
-- Este bloque instala capacidad. No finaliza planes ni solicita rollback
-- durante la migracion y no modifica la instalacion piloto de FingerFood.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_begin_installation_provisioning_step(uuid,uuid,bigint,bigint,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_complete_installation_provisioning_step(uuid,uuid,uuid,bigint,bigint,bigint,text,text,jsonb,jsonb,jsonb,text,text,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_transition_installation(uuid,text,text,uuid,bigint)'
     ) is null
     or to_regclass(
       'public.atlas_provisioning_operation_receipts'
     ) is null
     or to_regclass(
       'public.atlas_provisioned_resources'
     ) is null then
    raise exception 'B2.2G.3C.1 requiere B2.2G.3B instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_finalize_installation_provisioning_plan(
  p_provisioning_plan_id uuid,
  p_request_id uuid,
  p_expected_plan_state_version bigint,
  p_expected_installation_version bigint,
  p_reason text,
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
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing_event public.atlas_installation_provisioning_events%rowtype;
  v_readiness jsonb;
  v_required_step_count bigint;
  v_succeeded_required_step_count bigint;
  v_succeeded_step_count bigint;
  v_valid_resource_count bigint;
  v_new_plan_state_version bigint;
  v_transition_result jsonb;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
       'INSTALLATION_PROVISIONING_EXECUTE'
     )
     or not public.atlas_platform_has_permission(
       'INSTALLATION_TRANSITION'
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PROVISIONING_FINALIZE_FORBIDDEN';
  end if;

  if p_provisioning_plan_id is null
     or p_request_id is null
     or p_expected_plan_state_version is null
     or p_expected_plan_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or nullif(btrim(p_reason), '') is null
     or length(btrim(p_reason)) < 10
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_FINALIZE_REQUIRED_FIELDS_INVALID';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = p_provisioning_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <> 'PROVISIONING_PLAN_COMPLETED'
       or v_existing_event.entity_type <> 'PLAN'
       or v_existing_event.entity_id <> v_plan.id
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
       or v_existing_event.reason <> btrim(p_reason)
       or v_existing_event.metadata <> p_metadata then
      raise exception using
        errcode = '22023',
        message =
          'PROVISIONING_FINALIZE_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_plan.installation_id,
      'provisioning_plan_id', v_plan.id,
      'plan_status', v_existing_event.to_status,
      'plan_state_version', coalesce(
        (
          v_existing_event.evidence->>
            'resulting_plan_state_version'
        )::bigint,
        v_plan.state_version
      ),
      'installation_state', coalesce(
        v_existing_event.evidence->>'installation_state',
        'INTEGRATION_SETUP'
      ),
      'installation_version', coalesce(
        (
          v_existing_event.evidence->>'resulting_installation_version'
        )::bigint,
        p_expected_installation_version + 1
      )
    );
  end if;

  if v_plan.state_version <> p_expected_plan_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  if v_plan.plan_status <> 'EXECUTING' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_NOT_FINALIZABLE';
  end if;

  if v_plan.plan_sha256 <>
     public.atlas_normalization_sha256(v_plan.plan_payload::text) then
    raise exception using
      errcode = '22023', message = 'PROVISIONING_PLAN_HASH_MISMATCH';
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

  if v_plan.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_FINALIZE_TENANT_MISMATCH';
  end if;

  if exists (
    select 1
    from public.atlas_installation_provisioning_steps as step
    where step.provisioning_plan_id = v_plan.id
      and step.step_status in (
        'PENDING', 'BLOCKED', 'READY', 'EXECUTING',
        'FAILED', 'COMPENSATING', 'COMPENSATED'
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_PLAN_HAS_UNFINISHED_OR_FAILED_STEPS';
  end if;

  select count(*)
  into v_required_step_count
  from public.atlas_installation_provisioning_steps as step
  where step.provisioning_plan_id = v_plan.id
    and step.required = true;

  select count(*)
  into v_succeeded_required_step_count
  from public.atlas_installation_provisioning_steps as step
  where step.provisioning_plan_id = v_plan.id
    and step.required = true
    and step.step_status = 'SUCCEEDED';

  select count(*)
  into v_succeeded_step_count
  from public.atlas_installation_provisioning_steps as step
  where step.provisioning_plan_id = v_plan.id
    and step.step_status = 'SUCCEEDED';

  if v_required_step_count = 0
     or v_succeeded_required_step_count <> v_required_step_count then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_REQUIRED_STEPS_INCOMPLETE';
  end if;

  select count(*)
  into v_valid_resource_count
  from public.atlas_installation_provisioning_steps as step
  join public.atlas_provisioned_resources as resource
    on resource.provisioning_step_id = step.id
   and resource.provisioning_plan_id = v_plan.id
   and resource.installation_id = v_installation.id
   and resource.empresa_id = v_installation.empresa_id
  join public.atlas_provisioning_operation_receipts as receipt
    on receipt.id = resource.last_receipt_id
   and receipt.provisioning_step_id = step.id
   and receipt.provisioning_plan_id = v_plan.id
   and receipt.outcome = 'SUCCEEDED'
   and receipt.operation_phase = 'EXECUTION'
  where step.provisioning_plan_id = v_plan.id
    and step.step_status = 'SUCCEEDED'
    and resource.resource_status in ('PROVISIONED', 'VERIFIED')
    and resource.configuration_sha256 = receipt.output_sha256
    and receipt.input_sha256 = step.input_sha256;

  if v_succeeded_step_count = 0
     or v_valid_resource_count <> v_succeeded_step_count
     or (
       select count(*)
       from public.atlas_provisioned_resources as resource
       where resource.provisioning_plan_id = v_plan.id
     ) <> v_succeeded_step_count then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_RESOURCE_LEDGER_INCOMPLETE_OR_INVALID';
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

  v_new_plan_state_version := v_plan.state_version + 1;

  update public.atlas_installation_provisioning_plans
  set
    plan_status = 'COMPLETED',
    state_version = v_new_plan_state_version,
    completed_at = now(),
    metadata = metadata || jsonb_build_object(
      'finalization_request_id', p_request_id,
      'finalized_by_user_id', v_actor_user_id,
      'finalized_at', now(),
      'validated_resource_count', v_valid_resource_count
    ),
    updated_at = now()
  where id = v_plan.id
    and state_version = p_expected_plan_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  v_transition_result := public.atlas_transition_installation(
    v_installation.id,
    'INTEGRATION_SETUP',
    btrim(p_reason),
    p_request_id,
    p_expected_installation_version
  );

  if not coalesce((v_transition_result->>'ok')::boolean, false)
     or v_transition_result->>'state' <> 'INTEGRATION_SETUP' then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_INSTALLATION_TRANSITION_FAILED';
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
    'PLAN',
    v_plan.id,
    'PROVISIONING_PLAN_COMPLETED',
    v_plan.plan_status,
    'COMPLETED',
    v_actor_user_id,
    v_actor_role_code,
    btrim(p_reason),
    p_request_id,
    jsonb_build_object(
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'resulting_plan_state_version',
        v_new_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'resulting_installation_version',
        (v_transition_result->>'version')::bigint,
      'installation_state',
        v_transition_result->>'state',
      'installation_transition_code',
        v_transition_result->>'transition_code',
      'required_step_count', v_required_step_count,
      'validated_resource_count', v_valid_resource_count,
      'plan_sha256', v_plan.plan_sha256
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
    'INSTALLATION_PROVISIONING_PLAN_FINALIZED',
    'B2_PROVISIONING_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'provisioning_plan_id', v_plan.id,
      'request_id', p_request_id,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version
    ),
    jsonb_build_object(
      'plan_status', 'COMPLETED',
      'plan_state_version', v_new_plan_state_version,
      'installation_state',
        v_transition_result->>'state',
      'installation_version',
        (v_transition_result->>'version')::bigint,
      'validated_resource_count', v_valid_resource_count
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'PROVISIONING_PLAN_FINALIZED',
    'installation_id', v_installation.id,
    'provisioning_plan_id', v_plan.id,
    'plan_status', 'COMPLETED',
    'plan_state_version', v_new_plan_state_version,
    'installation_state', v_transition_result->>'state',
    'installation_version',
      (v_transition_result->>'version')::bigint,
    'transition_code',
      v_transition_result->>'transition_code',
    'validated_resource_count', v_valid_resource_count,
    'next_action', 'CONFIGURE_CONTRACTED_INTEGRATIONS'
  );
end;
$$;

create or replace function
public.atlas_request_installation_provisioning_rollback(
  p_provisioning_plan_id uuid,
  p_request_id uuid,
  p_expected_plan_state_version bigint,
  p_expected_installation_version bigint,
  p_reason text,
  p_evidence jsonb,
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
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing_event public.atlas_installation_provisioning_events%rowtype;
  v_new_plan_state_version bigint;
  v_resources_marked bigint := 0;
  v_steps_marked bigint := 0;
  v_plan_hash_valid boolean;
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
      message = 'INSTALLATION_PROVISIONING_ROLLBACK_FORBIDDEN';
  end if;

  if p_provisioning_plan_id is null
     or p_request_id is null
     or p_expected_plan_state_version is null
     or p_expected_plan_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or nullif(btrim(p_reason), '') is null
     or length(btrim(p_reason)) < 10
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb
     or nullif(
       btrim(p_evidence->>'evidence_reference'), ''
     ) is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_ROLLBACK_REQUIRED_FIELDS_INVALID';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = p_provisioning_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <>
         'PROVISIONING_ROLLBACK_REQUESTED'
       or v_existing_event.entity_type <> 'PLAN'
       or v_existing_event.entity_id <> v_plan.id
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
       or v_existing_event.reason <> btrim(p_reason)
       or v_existing_event.evidence->'request_evidence' <>
         p_evidence
       or v_existing_event.metadata <> p_metadata then
      raise exception using
        errcode = '22023',
        message =
          'PROVISIONING_ROLLBACK_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_plan.installation_id,
      'provisioning_plan_id', v_plan.id,
      'plan_status', v_existing_event.to_status,
      'plan_state_version', coalesce(
        (
          v_existing_event.evidence->>
            'resulting_plan_state_version'
        )::bigint,
        v_plan.state_version
      ),
      'resources_marked_for_compensation', coalesce(
        (
          v_existing_event.evidence->>
            'resources_marked_for_compensation'
        )::bigint,
        0
      )
    );
  end if;

  if v_plan.state_version <> p_expected_plan_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  if v_plan.plan_status not in (
    'PREFLIGHT_PASSED', 'EXECUTING', 'FAILED', 'ROLLBACK_REQUIRED'
  ) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_NOT_ROLLBACK_REQUESTABLE';
  end if;

  if exists (
    select 1
    from public.atlas_installation_provisioning_steps as step
    where step.provisioning_plan_id = v_plan.id
      and step.step_status in ('EXECUTING', 'COMPENSATING')
  ) then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_ROLLBACK_ACTIVE_STEP_PRESENT';
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

  if v_plan.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_ROLLBACK_TENANT_MISMATCH';
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

  v_plan_hash_valid := v_plan.plan_sha256 =
    public.atlas_normalization_sha256(v_plan.plan_payload::text);

  update public.atlas_provisioned_resources
  set
    resource_status = 'COMPENSATION_REQUIRED',
    state_version = state_version + 1,
    compensation_required_at = coalesce(
      compensation_required_at,
      now()
    ),
    metadata = metadata || jsonb_build_object(
      'rollback_request_id', p_request_id,
      'rollback_requested_by_user_id', v_actor_user_id
    ),
    updated_at = now()
  where provisioning_plan_id = v_plan.id
    and resource_status in ('PROVISIONED', 'VERIFIED');

  get diagnostics v_resources_marked = row_count;

  update public.atlas_installation_provisioning_steps as step
  set
    state_version = step.state_version + 1,
    compensation_status = 'PENDING',
    metadata = step.metadata || jsonb_build_object(
      'rollback_request_id', p_request_id
    ),
    updated_at = now()
  where step.provisioning_plan_id = v_plan.id
    and step.id in (
      select resource.provisioning_step_id
      from public.atlas_provisioned_resources as resource
      where resource.provisioning_plan_id = v_plan.id
        and resource.resource_status = 'COMPENSATION_REQUIRED'
    )
    and step.compensation_status not in ('COMPLETED', 'EXECUTING');

  get diagnostics v_steps_marked = row_count;

  v_new_plan_state_version := v_plan.state_version + 1;

  update public.atlas_installation_provisioning_plans
  set
    plan_status = 'ROLLBACK_REQUIRED',
    state_version = v_new_plan_state_version,
    metadata = metadata || jsonb_build_object(
      'rollback_request_id', p_request_id,
      'rollback_reason', btrim(p_reason),
      'rollback_requested_by_user_id', v_actor_user_id,
      'rollback_requested_at', now(),
      'resources_marked_for_compensation', v_resources_marked
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
    'PLAN',
    v_plan.id,
    'PROVISIONING_ROLLBACK_REQUESTED',
    v_plan.plan_status,
    'ROLLBACK_REQUIRED',
    v_actor_user_id,
    v_actor_role_code,
    btrim(p_reason),
    p_request_id,
    jsonb_build_object(
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'resulting_plan_state_version',
        v_new_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'resources_marked_for_compensation', v_resources_marked,
      'steps_marked_for_compensation', v_steps_marked,
      'plan_hash_valid_at_request', v_plan_hash_valid,
      'request_evidence', p_evidence
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
    'INSTALLATION_PROVISIONING_ROLLBACK_REQUESTED',
    'B2_PROVISIONING_ENGINE',
    'REQUESTED',
    jsonb_build_object(
      'provisioning_plan_id', v_plan.id,
      'request_id', p_request_id,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'reason', btrim(p_reason)
    ),
    jsonb_build_object(
      'plan_status', 'ROLLBACK_REQUIRED',
      'plan_state_version', v_new_plan_state_version,
      'resources_marked_for_compensation', v_resources_marked,
      'steps_marked_for_compensation', v_steps_marked
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'PROVISIONING_ROLLBACK_REQUESTED',
    'installation_id', v_installation.id,
    'provisioning_plan_id', v_plan.id,
    'plan_status', 'ROLLBACK_REQUIRED',
    'plan_state_version', v_new_plan_state_version,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'resources_marked_for_compensation', v_resources_marked,
    'steps_marked_for_compensation', v_steps_marked,
    'next_action', case
      when v_resources_marked = 0
        then 'FINALIZE_EMPTY_ROLLBACK_WITH_HUMAN_APPROVAL'
      else 'START_REVERSE_ORDER_COMPENSATION'
    end
  );
end;
$$;

revoke all on function
public.atlas_finalize_installation_provisioning_plan(
  uuid, uuid, bigint, bigint, text, jsonb
)
  from public, anon, authenticated;
grant execute on function
public.atlas_finalize_installation_provisioning_plan(
  uuid, uuid, bigint, bigint, text, jsonb
)
  to authenticated, service_role;

revoke all on function
public.atlas_request_installation_provisioning_rollback(
  uuid, uuid, bigint, bigint, text, jsonb, jsonb
)
  from public, anon, authenticated;
grant execute on function
public.atlas_request_installation_provisioning_rollback(
  uuid, uuid, bigint, bigint, text, jsonb, jsonb
)
  to authenticated, service_role;

comment on function
public.atlas_finalize_installation_provisioning_plan(
  uuid, uuid, bigint, bigint, text, jsonb
) is
  'B2: completa el plan tras verificar pasos, recibos y recursos y avanza a integraciones.';

comment on function
public.atlas_request_installation_provisioning_rollback(
  uuid, uuid, bigint, bigint, text, jsonb, jsonb
) is
  'B2: solicita rollback, marca recursos compensables y conserva autoridad humana terminal.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2G3C1_PLAN_FINALIZATION_ROLLBACK_REQUEST_RPCS_INSTALLED',
  'next_block', 'B2.2G.3C.2_REVERSE_COMPENSATION_RPCS',
  'finalization_rpcs', 2,
  'successful_exit_state', 'INTEGRATION_SETUP',
  'successful_exit_transition', 'START_INTEGRATION_SETUP',
  'rollback_terminal_transition_automatic', false,
  'rollback_terminal_approval_required', true,
  'resource_ledger_completion_guard_enabled', true,
  'receipt_lineage_completion_guard_enabled', true,
  'g02_finalization_revalidation_enabled', true,
  'rollback_request_enabled', true,
  'reverse_compensation_planning_enabled', true,
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
