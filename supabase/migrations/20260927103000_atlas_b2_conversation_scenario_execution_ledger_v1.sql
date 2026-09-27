-- ATLAS B2 conversational scenario execution ledger V1
-- Date: 2026-09-27
-- Stores execution/results for generic conversational certification scenarios.
-- No model/provider call is performed here; external/internal runner registers evidence.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_conversation_test_scenario_instances'
     ) is null
     or to_regprocedure(
       'public.atlas_test_assertion_results_match_contract_v1(jsonb,jsonb,text)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null then
    raise exception
      'Conversation scenario execution ledger requires scenario plans and B2 result validation core';
  end if;

  if to_regclass(
       'public.atlas_conversation_test_scenario_results'
     ) is not null then
    raise exception
      'Conversation scenario results already exist; reconcile before install';
  end if;
end;
$$;

create table public.atlas_conversation_test_scenario_results (
  id uuid primary key default gen_random_uuid(),
  scenario_instance_id uuid not null,
  scenario_plan_id uuid not null,
  test_plan_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  scenario_code text not null,
  attempt_number integer not null,
  outcome text not null,
  executor_code text not null,
  actor_user_id uuid not null,
  request_id uuid not null,
  rendered_input_sha256 text not null,
  response_sha256 text not null,
  assertion_results jsonb not null,
  assertion_results_sha256 text not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  error_code text,
  redacted_error_summary text,
  metadata jsonb not null default '{}'::jsonb,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  created_at timestamptz not null default now(),

  constraint atlas_conversation_scenario_result_attempt_key
    unique (scenario_instance_id, attempt_number),
  constraint atlas_conversation_scenario_result_request_key
    unique (scenario_plan_id, request_id),

  constraint atlas_conversation_scenario_result_instance_fkey
    foreign key (
      scenario_instance_id,
      scenario_plan_id,
      test_plan_id,
      installation_id,
      empresa_id
    )
    references public.atlas_conversation_test_scenario_instances(
      id,
      scenario_plan_id,
      test_plan_id,
      installation_id,
      empresa_id
    )
    on delete restrict,

  constraint atlas_conversation_scenario_result_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,

  constraint atlas_conversation_scenario_result_attempt_check
    check (attempt_number between 1 and 10),

  constraint atlas_conversation_scenario_result_outcome_check
    check (outcome in ('PASSED', 'FAILED', 'BLOCKED')),

  constraint atlas_conversation_scenario_result_executor_check
    check (
      executor_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(executor_code) between 3 and 100
    ),

  constraint atlas_conversation_scenario_result_hashes_check
    check (
      rendered_input_sha256 ~ '^[0-9a-f]{64}$'
      and response_sha256 ~ '^[0-9a-f]{64}$'
      and assertion_results_sha256 ~ '^[0-9a-f]{64}$'
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
    ),

  constraint atlas_conversation_scenario_result_assertions_check
    check (
      jsonb_typeof(assertion_results) = 'array'
      and jsonb_array_length(assertion_results) >= 1
      and not public.atlas_jsonb_has_forbidden_secret_key(
        assertion_results
      )
    ),

  constraint atlas_conversation_scenario_result_evidence_check
    check (
      length(btrim(evidence_reference)) between 12 and 500
    ),

  constraint atlas_conversation_scenario_result_timeline_check
    check (completed_at >= started_at),

  constraint atlas_conversation_scenario_result_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(
        metadata
      )
    )
);

alter table public.atlas_conversation_test_scenario_instances
  add constraint atlas_conversation_scenario_instance_identity_key
  unique (
    id,
    scenario_plan_id,
    test_plan_id,
    installation_id,
    empresa_id
  );

create index idx_atlas_conversation_scenario_results_plan
  on public.atlas_conversation_test_scenario_results(
    scenario_plan_id,
    outcome,
    scenario_code,
    attempt_number desc
  );

