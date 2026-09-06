-- ATLAS B2.2I.2B
-- Inicio de runs, ejecucion bifasica de casos y registro de resultados.
-- Corte: 2026-09-02
--
-- Invariantes:
-- - un run solo inicia sobre un plan READY, integro y vigente en TESTING;
-- - cada intento tiene BEGIN y COMPLETE, identidad y hash propios;
-- - las dependencias deben estar PASSED o SKIPPED antes de ejecutar;
-- - los resultados son append-only, coherentes y enlazados a evidencia;
-- - los fallos reintentan dentro del limite y bloquean dependientes al agotarlo;
-- - el ultimo caso terminal cierra run y plan; no decide G03 ni mueve estados.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_materialize_installation_test_plan(uuid,uuid,bigint,jsonb)'
     ) is null
     or to_regclass('public.atlas_installation_test_runs') is null
     or to_regclass('public.atlas_installation_test_results') is null
     or to_regclass('public.atlas_installation_test_events') is null
     or to_regprocedure(
       'public.atlas_compute_installation_integration_readiness(uuid)'
     ) is null then
    raise exception
      'B2.2I.2B requiere B2.2I.2A instalado y certificado';
  end if;
end;
$$;

alter table public.atlas_installation_test_runs
  add column if not exists request_sha256 text;

update public.atlas_installation_test_runs as run
set request_sha256 = public.atlas_normalization_sha256(
  jsonb_build_object(
    'contract_version', 'B2_TEST_RUN_START_REQUEST_V1',
    'test_plan_id', run.test_plan_id,
    'expected_installation_version',
      run.expected_installation_version,
    'executor_code', run.executor_code,
    'request_metadata', run.metadata
  )::text
)
where run.request_sha256 is null;

alter table public.atlas_installation_test_runs
  alter column request_sha256 set not null;

alter table public.atlas_installation_test_results
  add column if not exists request_sha256 text;

update public.atlas_installation_test_results as result
set request_sha256 = public.atlas_normalization_sha256(
  jsonb_build_object(
    'contract_version', 'B2_TEST_RESULT_REGISTRATION_REQUEST_V1',
    'test_run_id', result.test_run_id,
    'test_code', result.test_code,
    'attempt_number', result.attempt_number,
    'outcome', result.outcome,
    'assertion_results_sha256',
      result.assertion_results_sha256,
    'evidence_reference', result.evidence_reference,
    'evidence_sha256', result.evidence_sha256,
    'error_code', result.error_code,
    'redacted_error_summary',
      result.redacted_error_summary,
    'executor_code', result.executor_code,
    'request_metadata', result.metadata
  )::text
)
where result.request_sha256 is null;

alter table public.atlas_installation_test_results
  alter column request_sha256 set not null;

alter table public.atlas_installation_test_plan_cases
  add column if not exists active_test_run_id uuid,
  add column if not exists active_attempt_started_at timestamptz,
  add column if not exists active_attempt_request_id uuid,
  add column if not exists active_attempt_request_sha256 text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid =
      'public.atlas_installation_test_runs'::regclass
      and conname = 'atlas_test_runs_request_sha256_check'
  ) then
    alter table public.atlas_installation_test_runs
      add constraint atlas_test_runs_request_sha256_check
      check (request_sha256 ~ '^[0-9a-f]{64}$');
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid =
      'public.atlas_installation_test_results'::regclass
      and conname = 'atlas_test_results_request_sha256_check'
  ) then
    alter table public.atlas_installation_test_results
      add constraint atlas_test_results_request_sha256_check
      check (request_sha256 ~ '^[0-9a-f]{64}$');
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid =
      'public.atlas_installation_test_plan_cases'::regclass
      and conname = 'atlas_test_cases_active_run_fkey'
  ) then
    alter table public.atlas_installation_test_plan_cases
      add constraint atlas_test_cases_active_run_fkey
      foreign key (active_test_run_id)
      references public.atlas_installation_test_runs(id)
      on delete restrict;
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid =
      'public.atlas_installation_test_plan_cases'::regclass
      and conname = 'atlas_test_cases_active_attempt_check'
  ) then
    alter table public.atlas_installation_test_plan_cases
      add constraint atlas_test_cases_active_attempt_check
      check (
        (
          case_status = 'RUNNING'
          and active_test_run_id is not null
          and active_attempt_started_at is not null
          and active_attempt_request_id is not null
          and active_attempt_request_sha256 ~ '^[0-9a-f]{64}$'
        )
        or (
          case_status <> 'RUNNING'
          and active_test_run_id is null
          and active_attempt_started_at is null
          and active_attempt_request_id is null
          and active_attempt_request_sha256 is null
        )
      );
  end if;
end;
$$;

create unique index if not exists
uq_atlas_test_cases_active_attempt_request
  on public.atlas_installation_test_plan_cases(
    active_attempt_request_id
  )
  where active_attempt_request_id is not null;

