-- ATLAS B2 conversation certification batch core V1
-- Date: 2026-09-27
-- Provides governed queue/readiness access for executing all applicable
-- conversational scenarios belonging to one scenario plan.

begin;

do $$
begin
  if to_regclass('public.atlas_conversation_test_scenario_plans') is null
     or to_regclass('public.atlas_conversation_test_scenario_instances') is null
     or to_regprocedure(
       'public.atlas_compute_conversation_scenario_plan_readiness_v1(uuid)'
     ) is null then
    raise exception
      'Conversation certification batch core requires scenario plan/execution core';
  end if;
end;
$$;

create or replace function
public.atlas_get_conversation_certification_queue_v1(
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
  v_queue jsonb;
  v_readiness jsonb;
begin
  if auth.uid() is null
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_scenario_plan_id is null then
    raise exception using
      errcode = '22023',
      message = 'SCENARIO_PLAN_ID_REQUIRED';
  end if;

  select plan.*
  into v_plan
  from public.atlas_conversation_test_scenario_plans as plan
  where plan.id = p_scenario_plan_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'CONVERSATION_SCENARIO_PLAN_NOT_FOUND';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_platform_has_permission(
       'INSTALLATION_TEST_EXECUTE'
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'scenario_instance_id', instance.id,
        'scenario_code', instance.scenario_code,
        'scenario_order', instance.scenario_order,
        'instance_status', instance.instance_status,
        'applicability_status', instance.applicability_status
      )
      order by instance.scenario_order
    ),
    '[]'::jsonb
  )
  into v_queue
  from public.atlas_conversation_test_scenario_instances as instance
  where instance.scenario_plan_id = v_plan.id
    and instance.applicability_status = 'APPLICABLE'
    and instance.instance_status in (
      'PENDING', 'FAILED', 'BLOCKED'
    );

  v_readiness :=
    public.atlas_compute_conversation_scenario_plan_readiness_v1(
      v_plan.id
    );

  return jsonb_build_object(
    'ok', true,
    'code', 'CONVERSATION_CERTIFICATION_QUEUE_READY',
    'scenario_plan_id', v_plan.id,
    'test_plan_id', v_plan.test_plan_id,
    'installation_id', v_plan.installation_id,
    'empresa_id', v_plan.empresa_id,
    'plan_sha256', v_plan.plan_sha256,
    'readiness', v_readiness,
    'queue', v_queue,
    'queue_count', jsonb_array_length(v_queue)
  );
end;
$$;

create or replace function
public.atlas_get_installation_conversation_certification_v1(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.atlas_conversation_test_scenario_plans%rowtype;
  v_readiness jsonb;
begin
  if auth.uid() is null
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_installation_id is null then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_ID_REQUIRED';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_can_read_installation(p_installation_id) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_CONVERSATION_CERT_READ_FORBIDDEN';
  end if;

  select plan.*
  into v_plan
  from public.atlas_conversation_test_scenario_plans as plan
  where plan.installation_id = p_installation_id
  order by plan.scenario_plan_version desc, plan.created_at desc
  limit 1;

  if not found then
    return jsonb_build_object(
      'ok', true,
      'code', 'CONVERSATION_SCENARIO_PLAN_NOT_MATERIALIZED',
      'installation_id', p_installation_id,
      'ready', false
    );
  end if;

  v_readiness :=
    public.atlas_compute_conversation_scenario_plan_readiness_v1(v_plan.id);

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CONVERSATION_CERTIFICATION_STATUS',
    'installation_id', p_installation_id,
    'scenario_plan_id', v_plan.id,
    'scenario_plan_version', v_plan.scenario_plan_version,
    'scenario_plan_sha256', v_plan.plan_sha256,
    'ready', coalesce((v_readiness->>'ready')::boolean, false),
    'readiness', v_readiness
  );
end;
$$;

revoke all on function
public.atlas_get_conversation_certification_queue_v1(uuid)
from public, anon;
revoke all on function
public.atlas_get_installation_conversation_certification_v1(uuid)
from public, anon;

grant execute on function
public.atlas_get_conversation_certification_queue_v1(uuid)
to authenticated, service_role;
grant execute on function
public.atlas_get_installation_conversation_certification_v1(uuid)
to authenticated, service_role;

commit;