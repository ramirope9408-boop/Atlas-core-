-- ATLAS B2 conversation certification authenticated RPC hardening V1
-- Date: 2026-09-27
-- Exposes only operator-facing wrapper RPCs to authenticated users.
-- Underlying low-level resolver/evaluator functions remain service-role only.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_render_conversation_scenario_payload_v1(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_validate_conversation_semantic_evaluation_v1(uuid,jsonb,text)'
     ) is null
     or to_regprocedure(
       'public.atlas_get_next_conversation_certification_scenarios_v1(uuid,integer)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_conversation_certification_batch_summary_v1(uuid)'
     ) is null then
    raise exception
      'Authenticated hardening requires conversation certification RPCs installed';
  end if;
end;
$$;

create or replace function
public.atlas_render_conversation_scenario_payload_for_operator_v1(
  p_scenario_instance_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TEST_EXECUTE') then
    raise exception using errcode='42501', message='INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  return public.atlas_render_conversation_scenario_payload_v1(
    p_scenario_instance_id
  );
end;
$$;

create or replace function
public.atlas_validate_conversation_semantic_evaluation_for_operator_v1(
  p_scenario_instance_id uuid,
  p_assertion_results jsonb,
  p_outcome text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TEST_EXECUTE') then
    raise exception using errcode='42501', message='INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  return public.atlas_validate_conversation_semantic_evaluation_v1(
    p_scenario_instance_id, p_assertion_results, p_outcome
  );
end;
$$;

create or replace function
public.atlas_get_next_conversation_certification_scenarios_for_operator_v1(
  p_scenario_plan_id uuid,
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TEST_EXECUTE') then
    raise exception using errcode='42501', message='INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  return public.atlas_get_next_conversation_certification_scenarios_v1(
    p_scenario_plan_id, p_limit
  );
end;
$$;

create or replace function
public.atlas_compute_conversation_certification_batch_summary_for_operator_v1(
  p_scenario_plan_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TEST_READ') then
    raise exception using errcode='42501', message='INSTALLATION_TEST_READ_FORBIDDEN';
  end if;

  return public.atlas_compute_conversation_certification_batch_summary_v1(
    p_scenario_plan_id
  );
end;
$$;

revoke all on function
public.atlas_render_conversation_scenario_payload_for_operator_v1(uuid)
from public, anon;
revoke all on function
public.atlas_validate_conversation_semantic_evaluation_for_operator_v1(uuid,jsonb,text)
from public, anon;
revoke all on function
public.atlas_get_next_conversation_certification_scenarios_for_operator_v1(uuid,integer)
from public, anon;
revoke all on function
public.atlas_compute_conversation_certification_batch_summary_for_operator_v1(uuid)
from public, anon;

grant execute on function
public.atlas_render_conversation_scenario_payload_for_operator_v1(uuid)
to authenticated, service_role;
grant execute on function
public.atlas_validate_conversation_semantic_evaluation_for_operator_v1(uuid,jsonb,text)
to authenticated, service_role;
grant execute on function
public.atlas_get_next_conversation_certification_scenarios_for_operator_v1(uuid,integer)
to authenticated, service_role;
grant execute on function
public.atlas_compute_conversation_certification_batch_summary_for_operator_v1(uuid)
to authenticated, service_role;


create or replace function
public.atlas_register_conversation_scenario_result_for_operator_v1(
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
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TEST_EXECUTE') then
    raise exception using errcode='42501', message='INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  return public.atlas_register_conversation_scenario_result_v1(
    p_scenario_instance_id, p_outcome, p_executor_code, p_request_id,
    p_rendered_input_sha256, p_response_sha256, p_assertion_results,
    p_evidence_reference, p_evidence_sha256, p_error_code,
    p_redacted_error_summary, p_started_at, p_completed_at, p_metadata
  );
end;
$$;

revoke all on function
public.atlas_register_conversation_scenario_result_for_operator_v1(
  uuid,text,text,uuid,text,text,jsonb,text,text,text,text,
  timestamptz,timestamptz,jsonb
)
from public, anon;

grant execute on function
public.atlas_register_conversation_scenario_result_for_operator_v1(
  uuid,text,text,uuid,text,text,jsonb,text,text,text,text,
  timestamptz,timestamptz,jsonb
)
to authenticated, service_role;
commit;