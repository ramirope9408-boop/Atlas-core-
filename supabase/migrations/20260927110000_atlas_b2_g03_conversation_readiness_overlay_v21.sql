-- ATLAS B2 G03 conversational readiness overlay V2.1
-- Date: 2026-09-27
-- Adds mandatory conversational scenario readiness on top of G03 V2.
-- Additive only; V1 and V2 remain available for historical verification.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_compute_installation_g03_readiness_v2(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_conversation_scenario_plan_readiness_v1(uuid)'
     ) is null
     or to_regclass(
       'public.atlas_conversation_test_scenario_plans'
     ) is null then
    raise exception
      'B2 G03 conversational readiness V2.1 requires G03 V2 and conversation scenario execution ledger';
  end if;
end;
$$;

create or replace function
public.atlas_compute_installation_g03_readiness_v21(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_base jsonb;
  v_test_plan_id uuid;
  v_scenario_plan
    public.atlas_conversation_test_scenario_plans%rowtype;
  v_conversation jsonb;
  v_conversation_ready boolean := false;
  v_base_ready boolean := false;
  v_ready boolean := false;
  v_blockers jsonb := '[]'::jsonb;
  v_payload jsonb;
  v_readiness_sha256 text;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'contract_version', 'B2_TEST_READINESS_G03_V2_1',
      'ready', false
    );
  end if;

  v_base :=
    public.atlas_compute_installation_g03_readiness_v2(
      p_installation_id
    );

  v_base_ready :=
    coalesce((v_base->>'ready')::boolean, false);

  if nullif(v_base->>'test_plan_id', '') is not null then
    v_test_plan_id := (v_base->>'test_plan_id')::uuid;
  end if;

  if v_test_plan_id is not null then
    select scenario_plan.*
    into v_scenario_plan
    from public.atlas_conversation_test_scenario_plans
      as scenario_plan
    where scenario_plan.test_plan_id = v_test_plan_id
      and scenario_plan.installation_id = p_installation_id
    order by
      scenario_plan.scenario_plan_version desc,
      scenario_plan.created_at desc,
      scenario_plan.id desc
    limit 1;
  end if;

  if v_scenario_plan.id is not null then
    v_conversation :=
      public.atlas_compute_conversation_scenario_plan_readiness_v1(
        v_scenario_plan.id
      );

    v_conversation_ready :=
      coalesce((v_conversation->>'ready')::boolean, false);
  else
    v_conversation := jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_SCENARIO_PLAN_REQUIRED',
      'ready', false
    );
  end if;

  select coalesce(jsonb_agg(blocker), '[]'::jsonb)
  into v_blockers
  from jsonb_array_elements(
    coalesce(v_base->'blockers', '[]'::jsonb)
    || jsonb_build_array(
      case
        when v_scenario_plan.id is null then
          jsonb_build_object(
            'criterion', 'CONVERSATION_SCENARIO_PLAN_PRESENT',
            'reason',
              'MATERIALIZED_CONVERSATION_SCENARIO_PLAN_REQUIRED'
          )
      end,
      case
        when v_scenario_plan.id is not null
          and not v_conversation_ready then
          jsonb_build_object(
            'criterion', 'CONVERSATION_CERTIFICATION_COMPLETE',
            'reason',
              'ALL_APPLICABLE_CONVERSATION_SCENARIOS_MUST_PASS'
          )
      end
    )
  ) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  v_ready :=
    v_base_ready
    and v_scenario_plan.id is not null
    and v_conversation_ready
    and jsonb_array_length(v_blockers) = 0;

  v_payload := jsonb_build_object(
    'contract_version', 'B2_TEST_READINESS_G03_V2_1',
    'installation_id', p_installation_id,
    'base_readiness_sha256', v_base->>'readiness_sha256',
    'test_plan_id', v_base->>'test_plan_id',
    'scenario_plan_id', v_scenario_plan.id,
    'scenario_plan_sha256', v_scenario_plan.plan_sha256,
    'conversation_ready', v_conversation_ready,
    'base_ready', v_base_ready,
    'ready', v_ready
  );

  v_readiness_sha256 :=
    public.atlas_normalization_sha256(v_payload::text);

  return v_base
    || jsonb_build_object(
      'code', case
        when v_ready then 'G03_V21_READINESS_COMPLETE'
        else 'G03_V21_READINESS_INCOMPLETE'
      end,
      'contract_version', 'B2_TEST_READINESS_G03_V2_1',
      'ready', v_ready,
      'base_g03_v2_ready', v_base_ready,
      'conversation_scenario_plan_id', v_scenario_plan.id,
      'conversation_scenario_plan_sha256',
        v_scenario_plan.plan_sha256,
      'conversation_certification',
        v_conversation,
      'conversation_certification_ready',
        v_conversation_ready,
      'readiness_sha256', v_readiness_sha256,
      'blockers', v_blockers,
      'next_action', case
        when v_ready then 'APPROVE_G03_V21'
        when v_scenario_plan.id is null
          then 'MATERIALIZE_CONVERSATION_SCENARIO_PLAN'
        else 'COMPLETE_OR_REMEDIATE_CONVERSATION_SCENARIOS'
      end
    );
end;
$$;

create or replace function
public.atlas_get_installation_g03_readiness_v21(
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
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_can_read_installation(
       p_installation_id
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_G03_READ_FORBIDDEN';
  end if;

  return public.atlas_compute_installation_g03_readiness_v21(
    p_installation_id
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_g03_readiness_v21(uuid)
from public, anon, authenticated;

revoke all on function
public.atlas_get_installation_g03_readiness_v21(uuid)
from public, anon;

grant execute on function
public.atlas_compute_installation_g03_readiness_v21(uuid)
to service_role;

grant execute on function
public.atlas_get_installation_g03_readiness_v21(uuid)
to authenticated, service_role;

commit;
