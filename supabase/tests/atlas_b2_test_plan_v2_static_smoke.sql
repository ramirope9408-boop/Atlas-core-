-- ATLAS B2 Test Plan V2 smoke checks
-- Date: 2026-09-27
-- Execute only after applying the V2 assertion/materializer/readiness migrations.

do $$
declare
  v_plan_constraint text;
begin
  if to_regprocedure(
       'public.atlas_test_assertion_contract_v2(text,text,text[],text[])'
     ) is null then
    raise exception 'ASSERTION_CONTRACT_V2_MISSING';
  end if;

  if to_regprocedure(
       'public.atlas_materialize_installation_test_plan_v2(uuid,uuid,bigint,jsonb)'
     ) is null then
    raise exception 'TEST_PLAN_MATERIALIZER_V2_MISSING';
  end if;

  if to_regprocedure(
       'public.atlas_compute_installation_g03_readiness_v2(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_get_installation_g03_readiness_v2(uuid)'
     ) is null then
    raise exception 'G03_READINESS_V2_MISSING';
  end if;

  select pg_get_constraintdef(oid)
  into v_plan_constraint
  from pg_constraint
  where conrelid = 'public.atlas_installation_test_plans'::regclass
    and conname = 'atlas_test_plans_version_check';

  if v_plan_constraint is null
     or position('B2_INSTALLATION_TEST_PLAN_V1' in v_plan_constraint) = 0
     or position('B2_INSTALLATION_TEST_PLAN_V2' in v_plan_constraint) = 0 then
    raise exception
      'TEST_PLAN_VERSION_CONSTRAINT_DOES_NOT_ALLOW_V1_AND_V2: %',
      coalesce(v_plan_constraint, '<missing>');
  end if;

  if (
    select count(*)
    from public.atlas_installation_test_definitions
    where active
  ) <> 18 then
    raise exception
      'HISTORICAL_TOP_LEVEL_TEST_CAPABILITY_COUNT_CHANGED';
  end if;
end;
$$;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_TEST_PLAN_V2_STATIC_SMOKE_PASS',
  'v1_preserved', true,
  'v2_assertions_installed', true,
  'v2_materializer_installed', true,
  'v2_g03_readiness_installed', true,
  'top_level_capabilities', 18
) as result;
