-- ATLAS B2.2I.2A
-- Materializacion gobernada e idempotente del plan de pruebas.
-- Corte: 2026-09-02
--
-- Alcance deliberado:
-- - materializa las 18 definiciones activas como casos inmutables de alcance;
-- - resuelve VOICE_AUDIO_CALLS desde el inventario diagnostico canonico;
-- - enlaza manifest, readiness de integraciones y entradas mediante SHA-256;
-- - genera un plan READY con dependencias topologicas y evento auditable;
-- - no inicia runs, no registra resultados, no decide G03 y no mueve estados.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_test_definitions') is null
     or to_regclass('public.atlas_installation_test_plans') is null
     or to_regclass('public.atlas_installation_test_plan_cases') is null
     or to_regclass('public.atlas_installation_test_events') is null
     or to_regclass(
       'public.atlas_installation_inventory_requirements'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_integration_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception
      'B2.2I.2A requiere B2.2I.1, B2.2H.4 y D3 instalados y certificados';
  end if;

  if (
    select count(*)
    from public.atlas_installation_test_definitions
    where active
  ) <> 18 then
    raise exception
      'B2.2I.2A requiere exactamente 18 definiciones activas';
  end if;

  if not exists (
    select 1
    from public.atlas_installation_test_definitions
    where test_code = 'VOICE_AUDIO_CALLS'
      and requirement_mode = 'CONDITIONAL'
      and applicability_rule->>'condition' =
        'VOICE_OR_CALLS_ENABLED'
      and active
  ) then
    raise exception
      'B2.2I.2A requiere contrato condicional de voz canonico';
  end if;
end;
$$;

alter table public.atlas_installation_test_plans
  add column if not exists request_sha256 text;

update public.atlas_installation_test_plans as plan
set request_sha256 = public.atlas_normalization_sha256(
  jsonb_build_object(
    'contract_version', 'B2_TEST_PLAN_MATERIALIZATION_REQUEST_V1',
    'installation_id', plan.installation_id,
    'expected_installation_version',
      plan.expected_installation_version,
    'request_metadata', plan.metadata
  )::text
)
where plan.request_sha256 is null;

alter table public.atlas_installation_test_plans
  alter column request_sha256 set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid =
      'public.atlas_installation_test_plans'::regclass
      and conname = 'atlas_test_plans_request_sha256_check'
  ) then
    alter table public.atlas_installation_test_plans
      add constraint atlas_test_plans_request_sha256_check
      check (request_sha256 ~ '^[0-9a-f]{64}$');
  end if;
end;
$$;

create or replace function public.atlas_test_case_order_v1(
  p_test_code text
)
returns integer
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select case p_test_code
    when 'TENANT_IDENTITY_MEMBERSHIP' then 10
    when 'RLS_CROSS_TENANT_ISOLATION' then 20
    when 'OWNER_ROLES_PERMISSIONS' then 30
    when 'SECURE_FILE_ACCESS' then 40
    when 'KNOWLEDGE_SEARCH_ACCURACY' then 50
    when 'COMMERCIAL_RULES_ENFORCEMENT' then 60
    when 'INTERNAL_CHAT_AUTHORIZATION' then 70
    when 'INTEGRATION_HEALTH' then 80
    when 'EXTERNAL_CONVERSATION_E2E' then 90
    when 'HUMAN_CONTROL_HANDOFF' then 100
    when 'TOOL_ACTION_EXECUTION' then 110
    when 'AUDIT_TRACEABILITY' then 120
    when 'IDEMPOTENCY_REPLAY' then 130
    when 'ERROR_HANDLING' then 140
    when 'RETRY_RECOVERY' then 150
    when 'DOCUMENT_TEMPLATE_OUTPUT' then 160
    when 'VOICE_AUDIO_CALLS' then 170
    when 'PERFORMANCE_LIMITS' then 180
    else null
  end
$$;

