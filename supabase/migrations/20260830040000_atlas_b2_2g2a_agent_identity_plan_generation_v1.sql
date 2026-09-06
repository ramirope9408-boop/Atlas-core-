-- ATLAS B2.2G.2A
-- Identidad configurable y generacion gobernada del plan de aprovisionamiento.
-- Corte: 2026-08-30
--
-- Este bloque:
-- - separa agent_code tecnico de display_name visible;
-- - genera un plan determinista desde manifest + canonico + paquete;
-- - materializa pasos idempotentes con dependencias y compensacion;
-- - no ejecuta preflight ni crea recursos del tenant;
-- - no modifica la instalacion piloto de FingerFood.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_provisioning_plans'
     ) is null
     or to_regclass(
       'public.atlas_installation_provisioning_steps'
     ) is null
     or to_regclass(
       'public.atlas_installation_provisioning_events'
     ) is null
     or to_regclass(
       'public.atlas_provisioning_resource_definitions'
     ) is null
     or to_regprocedure(
       'public.atlas_platform_has_permission(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_g02_readiness(uuid)'
     ) is null then
    raise exception 'B2.2G.2A requiere B2.2G.1 instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_provisioning_agent_identities_are_valid(
  p_identities jsonb
)
returns boolean
language plpgsql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
declare
  v_identity_count bigint;
  v_distinct_code_count bigint;
begin
  if jsonb_typeof(p_identities) <> 'array'
     or jsonb_array_length(p_identities) = 0 then
    return false;
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_identities) then
    return false;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_identities) as identity_record(value)
    where jsonb_typeof(identity_record.value) <> 'object'
       or not (identity_record.value ?& array[
         'agent_code',
         'display_name',
         'default_display_name',
         'role_description',
         'display_name_source',
         'technical_code_locked'
       ])
       or jsonb_typeof(identity_record.value->'agent_code') <>
         'string'
       or jsonb_typeof(identity_record.value->'display_name') <>
         'string'
       or jsonb_typeof(
         identity_record.value->'default_display_name'
       ) <> 'string'
       or jsonb_typeof(identity_record.value->'role_description') <>
         'string'
       or jsonb_typeof(identity_record.value->'display_name_source') <>
         'string'
       or coalesce(identity_record.value->>'agent_code', '') !~
         '^[A-Z][A-Z0-9_]*$'
       or length(btrim(identity_record.value->>'display_name'))
         not between 2 and 60
       or length(btrim(identity_record.value->>'default_display_name'))
         not between 2 and 60
       or length(btrim(identity_record.value->>'role_description'))
         not between 3 and 160
       or identity_record.value->>'display_name' ~ '[[:cntrl:]]'
       or identity_record.value->>'default_display_name' ~ '[[:cntrl:]]'
       or identity_record.value->>'role_description' ~ '[[:cntrl:]]'
       or identity_record.value->>'display_name_source' not in (
         'MANIFEST_DEFAULT', 'CLIENT_OVERRIDE'
       )
       or identity_record.value->'technical_code_locked' <>
         'true'::jsonb
  ) then
    return false;
  end if;

  select
    count(*),
    count(distinct identity_record.value->>'agent_code')
  into v_identity_count, v_distinct_code_count
  from jsonb_array_elements(p_identities) as identity_record(value);

  return v_identity_count = v_distinct_code_count;
exception
  when others then
    return false;
end;
$$;

revoke all on function
public.atlas_provisioning_agent_identities_are_valid(jsonb)
  from public, anon, authenticated;
grant execute on function
public.atlas_provisioning_agent_identities_are_valid(jsonb)
  to service_role;

update public.atlas_provisioning_resource_definitions
set
  description =
    'Instala codigo tecnico estable, nombre visible configurable y rol del agente.',
  input_contract = jsonb_build_object(
    'requires', jsonb_build_array(
      'agent_code',
      'display_name',
      'default_display_name',
      'role_description',
      'technical_code_locked'
    ),
    'identity_rule',
      'AGENT_CODE_STABLE_DISPLAY_NAME_CONFIGURABLE'
  ),
  verification_contract = jsonb_build_object(
    'asserts', jsonb_build_array(
      'TECHNICAL_CODE_IMMUTABLE',
      'DISPLAY_NAME_CONFIGURABLE',
      'ROLE_DESCRIPTION_PRESENT',
      'NO_PROCESS_BOUND_TO_DISPLAY_NAME'
    )
  ),
  metadata = metadata || jsonb_build_object(
    'identity_contract_version', 'B2_AGENT_IDENTITY_V1',
    'post_activation_rename_requires_audit', true
  ),
  updated_at = now()