create or replace function
public.atlas_test_assertion_results_match_contract_v1(
  p_expected_assertions jsonb,
  p_assertion_results jsonb,
  p_outcome text
)
returns boolean
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select
    jsonb_typeof(p_expected_assertions) = 'array'
    and jsonb_typeof(p_assertion_results) = 'array'
    and jsonb_array_length(p_expected_assertions) >= 1
    and jsonb_array_length(p_expected_assertions) =
      jsonb_array_length(p_assertion_results)
    and p_outcome in ('PASSED', 'FAILED', 'BLOCKED')
    and not public.atlas_jsonb_has_forbidden_secret_key(
      p_assertion_results
    )
    and not exists (
      select 1
      from jsonb_array_elements(p_assertion_results) as item(value)
      where jsonb_typeof(item.value) <> 'object'
        or nullif(btrim(item.value->>'assertion_code'), '') is null
        or jsonb_typeof(item.value->'passed') <> 'boolean'
    )
    and not exists (
      select result_item.value->>'assertion_code'
      from jsonb_array_elements(p_assertion_results)
        as result_item(value)
      except
      select expected_item.value->>'assertion_code'
      from jsonb_array_elements(p_expected_assertions)
        as expected_item(value)
    )
    and not exists (
      select expected_item.value->>'assertion_code'
      from jsonb_array_elements(p_expected_assertions)
        as expected_item(value)
      where coalesce(
        (expected_item.value->>'required')::boolean,
        false
      )
      except
      select result_item.value->>'assertion_code'
      from jsonb_array_elements(p_assertion_results)
        as result_item(value)
    )
    and not exists (
      select result_item.value->>'assertion_code'
      from jsonb_array_elements(p_assertion_results)
        as result_item(value)
      group by result_item.value->>'assertion_code'
      having count(*) > 1
    )
    and (
      (
        p_outcome = 'PASSED'
        and not exists (
          select 1
          from jsonb_array_elements(p_assertion_results)
            as result_item(value)
          where not (result_item.value->>'passed')::boolean
        )
      )
      or (
        p_outcome in ('FAILED', 'BLOCKED')
        and exists (
          select 1
          from jsonb_array_elements(p_assertion_results)
            as result_item(value)
          where not (result_item.value->>'passed')::boolean
        )
      )
    )
$$;

revoke all on function
public.atlas_test_assertion_results_match_contract_v1(
  jsonb, jsonb, text
)
from public, anon, authenticated;
grant execute on function
public.atlas_test_assertion_results_match_contract_v1(
  jsonb, jsonb, text
)
to service_role;

