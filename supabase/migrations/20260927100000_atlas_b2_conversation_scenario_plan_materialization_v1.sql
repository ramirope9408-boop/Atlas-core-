-- ATLAS B2 conversational scenario plan materialization V1
-- Date: 2026-09-27
-- Additive, service-governed and company-agnostic.
-- Materializes generic conversational scenarios against a B2 V2 test plan.
-- It stores canonical references/binding policies, not raw business values.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_conversation_test_scenario_definitions'
     ) is null
     or to_regclass('public.atlas_installation_test_plans') is null
     or to_regclass('public.atlas_installation_test_plan_cases') is null
     or to_regclass('public.atlas_canonical_data_versions') is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception
      'Conversation scenario materialization requires B2 V2 scenario registry and canonical data core';
  end if;

  if to_regclass(
       'public.atlas_conversation_test_scenario_plans'
     ) is not null
     or to_regclass(
       'public.atlas_conversation_test_scenario_instances'
     ) is not null then
    raise exception
      'Conversation scenario plan structures already exist; reconcile before install';
  end if;
end;
$$;

create table public.atlas_conversation_test_scenario_plans (
  id uuid primary key default gen_random_uuid(),
  test_plan_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  canonical_data_version_id uuid not null,
  scenario_plan_version integer not null,
  contract_version text not null,
  plan_status text not null default 'READY',
  total_scenarios integer not null,
  applicable_scenarios integer not null,
  skipped_scenarios integer not null,
  plan_payload jsonb not null,
  plan_sha256 text not null,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  request_sha256 text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_conversation_scenario_plan_test_key
    unique (test_plan_id, scenario_plan_version),
  constraint atlas_conversation_scenario_plan_request_key
    unique (test_plan_id, idempotency_key),
  constraint atlas_conversation_scenario_plan_identity_key
    unique (id, test_plan_id, installation_id, empresa_id),

  constraint atlas_conversation_scenario_plan_test_fkey
    foreign key (test_plan_id, installation_id, empresa_id)
    references public.atlas_installation_test_plans(
      id, installation_id, empresa_id
    )
    on delete restrict,

  constraint atlas_conversation_scenario_plan_canonical_fkey
    foreign key (canonical_data_version_id)
    references public.atlas_canonical_data_versions(id)
    on delete restrict,

  constraint atlas_conversation_scenario_plan_actor_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,

  constraint atlas_conversation_scenario_plan_version_check
    check (
      scenario_plan_version >= 1
      and contract_version =
        'B2_CONVERSATION_SCENARIO_PLAN_V1'
    ),

  constraint atlas_conversation_scenario_plan_status_check
    check (
      plan_status in (
        'READY', 'RUNNING', 'PASSED', 'FAILED',
        'CANCELLED', 'SUPERSEDED'
      )
    ),

  constraint atlas_conversation_scenario_plan_counts_check
    check (
      total_scenarios >= 1
      and applicable_scenarios >= 1
      and skipped_scenarios >= 0
      and applicable_scenarios + skipped_scenarios =
        total_scenarios
    ),

  constraint atlas_conversation_scenario_plan_payload_check
    check (
      jsonb_typeof(plan_payload) = 'object'
      and plan_payload->>'contract_version' =
        contract_version
      and plan_payload->>'test_plan_id' =
        test_plan_id::text
      and plan_payload->>'installation_id' =
        installation_id::text
      and plan_payload->>'empresa_id' =
        empresa_id::text
      and plan_payload->>'canonical_data_version_id' =
        canonical_data_version_id::text
      and not public.atlas_jsonb_has_forbidden_secret_key(
        plan_payload
      )
    ),

  constraint atlas_conversation_scenario_plan_hash_check
    check (
      plan_sha256 ~ '^[0-9a-f]{64}$'
      and request_sha256 ~ '^[0-9a-f]{64}$'
    ),

  constraint atlas_conversation_scenario_plan_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(
        metadata
      )
    )
);

