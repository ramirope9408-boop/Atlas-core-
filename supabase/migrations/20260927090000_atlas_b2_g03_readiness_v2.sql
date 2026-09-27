-- ATLAS B2 G03 readiness V2
-- Date: 2026-09-27
-- Additive/coexistent with V1. Reads only V2 test plans and their results.
-- Does not replace V1 readiness or alter historical approvals.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_test_assertion_contract_v2(text,text,text[],text[])'
     ) is null then
    raise exception 'B2 G03 readiness V2 requires assertion contract V2';
  end if;
end;
$$;

create or replace function
public.atlas_compute_installation_g03_readiness_v2(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_installation public.atlas_installations%rowtype;
  v_plan public.atlas_installation_test_plans%rowtype;
  v_run public.atlas_installation_test_runs%rowtype;
  v_integration_readiness jsonb;
  v_integration_ready boolean := false;
  v_plan_binding_valid boolean := false;
  v_run_summary_valid boolean := false;
  v_run_evidence_valid boolean := false;
  v_case_set_complete boolean := false;
  v_result_contracts_valid boolean := false;
  v_g03_coverage_complete boolean := false;
  v_total_case_count integer := 0;
  v_applicable_case_count integer := 0;
  v_passed_case_count integer := 0;
  v_skipped_case_count integer := 0;
  v_invalid_case_count integer := 0;
  v_valid_result_count integer := 0;
  v_required_g03_count integer := 0;
  v_covered_g03_count integer := 0;
  v_result_record_count integer := 0;
  v_recomputed_evidence_root_sha256 text;
  v_criteria jsonb := '{}'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_readiness_payload jsonb;
  v_readiness_sha256 text;
  v_ready boolean := false;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'contract_version', 'B2_TEST_READINESS_G03_V2',
      'ready', false
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_NOT_FOUND',
      'contract_version', 'B2_TEST_READINESS_G03_V2',
      'installation_id', p_installation_id,
      'ready', false
    );
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_test_plans as plan
  where plan.installation_id = v_installation.id
    and plan.empresa_id = v_installation.empresa_id
  order by plan.plan_version desc, plan.created_at desc, plan.id desc
  limit 1;

  if found then
    select run.*
    into v_run
    from public.atlas_installation_test_runs as run
    where run.test_plan_id = v_plan.id
      and run.installation_id = v_installation.id
      and run.empresa_id = v_installation.empresa_id
    order by run.run_number desc, run.created_at desc, run.id desc
    limit 1;

    v_integration_readiness :=
      public.atlas_compute_installation_integration_readiness(
        v_installation.id
      );

    v_integration_ready :=
      coalesce(
        (v_integration_readiness->>'ready')::boolean,
        false
      )
      and v_integration_readiness->>'manifest_id' =
        v_plan.source_manifest_id::text
      and v_integration_readiness->>'manifest_sha256' =
        v_plan.plan_payload->>'source_manifest_sha256'
      and v_integration_readiness->>'evidence_root_sha256' =
        v_plan.plan_payload
          ->>'integration_readiness_evidence_root_sha256';

    v_plan_binding_valid :=
      v_plan.plan_status = 'PASSED'
      and v_plan.expected_installation_version =
        v_installation.version
      and v_plan.test_contract_version =
        'B2_INSTALLATION_TEST_PLAN_V2'
      and v_plan.plan_sha256 =
        public.atlas_normalization_sha256(
          v_plan.plan_payload::text
        )
      and v_plan.plan_payload->>'installation_id' =
        v_installation.id::text
      and v_plan.plan_payload->>'empresa_id' =
        v_installation.empresa_id::text
      and v_plan.plan_payload->>'source_manifest_id' =
        v_plan.source_manifest_id::text
      and v_plan.plan_payload->>'plan_version' =
        v_plan.plan_version::text
      and not public.atlas_jsonb_has_forbidden_secret_key(
        v_plan.plan_payload
      );

    select
      count(*)::integer,
      count(*) filter (
        where test_case.applicability_status = 'APPLICABLE'
      )::integer,
      count(*) filter (
        where test_case.case_status = 'PASSED'
      )::integer,
      count(*) filter (
        where test_case.case_status = 'SKIPPED'
      )::integer,
      count(*) filter (
        where not (
          (
            test_case.applicability_status = 'APPLICABLE'
            and test_case.case_status = 'PASSED'
          )
          or (
            test_case.applicability_status = 'NOT_APPLICABLE'
            and test_case.requirement_mode = 'CONDITIONAL'
            and test_case.case_status = 'SKIPPED'
          )
        )
      )::integer
    into
      v_total_case_count,
      v_applicable_case_count,
      v_passed_case_count,
      v_skipped_case_count,
      v_invalid_case_count
    from public.atlas_installation_test_plan_cases as test_case
    where test_case.test_plan_id = v_plan.id;

    v_case_set_complete :=
      v_total_case_count =
        v_plan.required_case_count + v_plan.conditional_case_count
      and v_total_case_count = 18
      and v_applicable_case_count >= v_plan.required_case_count
      and v_passed_case_count = v_applicable_case_count
      and v_passed_case_count + v_skipped_case_count =
        v_total_case_count
      and v_invalid_case_count = 0;

    if v_run.id is not null then
      select count(*)::integer
      into v_result_record_count
      from public.atlas_installation_test_results as result
      where result.test_run_id = v_run.id;

      select count(*)::integer
      into v_valid_result_count
      from public.atlas_installation_test_plan_cases as test_case
      where test_case.test_plan_id = v_plan.id
        and test_case.applicability_status = 'APPLICABLE'
        and test_case.case_status = 'PASSED'
        and test_case.attempt_count between 1 and test_case.max_attempts
        and exists (
          select 1
          from public.atlas_installation_test_results as result
          where result.test_run_id = v_run.id
            and result.test_plan_id = v_plan.id
            and result.test_case_id = test_case.id
            and result.test_code = test_case.test_code
            and result.attempt_number = test_case.attempt_count
            and result.outcome = 'PASSED'
            and result.assertion_results_sha256 =
              public.atlas_normalization_sha256(
                result.assertion_results::text
              )
            and public.atlas_test_assertion_results_match_contract_v1(
              test_case.expected_assertions,
              result.assertion_results,
              result.outcome
            )
            and public.atlas_test_evidence_reference_is_safe(
              result.evidence_reference
            )
            and result.evidence_sha256 ~ '^[0-9a-f]{64}$'
            and result.request_sha256 ~ '^[0-9a-f]{64}$'
            and result.error_code is null
            and result.redacted_error_summary is null
        );

      v_result_contracts_valid :=
        v_valid_result_count = v_applicable_case_count;

      select public.atlas_normalization_sha256(
        jsonb_build_object(
          'contract_version', 'B2_TEST_RUN_EVIDENCE_ROOT_V1',
          'test_run_id', v_run.id,
          'test_plan_id', v_plan.id,
          'plan_sha256', v_plan.plan_sha256,
          'results', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'test_code', result.test_code,
                'attempt_number', result.attempt_number,
                'outcome', result.outcome,
                'assertion_results_sha256',
                  result.assertion_results_sha256,
                'evidence_sha256', result.evidence_sha256,
                'request_sha256', result.request_sha256
              )
              order by result.test_code, result.attempt_number
            )
            from public.atlas_installation_test_results as result
            where result.test_run_id = v_run.id
          ), '[]'::jsonb),
          'case_states', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'test_code', test_case.test_code,
                'case_status', test_case.case_status,
                'attempt_count', test_case.attempt_count,
                'input_contract_sha256',
                  test_case.input_contract_sha256
              )
              order by test_case.case_order
            )
            from public.atlas_installation_test_plan_cases
              as test_case
            where test_case.test_plan_id = v_plan.id
          ), '[]'::jsonb)
        )::text
      )
      into v_recomputed_evidence_root_sha256;

      v_run_evidence_valid :=
        v_run.evidence_root_sha256 is not null
        and v_run.evidence_root_sha256 =
          v_recomputed_evidence_root_sha256;

      v_run_summary_valid :=
        v_run.run_status = 'PASSED'
        and v_run.expected_installation_version =
          v_installation.version
        and v_run.total_cases = v_total_case_count
        and v_run.passed_cases = v_passed_case_count
        and v_run.failed_cases = 0
        and v_run.blocked_cases = 0
        and v_run.skipped_cases = v_skipped_case_count
        and v_run.passed_cases + v_run.skipped_cases =
          v_run.total_cases
        and v_run.started_at is not null
        and v_run.completed_at is not null
        and v_run.completed_at >= v_run.started_at;
    end if;

    select
      count(*)::integer,
      count(*) filter (
        where exists (
          select 1
          from public.atlas_installation_test_definitions
            as test_definition
          join public.atlas_installation_test_plan_cases
            as test_case
            on test_case.test_plan_id = v_plan.id
           and test_case.test_code = test_definition.test_code
          where test_definition.active
            and criterion.value->>'code' = any(
              test_definition.g03_criterion_codes
            )
            and test_case.applicability_status = 'APPLICABLE'
            and test_case.case_status = 'PASSED'
        )
      )::integer,
      coalesce(
        jsonb_object_agg(
          criterion.value->>'code',
          exists (
            select 1
            from public.atlas_installation_test_definitions
              as test_definition
            join public.atlas_installation_test_plan_cases
              as test_case
              on test_case.test_plan_id = v_plan.id
             and test_case.test_code = test_definition.test_code
            where test_definition.active
              and criterion.value->>'code' = any(
                test_definition.g03_criterion_codes
              )
              and test_case.applicability_status = 'APPLICABLE'
              and test_case.case_status = 'PASSED'
          )
        ),
        '{}'::jsonb
      )
    into
      v_required_g03_count,
      v_covered_g03_count,
      v_criteria
    from public.atlas_installation_gates as gate_record
    cross join lateral jsonb_array_elements(
      gate_record.criteria_snapshot
    ) as criterion(value)
    where gate_record.installation_id = v_installation.id
      and gate_record.gate_code = 'G03'
      and coalesce(
        (criterion.value->>'required')::boolean,
        false
      );

    v_g03_coverage_complete :=
      v_required_g03_count = 9
      and v_covered_g03_count = v_required_g03_count
      and (
        select count(*)
        from jsonb_object_keys(v_criteria)
      ) = v_required_g03_count;
  end if;

  select coalesce(jsonb_agg(blocker), '[]'::jsonb)
  into v_blockers
  from jsonb_array_elements(jsonb_build_array(
    case when v_plan.id is null then jsonb_build_object(
      'criterion', 'CURRENT_TEST_PLAN_PRESENT',
      'reason', 'MATERIALIZED_TEST_PLAN_REQUIRED'
    ) end,
    case when v_plan.id is not null and not v_plan_binding_valid
      then jsonb_build_object(
        'criterion', 'CURRENT_TEST_PLAN_VALID',
        'reason', 'PASSED_CURRENT_HASH_BOUND_PLAN_REQUIRED'
      ) end,
    case when v_run.id is null then jsonb_build_object(
      'criterion', 'CURRENT_TEST_RUN_PRESENT',
      'reason', 'COMPLETED_TEST_RUN_REQUIRED'
    ) end,
    case when v_run.id is not null and not v_run_summary_valid
      then jsonb_build_object(
        'criterion', 'TEST_RUN_PASSED',
        'reason', 'ZERO_FAILED_OR_BLOCKED_CASES_REQUIRED'
      ) end,
    case when not v_case_set_complete then jsonb_build_object(
      'criterion', 'TEST_CASE_SET_COMPLETE',
      'reason', 'ALL_APPLICABLE_CASES_MUST_PASS'
    ) end,
    case when not v_result_contracts_valid then jsonb_build_object(
      'criterion', 'TEST_RESULT_CONTRACTS_VALID',
      'reason', 'CURRENT_ASSERTIONS_AND_EVIDENCE_REQUIRED'
    ) end,
    case when not v_run_evidence_valid then jsonb_build_object(
      'criterion', 'TEST_EVIDENCE_ROOT_VALID',
      'reason', 'RECOMPUTED_RUN_EVIDENCE_ROOT_MUST_MATCH'
    ) end,
    case when not v_g03_coverage_complete then jsonb_build_object(
      'criterion', 'G03_CRITERIA_COVERED',
      'reason', 'ALL_NINE_G03_CRITERIA_REQUIRE_PASSED_TEST_COVERAGE'
    ) end,
    case when not v_integration_ready then jsonb_build_object(
      'criterion', 'INTEGRATION_READINESS_CURRENT',
      'reason', 'CURRENT_INTEGRATION_EVIDENCE_MUST_MATCH_TEST_PLAN'
    ) end
  )) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  v_ready :=
    v_plan.id is not null
    and v_run.id is not null
    and v_plan_binding_valid
    and v_run_summary_valid
    and v_run_evidence_valid
    and v_case_set_complete
    and v_result_contracts_valid
    and v_g03_coverage_complete
    and v_integration_ready
    and jsonb_array_length(v_blockers) = 0;

  v_readiness_payload := jsonb_build_object(
    'contract_version', 'B2_TEST_READINESS_G03_V2',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_version', v_installation.version,
    'test_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'plan_sha256', v_plan.plan_sha256,
    'test_run_id', v_run.id,
    'run_number', v_run.run_number,
    'evidence_root_sha256', v_run.evidence_root_sha256,
    'source_manifest_id', v_plan.source_manifest_id,
    'source_manifest_sha256',
      v_plan.plan_payload->>'source_manifest_sha256',
    'integration_evidence_root_sha256',
      v_integration_readiness->>'evidence_root_sha256',
    'total_cases', v_total_case_count,
    'applicable_cases', v_applicable_case_count,
    'passed_cases', v_passed_case_count,
    'skipped_cases', v_skipped_case_count,
    'result_records', v_result_record_count,
    'g03_criteria', v_criteria,
    'ready', v_ready
  );
  v_readiness_sha256 := public.atlas_normalization_sha256(
    v_readiness_payload::text
  );

  return jsonb_build_object(
    'ok', true,
    'code', case when v_ready
      then 'G03_TEST_READINESS_COMPLETE'
      else 'G03_TEST_READINESS_INCOMPLETE'
    end,
    'contract_version', 'B2_TEST_READINESS_G03_V2',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'ready', v_ready,
    'test_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'plan_sha256', v_plan.plan_sha256,
    'test_run_id', v_run.id,
    'run_number', v_run.run_number,
    'run_status', v_run.run_status,
    'evidence_root_sha256', v_run.evidence_root_sha256,
    'recomputed_evidence_root_sha256',
      v_recomputed_evidence_root_sha256,
    'readiness_sha256', v_readiness_sha256,
    'source_manifest_id', v_plan.source_manifest_id,
    'source_manifest_sha256',
      v_plan.plan_payload->>'source_manifest_sha256',
    'integration_evidence_root_sha256',
      v_integration_readiness->>'evidence_root_sha256',
    'total_cases', v_total_case_count,
    'applicable_cases', v_applicable_case_count,
    'passed_cases', v_passed_case_count,
    'skipped_cases', v_skipped_case_count,
    'invalid_cases', v_invalid_case_count,
    'valid_current_results', v_valid_result_count,
    'result_records', v_result_record_count,
    'required_g03_criteria', v_required_g03_count,
    'covered_g03_criteria', v_covered_g03_count,
    'criteria', v_criteria,
    'plan_binding_valid', v_plan_binding_valid,
    'run_summary_valid', v_run_summary_valid,
    'run_evidence_valid', v_run_evidence_valid,
    'case_set_complete', v_case_set_complete,
    'result_contracts_valid', v_result_contracts_valid,
    'g03_coverage_complete', v_g03_coverage_complete,
    'integration_readiness_current', v_integration_ready,
    'blockers', v_blockers,
    'credential_values_exposed', false,
    'raw_test_payloads_exposed', false,
    'evaluated_at', now(),
    'next_action', case
      when v_ready then 'APPROVE_G03'
      else 'COMPLETE_OR_REMEDIATE_TESTS'
    end
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_g03_readiness_v2(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_g03_readiness_v2(uuid)
to service_role;

create or replace function
public.atlas_get_installation_g03_readiness_v2(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_can_read_installation(
       p_installation_id
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_G03_READ_FORBIDDEN';
  end if;

  return public.atlas_compute_installation_g03_readiness_v2(
    p_installation_id
  );
end;
$$;

revoke all on function
public.atlas_get_installation_g03_readiness_v2(uuid)
from public, anon;
grant execute on function
public.atlas_get_installation_g03_readiness_v2(uuid)
to authenticated, service_role;



commit;