create or replace function
public.atlas_register_conversation_scenario_result_v1(
  p_scenario_instance_id uuid,
  p_outcome text,
  p_executor_code text,
  p_request_id uuid,
  p_rendered_input_sha256 text,
  p_response_sha256 text,
  p_assertion_results jsonb,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_error_code text,
  p_redacted_error_summary text,
  p_started_at timestamptz,
  p_completed_at timestamptz,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_instance public.atlas_conversation_test_scenario_instances%rowtype;
  v_existing public.atlas_conversation_test_scenario_results%rowtype;
  v_created public.atlas_conversation_test_scenario_results%rowtype;
  v_attempt integer;
  v_expected jsonb;
  v_assertion_results_sha256 text;
begin
  if v_actor_user_id is null
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_platform_has_permission(
       'INSTALLATION_TEST_EXECUTE'
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  if p_scenario_instance_id is null
     or p_request_id is null
     or p_outcome not in ('PASSED', 'FAILED', 'BLOCKED')
     or p_executor_code is null
     or p_executor_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_executor_code) not between 3 and 100
     or p_rendered_input_sha256 !~ '^[0-9a-f]{64}$'
     or p_response_sha256 !~ '^[0-9a-f]{64}$'
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_assertion_results is null
     or jsonb_typeof(p_assertion_results) <> 'array'
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata)
     or p_started_at is null
     or p_completed_at is null
     or p_completed_at < p_started_at then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_SCENARIO_RESULT_REQUIRED_FIELDS_INVALID';
  end if;

  select instance.*
  into v_instance
  from public.atlas_conversation_test_scenario_instances as instance
  where instance.id = p_scenario_instance_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'CONVERSATION_SCENARIO_INSTANCE_NOT_FOUND';
  end if;

  if v_instance.applicability_status <> 'APPLICABLE' then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_SCENARIO_NOT_APPLICABLE';
  end if;

  select result.*
  into v_existing
  from public.atlas_conversation_test_scenario_results as result
  where result.scenario_plan_id = v_instance.scenario_plan_id
    and result.request_id = p_request_id
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'scenario_result_id', v_existing.id,
      'scenario_instance_id', v_existing.scenario_instance_id,
      'outcome', v_existing.outcome,
      'attempt_number', v_existing.attempt_number
    );
  end if;

  select coalesce(max(result.attempt_number), 0) + 1
  into v_attempt
  from public.atlas_conversation_test_scenario_results as result
  where result.scenario_instance_id = v_instance.id;

  if v_attempt > 10 then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_SCENARIO_MAX_ATTEMPTS_EXCEEDED';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'assertion_code', code,
        'required', true
      )
      order by code
    ),
    '[]'::jsonb
  )
  into v_expected
  from unnest(v_instance.expected_assertion_codes) as x(code);

  if not public.atlas_test_assertion_results_match_contract_v1(
    v_expected,
    p_assertion_results,
    p_outcome
  ) then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_SCENARIO_ASSERTION_RESULTS_INVALID';
  end if;

  v_assertion_results_sha256 :=
    public.atlas_normalization_sha256(
      p_assertion_results::text
    );

  insert into public.atlas_conversation_test_scenario_results (
    scenario_instance_id,
    scenario_plan_id,
    test_plan_id,
    installation_id,
    empresa_id,
    scenario_code,
    attempt_number,
    outcome,
    executor_code,
    actor_user_id,
    request_id,
    rendered_input_sha256,
    response_sha256,
    assertion_results,
    assertion_results_sha256,
    evidence_reference,
    evidence_sha256,
    error_code,
    redacted_error_summary,
    metadata,
    started_at,
    completed_at
  )
  values (
    v_instance.id,
    v_instance.scenario_plan_id,
    v_instance.test_plan_id,
    v_instance.installation_id,
    v_instance.empresa_id,
    v_instance.scenario_code,
    v_attempt,
    p_outcome,
    p_executor_code,
    coalesce(v_actor_user_id, (
      select created_by_user_id
      from public.atlas_conversation_test_scenario_plans
      where id = v_instance.scenario_plan_id
    )),
    p_request_id,
    p_rendered_input_sha256,
    p_response_sha256,
    p_assertion_results,
    v_assertion_results_sha256,
    btrim(p_evidence_reference),
    p_evidence_sha256,
    nullif(btrim(p_error_code), ''),
    nullif(btrim(p_redacted_error_summary), ''),
    p_metadata,
    p_started_at,
    p_completed_at
  )
  returning * into v_created;

  update public.atlas_conversation_test_scenario_instances
  set
    instance_status = case
      when p_outcome = 'PASSED' then 'PASSED'
      when p_outcome = 'FAILED' then 'FAILED'
      else 'BLOCKED'
    end,
    updated_at = now()
  where id = v_instance.id;

  return jsonb_build_object(
    'ok', true,
    'code', 'CONVERSATION_SCENARIO_RESULT_RECORDED',
    'scenario_result_id', v_created.id,
    'scenario_instance_id', v_created.scenario_instance_id,
    'scenario_code', v_created.scenario_code,
    'attempt_number', v_created.attempt_number,
    'outcome', v_created.outcome,
    'assertion_results_sha256',
      v_created.assertion_results_sha256
  );