create or replace function public.atlas_start_installation_test_run(
  p_test_plan_id uuid,
  p_executor_code text,
  p_request_id uuid,
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
  v_plan public.atlas_installation_test_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_installation_test_runs%rowtype;
  v_created public.atlas_installation_test_runs%rowtype;
  v_readiness jsonb;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_event_evidence jsonb;
  v_total_cases integer;
  v_skipped_cases integer;
  v_run_number integer;
  v_now timestamptz := clock_timestamp();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_TEST_EXECUTE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  if p_test_plan_id is null
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_executor_code is null
     or p_executor_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_executor_code) not between 3 and 100
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'TEST_RUN_START_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_TEST_RUN_START_REQUEST_V1',
    'test_plan_id', p_test_plan_id,
    'expected_installation_version',
      p_expected_installation_version,
    'executor_code', p_executor_code,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select plan.*
  into v_plan
  from public.atlas_installation_test_plans as plan
  where plan.id = p_test_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_TEST_PLAN_NOT_FOUND';
  end if;

  select run.*
  into v_existing
  from public.atlas_installation_test_runs as run
  where run.test_plan_id = v_plan.id
    and run.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256
       or v_existing.metadata->'request_contract' <>
         v_request_payload then
      raise exception using
        errcode = '22023',
        message =
          'TEST_RUN_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'test_plan_id', v_existing.test_plan_id,
      'test_run_id', v_existing.id,
      'run_number', v_existing.run_number,
      'run_status', v_existing.run_status,
      'total_cases', v_existing.total_cases,
      'skipped_cases', v_existing.skipped_cases,
      'next_action', case
        when v_existing.run_status = 'RUNNING'
          then 'BEGIN_NEXT_TEST_CASE'
        else 'REVIEW_TEST_RUN'
      end
    );
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

  if v_installation.current_state_code <> 'TESTING' then
    raise exception using
      errcode = '22023', message = 'INSTALLATION_NOT_IN_TESTING';
  end if;

  if v_plan.plan_status <> 'READY' then
    raise exception using
      errcode = '55000', message = 'TEST_PLAN_NOT_READY';
  end if;

  if v_plan.expected_installation_version <>
     v_installation.version then
    raise exception using
      errcode = '40001',
      message = 'TEST_PLAN_INSTALLATION_VERSION_STALE';
  end if;

  if v_plan.plan_sha256 <>
     public.atlas_normalization_sha256(
       v_plan.plan_payload::text
     ) then
    raise exception using
      errcode = '55000', message = 'TEST_PLAN_HASH_INVALID';
  end if;

  v_readiness :=
    public.atlas_compute_installation_integration_readiness(
      v_installation.id
    );

  if not coalesce((v_readiness->>'ready')::boolean, false) then
    raise exception using
      errcode = '42501',
      message = 'TEST_RUN_INTEGRATION_READINESS_REQUIRED';
  end if;

  if v_plan.source_manifest_id <>
       (v_readiness->>'manifest_id')::uuid
     or v_plan.plan_payload->>'source_manifest_sha256' <>
       v_readiness->>'manifest_sha256'
     or v_plan.plan_payload->>
       'integration_readiness_evidence_root_sha256' <>
       v_readiness->>'evidence_root_sha256' then
    raise exception using
      errcode = '42501',
      message = 'TEST_RUN_PLAN_READINESS_BINDING_STALE';
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where test_case.case_status = 'SKIPPED'
    )::integer
  into v_total_cases, v_skipped_cases
  from public.atlas_installation_test_plan_cases as test_case
  where test_case.test_plan_id = v_plan.id;

  if v_total_cases < 1
     or v_total_cases <>
       v_plan.required_case_count + v_plan.conditional_case_count
     or exists (
       select 1
       from public.atlas_installation_test_plan_cases as test_case
       where test_case.test_plan_id = v_plan.id
         and test_case.case_status not in ('PENDING', 'SKIPPED')
     ) then
    raise exception using
      errcode = '55000',
      message = 'TEST_RUN_PLAN_CASE_SET_INVALID';
  end if;

  if exists (
    select 1
    from public.atlas_installation_test_runs as run
    where run.test_plan_id = v_plan.id
      and run.run_status = 'RUNNING'
  ) then
    raise exception using
      errcode = '55000', message = 'TEST_RUN_ALREADY_RUNNING';
  end if;

  select coalesce(max(run.run_number), 0) + 1
  into v_run_number
  from public.atlas_installation_test_runs as run
  where run.test_plan_id = v_plan.id;

  if v_run_number > 100 then
    raise exception using
      errcode = '54000', message = 'TEST_RUN_LIMIT_EXCEEDED';
  end if;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code = 'INSTALLATION_TEST_EXECUTE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501', message = 'TEST_RUN_ACTOR_ROLE_NOT_FOUND';
  end if;

  insert into public.atlas_installation_test_runs (
    test_plan_id,
    installation_id,
    empresa_id,
    run_number,
    run_status,
    expected_installation_version,
    executor_code,
    initiated_by_user_id,
    idempotency_key,
    request_sha256,
    total_cases,
    passed_cases,
    failed_cases,
    blocked_cases,
    skipped_cases,
    started_at,
    metadata,
    created_at,
    updated_at
  )
  values (
    v_plan.id,
    v_plan.installation_id,
    v_plan.empresa_id,
    v_run_number,
    'RUNNING',
    v_installation.version,
    p_executor_code,
    v_actor_user_id,
    p_request_id,
    v_request_sha256,
    v_total_cases,
    0,
    0,
    0,
    v_skipped_cases,
    v_now,
    jsonb_build_object(
      'request_contract', v_request_payload,
      'start_request_metadata', p_metadata,
      'plan_sha256', v_plan.plan_sha256
    ),
    v_now,
    v_now
  )
  returning * into v_created;

  update public.atlas_installation_test_plans
  set
    plan_status = 'RUNNING',
    started_at = v_now,
    updated_at = v_now
  where id = v_plan.id;

  v_event_evidence := jsonb_build_object(
    'contract_version', 'B2_TEST_RUN_START_V1',
    'test_run_id', v_created.id,
    'test_plan_id', v_created.test_plan_id,
    'run_number', v_created.run_number,
    'executor_code', v_created.executor_code,
    'total_cases', v_created.total_cases,
    'skipped_cases', v_created.skipped_cases,
    'plan_sha256', v_plan.plan_sha256,
    'request_sha256', v_created.request_sha256,
    'manifest_sha256', v_readiness->>'manifest_sha256',
    'integration_readiness_evidence_root_sha256',
      v_readiness->>'evidence_root_sha256'
  );

  insert into public.atlas_installation_test_events (
    installation_id, empresa_id, test_plan_id, test_run_id,
    test_case_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, request_id,
    evidence, evidence_sha256, metadata
  )
  values (
    v_created.installation_id, v_created.empresa_id,
    v_created.test_plan_id, v_created.id, null,
    'TEST_RUN_STARTED', 'CREATED', 'RUNNING',
    v_actor_user_id, v_actor_role_code, p_executor_code,
    p_request_id, v_event_evidence,
    public.atlas_normalization_sha256(v_event_evidence::text),
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status, input_summary,
    output_summary, error_message
  )
  values (
    v_created.empresa_id, v_actor_user_id, null, null,
    'INSTALLATION_TEST_RUN_STARTED', 'B2_TEST_EXECUTION_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'test_plan_id', v_created.test_plan_id,
      'request_id', p_request_id,
      'request_sha256', v_created.request_sha256
    ),
    jsonb_build_object(
      'test_run_id', v_created.id,
      'run_number', v_created.run_number,
      'run_status', v_created.run_status,
      'total_cases', v_created.total_cases
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_TEST_RUN_STARTED',
    'installation_id', v_created.installation_id,
    'test_plan_id', v_created.test_plan_id,
    'test_run_id', v_created.id,
    'run_number', v_created.run_number,
    'run_status', v_created.run_status,
    'total_cases', v_created.total_cases,
    'skipped_cases', v_created.skipped_cases,
    'test_results', 0,
    'next_action', 'BEGIN_NEXT_TEST_CASE'
  );