where resource_code = 'AGENT_IDENTITY';

do $$
begin
  if not exists (
    select 1
    from public.atlas_provisioning_resource_definitions
    where resource_code = 'AGENT_IDENTITY'
      and input_contract->>'identity_rule' =
        'AGENT_CODE_STABLE_DISPLAY_NAME_CONFIGURABLE'
      and metadata->>'identity_contract_version' =
        'B2_AGENT_IDENTITY_V1'
  ) then
    raise exception 'B2.2G.2A no pudo reconciliar AGENT_IDENTITY';
  end if;
end;
$$;

alter table public.atlas_installation_provisioning_plans
  drop constraint if exists atlas_provisioning_plans_payload_check;

alter table public.atlas_installation_provisioning_plans
  add constraint atlas_provisioning_plans_payload_check
  check (
    jsonb_typeof(plan_payload) = 'object'
    and plan_payload ?& array[
      'schema_version',
      'installation_id',
      'empresa_id',
      'source_installation_version',
      'source_manifest_id',
      'canonical_data_version_id',
      'package_id',
      'package_version',
      'agent_identities',
      'agent_display_name_overrides',
      'resources'
    ]
    and jsonb_typeof(plan_payload->'resources') = 'array'
    and jsonb_array_length(plan_payload->'resources') > 0
    and jsonb_typeof(
      plan_payload->'agent_display_name_overrides'
    ) = 'object'
    and public.atlas_provisioning_agent_identities_are_valid(
      plan_payload->'agent_identities'
    )
    and not public.atlas_jsonb_has_forbidden_secret_key(plan_payload)
  );