create table public.atlas_conversation_test_scenario_instances (
  id uuid primary key default gen_random_uuid(),
  scenario_plan_id uuid not null,
  test_plan_id uuid not null,
  test_case_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  canonical_data_version_id uuid not null,
  scenario_code text not null,
  scenario_order integer not null,
  applicability_status text not null,
  instance_status text not null default 'PENDING',
  prompt_template text not null,
  binding_policy jsonb not null,
  expected_assertion_codes text[] not null,
  instance_contract_sha256 text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_conversation_scenario_instance_code_key
    unique (scenario_plan_id, scenario_code),
  constraint atlas_conversation_scenario_instance_order_key
    unique (scenario_plan_id, scenario_order),

  constraint atlas_conversation_scenario_instance_plan_fkey
    foreign key (
      scenario_plan_id, test_plan_id, installation_id, empresa_id
    )
    references public.atlas_conversation_test_scenario_plans(
      id, test_plan_id, installation_id, empresa_id
    )
    on delete restrict,

  constraint atlas_conversation_scenario_instance_case_fkey
    foreign key (
      test_case_id, test_plan_id, installation_id, empresa_id
    )
    references public.atlas_installation_test_plan_cases(
      id, test_plan_id, installation_id, empresa_id
    )
    on delete restrict,

  constraint atlas_conversation_scenario_instance_canonical_fkey
    foreign key (canonical_data_version_id)
    references public.atlas_canonical_data_versions(id)
    on delete restrict,

  constraint atlas_conversation_scenario_instance_definition_fkey
    foreign key (scenario_code)
    references public.atlas_conversation_test_scenario_definitions(
      scenario_code
    )
    on delete restrict,

  constraint atlas_conversation_scenario_instance_applicability_check
    check (
      applicability_status in (
        'APPLICABLE', 'NOT_APPLICABLE'
      )
    ),

  constraint atlas_conversation_scenario_instance_status_check
    check (
      instance_status in (
        'PENDING', 'RUNNING', 'PASSED', 'FAILED',
        'BLOCKED', 'SKIPPED'
      )
    ),

  constraint atlas_conversation_scenario_instance_binding_check
    check (
      jsonb_typeof(binding_policy) = 'object'
      and binding_policy <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        binding_policy
      )
    ),

  constraint atlas_conversation_scenario_instance_assertions_check
    check (
      cardinality(expected_assertion_codes) >= 1
      and array_position(expected_assertion_codes, null) is null
    ),

  constraint atlas_conversation_scenario_instance_hash_check
    check (instance_contract_sha256 ~ '^[0-9a-f]{64}$'),

  constraint atlas_conversation_scenario_instance_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(
        metadata
      )
    )
);

create index idx_atlas_conversation_scenario_instances_case
  on public.atlas_conversation_test_scenario_instances(
    test_case_id,
    applicability_status,
    scenario_order
  );

create or replace function
public.atlas_conversation_scenario_binding_policy_v1(
  p_scenario_code text
)
returns jsonb
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select case p_scenario_code
    when 'DIRECT_CANONICAL_LOOKUP' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('PRODUCTS_SERVICES', 'FAQ_SERVICE_LIMITS'),
        'selection', 'CURRENT_APPROVED_CANONICAL_RECORD',
        'raw_values_persisted', false
      )
    when 'UNSUPPORTED_ATTRIBUTE_REJECTION' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('PRODUCTS_SERVICES'),
        'selection', 'CURRENT_APPROVED_CANONICAL_ENTITY',
        'negative_attribute_generated', true,
        'raw_values_persisted', false
      )
    when 'AMBIGUOUS_COMMERCIAL_REQUEST' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('PRODUCTS_SERVICES', 'COMMERCIAL_POLICIES'),
        'selection', 'CURRENT_APPROVED_CANONICAL_RECORD',
        'raw_values_persisted', false
      )
    when 'ACKNOWLEDGEMENT_NO_RETRIGGER' then
      jsonb_build_object(
        'inventory_codes', '[]'::jsonb,
        'selection', 'ACTIVE_CONVERSATION_STATE',
        'raw_values_persisted', false
      )
    when 'SELF_CORRECTION_FINAL_INTENT' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('PRODUCTS_SERVICES'),
        'selection', 'TWO_COMPATIBLE_CANONICAL_REQUESTS',
        'raw_values_persisted', false
      )
    when 'POST_MODIFICATION_ACK_NO_LOOP' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('PRODUCTS_SERVICES', 'COMMERCIAL_POLICIES'),
        'selection', 'ACTIVE_MODIFIED_COMMERCIAL_OBJECT',
        'raw_values_persisted', false
      )
    when 'EXPLICIT_ACCEPTANCE_REQUIRED' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('COMMERCIAL_POLICIES', 'QUOTES_AND_TEMPLATES'),
        'selection', 'CURRENT_VISIBLE_COMMERCIAL_OBJECT',
        'raw_values_persisted', false
      )
    when 'NON_ACCEPTANCE_ACK_BLOCKED' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('COMMERCIAL_POLICIES', 'QUOTES_AND_TEMPLATES'),
        'selection', 'CURRENT_VISIBLE_COMMERCIAL_OBJECT',
        'raw_values_persisted', false
      )
    when 'MODIFICATION_OVERRIDES_STALE_ACCEPTANCE' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('PRODUCTS_SERVICES', 'COMMERCIAL_POLICIES'),
        'selection', 'CURRENT_VISIBLE_COMMERCIAL_OBJECT',
        'raw_values_persisted', false
      )
    when 'PAYMENT_BEFORE_ACCEPTANCE_BLOCKED' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('PAYMENT_METHODS_TERMS', 'COMMERCIAL_POLICIES'),
        'selection', 'CURRENT_APPROVED_PAYMENT_POLICY',
        'raw_values_persisted', false
      )
    when 'VISUAL_FAMILY_REFERENCE' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('PRODUCTS_SERVICES', 'MEDIA_TECHNICAL_DOCUMENTS'),
        'selection', 'CURRENT_CANONICAL_ENTITY_WITH_MEDIA',
        'raw_values_persisted', false
      )
    when 'DOCUMENT_CURRENT_VERSION_BINDING' then
      jsonb_build_object(
        'inventory_codes',
          jsonb_build_array('QUOTES_AND_TEMPLATES', 'COMMERCIAL_POLICIES'),
        'selection', 'CURRENT_CANONICAL_DOCUMENT_CONTRACT',
        'raw_values_persisted', false
      )
    else
      jsonb_build_object(
        'inventory_codes', '[]'::jsonb,
        'selection', 'NONE',
        'raw_values_persisted', false
      )
  end