end;
$$;
create or replace function public.atlas_begin_installation_test_case(
  p_test_run_id uuid,
  p_test_code text,
  p_executor_code text,
  p_request_id uuid,
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
  v_run public.atlas_installation_test_runs%rowtype;
  v_plan public.atlas_installation_test_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_case public.atlas_installation_test_plan_cases%rowtype;
  v_existing_event public.atlas_installation_test_events%rowtype;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_event_evidence jsonb;
  v_next_attempt integer;
  v_now timestamptz := clock_timestamp();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_TEST_EXECUTE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  if p_test_run_id is null
     or p_test_code is null
     or p_test_code !~ '^[A-Z][A-Z0-9_]*$'
     or p_executor_code is null
     or p_executor_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_executor_code) not between 3 and 100
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'TEST_CASE_BEGIN_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_TEST_CASE_BEGIN_REQUEST_V1',
    'test_run_id', p_test_run_id,
    'test_code', p_test_code,
    'executor_code', p_executor_code,
    'expected_installation_version',
      p_expected_installation_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select run.*
  into v_run
  from public.atlas_installation_test_runs as run
  where run.id = p_test_run_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_TEST_RUN_NOT_FOUND';
  end if;

  select event.*
  into v_existing_event
  from public.atlas_installation_test_events as event
  where event.installation_id = v_run.installation_id
    and event.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <> 'TEST_CASE_STARTED'
       or v_existing_event.test_run_id <> v_run.id
       or v_existing_event.evidence->>'test_code' <> p_test_code
       or v_existing_event.evidence->>'request_sha256' <>
         v_request_sha256
       or v_existing_event.metadata->'request_contract' <>
         v_request_payload then
      raise exception using
        errcode = '22023',
        message =
          'TEST_CASE_BEGIN_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_run.installation_id,
      'test_plan_id', v_run.test_plan_id,
      'test_run_id', v_run.id,
      'test_case_id', v_existing_event.test_case_id,
      'test_code', p_test_code,
      'attempt_number',
        (v_existing_event.evidence->>'attempt_number')::integer,
      'case_status', v_existing_event.to_status,
      'next_action', 'REGISTER_TEST_CASE_RESULT'
    );
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_test_plans as plan
  where plan.id = v_run.test_plan_id
  for update;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_run.installation_id
  for update;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'TESTING' then
    raise exception using
      errcode = '22023', message = 'INSTALLATION_NOT_IN_TESTING';
  end if;

  if v_plan.plan_status <> 'RUNNING'
     or v_run.run_status <> 'RUNNING' then
    raise exception using
      errcode = '55000', message = 'TEST_RUN_NOT_RUNNING';
  end if;

  if v_run.expected_installation_version <>
       v_installation.version
     or v_plan.expected_installation_version <>
       v_installation.version then
    raise exception using
      errcode = '40001', message = 'TEST_EXECUTION_VERSION_STALE';
  end if;

  select test_case.*
  into v_case
  from public.atlas_installation_test_plan_cases as test_case
  where test_case.test_plan_id = v_plan.id
    and test_case.test_code = p_test_code
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_TEST_CASE_NOT_FOUND';
  end if;

  if v_case.applicability_status <> 'APPLICABLE'
     or v_case.case_status not in ('PENDING', 'RETRYING') then
    raise exception using
      errcode = '55000', message = 'TEST_CASE_NOT_EXECUTABLE';
  end if;

  if v_case.executor_code <> p_executor_code then
    raise exception using
      errcode = '42501', message = 'TEST_CASE_EXECUTOR_MISMATCH';
  end if;

  if exists (
    select 1
    from unnest(v_case.dependency_test_codes)
      as dependency(test_code)
    left join public.atlas_installation_test_plan_cases
      as dependency_case
      on dependency_case.test_plan_id = v_plan.id
     and dependency_case.test_code = dependency.test_code
    where dependency_case.id is null
       or dependency_case.case_status not in ('PASSED', 'SKIPPED')
  ) then
    raise exception using
      errcode = '55000', message = 'TEST_CASE_DEPENDENCIES_NOT_SATISFIED';
  end if;

  v_next_attempt := v_case.attempt_count + 1;
  if v_next_attempt > v_case.max_attempts then
    raise exception using
      errcode = '54000', message = 'TEST_CASE_ATTEMPT_LIMIT_EXCEEDED';
  end if;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code = 'INSTALLATION_TEST_EXECUTE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501', message = 'TEST_CASE_ACTOR_ROLE_NOT_FOUND';
  end if;

  update public.atlas_installation_test_plan_cases
  set
    case_status = 'RUNNING',
    attempt_count = v_next_attempt,
    started_at = coalesce(started_at, v_now),
    completed_at = null,
    active_test_run_id = v_run.id,
    active_attempt_started_at = v_now,
    active_attempt_request_id = p_request_id,
    active_attempt_request_sha256 = v_request_sha256,
    updated_at = v_now
  where id = v_case.id;

  v_event_evidence := jsonb_build_object(
    'contract_version', 'B2_TEST_CASE_BEGIN_V1',
    'test_run_id', v_run.id,
    'test_case_id', v_case.id,
    'test_code', v_case.test_code,
    'attempt_number', v_next_attempt,
    'executor_code', p_executor_code,
    'input_contract_sha256', v_case.input_contract_sha256,
    'request_sha256', v_request_sha256,
    'dependency_test_codes', to_jsonb(v_case.dependency_test_codes)
  );

  insert into public.atlas_installation_test_events (
    installation_id, empresa_id, test_plan_id, test_run_id,
    test_case_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, request_id,
    evidence, evidence_sha256, metadata
  )
  values (
    v_run.installation_id, v_run.empresa_id, v_run.test_plan_id,
    v_run.id, v_case.id, 'TEST_CASE_STARTED',
    v_case.case_status, 'RUNNING', v_actor_user_id,
    v_actor_role_code, p_executor_code, p_request_id,
    v_event_evidence,
    public.atlas_normalization_sha256(v_event_evidence::text),
    jsonb_build_object(
      'request_contract', v_request_payload,
      'request_metadata', p_metadata
    )
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status, input_summary,
    output_summary, error_message
  )
  values (
    v_run.empresa_id, v_actor_user_id, null, null,
    'INSTALLATION_TEST_CASE_STARTED', 'B2_TEST_EXECUTION_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'test_run_id', v_run.id,
      'test_code', v_case.test_code,
      'request_id', p_request_id,
      'request_sha256', v_request_sha256
    ),
    jsonb_build_object(
      'test_case_id', v_case.id,
      'attempt_number', v_next_attempt,
      'case_status', 'RUNNING'
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_TEST_CASE_STARTED',
    'installation_id', v_run.installation_id,
    'test_plan_id', v_run.test_plan_id,
    'test_run_id', v_run.id,
    'test_case_id', v_case.id,
    'test_code', v_case.test_code,
    'attempt_number', v_next_attempt,
    'case_status', 'RUNNING',
    'max_attempts', v_case.max_attempts,
    'next_action', 'REGISTER_TEST_CASE_RESULT'
  );
