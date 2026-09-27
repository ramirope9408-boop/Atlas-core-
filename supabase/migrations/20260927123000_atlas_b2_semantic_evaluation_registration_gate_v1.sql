-- ATLAS B2 semantic evaluation registration gate V1
-- Date: 2026-09-27
-- Accepts semantic-evaluator output only when it matches the scenario contract.
-- It does not call a model and cannot turn missing evidence into PASS.

begin;

do $$
begin
  if to_regclass('public.atlas_conversation_test_scenario_instances') is null
     or to_regprocedure(
       'public.atlas_test_assertion_results_match_contract_v1(jsonb,jsonb,text)'
     ) is null then
    raise exception
      'Semantic evaluation gate requires conversation scenario execution core';
  end if;
end;
$$;

create or replace function
public.atlas_validate_conversation_semantic_evaluation_v1(
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
declare
  v_instance
    public.atlas_conversation_test_scenario_instances%rowtype;
  v_expected jsonb;
  v_valid boolean := false;
begin
  if p_scenario_instance_id is null
     or p_assertion_results is null
     or jsonb_typeof(p_assertion_results) <> 'array'
     or p_outcome not in ('PASSED', 'FAILED', 'BLOCKED') then
    return jsonb_build_object(
      'ok', false,
      'code', 'SEMANTIC_EVALUATION_REQUIRED_FIELDS_INVALID',
      'valid', false
    );
  end if;

  select instance.*
  into v_instance
  from public.atlas_conversation_test_scenario_instances as instance
  where instance.id = p_scenario_instance_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_SCENARIO_INSTANCE_NOT_FOUND',
      'valid', false
    );
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

  v_valid :=
    public.atlas_test_assertion_results_match_contract_v1(
      v_expected,
      p_assertion_results,
      p_outcome
    );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_valid then 'SEMANTIC_EVALUATION_CONTRACT_VALID'
      else 'SEMANTIC_EVALUATION_CONTRACT_INVALID'
    end,
    'valid', v_valid,
    'scenario_instance_id', v_instance.id,
    'scenario_code', v_instance.scenario_code,
    'expected_assertion_codes',
      to_jsonb(v_instance.expected_assertion_codes),
    'outcome', p_outcome
  );
end;
$$;

revoke all on function
public.atlas_validate_conversation_semantic_evaluation_v1(uuid,jsonb,text)
from public, anon, authenticated;

grant execute on function
public.atlas_validate_conversation_semantic_evaluation_v1(uuid,jsonb,text)
to service_role;

commit;