end;
$$;

create or replace function
public.atlas_compute_conversation_scenario_plan_readiness_v1(
  p_scenario_plan_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.atlas_conversation_test_scenario_plans%rowtype;
  v_total integer := 0;
  v_applicable integer := 0;
  v_passed integer := 0;
  v_failed integer := 0;
  v_blocked integer := 0;
  v_skipped integer := 0;
  v_pending integer := 0;
  v_ready boolean := false;
begin
  select plan.*
  into v_plan
  from public.atlas_conversation_test_scenario_plans as plan
  where plan.id = p_scenario_plan_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_SCENARIO_PLAN_NOT_FOUND',
      'ready', false
    );
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where instance.applicability_status = 'APPLICABLE'
    )::integer,
    count(*) filter (
      where instance.instance_status = 'PASSED'
    )::integer,
    count(*) filter (
      where instance.instance_status = 'FAILED'
    )::integer,
    count(*) filter (
      where instance.instance_status = 'BLOCKED'
    )::integer,
    count(*) filter (
      where instance.instance_status = 'SKIPPED'
    )::integer,
    count(*) filter (
      where instance.instance_status in ('PENDING', 'RUNNING')
    )::integer
  into
    v_total,
    v_applicable,
    v_passed,
    v_failed,
    v_blocked,
    v_skipped,
    v_pending
  from public.atlas_conversation_test_scenario_instances
    as instance
  where instance.scenario_plan_id = v_plan.id;

  v_ready :=
    v_total = v_plan.total_scenarios
    and v_applicable = v_plan.applicable_scenarios
    and v_skipped = v_plan.skipped_scenarios
    and v_passed = v_applicable
    and v_failed = 0
    and v_blocked = 0
    and v_pending = 0;

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_ready then 'CONVERSATION_SCENARIOS_PASSED'
      else 'CONVERSATION_SCENARIOS_INCOMPLETE'
    end,
    'ready', v_ready,
    'scenario_plan_id', v_plan.id,
    'test_plan_id', v_plan.test_plan_id,
    'total_scenarios', v_total,
    'applicable_scenarios', v_applicable,
    'passed_scenarios', v_passed,
    'failed_scenarios', v_failed,
    'blocked_scenarios', v_blocked,
    'skipped_scenarios', v_skipped,
    'pending_scenarios', v_pending,
    'next_action', case
      when v_ready then 'BIND_TO_G03_V2_READINESS'
      else 'COMPLETE_OR_REMEDIATE_CONVERSATION_SCENARIOS'
    end
  );
end;
$$;

revoke all on table
public.atlas_conversation_test_scenario_results
from public, anon, authenticated;

revoke all on function
public.atlas_register_conversation_scenario_result_v1(
  uuid,text,text,uuid,text,text,jsonb,text,text,text,text,
  timestamptz,timestamptz,jsonb
)
from public, anon, authenticated;

revoke all on function
public.atlas_compute_conversation_scenario_plan_readiness_v1(uuid)
from public, anon, authenticated;

grant select on table
public.atlas_conversation_test_scenario_results
to service_role;

grant execute on function
public.atlas_register_conversation_scenario_result_v1(
  uuid,text,text,uuid,text,text,jsonb,text,text,text,text,
  timestamptz,timestamptz,jsonb
)
to service_role;

grant execute on function
public.atlas_compute_conversation_scenario_plan_readiness_v1(uuid)
to service_role;

commit;