create or replace function public.atlas_test_dependency_codes_v1(
  p_test_code text
)
returns text[]
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select case p_test_code
    when 'TENANT_IDENTITY_MEMBERSHIP'
      then array[]::text[]
    when 'RLS_CROSS_TENANT_ISOLATION'
      then array['TENANT_IDENTITY_MEMBERSHIP']::text[]
    when 'OWNER_ROLES_PERMISSIONS'
      then array['TENANT_IDENTITY_MEMBERSHIP']::text[]
    when 'SECURE_FILE_ACCESS'
      then array['RLS_CROSS_TENANT_ISOLATION']::text[]
    when 'KNOWLEDGE_SEARCH_ACCURACY'
      then array['RLS_CROSS_TENANT_ISOLATION']::text[]
    when 'COMMERCIAL_RULES_ENFORCEMENT'
      then array['KNOWLEDGE_SEARCH_ACCURACY']::text[]
    when 'INTERNAL_CHAT_AUTHORIZATION'
      then array[
        'RLS_CROSS_TENANT_ISOLATION',
        'OWNER_ROLES_PERMISSIONS'
      ]::text[]
    when 'INTEGRATION_HEALTH'
      then array['RLS_CROSS_TENANT_ISOLATION']::text[]
    when 'EXTERNAL_CONVERSATION_E2E'
      then array[
        'COMMERCIAL_RULES_ENFORCEMENT',
        'INTEGRATION_HEALTH'
      ]::text[]
    when 'HUMAN_CONTROL_HANDOFF'
      then array['EXTERNAL_CONVERSATION_E2E']::text[]
    when 'TOOL_ACTION_EXECUTION'
      then array[
        'COMMERCIAL_RULES_ENFORCEMENT',
        'INTERNAL_CHAT_AUTHORIZATION'
      ]::text[]
    when 'AUDIT_TRACEABILITY'
      then array['TOOL_ACTION_EXECUTION']::text[]
    when 'IDEMPOTENCY_REPLAY'
      then array['AUDIT_TRACEABILITY']::text[]
    when 'ERROR_HANDLING'
      then array['AUDIT_TRACEABILITY']::text[]
    when 'RETRY_RECOVERY'
      then array[
        'IDEMPOTENCY_REPLAY',
        'ERROR_HANDLING'
      ]::text[]
    when 'DOCUMENT_TEMPLATE_OUTPUT'
      then array['TOOL_ACTION_EXECUTION']::text[]
    when 'VOICE_AUDIO_CALLS'
      then array[
        'INTEGRATION_HEALTH',
        'EXTERNAL_CONVERSATION_E2E'
      ]::text[]
    when 'PERFORMANCE_LIMITS'
      then array[
        'EXTERNAL_CONVERSATION_E2E',
        'TOOL_ACTION_EXECUTION'
      ]::text[]
    else null
  end
$$;

create or replace function public.atlas_test_assertion_contract_v1(
  p_test_code text,
  p_description text,
  p_required_evidence_kinds text[],
  p_g03_criterion_codes text[]
)
returns jsonb
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_array(
    jsonb_build_object(
      'assertion_code', p_test_code || '_VERIFIED',
      'description', p_description,
      'required', true,
      'required_evidence_kinds',
        to_jsonb(p_required_evidence_kinds),
      'g03_criterion_codes', to_jsonb(p_g03_criterion_codes)
    )
  )
$$;

revoke all on function public.atlas_test_case_order_v1(text)
from public, anon, authenticated;
revoke all on function public.atlas_test_dependency_codes_v1(text)
from public, anon, authenticated;
revoke all on function public.atlas_test_assertion_contract_v1(
  text, text, text[], text[]
)
from public, anon, authenticated;

grant execute on function public.atlas_test_case_order_v1(text)
to service_role;
grant execute on function public.atlas_test_dependency_codes_v1(text)
to service_role;
grant execute on function public.atlas_test_assertion_contract_v1(
  text, text, text[], text[]
)
to service_role;