end;
$$;

create or replace function
public.atlas_register_installation_test_case_result(
  p_test_run_id uuid,
  p_test_code text,
  p_outcome text,
  p_assertion_results jsonb,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_error_code text,
  p_redacted_error_summary text,
  p_executor_code text,
  p_request_id uuid,
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
  v_run public.atlas_installation_test_runs%rowtype;
  v_plan public.atlas_installation_test_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_case public.atlas_installation_test_plan_cases%rowtype;
  v_existing public.atlas_installation_test_results%rowtype;
  v_created public.atlas_installation_test_results%rowtype;
  v_blocked_case public.atlas_installation_test_plan_cases%rowtype;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_assertion_sha256 text;
  v_evidence_sha256 text := lower(nullif(btrim(p_evidence_sha256), ''));
  v_event_evidence jsonb;
  v_block_event_evidence jsonb;
  v_run_event_evidence jsonb;
  v_case_resulting_status text;
  v_run_resulting_status text := 'RUNNING';
  v_passed integer;
  v_failed integer;
  v_blocked integer;
  v_skipped integer;
  v_terminal integer;
  v_blocked_this_round integer;
  v_evidence_root_sha256 text;
  v_now timestamptz := clock_timestamp();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_TEST_EXECUTE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  if p_test_run_id is null
     or p_test_code is null
     or p_test_code !~ '^[A-Z][A-Z0-9_]*$'
     or p_outcome not in ('PASSED', 'FAILED', 'BLOCKED')
     or p_assertion_results is null
     or jsonb_typeof(p_assertion_results) <> 'array'
     or jsonb_array_length(p_assertion_results) < 1
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_assertion_results
     )
     or p_evidence_reference is null
     or not public.atlas_test_evidence_reference_is_safe(
       p_evidence_reference
     )
     or v_evidence_sha256 is null
     or v_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_executor_code is null
     or p_executor_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_executor_code) not between 3 and 100
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata)
     or (
       p_outcome = 'PASSED'
       and (
         p_error_code is not null
         or p_redacted_error_summary is not null
       )
     )
     or (
       p_outcome in ('FAILED', 'BLOCKED')
       and (
         p_error_code is null
         or p_error_code !~ '^[A-Z][A-Z0-9_]*$'
         or p_redacted_error_summary is null
         or length(btrim(p_redacted_error_summary))
           not between 5 and 500
         or p_redacted_error_summary ~ '[[:cntrl:]]'
       )
     ) then
    raise exception using
      errcode = '22023',
      message = 'TEST_RESULT_REGISTRATION_REQUIRED_FIELDS_INVALID';
  end if;

  v_assertion_sha256 := public.atlas_normalization_sha256(
    p_assertion_results::text
  );
  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_TEST_RESULT_REGISTRATION_REQUEST_V1',
    'test_run_id', p_test_run_id,
    'test_code', p_test_code,
    'outcome', p_outcome,
    'assertion_results_sha256', v_assertion_sha256,
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', v_evidence_sha256,
    'error_code', p_error_code,
    'redacted_error_summary', p_redacted_error_summary,
    'executor_code', p_executor_code,
    'expected_installation_version',
      p_expected_installation_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select run.*
  into v_run
  from public.atlas_installation_test_runs as run
  where run.id = p_test_run_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_TEST_RUN_NOT_FOUND';
  end if;

  select result.*
  into v_existing
  from public.atlas_installation_test_results as result
  where result.test_plan_id = v_run.test_plan_id
    and result.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256
       or v_existing.metadata->'request_contract' <>
         v_request_payload then
      raise exception using
        errcode = '22023',
        message =
          'TEST_RESULT_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'test_plan_id', v_existing.test_plan_id,
      'test_run_id', v_existing.test_run_id,
      'test_case_id', v_existing.test_case_id,
      'test_result_id', v_existing.id,
      'test_code', v_existing.test_code,
      'attempt_number', v_existing.attempt_number,
      'outcome', v_existing.outcome,
      'case_status', (
        select test_case.case_status
        from public.atlas_installation_test_plan_cases as test_case
        where test_case.id = v_existing.test_case_id
      ),
      'run_status', (
        select run.run_status
        from public.atlas_installation_test_runs as run
        where run.id = v_existing.test_run_id
      )
    );
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_test_plans as plan
  where plan.id = v_run.test_plan_id
  for update;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_run.installation_id
  for update;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'TESTING' then
    raise exception using
      errcode = '22023', message = 'INSTALLATION_NOT_IN_TESTING';
  end if;

  if v_plan.plan_status <> 'RUNNING'
     or v_run.run_status <> 'RUNNING' then
    raise exception using
      errcode = '55000', message = 'TEST_RUN_NOT_RUNNING';
  end if;

  if v_run.expected_installation_version <>
       v_installation.version
     or v_plan.expected_installation_version <>
       v_installation.version then
    raise exception using
      errcode = '40001', message = 'TEST_EXECUTION_VERSION_STALE';
  end if;

  select test_case.*
  into v_case
  from public.atlas_installation_test_plan_cases as test_case
  where test_case.test_plan_id = v_plan.id
    and test_case.test_code = p_test_code
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_TEST_CASE_NOT_FOUND';
  end if;

  if v_case.case_status <> 'RUNNING'
     or v_case.active_test_run_id <> v_run.id
     or v_case.active_attempt_started_at is null
     or v_case.active_attempt_request_id is null
     or v_case.active_attempt_request_sha256 is null then
    raise exception using
      errcode = '55000', message = 'TEST_CASE_ATTEMPT_NOT_RUNNING';
  end if;

  if v_case.executor_code <> p_executor_code then
    raise exception using
      errcode = '42501', message = 'TEST_CASE_EXECUTOR_MISMATCH';
  end if;

  if not public.atlas_test_assertion_results_match_contract_v1(
    v_case.expected_assertions,
    p_assertion_results,
    p_outcome
  ) then
    raise exception using
      errcode = '22023',
      message = 'TEST_ASSERTION_RESULTS_CONTRACT_INVALID';
  end if;

  insert into public.atlas_installation_test_results (
    test_run_id, test_case_id, test_plan_id, installation_id,
    empresa_id, test_code, attempt_number, outcome,
    executor_code, actor_user_id, request_id, request_sha256,
    assertion_results, assertion_results_sha256,
    evidence_reference, evidence_sha256, error_code,
    redacted_error_summary, started_at, completed_at,
    metadata, created_at
  )
  values (
    v_run.id, v_case.id, v_plan.id, v_installation.id,
    v_installation.empresa_id, v_case.test_code,
    v_case.attempt_count, p_outcome, p_executor_code,
    v_actor_user_id, p_request_id, v_request_sha256,
    p_assertion_results, v_assertion_sha256,
    p_evidence_reference, v_evidence_sha256,
    p_error_code, p_redacted_error_summary,
    v_case.active_attempt_started_at, v_now,
    jsonb_build_object(
      'request_contract', v_request_payload,
      'request_metadata', p_metadata,
      'begin_request_id', v_case.active_attempt_request_id,
      'begin_request_sha256',
        v_case.active_attempt_request_sha256,
      'input_contract_sha256', v_case.input_contract_sha256
    ),
    v_now
  )
  returning * into v_created;

  v_case_resulting_status := case
    when p_outcome = 'PASSED' then 'PASSED'
    when p_outcome = 'BLOCKED' then 'BLOCKED'
    when v_case.attempt_count < v_case.max_attempts then 'RETRYING'
    else 'FAILED'
  end;

  update public.atlas_installation_test_plan_cases
  set
    case_status = v_case_resulting_status,
    completed_at = case
      when v_case_resulting_status in ('PASSED', 'FAILED', 'BLOCKED')
        then v_now
      else null
    end,
    active_test_run_id = null,
    active_attempt_started_at = null,
    active_attempt_request_id = null,
    active_attempt_request_sha256 = null,
    updated_at = v_now
  where id = v_case.id;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code = 'INSTALLATION_TEST_EXECUTE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501', message = 'TEST_RESULT_ACTOR_ROLE_NOT_FOUND';
  end if;

  v_event_evidence := jsonb_build_object(
    'contract_version', 'B2_TEST_RESULT_REGISTRATION_V1',
    'test_result_id', v_created.id,
    'test_run_id', v_created.test_run_id,
    'test_case_id', v_created.test_case_id,
    'test_code', v_created.test_code,
    'attempt_number', v_created.attempt_number,
    'outcome', v_created.outcome,
    'case_resulting_status', v_case_resulting_status,
    'assertion_results_sha256',
      v_created.assertion_results_sha256,
    'evidence_reference', v_created.evidence_reference,
    'evidence_sha256', v_created.evidence_sha256,
    'request_sha256', v_created.request_sha256,
    'error_code', v_created.error_code
  );

  insert into public.atlas_installation_test_events (
    installation_id, empresa_id, test_plan_id, test_run_id,
    test_case_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, request_id,
    evidence, evidence_sha256, metadata
  )
  values (
    v_created.installation_id, v_created.empresa_id,
    v_created.test_plan_id, v_created.test_run_id,
    v_created.test_case_id, 'TEST_CASE_RESULT_REGISTERED',
    'RUNNING', v_case_resulting_status, v_actor_user_id,
    v_actor_role_code, p_executor_code, p_request_id,
    v_event_evidence,
    public.atlas_normalization_sha256(v_event_evidence::text),
    jsonb_build_object('request_metadata', p_metadata)
  );

  if v_case_resulting_status in ('FAILED', 'BLOCKED') then
    loop
      v_blocked_this_round := 0;

      for v_blocked_case in
        select dependent.*
        from public.atlas_installation_test_plan_cases as dependent
        where dependent.test_plan_id = v_plan.id
          and dependent.case_status in ('PENDING', 'RETRYING')
          and exists (
            select 1
            from unnest(dependent.dependency_test_codes)
              as dependency(test_code)
            join public.atlas_installation_test_plan_cases
              as dependency_case
              on dependency_case.test_plan_id = v_plan.id
             and dependency_case.test_code = dependency.test_code
            where dependency_case.case_status in ('FAILED', 'BLOCKED')
          )
        order by dependent.case_order
        for update
      loop
        update public.atlas_installation_test_plan_cases
        set
          case_status = 'BLOCKED',
          started_at = coalesce(started_at, v_now),
          completed_at = v_now,
          active_test_run_id = null,
          active_attempt_started_at = null,
          active_attempt_request_id = null,
          active_attempt_request_sha256 = null,
          updated_at = v_now
        where id = v_blocked_case.id;

        v_block_event_evidence := jsonb_build_object(
          'contract_version', 'B2_TEST_DEPENDENCY_BLOCK_V1',
          'test_run_id', v_run.id,
          'test_case_id', v_blocked_case.id,
          'test_code', v_blocked_case.test_code,
          'dependency_test_codes',
            to_jsonb(v_blocked_case.dependency_test_codes),
          'triggering_test_code', v_case.test_code,
          'triggering_result_id', v_created.id
        );

        insert into public.atlas_installation_test_events (
          installation_id, empresa_id, test_plan_id, test_run_id,
          test_case_id, event_code, from_status, to_status,
          actor_user_id, actor_role_code, executor_code, request_id,
          evidence, evidence_sha256, metadata
        )
        values (
          v_run.installation_id, v_run.empresa_id, v_run.test_plan_id,
          v_run.id, v_blocked_case.id, 'TEST_CASE_DEPENDENCY_BLOCKED',
          v_blocked_case.case_status, 'BLOCKED', v_actor_user_id,
          v_actor_role_code, 'B2_TEST_EXECUTION_ENGINE',
          gen_random_uuid(), v_block_event_evidence,
          public.atlas_normalization_sha256(
            v_block_event_evidence::text
          ),
          jsonb_build_object(
            'source_result_request_id', p_request_id
          )
        );

        v_blocked_this_round := v_blocked_this_round + 1;
      end loop;

      exit when v_blocked_this_round = 0;
    end loop;
  end if;

  select
    count(*) filter (
      where test_case.case_status = 'PASSED'
    )::integer,
    count(*) filter (
      where test_case.case_status = 'FAILED'
    )::integer,
    count(*) filter (
      where test_case.case_status = 'BLOCKED'
    )::integer,
    count(*) filter (
      where test_case.case_status = 'SKIPPED'
    )::integer
  into v_passed, v_failed, v_blocked, v_skipped
  from public.atlas_installation_test_plan_cases as test_case
  where test_case.test_plan_id = v_plan.id;

  v_terminal := v_passed + v_failed + v_blocked + v_skipped;

  if v_terminal = v_run.total_cases then
    v_run_resulting_status := case
      when v_failed = 0 and v_blocked = 0 then 'PASSED'
      else 'FAILED'
    end;

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
          from public.atlas_installation_test_plan_cases as test_case
          where test_case.test_plan_id = v_plan.id
        ), '[]'::jsonb)
      )::text
    )
    into v_evidence_root_sha256;

    update public.atlas_installation_test_runs
    set
      run_status = v_run_resulting_status,
      passed_cases = v_passed,
      failed_cases = v_failed,
      blocked_cases = v_blocked,
      skipped_cases = v_skipped,
      evidence_root_sha256 = v_evidence_root_sha256,
      completed_at = v_now,
      updated_at = v_now
    where id = v_run.id;

    update public.atlas_installation_test_plans
    set
      plan_status = v_run_resulting_status,
      completed_at = v_now,
      updated_at = v_now
    where id = v_plan.id;

    v_run_event_evidence := jsonb_build_object(
      'contract_version', 'B2_TEST_RUN_COMPLETION_V1',
      'test_run_id', v_run.id,
      'test_plan_id', v_plan.id,
      'run_status', v_run_resulting_status,
      'total_cases', v_run.total_cases,
      'passed_cases', v_passed,
      'failed_cases', v_failed,
      'blocked_cases', v_blocked,
      'skipped_cases', v_skipped,
      'evidence_root_sha256', v_evidence_root_sha256
    );

    insert into public.atlas_installation_test_events (
      installation_id, empresa_id, test_plan_id, test_run_id,
      test_case_id, event_code, from_status, to_status,
      actor_user_id, actor_role_code, executor_code, request_id,
      evidence, evidence_sha256, metadata
    )
    values (
      v_run.installation_id, v_run.empresa_id, v_run.test_plan_id,
      v_run.id, null, 'TEST_RUN_COMPLETED', 'RUNNING',
      v_run_resulting_status, v_actor_user_id, v_actor_role_code,
      p_executor_code, gen_random_uuid(), v_run_event_evidence,
      public.atlas_normalization_sha256(v_run_event_evidence::text),
      jsonb_build_object(
        'source_result_request_id', p_request_id
      )
    );
  else
    update public.atlas_installation_test_runs
    set
      passed_cases = v_passed,
      failed_cases = v_failed,
      blocked_cases = v_blocked,
      skipped_cases = v_skipped,
      updated_at = v_now
    where id = v_run.id;
  end if;

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status, input_summary,
    output_summary, error_message
  )
  values (
    v_run.empresa_id, v_actor_user_id, null, null,
    'INSTALLATION_TEST_RESULT_REGISTERED',
    'B2_TEST_EXECUTION_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'test_run_id', v_run.id,
      'test_code', v_case.test_code,
      'attempt_number', v_case.attempt_count,
      'request_id', p_request_id,
      'request_sha256', v_request_sha256
    ),
    jsonb_build_object(
      'test_result_id', v_created.id,
      'outcome', p_outcome,
      'case_status', v_case_resulting_status,
      'run_status', v_run_resulting_status,
      'evidence_sha256', v_created.evidence_sha256
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_TEST_RESULT_REGISTERED',
    'installation_id', v_run.installation_id,
    'test_plan_id', v_run.test_plan_id,
    'test_run_id', v_run.id,
    'test_case_id', v_case.id,
    'test_result_id', v_created.id,
    'test_code', v_case.test_code,
    'attempt_number', v_case.attempt_count,
    'outcome', p_outcome,
    'case_status', v_case_resulting_status,
    'run_status', v_run_resulting_status,
    'passed_cases', v_passed,
    'failed_cases', v_failed,
    'blocked_cases', v_blocked,
    'skipped_cases', v_skipped,
    'total_cases', v_run.total_cases,
    'evidence_root_sha256', v_evidence_root_sha256,
    'next_action', case
      when v_case_resulting_status = 'RETRYING'
        then 'RETRY_TEST_CASE'
      when v_run_resulting_status = 'RUNNING'
        then 'BEGIN_NEXT_TEST_CASE'
      else 'REVIEW_TEST_RUN_FOR_G03'
    end
  );