create or replace function
public.atlas_generate_installation_provisioning_plan(
  p_installation_id uuid,
  p_agent_display_name_overrides jsonb,
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
  v_canonical public.atlas_canonical_data_versions%rowtype;
  v_package public.atlas_agent_packages%rowtype;
  v_existing public.atlas_installation_provisioning_plans%rowtype;
  v_created public.atlas_installation_provisioning_plans%rowtype;
  v_readiness jsonb;
  v_agent_identities jsonb;
  v_resources jsonb;
  v_plan_payload jsonb;
  v_plan_sha256 text;
  v_plan_version integer;
  v_step_count integer;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PROVISIONING_MANAGE_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_agent_display_name_overrides is null
     or jsonb_typeof(p_agent_display_name_overrides) <> 'object'
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_agent_display_name_overrides
     )
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_REQUIRED_FIELDS_INVALID';
  end if;

  if exists (
    select 1
    from jsonb_each(p_agent_display_name_overrides) as override_entry
    where override_entry.key !~ '^[A-Z][A-Z0-9_]*$'
       or jsonb_typeof(override_entry.value) <> 'string'
       or length(btrim(override_entry.value #>> '{}'))
         not between 2 and 60
       or (override_entry.value #>> '{}') ~ '[[:cntrl:]]'
  ) then
    raise exception using
      errcode = '22023',
      message = 'AGENT_DISPLAY_NAME_OVERRIDE_INVALID';
  end if;

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
  from public.atlas_installation_provisioning_plans as plan
  where plan.installation_id = v_installation.id
    and plan.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.plan_payload->'agent_display_name_overrides' <>
         p_agent_display_name_overrides
       or (
         v_existing.plan_payload->>'source_installation_version'
       )::bigint <> p_expected_installation_version then
      raise exception using
        errcode = '22023',
        message =
          'PROVISIONING_PLAN_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'provisioning_plan_id', v_existing.id,
      'plan_version', v_existing.plan_version,
      'plan_status', v_existing.plan_status,
      'state_version', v_existing.state_version,
      'plan_sha256', v_existing.plan_sha256,
      'agent_identities', v_existing.plan_payload->'agent_identities',
      'step_count', (
        select count(*)
        from public.atlas_installation_provisioning_steps as step
        where step.provisioning_plan_id = v_existing.id
      )
    );
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001',
      message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'DATA_APPROVED' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_DATA_APPROVED';
  end if;

  if v_installation.empresa_id is null then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_EMPRESA_REQUIRED';
  end if;

  if exists (
    select 1
    from public.atlas_installation_provisioning_plans as active_plan
    where active_plan.installation_id = v_installation.id
      and active_plan.plan_status in (
        'DRAFT', 'PREFLIGHT_PENDING', 'PREFLIGHT_FAILED',
        'PREFLIGHT_PASSED', 'EXECUTING', 'ROLLBACK_REQUIRED'
      )
  ) then
    raise exception using
      errcode = '23505',
      message = 'ACTIVE_PROVISIONING_PLAN_ALREADY_EXISTS';
  end if;

  select manifest.*
  into v_manifest
  from public.atlas_installation_manifests as manifest
  where manifest.installation_id = v_installation.id
    and manifest.empresa_id = v_installation.empresa_id
    and manifest.manifest_status in ('VALIDATED', 'APPROVED')
  order by
    manifest.package_version desc,
    manifest.created_at desc,
    manifest.id desc
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'CURRENT_VALIDATED_MANIFEST_NOT_FOUND';
  end if;

  if not public.atlas_manifest_payload_is_valid(
    v_manifest.manifest_payload
  ) then
    raise exception using
      errcode = '22023',
      message = 'CURRENT_MANIFEST_INVALID_OR_CONTAINS_SECRETS';
  end if;

  select canonical.*
  into v_canonical
  from public.atlas_canonical_data_versions as canonical
  where canonical.installation_id = v_installation.id
    and canonical.empresa_id = v_installation.empresa_id
    and canonical.source_manifest_id = v_manifest.id
    and canonical.version_status = 'APPROVED'
  order by
    canonical.canonical_version desc,
    canonical.created_at desc,
    canonical.id desc
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
      errcode = '22023',
      message = 'CANONICAL_VERSION_HASH_MISMATCH';
  end if;

  v_readiness := public.atlas_compute_installation_g02_readiness(
    v_installation.id
  );

  if not coalesce((v_readiness->>'ready')::boolean, false)
     or (v_readiness->>'canonical_data_version_id') is distinct from
       v_canonical.id::text
     or not exists (
       select 1
       from public.atlas_installation_gates as gate_record
       where gate_record.installation_id = v_installation.id
         and gate_record.gate_code = 'G02'
         and gate_record.status = 'APPROVED'
         and gate_record.client_approved = true
     ) then
    raise exception using
      errcode = '42501',
      message = 'G02_DATA_APPROVAL_REQUIRED_FOR_PLAN',
      detail = v_readiness::text;
  end if;

  select package.*
  into v_package
  from public.atlas_agent_packages as package
  where package.id = v_manifest.package_id
    and package.version = format('V%s', v_manifest.package_version)
    and package.status = 'ACTIVE';

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACTIVE_AGENT_PACKAGE_VERSION_NOT_FOUND';
  end if;

  if jsonb_typeof(v_manifest.manifest_payload->'agents') <> 'array'
     or jsonb_array_length(v_manifest.manifest_payload->'agents') = 0
     or exists (
       select 1
       from jsonb_array_elements(
         v_manifest.manifest_payload->'agents'
       ) as manifest_agent(value)
       where jsonb_typeof(manifest_agent.value) <> 'object'
          or not (manifest_agent.value ?& array[
            'agent_code', 'display_name', 'role_description'
          ])
          or jsonb_typeof(manifest_agent.value->'agent_code') <>
            'string'
          or jsonb_typeof(manifest_agent.value->'display_name') <>
            'string'
          or jsonb_typeof(manifest_agent.value->'role_description') <>
            'string'
          or coalesce(manifest_agent.value->>'agent_code', '') !~
            '^[A-Z][A-Z0-9_]*$'
          or length(btrim(manifest_agent.value->>'display_name'))
            not between 2 and 60
          or length(btrim(manifest_agent.value->>'role_description'))
            not between 3 and 160
          or manifest_agent.value->>'display_name' ~ '[[:cntrl:]]'
          or manifest_agent.value->>'role_description' ~ '[[:cntrl:]]'
     ) then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_AGENT_IDENTITY_CONTRACT_INVALID';
  end if;

  if (
    select count(*)
    from jsonb_array_elements(
      v_manifest.manifest_payload->'agents'
    ) as manifest_agent(value)
  ) <> (
    select count(distinct manifest_agent.value->>'agent_code')
    from jsonb_array_elements(
      v_manifest.manifest_payload->'agents'
    ) as manifest_agent(value)
  ) then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_AGENT_CODE_DUPLICATED';
  end if;

  if exists (
    select 1
    from jsonb_object_keys(
      p_agent_display_name_overrides
    ) as override_code(agent_code)
    where not exists (
      select 1
      from jsonb_array_elements(
        v_manifest.manifest_payload->'agents'
      ) as manifest_agent(value)
      where manifest_agent.value->>'agent_code' =
        override_code.agent_code
    )
  ) then
    raise exception using
      errcode = '22023',
      message = 'AGENT_DISPLAY_NAME_OVERRIDE_CODE_NOT_IN_MANIFEST';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'agent_code', manifest_agent.value->>'agent_code',
      'display_name', coalesce(
        nullif(btrim(
          p_agent_display_name_overrides->>
            (manifest_agent.value->>'agent_code')
        ), ''),
        btrim(manifest_agent.value->>'display_name')
      ),
      'default_display_name',
        btrim(manifest_agent.value->>'display_name'),
      'role_description',
        btrim(manifest_agent.value->>'role_description'),
      'display_name_source', case
        when p_agent_display_name_overrides ?
          (manifest_agent.value->>'agent_code')
          then 'CLIENT_OVERRIDE'
        else 'MANIFEST_DEFAULT'
      end,
      'technical_code_locked', true
    )
    order by manifest_agent.value->>'agent_code'
  )
  into v_agent_identities
  from jsonb_array_elements(
    v_manifest.manifest_payload->'agents'
  ) as manifest_agent(value);

  if not public.atlas_provisioning_agent_identities_are_valid(
    v_agent_identities
  ) then
    raise exception using
      errcode = '22023',
      message = 'EFFECTIVE_AGENT_IDENTITIES_INVALID';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'resource_code', resource.resource_code,
      'resource_group', resource.resource_group,
      'operation_type', resource.operation_type,
      'target_kind', resource.target_kind,
      'execution_order', resource.execution_order,
      'required', resource.required_by_default,
      'dependency_codes', to_jsonb(resource.dependency_codes),
      'compensation_strategy', resource.compensation_strategy
    )
    order by resource.execution_order
  )
  into v_resources
  from public.atlas_provisioning_resource_definitions as resource
  where resource.active = true;

  if jsonb_array_length(coalesce(v_resources, '[]'::jsonb)) <> 16 then
    raise exception using
      errcode = '55000',
      message = 'CANONICAL_PROVISIONING_RESOURCE_CATALOG_INCOMPLETE';
  end if;

  select coalesce(max(plan.plan_version), 0) + 1
  into v_plan_version
  from public.atlas_installation_provisioning_plans as plan
  where plan.installation_id = v_installation.id;

  v_plan_payload := jsonb_build_object(
    'schema_version', 'B2_PROVISIONING_PLAN_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'source_installation_version', v_installation.version,
    'source_manifest_id', v_manifest.id,
    'manifest_sha256', v_manifest.manifest_sha256,
    'canonical_data_version_id', v_canonical.id,
    'canonical_sha256', v_canonical.canonical_sha256,
    'package_id', v_package.id,
    'package_code', v_package.package_code,
    'package_version', v_package.version,
    'agent_identities', v_agent_identities,
    'agent_display_name_overrides', p_agent_display_name_overrides,
    'resources', v_resources
  );

  v_plan_sha256 := public.atlas_normalization_sha256(
    v_plan_payload::text
  );

  select plan.*
  into v_existing
  from public.atlas_installation_provisioning_plans as plan
  where plan.installation_id = v_installation.id
    and plan.plan_sha256 = v_plan_sha256
  order by plan.plan_version desc
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'PROVISIONING_PLAN_ALREADY_EXISTS_BY_HASH',
      'installation_id', v_existing.installation_id,
      'provisioning_plan_id', v_existing.id,
      'plan_version', v_existing.plan_version,
      'plan_status', v_existing.plan_status,
      'state_version', v_existing.state_version,
      'plan_sha256', v_existing.plan_sha256,
      'agent_identities', v_existing.plan_payload->'agent_identities',
      'step_count', (
        select count(*)
        from public.atlas_installation_provisioning_steps as step
        where step.provisioning_plan_id = v_existing.id
      )
    );
  end if;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active = true
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code =
     'INSTALLATION_PROVISIONING_MANAGE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PROVISIONING_ACTOR_ROLE_NOT_FOUND';
  end if;

  insert into public.atlas_installation_provisioning_plans (
    installation_id,
    empresa_id,
    source_manifest_id,
    canonical_data_version_id,
    package_id,
    package_version,
    plan_version,
    plan_status,
    state_version,
    plan_payload,
    plan_sha256,
    created_by_user_id,
    idempotency_key,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_manifest.id,
    v_canonical.id,
    v_package.id,
    v_package.version,
    v_plan_version,
    'PREFLIGHT_PENDING',
    1,
    v_plan_payload,
    v_plan_sha256,
    v_actor_user_id,
    p_request_id,
    p_metadata || jsonb_build_object(
      'generated_via',
        'atlas_generate_installation_provisioning_plan',
      'identity_contract_version', 'B2_AGENT_IDENTITY_V1'
    )
  )
  returning * into v_created;

  with step_source as (
    select
      resource.resource_code,
      resource.execution_order,
      resource.required_by_default,
      resource.operation_type,
      resource.target_kind,
      resource.resource_group,
      resource.dependency_codes,
      jsonb_build_object(
        'schema_version', 'B2_PROVISIONING_STEP_V1',
        'installation_id', v_installation.id,
        'empresa_id', v_installation.empresa_id,
        'resource_code', resource.resource_code,
        'source_manifest_id', v_manifest.id,
        'canonical_data_version_id', v_canonical.id,
        'package_id', v_package.id,
        'package_version', v_package.version,
        'agent_identities', case
          when resource.resource_group = 'AGENT'
            then v_agent_identities
          else '[]'::jsonb
        end
      ) as input_payload
    from public.atlas_provisioning_resource_definitions as resource
    where resource.active = true
  )
  insert into public.atlas_installation_provisioning_steps (
    installation_id,
    empresa_id,
    provisioning_plan_id,
    resource_code,
    step_code,
    step_order,
    required,
    step_status,
    state_version,
    operation_type,
    target_reference,
    input_payload,
    input_sha256,
    dependency_step_codes,
    idempotency_key,
    max_attempts,
    metadata
  )
  select
    v_installation.id,
    v_installation.empresa_id,
    v_created.id,
    step_source.resource_code,
    step_source.resource_code,
    step_source.execution_order,
    step_source.required_by_default,
    case
      when cardinality(step_source.dependency_codes) = 0
        then 'READY'
      else 'BLOCKED'
    end,
    1,
    step_source.operation_type,
    jsonb_build_object(
      'target_kind', step_source.target_kind,
      'empresa_id', v_installation.empresa_id,
      'technical_agent_codes', case
        when step_source.resource_group = 'AGENT'
          then (
            select jsonb_agg(identity_record.value->>'agent_code')
            from jsonb_array_elements(v_agent_identities)
              as identity_record(value)
          )
        else '[]'::jsonb
      end
    ),
    step_source.input_payload,
    public.atlas_normalization_sha256(
      step_source.input_payload::text
    ),
    step_source.dependency_codes,
    gen_random_uuid(),
    3,
    jsonb_build_object(
      'resource_group', step_source.resource_group,
      'plan_version', v_created.plan_version
    )
  from step_source
  order by step_source.execution_order;

  get diagnostics v_step_count = row_count;

  if v_step_count <> 16 then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_STEP_MATERIALIZATION_INCOMPLETE';
  end if;

  insert into public.atlas_installation_provisioning_events (
    installation_id,
    empresa_id,
    provisioning_plan_id,
    entity_type,
    entity_id,
    event_code,
    from_status,
    to_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    evidence,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_created.id,
    'PLAN',
    v_created.id,
    'PROVISIONING_PLAN_GENERATED',
    null,
    v_created.plan_status,
    v_actor_user_id,
    v_actor_role_code,
    'Plan generado desde fuentes aprobadas y catalogo canonico.',
    p_request_id,
    jsonb_build_object(
      'plan_sha256', v_created.plan_sha256,
      'source_manifest_id', v_manifest.id,
      'canonical_data_version_id', v_canonical.id,
      'step_count', v_step_count,
      'agent_identity_contract',
        'AGENT_CODE_STABLE_DISPLAY_NAME_CONFIGURABLE'
    ),
    '{}'::jsonb
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
    v_installation.empresa_id,
    v_actor_user_id,
    null,
    null,
    'INSTALLATION_PROVISIONING_PLAN_GENERATED',
    'B2_PROVISIONING_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'installation_id', v_installation.id,
      'request_id', p_request_id,
      'expected_installation_version',
        p_expected_installation_version,
      'overridden_agent_codes', (
        select coalesce(jsonb_agg(override_code), '[]'::jsonb)
        from jsonb_object_keys(p_agent_display_name_overrides)
          as override_keys(override_code)
      )
    ),
    jsonb_build_object(
      'provisioning_plan_id', v_created.id,
      'plan_version', v_created.plan_version,
      'plan_status', v_created.plan_status,
      'plan_sha256', v_created.plan_sha256,
      'step_count', v_step_count,
      'agent_identities', v_agent_identities
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'PROVISIONING_PLAN_GENERATED',
    'installation_id', v_created.installation_id,
    'provisioning_plan_id', v_created.id,
    'plan_version', v_created.plan_version,
    'plan_status', v_created.plan_status,
    'state_version', v_created.state_version,
    'plan_sha256', v_created.plan_sha256,
    'source_manifest_id', v_created.source_manifest_id,
    'canonical_data_version_id',
      v_created.canonical_data_version_id,
    'package_id', v_created.package_id,
    'package_version', v_created.package_version,
    'agent_identities', v_agent_identities,
    'step_count', v_step_count,
    'next_action', 'RUN_PROVISIONING_PREFLIGHT'
  );
