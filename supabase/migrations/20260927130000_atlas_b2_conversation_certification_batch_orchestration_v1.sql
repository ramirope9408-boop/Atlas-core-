-- ATLAS B2 conversation certification batch orchestration V1
-- Date: 2026-09-27
-- Provides deterministic next-work selection and aggregate batch readiness.

begin;

do $$
begin
  if to_regclass('public.atlas_conversation_test_scenario_plans') is null
     or to_regclass('public.atlas_conversation_test_scenario_instances') is null
     or to_regclass('public.atlas_conversation_test_scenario_results') is null
     or to_regprocedure(
       'public.atlas_compute_conversation_scenario_plan_readiness_v1(uuid)'
     ) is null then
    raise exception
      'Conversation certification batch orchestration requires scenario execution core';
  end if;
end;
$$;

create or replace function
public.atlas_get_next_conversation_certification_scenarios_v1(
  p_scenario_plan_id uuid,
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.atlas_conversation_test_scenario_plans%rowtype;
  v_items jsonb;
begin
  if p_scenario_plan_id is null
     or p_limit is null
     or p_limit < 1
     or p_limit > 100 then
    return jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_CERT_BATCH_INPUT_INVALID'
    );
  end if;

  select plan.*
  into v_plan
  from public.atlas_conversation_test_scenario_plans as plan
  where plan.id = p_scenario_plan_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_SCENARIO_PLAN_NOT_FOUND'
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'scenario_instance_id', instance.id,
        'scenario_code', instance.scenario_code,
        'scenario_order', instance.scenario_order,
        'instance_status', instance.instance_status,
        'expected_assertion_codes',
          to_jsonb(instance.expected_assertion_codes),
        'latest_attempt_number', latest.attempt_number,
        'latest_outcome', latest.outcome
      )
      order by instance.scenario_order
    ),
    '[]'::jsonb
  )
  into v_items
  from (
    select instance.*
    from public.atlas_conversation_test_scenario_instances as instance
    where instance.scenario_plan_id = v_plan.id
      and instance.applicability_status = 'APPLICABLE'
      and instance.instance_status in ('PENDING','FAILED','BLOCKED')
    order by instance.scenario_order
    limit p_limit
  ) as instance
  left join lateral (
    select result.attempt_number, result.outcome
    from public.atlas_conversation_test_scenario_results as result
    where result.scenario_instance_id = instance.id
    order by result.attempt_number desc
    limit 1
  ) as latest on true;

  return jsonb_build_object(
    'ok', true,
    'code', case
      when jsonb_array_length(v_items) = 0
        then 'NO_PENDING_CONVERSATION_SCENARIOS'
      else 'CONVERSATION_SCENARIOS_READY_FOR_EXECUTION'
    end,
    'scenario_plan_id', v_plan.id,
    'test_plan_id', v_plan.test_plan_id,
    'items', v_items,
    'count', jsonb_array_length(v_items),
    'next_action', case
      when jsonb_array_length(v_items) = 0
        then 'COMPUTE_CONVERSATION_READINESS'
      else 'EXECUTE_SCENARIO_BATCH'
    end
  );
end;
$$;

create or replace function
public.atlas_compute_conversation_certification_batch_summary_v1(
  p_scenario_plan_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
  v_attempts integer := 0;
  v_latest_results integer := 0;
  v_evidence_root text;
  v_projection jsonb;
begin
  v_readiness :=
    public.atlas_compute_conversation_scenario_plan_readiness_v1(
      p_scenario_plan_id
    );

  if coalesce(v_readiness->>'code','') =
       'CONVERSATION_SCENARIO_PLAN_NOT_FOUND' then
    return v_readiness;
  end if;

  select count(*)::integer
  into v_attempts
  from public.atlas_conversation_test_scenario_results as result
  where result.scenario_plan_id = p_scenario_plan_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'scenario_instance_id', instance.id,
        'scenario_code', instance.scenario_code,
        'status', instance.instance_status,
        'attempt_number', latest.attempt_number,
        'outcome', latest.outcome,
        'assertion_results_sha256',
          latest.assertion_results_sha256,
        'evidence_sha256', latest.evidence_sha256
      )
      order by instance.scenario_order
    ),
    '[]'::jsonb
  )
  into v_projection
  from public.atlas_conversation_test_scenario_instances as instance
  left join lateral (
    select result.*
    from public.atlas_conversation_test_scenario_results as result
    where result.scenario_instance_id = instance.id
    order by result.attempt_number desc
    limit 1
  ) as latest on true
  where instance.scenario_plan_id = p_scenario_plan_id;

  select count(*)::integer
  into v_latest_results
  from jsonb_array_elements(v_projection) as item(value)
  where item.value->>'attempt_number' is not null;

  v_evidence_root :=
    public.atlas_normalization_sha256(v_projection::text);

  return v_readiness || jsonb_build_object(
    'contract_version', 'B2_CONVERSATION_CERT_BATCH_SUMMARY_V1',
    'attempt_records', v_attempts,
    'latest_result_records', v_latest_results,
    'evidence_root_sha256', v_evidence_root,
    'result_projection', v_projection
  );
end;
$$;

revoke all on function
public.atlas_get_next_conversation_certification_scenarios_v1(uuid,integer)
from public, anon, authenticated;

revoke all on function
public.atlas_compute_conversation_certification_batch_summary_v1(uuid)
from public, anon, authenticated;

grant execute on function
public.atlas_get_next_conversation_certification_scenarios_v1(uuid,integer)
to service_role;

grant execute on function
public.atlas_compute_conversation_certification_batch_summary_v1(uuid)
to service_role;

commit;