end;
$$;

revoke all on function public.atlas_start_installation_test_run(
  uuid, text, uuid, bigint, jsonb
)
from public, anon, authenticated;
revoke all on function public.atlas_begin_installation_test_case(
  uuid, text, text, uuid, bigint, jsonb
)
from public, anon, authenticated;
revoke all on function
public.atlas_register_installation_test_case_result(
  uuid, text, text, jsonb, text, text, text, text,
  text, uuid, bigint, jsonb
)
from public, anon, authenticated;

grant execute on function public.atlas_start_installation_test_run(
  uuid, text, uuid, bigint, jsonb
)
to authenticated, service_role;
grant execute on function public.atlas_begin_installation_test_case(
  uuid, text, text, uuid, bigint, jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_register_installation_test_case_result(
  uuid, text, text, jsonb, text, text, text, text,
  text, uuid, bigint, jsonb
)
to authenticated, service_role;

comment on function public.atlas_start_installation_test_run(
  uuid, text, uuid, bigint, jsonb
) is
  'B2.2I.2B: inicia un run sobre plan READY y readiness vigente.';

comment on function public.atlas_begin_installation_test_case(
  uuid, text, text, uuid, bigint, jsonb
) is
  'B2.2I.2B: abre un intento tras validar dependencias, actor y concurrencia.';

comment on function
public.atlas_register_installation_test_case_result(
  uuid, text, text, jsonb, text, text, text, text,
  text, uuid, bigint, jsonb
) is
  'B2.2I.2B: registra resultado append-only, reintentos, bloqueos y cierre del run.';

do $$
declare
  v_installation public.atlas_installations%rowtype;
begin
  select installation.*
  into v_installation
  from public.atlas_installations as installation
  order by installation.created_at asc, installation.id asc
  limit 1;

  raise notice '%', jsonb_build_object(
    'ok', true,
    'code', 'B2_2I2B_TEST_RUN_RESULT_REGISTRATION_RPCS_INSTALLED',
    'next_action', 'CERTIFY_I2B_RUN_RESULT_RPC_GUARDS',
    'execution_rpcs', 3,
    'test_plan_records', (
      select count(*) from public.atlas_installation_test_plans
    ),
    'test_run_records', (
      select count(*) from public.atlas_installation_test_runs
    ),
    'test_result_records', (
      select count(*) from public.atlas_installation_test_results
    ),
    'two_phase_case_execution_enabled', true,
    'dependency_enforcement_enabled', true,
    'attempt_identity_enabled', true,
    'attempt_limits_enabled', true,
    'request_idempotency_enabled', true,
    'optimistic_concurrency_enabled', true,
    'assertion_contract_enforced', true,
    'append_only_results_enabled', true,
    'redacted_error_contract_enabled', true,
    'automatic_retry_state_enabled', true,
    'dependency_block_propagation_enabled', true,
    'run_auto_finalization_enabled', true,
    'g03_decision_enabled', false,
    'active_auto_transition_enabled', false,
    'current_installation_state',
      v_installation.current_state_code,
    'current_installation_version', v_installation.version,
    'direct_authenticated_write', false
  );
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2I2B_TEST_RUN_RESULT_REGISTRATION_RPCS_INSTALLED',
  'next_action', 'CERTIFY_I2B_RUN_RESULT_RPC_GUARDS',
  'execution_rpcs', (
    select count(*)
    from pg_proc as function
    join pg_namespace as namespace
      on namespace.oid = function.pronamespace
    where namespace.nspname = 'public'
      and function.proname in (
        'atlas_start_installation_test_run',
        'atlas_begin_installation_test_case',
        'atlas_register_installation_test_case_result'
      )
      and function.prosecdef
  ),
  'test_plan_records', (
    select count(*) from public.atlas_installation_test_plans
  ),
  'test_run_records', (
    select count(*) from public.atlas_installation_test_runs
  ),
  'test_result_records', (
    select count(*) from public.atlas_installation_test_results
  ),
  'two_phase_case_execution_enabled', true,
  'dependency_enforcement_enabled', true,
  'attempt_identity_enabled', true,
  'attempt_limits_enabled', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'assertion_contract_enforced', true,
  'append_only_results_enabled', true,
  'redacted_error_contract_enabled', true,
  'automatic_retry_state_enabled', true,
  'dependency_block_propagation_enabled', true,
  'run_auto_finalization_enabled', true,
  'g03_decision_enabled', false,
  'active_auto_transition_enabled', false,
  'current_installation_state', (
    select installation.current_state_code
    from public.atlas_installations as installation
    order by installation.created_at asc, installation.id asc
    limit 1
  ),
  'current_installation_version', (
    select installation.version
    from public.atlas_installations as installation
    order by installation.created_at asc, installation.id asc
    limit 1
  ),
  'direct_authenticated_write', exists (
    select 1
    from information_schema.role_table_grants as table_grant
    where table_grant.table_schema = 'public'
      and table_grant.table_name in (
        'atlas_installation_test_plans',
        'atlas_installation_test_plan_cases',
        'atlas_installation_test_runs',
        'atlas_installation_test_results',
        'atlas_installation_test_events'
      )
      and table_grant.grantee = 'authenticated'
      and table_grant.privilege_type in (
        'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'
      )
  )
) as result;