create or replace function
public.atlas_materialize_installation_test_plan(
  p_installation_id uuid,
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
  v_installation public.atlas_installations%rowtype;
  v_manifest public.atlas_installation_manifests%rowtype;
  v_existing public.atlas_installation_test_plans%rowtype;
  v_created public.atlas_installation_test_plans%rowtype;
  v_voice_requirement
    public.atlas_installation_inventory_requirements%rowtype;
  v_readiness jsonb;
  v_cases_payload jsonb;
  v_plan_payload jsonb;
  v_event_evidence jsonb;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_plan_sha256 text;
  v_plan_version integer;
  v_required_count integer;
  v_conditional_count integer;
  v_applicable_count integer;
  v_skipped_count integer;
  v_voice_applicable boolean;
  v_now timestamptz := clock_timestamp();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_TEST_PLAN'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_TEST_PLAN_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'TEST_PLAN_MATERIALIZATION_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_TEST_PLAN_MATERIALIZATION_REQUEST_V1',
    'installation_id', p_installation_id,
    'expected_installation_version',
      p_expected_installation_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  select plan.*
  into v_existing
  from public.atlas_installation_test_plans as plan
  where plan.installation_id = v_installation.id
    and plan.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256
       or v_existing.metadata->'request_contract' <>
         v_request_payload then
      raise exception using
        errcode = '22023',
        message =
          'TEST_PLAN_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'test_plan_id', v_existing.id,
      'plan_code', v_existing.plan_code,
      'plan_version', v_existing.plan_version,
      'plan_status', v_existing.plan_status,
      'required_cases', v_existing.required_case_count,
      'conditional_cases', v_existing.conditional_case_count,
      'plan_sha256', v_existing.plan_sha256,
      'next_action', 'START_TEST_RUN'
    );
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'TESTING' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_TESTING';
  end if;

  if exists (
    select 1
    from public.atlas_installation_test_plans as plan
    where plan.installation_id = v_installation.id
      and plan.plan_status in ('DRAFT', 'READY', 'RUNNING')
  ) then
    raise exception using
      errcode = '55000',
      message = 'ACTIVE_INSTALLATION_TEST_PLAN_ALREADY_EXISTS';
  end if;

  v_readiness :=
    public.atlas_compute_installation_integration_readiness(
      v_installation.id
    );

  if not coalesce((v_readiness->>'ready')::boolean, false) then
    raise exception using
      errcode = '42501',
      message = 'TEST_PLAN_INTEGRATION_READINESS_REQUIRED',
      detail = jsonb_build_object(
        'readiness_code', v_readiness->>'code',
        'blockers', coalesce(
          v_readiness->'blockers',
          '[]'::jsonb
        )
      )::text;
  end if;

  select manifest.*
  into v_manifest
  from public.atlas_installation_manifests as manifest
  where manifest.id = (v_readiness->>'manifest_id')::uuid
    and manifest.installation_id = v_installation.id
    and manifest.empresa_id = v_installation.empresa_id
    and manifest.manifest_status in ('VALIDATED', 'APPROVED')
  limit 1;

  if not found
     or v_manifest.manifest_sha256 <>
       v_readiness->>'manifest_sha256' then
    raise exception using
      errcode = '42501',
      message = 'TEST_PLAN_CURRENT_MANIFEST_BINDING_INVALID';
  end if;

  select requirement.*
  into v_voice_requirement
  from public.atlas_installation_inventory_requirements as requirement
  where requirement.installation_id = v_installation.id
    and requirement.empresa_id = v_installation.empresa_id
    and requirement.source_manifest_id = v_manifest.id
    and requirement.inventory_code = 'VOICE_CALLS_CONSENTS'
  limit 1;

  if not found
     or v_voice_requirement.requirement_mode not in (
       'REQUIRED', 'NOT_APPLICABLE'
     ) then
    raise exception using
      errcode = '42501',
      message = 'TEST_PLAN_VOICE_CONDITION_NOT_RESOLVED';
  end if;

  v_voice_applicable :=
    v_voice_requirement.requirement_mode = 'REQUIRED';

  select
    count(*) filter (
      where definition.requirement_mode = 'REQUIRED'
    )::integer,
    count(*) filter (
      where definition.requirement_mode = 'CONDITIONAL'
    )::integer,
    count(*) filter (
      where definition.requirement_mode = 'REQUIRED'
         or (
           definition.test_code = 'VOICE_AUDIO_CALLS'
           and v_voice_applicable
         )
    )::integer,
    count(*) filter (
      where definition.test_code = 'VOICE_AUDIO_CALLS'
        and not v_voice_applicable
    )::integer
  into
    v_required_count,
    v_conditional_count,
    v_applicable_count,
    v_skipped_count
  from public.atlas_installation_test_definitions as definition
  where definition.active;

  if v_required_count <> 17
     or v_conditional_count <> 1
     or v_required_count + v_conditional_count <> 18 then
    raise exception using
      errcode = '55000',
      message = 'CANONICAL_TEST_DEFINITION_SET_CHANGED';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'test_code', definition.test_code,
      'test_contract_version',
        definition.test_contract_version,
      'case_order',
        public.atlas_test_case_order_v1(definition.test_code),
      'requirement_mode', definition.requirement_mode,
      'applicability_status', case
        when definition.requirement_mode = 'REQUIRED'
          then 'APPLICABLE'
        when v_voice_applicable then 'APPLICABLE'
        else 'NOT_APPLICABLE'
      end,
      'case_status', case
        when definition.requirement_mode = 'CONDITIONAL'
          and not v_voice_applicable then 'SKIPPED'
        else 'PENDING'
      end,
      'blocking', definition.blocking_by_default,
      'max_attempts', definition.max_attempts,
      'timeout_seconds', definition.timeout_seconds,
      'executor_type', definition.execution_type,
      'dependency_test_codes', to_jsonb(
        public.atlas_test_dependency_codes_v1(
          definition.test_code
        )
      ),
      'expected_assertions',
        public.atlas_test_assertion_contract_v1(
          definition.test_code,
          definition.description,
          definition.required_evidence_kinds,
          definition.g03_criterion_codes
        )
    )
    order by public.atlas_test_case_order_v1(
      definition.test_code
    )
  )
  into v_cases_payload
  from public.atlas_installation_test_definitions as definition
  where definition.active;

  if jsonb_array_length(v_cases_payload) <> 18
     or exists (
       select 1
       from public.atlas_installation_test_definitions as definition
       where definition.active
         and (
           public.atlas_test_case_order_v1(
             definition.test_code
           ) is null
           or public.atlas_test_dependency_codes_v1(
             definition.test_code
           ) is null
         )
     ) then
    raise exception using
      errcode = '55000',
      message = 'TEST_PLAN_CANONICAL_CASE_MAPPING_INCOMPLETE';
  end if;

  if exists (
    select 1
    from public.atlas_installation_test_definitions as definition
    cross join unnest(
      public.atlas_test_dependency_codes_v1(definition.test_code)
    ) as dependency(test_code)
    where definition.active
      and not exists (
        select 1
        from public.atlas_installation_test_definitions as target
        where target.test_code = dependency.test_code
          and target.active
          and public.atlas_test_case_order_v1(target.test_code) <
            public.atlas_test_case_order_v1(definition.test_code)
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'TEST_PLAN_DEPENDENCY_GRAPH_INVALID';
  end if;

  select coalesce(max(plan.plan_version), 0) + 1
  into v_plan_version
  from public.atlas_installation_test_plans as plan
  where plan.installation_id = v_installation.id;

  v_plan_payload := jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_TEST_PLAN_V1',
    'materialization_contract_version',
      'B2_TEST_PLAN_MATERIALIZATION_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'source_manifest_id', v_manifest.id,
    'source_manifest_sha256', v_manifest.manifest_sha256,
    'integration_readiness_evidence_root_sha256',
      v_readiness->>'evidence_root_sha256',
    'plan_version', v_plan_version,
    'installation_version', v_installation.version,
    'required_case_count', v_required_count,
    'conditional_case_count', v_conditional_count,
    'applicable_case_count', v_applicable_count,
    'skipped_case_count', v_skipped_count,
    'voice_condition', jsonb_build_object(
      'inventory_code', 'VOICE_CALLS_CONSENTS',
      'requirement_version',
        v_voice_requirement.requirement_version,
      'requirement_mode',
        v_voice_requirement.requirement_mode,
      'applicable', v_voice_applicable
    ),
    'cases', v_cases_payload
  );
  v_plan_sha256 := public.atlas_normalization_sha256(
    v_plan_payload::text
  );

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active = true
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code = 'INSTALLATION_TEST_PLAN'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'TEST_PLAN_ACTOR_ROLE_NOT_FOUND';
  end if;

  insert into public.atlas_installation_test_plans (
    installation_id,
    empresa_id,
    source_manifest_id,
    plan_code,
    plan_version,
    test_contract_version,
    plan_status,
    expected_installation_version,
    required_case_count,
    conditional_case_count,
    plan_payload,
    plan_sha256,
    request_sha256,
    created_by_user_id,
    idempotency_key,
    ready_at,
    metadata,
    created_at,
    updated_at
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_manifest.id,
    format(
      'B2-TEST-%s-V%s',
      upper(substr(replace(v_installation.id::text, '-', ''), 1, 12)),
      v_plan_version
    ),
    v_plan_version,
    'B2_INSTALLATION_TEST_PLAN_V1',
    'READY',
    v_installation.version,
    v_required_count,
    v_conditional_count,
    v_plan_payload,
    v_plan_sha256,
    v_request_sha256,
    v_actor_user_id,
    p_request_id,
    v_now,
    jsonb_build_object(
      'materialization_request_metadata', p_metadata,
      'request_contract', v_request_payload
    ),
    v_now,
    v_now
  )
  returning * into v_created;

  insert into public.atlas_installation_test_plan_cases (
    test_plan_id,
    installation_id,
    empresa_id,
    test_code,
    case_order,
    requirement_mode,
    applicability_status,
    case_status,
    blocking,
    max_attempts,
    attempt_count,
    executor_type,
    executor_code,
    dependency_test_codes,
    expected_assertions,
    input_contract_sha256,
    started_at,
    completed_at,
    metadata,
    created_at,
    updated_at
  )
  select
    v_created.id,
    v_created.installation_id,
    v_created.empresa_id,
    definition.test_code,
    public.atlas_test_case_order_v1(definition.test_code),
    definition.requirement_mode,
    case
      when definition.requirement_mode = 'REQUIRED'
        then 'APPLICABLE'
      when v_voice_applicable then 'APPLICABLE'
      else 'NOT_APPLICABLE'
    end,
    case
      when definition.requirement_mode = 'CONDITIONAL'
        and not v_voice_applicable then 'SKIPPED'
      else 'PENDING'
    end,
    definition.blocking_by_default,
    definition.max_attempts,
    0,
    definition.execution_type,
    case definition.execution_type
      when 'AUTOMATED' then 'B2_AUTOMATED_TEST_RUNNER'
      when 'HYBRID' then 'B2_HYBRID_TEST_ORCHESTRATOR'
      else 'B2_MANUAL_TEST_REVIEW'
    end,
    public.atlas_test_dependency_codes_v1(
      definition.test_code
    ),
    public.atlas_test_assertion_contract_v1(
      definition.test_code,
      definition.description,
      definition.required_evidence_kinds,
      definition.g03_criterion_codes
    ),
    public.atlas_normalization_sha256(
      jsonb_build_object(
        'contract_version', 'B2_TEST_CASE_INPUT_V1',
        'installation_id', v_created.installation_id,
        'empresa_id', v_created.empresa_id,
        'test_plan_id', v_created.id,
        'plan_sha256', v_created.plan_sha256,
        'source_manifest_id', v_manifest.id,
        'source_manifest_sha256', v_manifest.manifest_sha256,
        'integration_readiness_evidence_root_sha256',
          v_readiness->>'evidence_root_sha256',
        'test_code', definition.test_code,
        'test_contract_version',
          definition.test_contract_version,
        'applicability_status', case
          when definition.requirement_mode = 'REQUIRED'
            then 'APPLICABLE'
          when v_voice_applicable then 'APPLICABLE'
          else 'NOT_APPLICABLE'
        end,
        'dependency_test_codes', to_jsonb(
          public.atlas_test_dependency_codes_v1(
            definition.test_code
          )
        ),
        'expected_assertions',
          public.atlas_test_assertion_contract_v1(
            definition.test_code,
            definition.description,
            definition.required_evidence_kinds,
            definition.g03_criterion_codes
          )
      )::text
    ),
    case
      when definition.requirement_mode = 'CONDITIONAL'
        and not v_voice_applicable then v_now
      else null
    end,
    case
      when definition.requirement_mode = 'CONDITIONAL'
        and not v_voice_applicable then v_now
      else null
    end,
    jsonb_build_object(
      'definition_snapshot', jsonb_build_object(
        'display_name', definition.display_name,
        'test_group', definition.test_group,
        'timeout_seconds', definition.timeout_seconds,
        'required_evidence_kinds',
          to_jsonb(definition.required_evidence_kinds),
        'g03_criterion_codes',
          to_jsonb(definition.g03_criterion_codes)
      ),
      'voice_condition_source', case
        when definition.test_code = 'VOICE_AUDIO_CALLS'
          then jsonb_build_object(
            'inventory_requirement_id', v_voice_requirement.id,
            'requirement_version',
              v_voice_requirement.requirement_version,
            'requirement_mode',
              v_voice_requirement.requirement_mode
          )
        else null
      end
    ),
    v_now,
    v_now
  from public.atlas_installation_test_definitions as definition
  where definition.active;

  if (
    select count(*)
    from public.atlas_installation_test_plan_cases as test_case
    where test_case.test_plan_id = v_created.id
  ) <> 18 then
    raise exception using
      errcode = '55000',
      message = 'TEST_PLAN_CASE_MATERIALIZATION_INCOMPLETE';
  end if;

  v_event_evidence := jsonb_build_object(
    'contract_version', 'B2_TEST_PLAN_MATERIALIZATION_V1',
    'test_plan_id', v_created.id,
    'plan_code', v_created.plan_code,
    'plan_version', v_created.plan_version,
    'plan_sha256', v_created.plan_sha256,
    'request_sha256', v_created.request_sha256,
    'source_manifest_id', v_created.source_manifest_id,
    'source_manifest_sha256', v_manifest.manifest_sha256,
    'integration_readiness_evidence_root_sha256',
      v_readiness->>'evidence_root_sha256',
    'materialized_case_count', 18,
    'applicable_case_count', v_applicable_count,
    'skipped_case_count', v_skipped_count,
    'credential_values_exposed', false,
    'raw_payloads_exposed', false
  );

  insert into public.atlas_installation_test_events (
    installation_id,
    empresa_id,
    test_plan_id,
    test_run_id,
    test_case_id,
    event_code,
    from_status,
    to_status,
    actor_user_id,
    actor_role_code,
    executor_code,
    request_id,
    evidence,
    evidence_sha256,
    metadata
  )
  values (
    v_created.installation_id,
    v_created.empresa_id,
    v_created.id,
    null,
    null,
    'TEST_PLAN_MATERIALIZED',
    'DRAFT',
    'READY',
    v_actor_user_id,
    v_actor_role_code,
    'B2_TEST_PLAN_ENGINE',
    p_request_id,
    v_event_evidence,
    public.atlas_normalization_sha256(v_event_evidence::text),
    jsonb_build_object(
      'request_metadata', p_metadata
    )
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
    v_created.empresa_id,
    v_actor_user_id,
    null,
    null,
    'INSTALLATION_TEST_PLAN_MATERIALIZED',
    'B2_TEST_PLAN_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'installation_id', v_created.installation_id,
      'request_id', p_request_id,
      'expected_installation_version',
        p_expected_installation_version,
      'request_sha256', v_created.request_sha256
    ),
    jsonb_build_object(
      'test_plan_id', v_created.id,
      'plan_code', v_created.plan_code,
      'plan_status', v_created.plan_status,
      'plan_sha256', v_created.plan_sha256,
      'materialized_cases', 18,
      'applicable_cases', v_applicable_count,
      'skipped_cases', v_skipped_count
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_TEST_PLAN_MATERIALIZED',
    'installation_id', v_created.installation_id,
    'test_plan_id', v_created.id,
    'plan_code', v_created.plan_code,
    'plan_version', v_created.plan_version,
    'plan_status', v_created.plan_status,
    'required_cases', v_required_count,
    'conditional_cases', v_conditional_count,
    'applicable_cases', v_applicable_count,
    'skipped_cases', v_skipped_count,
    'voice_test_applicable', v_voice_applicable,
    'plan_sha256', v_created.plan_sha256,
    'source_manifest_sha256', v_manifest.manifest_sha256,
    'integration_readiness_evidence_root_sha256',
      v_readiness->>'evidence_root_sha256',
    'test_execution_started', false,
    'next_action', 'START_TEST_RUN'
  );
end;
$$;

revoke all on function
public.atlas_materialize_installation_test_plan(
  uuid, uuid, bigint, jsonb
)
from public, anon, authenticated;

grant execute on function
public.atlas_materialize_installation_test_plan(
  uuid, uuid, bigint, jsonb
)
to authenticated, service_role;

comment on function public.atlas_materialize_installation_test_plan(
  uuid, uuid, bigint, jsonb
) is
  'B2.2I.2A: materializa un plan READY enlazado a manifest, readiness e inventario canonicos; no ejecuta pruebas.';

comment on function public.atlas_test_dependency_codes_v1(text) is
  'B2.2I.2A: grafo canonico y topologico de dependencias de pruebas V1.';

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
    'code', 'B2_2I2A_TEST_PLAN_MATERIALIZATION_RPC_INSTALLED',
    'next_action', 'CERTIFY_I2A_MATERIALIZATION_RPC_GUARDS',
    'materialization_rpcs', 1,
    'canonical_test_definitions', (
      select count(*)
      from public.atlas_installation_test_definitions
      where active
    ),
    'test_plan_records', (
      select count(*)
      from public.atlas_installation_test_plans
    ),
    'test_case_records', (
      select count(*)
      from public.atlas_installation_test_plan_cases
    ),
    'request_idempotency_enabled', true,
    'optimistic_concurrency_enabled', true,
    'integration_readiness_revalidation_enabled', true,
    'manifest_hash_binding_enabled', true,
    'conditional_voice_resolution_enabled', true,
    'dependency_graph_enabled', true,
    'test_execution_enabled', false,
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
  'code', 'B2_2I2A_TEST_PLAN_MATERIALIZATION_RPC_INSTALLED',
  'next_action', 'CERTIFY_I2A_MATERIALIZATION_RPC_GUARDS',
  'materialization_rpcs', (
    select count(*)
    from pg_proc as procedure
    join pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname =
        'atlas_materialize_installation_test_plan'
      and procedure.prosecdef
  ),
  'canonical_test_definitions', (
    select count(*)
    from public.atlas_installation_test_definitions
    where active
  ),
  'test_plan_records', (
    select count(*)
    from public.atlas_installation_test_plans
  ),
  'test_case_records', (
    select count(*)
    from public.atlas_installation_test_plan_cases
  ),
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'integration_readiness_revalidation_enabled', true,
  'manifest_hash_binding_enabled', true,
  'conditional_voice_resolution_enabled', true,
  'dependency_graph_enabled', true,
  'test_execution_enabled', false,
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
        'atlas_installation_test_events'
      )
      and table_grant.grantee = 'authenticated'
      and table_grant.privilege_type in (
        'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'
      )
  )
) as result;