$$;

revoke all on function
public.atlas_conversation_scenario_binding_policy_v1(text)
from public, anon, authenticated;

grant execute on function
public.atlas_conversation_scenario_binding_policy_v1(text)
to service_role;

create or replace function
public.atlas_materialize_conversation_scenario_plan_v1(
  p_test_plan_id uuid,
  p_request_id uuid,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_plan public.atlas_installation_test_plans%rowtype;
  v_canonical public.atlas_canonical_data_versions%rowtype;
  v_existing public.atlas_conversation_test_scenario_plans%rowtype;
  v_created public.atlas_conversation_test_scenario_plans%rowtype;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_plan_payload jsonb;
  v_plan_sha256 text;
  v_scenario_plan_version integer;
  v_total integer;
  v_applicable integer;
  v_skipped integer;
  v_media_enabled boolean := false;
  v_documents_enabled boolean := false;
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

  if p_test_plan_id is null
     or p_request_id is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_SCENARIO_PLAN_REQUIRED_FIELDS_INVALID';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_test_plans as plan
  where plan.id = p_test_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_TEST_PLAN_NOT_FOUND';
  end if;

  if v_plan.test_contract_version <>
       'B2_INSTALLATION_TEST_PLAN_V2' then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_SCENARIO_PLAN_REQUIRES_TEST_PLAN_V2';
  end if;

  if v_plan.plan_status not in ('READY', 'RUNNING') then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_SCENARIO_PLAN_TEST_PLAN_NOT_ACTIVE';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version',
      'B2_CONVERSATION_SCENARIO_PLAN_REQUEST_V1',
    'test_plan_id', v_plan.id,
    'installation_id', v_plan.installation_id,
    'empresa_id', v_plan.empresa_id,
    'request_metadata', p_metadata
  );

  v_request_sha256 :=
    public.atlas_normalization_sha256(
      v_request_payload::text
    );

  select scenario_plan.*
  into v_existing
  from public.atlas_conversation_test_scenario_plans as scenario_plan
  where scenario_plan.test_plan_id = v_plan.id
    and scenario_plan.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'CONVERSATION_SCENARIO_PLAN_IDEMPOTENCY_KEY_REUSED';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'scenario_plan_id', v_existing.id,
      'scenario_plan_version',
        v_existing.scenario_plan_version,
      'total_scenarios', v_existing.total_scenarios,
      'applicable_scenarios',
        v_existing.applicable_scenarios,
      'skipped_scenarios',
        v_existing.skipped_scenarios,
      'plan_sha256', v_existing.plan_sha256,
      'next_action', 'RESOLVE_SCENARIO_BINDINGS'
    );
  end if;

  select canonical.*
  into v_canonical
  from public.atlas_canonical_data_versions as canonical
  where canonical.installation_id = v_plan.installation_id
    and canonical.empresa_id = v_plan.empresa_id
    and canonical.source_manifest_id =
      v_plan.source_manifest_id
    and canonical.version_status = 'APPROVED'
  order by
    canonical.canonical_version desc,
    canonical.created_at desc
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'CURRENT_APPROVED_CANONICAL_VERSION_NOT_FOUND';
  end if;

  if v_canonical.canonical_sha256 <>
       public.atlas_normalization_sha256(
         v_canonical.canonical_payload::text
       ) then
    raise exception using
      errcode = '55000',
      message = 'CANONICAL_VERSION_HASH_MISMATCH';
  end if;

  select exists (
    select 1
    from jsonb_array_elements(
      v_canonical.canonical_payload->'records'
    ) as record(value)
    where record.value->>'inventory_code' =
      'MEDIA_TECHNICAL_DOCUMENTS'
  )
  into v_media_enabled;

  select exists (
    select 1
    from jsonb_array_elements(
      v_canonical.canonical_payload->'records'
    ) as record(value)
    where record.value->>'inventory_code' =
      'QUOTES_AND_TEMPLATES'
  )
  into v_documents_enabled;

  select
    count(*)::integer,
    count(*) filter (
      where definition.requirement_mode = 'REQUIRED'
        or (
          definition.scenario_code =
            'VISUAL_FAMILY_REFERENCE'
          and v_media_enabled
        )
        or (
          definition.scenario_code =
            'DOCUMENT_CURRENT_VERSION_BINDING'
          and v_documents_enabled
        )
    )::integer
  into v_total, v_applicable
  from public.atlas_conversation_test_scenario_definitions
    as definition
  where definition.active;

  v_skipped := v_total - v_applicable;

  if v_total < 1 or v_applicable < 1 then
    raise exception using
      errcode = '55000',
      message = 'CONVERSATION_SCENARIO_DEFINITION_SET_EMPTY';
  end if;

  select coalesce(max(scenario_plan.scenario_plan_version), 0) + 1
  into v_scenario_plan_version
  from public.atlas_conversation_test_scenario_plans
    as scenario_plan
  where scenario_plan.test_plan_id = v_plan.id;

  v_plan_payload := jsonb_build_object(
    'contract_version',
      'B2_CONVERSATION_SCENARIO_PLAN_V1',
    'test_plan_id', v_plan.id,
    'installation_id', v_plan.installation_id,
    'empresa_id', v_plan.empresa_id,
    'canonical_data_version_id', v_canonical.id,
    'canonical_sha256', v_canonical.canonical_sha256,
    'scenario_plan_version',
      v_scenario_plan_version,
    'total_scenarios', v_total,
    'applicable_scenarios', v_applicable,
    'skipped_scenarios', v_skipped,
    'capabilities', jsonb_build_object(
      'catalog_media_enabled', v_media_enabled,
      'document_output_enabled', v_documents_enabled
    ),
    'raw_business_values_persisted', false
  );

  v_plan_sha256 :=
    public.atlas_normalization_sha256(
      v_plan_payload::text
    );

  insert into public.atlas_conversation_test_scenario_plans (
    test_plan_id,
    installation_id,
    empresa_id,
    canonical_data_version_id,
    scenario_plan_version,
    contract_version,
    plan_status,
    total_scenarios,
    applicable_scenarios,
    skipped_scenarios,
    plan_payload,
    plan_sha256,
    created_by_user_id,
    idempotency_key,
    request_sha256,
    metadata
  )
  values (
    v_plan.id,
    v_plan.installation_id,
    v_plan.empresa_id,
    v_canonical.id,
    v_scenario_plan_version,
    'B2_CONVERSATION_SCENARIO_PLAN_V1',
    'READY',
    v_total,
    v_applicable,
    v_skipped,
    v_plan_payload,
    v_plan_sha256,
    v_actor_user_id,
    p_request_id,
    v_request_sha256,
    jsonb_build_object(
      'request_metadata', p_metadata
    )
  )
  returning * into v_created;

  insert into public.atlas_conversation_test_scenario_instances (
    scenario_plan_id,
    test_plan_id,
    test_case_id,
    installation_id,
    empresa_id,
    canonical_data_version_id,
    scenario_code,
    scenario_order,
    applicability_status,
    instance_status,
    prompt_template,
    binding_policy,
    expected_assertion_codes,
    instance_contract_sha256,
    metadata
  )
  select
    v_created.id,
    v_plan.id,
    test_case.id,
    v_plan.installation_id,
    v_plan.empresa_id,
    v_canonical.id,
    definition.scenario_code,
    definition.sort_order,
    case
      when definition.requirement_mode = 'REQUIRED'
        then 'APPLICABLE'
      when definition.scenario_code =
             'VISUAL_FAMILY_REFERENCE'
        then case
          when v_media_enabled then 'APPLICABLE'
          else 'NOT_APPLICABLE'
        end
      when definition.scenario_code =
             'DOCUMENT_CURRENT_VERSION_BINDING'
        then case
          when v_documents_enabled then 'APPLICABLE'
          else 'NOT_APPLICABLE'
        end
      else 'NOT_APPLICABLE'
    end,
    case
      when definition.requirement_mode = 'REQUIRED'
        then 'PENDING'
      when definition.scenario_code =
             'VISUAL_FAMILY_REFERENCE'
           and v_media_enabled
        then 'PENDING'
      when definition.scenario_code =
             'DOCUMENT_CURRENT_VERSION_BINDING'
           and v_documents_enabled
        then 'PENDING'
      else 'SKIPPED'
    end,
    definition.prompt_template,
    public.atlas_conversation_scenario_binding_policy_v1(
      definition.scenario_code
    ),
    definition.expected_assertion_codes,
    public.atlas_normalization_sha256(
      jsonb_build_object(
        'contract_version',
          'B2_CONVERSATION_SCENARIO_INSTANCE_V1',
        'scenario_plan_id', v_created.id,
        'test_plan_id', v_plan.id,
        'test_case_id', test_case.id,
        'canonical_data_version_id', v_canonical.id,
        'scenario_code', definition.scenario_code,
        'prompt_template', definition.prompt_template,
        'binding_policy',
          public.atlas_conversation_scenario_binding_policy_v1(
            definition.scenario_code
          ),
        'expected_assertion_codes',
          to_jsonb(definition.expected_assertion_codes)
      )::text
    ),
    jsonb_build_object(
      'raw_business_values_persisted', false
    )
  from public.atlas_conversation_test_scenario_definitions
    as definition
  join public.atlas_installation_test_plan_cases as test_case
    on test_case.test_plan_id = v_plan.id
   and test_case.test_code = definition.parent_test_code
  where definition.active
  order by definition.sort_order;

  if (
    select count(*)
    from public.atlas_conversation_test_scenario_instances
      as instance
    where instance.scenario_plan_id = v_created.id
  ) <> v_total then
    raise exception using
      errcode = '55000',
      message = 'CONVERSATION_SCENARIO_PLAN_INSTANCE_COUNT_MISMATCH';
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'CONVERSATION_SCENARIO_PLAN_READY',
    'scenario_plan_id', v_created.id,
    'scenario_plan_version',
      v_created.scenario_plan_version,
    'test_plan_id', v_plan.id,
    'canonical_data_version_id', v_canonical.id,
    'total_scenarios', v_total,
    'applicable_scenarios', v_applicable,
    'skipped_scenarios', v_skipped,
    'catalog_media_enabled', v_media_enabled,
    'document_output_enabled', v_documents_enabled,
    'raw_business_values_persisted', false,
    'plan_sha256', v_plan_sha256,
    'next_action', 'RESOLVE_SCENARIO_BINDINGS'
  );
end;
$$;

revoke all on table
public.atlas_conversation_test_scenario_plans
from public, anon, authenticated;

revoke all on table
public.atlas_conversation_test_scenario_instances
from public, anon, authenticated;

revoke all on function
public.atlas_materialize_conversation_scenario_plan_v1(
  uuid, uuid, jsonb
)
from public, anon, authenticated;

grant select on table
public.atlas_conversation_test_scenario_plans
to service_role;

grant select on table
public.atlas_conversation_test_scenario_instances
to service_role;

grant execute on function
public.atlas_materialize_conversation_scenario_plan_v1(
  uuid, uuid, jsonb
)
to service_role;

commit;