end;
$$;

revoke all on function
public.atlas_generate_installation_provisioning_plan(
  uuid, jsonb, uuid, bigint, jsonb
)
  from public, anon, authenticated;
grant execute on function
public.atlas_generate_installation_provisioning_plan(
  uuid, jsonb, uuid, bigint, jsonb
)
  to authenticated, service_role;

comment on function
public.atlas_provisioning_agent_identities_are_valid(jsonb) is
  'B2: valida codigo tecnico estable y nombre visible configurable.';
comment on function
public.atlas_generate_installation_provisioning_plan(
  uuid, jsonb, uuid, bigint, jsonb
) is
  'B2: genera plan y pasos sin ejecutar preflight ni aprovisionar recursos.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2G2A_AGENT_IDENTITY_PLAN_GENERATION_INSTALLED',
  'next_block', 'B2.2G.2B_PREFLIGHT_EXECUTION_RPC',
  'plan_generation_rpc_enabled', true,
  'preflight_execution_rpc_enabled', false,
  'agent_identity_contract_version', 'B2_AGENT_IDENTITY_V1',
  'agent_code_stable', true,
  'display_name_configurable', true,
  'display_name_changes_process_keys', false,
  'canonical_resources', (
    select count(*)
    from public.atlas_provisioning_resource_definitions
    where active = true
  ),
  'provisioning_plans', (
    select count(*)
    from public.atlas_installation_provisioning_plans
  ),
  'provisioning_steps', (
    select count(*)
    from public.atlas_installation_provisioning_steps
  ),
  'provisioning_events', (
    select count(*)
    from public.atlas_installation_provisioning_events
  ),
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'direct_authenticated_write', false
) as result;
