-- ATLAS B2.2G.2B
-- Ejecucion gobernada de las verificaciones preflight.
-- Corte: 2026-08-30
--
-- Este bloque instala capacidad, no crea planes ni ejecuta preflight.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_preflight_results'
     ) is null
     or to_regclass(
       'public.atlas_installation_provisioning_plans'
     ) is null
     or to_regprocedure(
       'public.atlas_generate_installation_provisioning_plan(uuid,jsonb,uuid,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_provisioning_agent_identities_are_valid(jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_g02_readiness(uuid)'
     ) is null then
    raise exception 'B2.2G.2B requiere B2.2G.2A instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_run_installation_provisioning_preflight(
  p_provisioning_plan_id uuid,
  p_request_id uuid,
  p_expected_plan_state_version bigint,
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
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_manifest public.atlas_installation_manifests%rowtype;
  v_canonical public.atlas_canonical_data_versions%rowtype;
  v_package public.atlas_agent_packages%rowtype;
  v_existing_event public.atlas_installation_provisioning_events%rowtype;
  v_definition record;
  v_readiness jsonb;
  v_passed boolean;
  v_reason_code text;
  v_evaluation_version integer;
  v_new_plan_state_version bigint;
  v_new_plan_status text;
  v_passed_count integer := 0;
  v_failed_count integer := 0;
  v_required_count integer := 0;
  v_result_count integer := 0;
  v_step_count integer := 0;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PREFLIGHT_EXECUTE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PREFLIGHT_EXECUTE_FORBIDDEN';
  end if;

  if p_provisioning_plan_id is null
     or p_request_id is null
     or p_expected_plan_state_version is null
     or p_expected_plan_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PREFLIGHT_REQUIRED_FIELDS_INVALID';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = p_provisioning_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <> 'PROVISIONING_PREFLIGHT_COMPLETED'
       or coalesce(
         (v_existing_event.evidence->>'expected_plan_state_version')::bigint,
         0
       ) <> p_expected_plan_state_version
       or coalesce(
         (v_existing_event.evidence->>'expected_installation_version')::bigint,
         0
       ) <> p_expected_installation_version then
      raise exception using
        errcode = '22023',
        message =
          'PROVISIONING_PREFLIGHT_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    select
      count(*) filter (where result_record.outcome = 'PASSED'),
      count(*) filter (where result_record.outcome = 'FAILED'),
      count(*)
    into v_passed_count, v_failed_count, v_result_count
    from public.atlas_installation_preflight_results as result_record
    where result_record.provisioning_plan_id = v_plan.id
      and result_record.request_id = p_request_id;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_plan.installation_id,
      'provisioning_plan_id', v_plan.id,
      'plan_status', v_existing_event.to_status,
      'state_version', coalesce(
        (
          v_existing_event.evidence->>
            'resulting_plan_state_version'
        )::bigint,
        v_plan.state_version
      ),
      'passed_checks', v_passed_count,
      'failed_checks', v_failed_count,
      'result_count', v_result_count,
      'ready_for_provisioning',
        v_existing_event.to_status = 'PREFLIGHT_PASSED'
    );
  end if;

  if v_plan.state_version <> p_expected_plan_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  if v_plan.plan_status not in (
    'PREFLIGHT_PENDING', 'PREFLIGHT_FAILED'
  ) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_NOT_PREFLIGHT_EXECUTABLE';
  end if;

  if v_plan.plan_sha256 <>
     public.atlas_normalization_sha256(v_plan.plan_payload::text) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_HASH_MISMATCH';
  end if;

  if not public.atlas_provisioning_agent_identities_are_valid(
    v_plan.plan_payload->'agent_identities'
  ) then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_AGENT_IDENTITIES_INVALID';
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
      errcode = '40001',
      message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_plan.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_EMPRESA_MISMATCH';
  end if;

  select manifest.*
  into v_manifest
  from public.atlas_installation_manifests as manifest
  where manifest.id = v_plan.source_manifest_id
    and manifest.installation_id = v_installation.id
    and manifest.empresa_id = v_installation.empresa_id;

  select canonical.*
  into v_canonical
  from public.atlas_canonical_data_versions as canonical
  where canonical.id = v_plan.canonical_data_version_id
    and canonical.installation_id = v_installation.id
    and canonical.empresa_id = v_installation.empresa_id;

  select package.*
  into v_package
  from public.atlas_agent_packages as package
  where package.id = v_plan.package_id;

  v_readiness := public.atlas_compute_installation_g02_readiness(
    v_installation.id
  );

  select count(*)
  into v_step_count
  from public.atlas_installation_provisioning_steps as step
  where step.provisioning_plan_id = v_plan.id;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active = true
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code =
     'INSTALLATION_PREFLIGHT_EXECUTE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PREFLIGHT_ACTOR_ROLE_NOT_FOUND';
  end if;

  v_new_plan_state_version := v_plan.state_version + 1;

  for v_definition in
    select definition.*
    from public.atlas_provisioning_preflight_definitions as definition
    where definition.active = true
    order by definition.execution_order
  loop
    v_passed := false;
    v_reason_code := v_definition.check_code || '_FAILED';

    case v_definition.check_code
      when 'INSTALLATION_STATE_DATA_APPROVED' then
        v_passed :=
          v_installation.current_state_code = 'DATA_APPROVED'
          and coalesce(
            (v_plan.plan_payload->>'source_installation_version')::bigint,
            0
          ) = v_installation.version;
        v_reason_code := case when v_passed
          then 'INSTALLATION_STATE_AND_VERSION_CURRENT'
          else 'INSTALLATION_STATE_OR_VERSION_STALE'
        end;

      when 'G02_GATE_APPROVED' then
        v_passed :=
          coalesce((v_readiness->>'ready')::boolean, false)
          and (v_readiness->>'canonical_data_version_id')
            is not distinct from v_plan.canonical_data_version_id::text
          and exists (
            select 1
            from public.atlas_installation_gates as gate_record
            where gate_record.installation_id = v_installation.id
              and gate_record.gate_code = 'G02'
              and gate_record.status = 'APPROVED'
              and gate_record.client_approved = true
          );
        v_reason_code := case when v_passed
          then 'G02_CURRENT_AND_APPROVED'
          else 'G02_STALE_OR_INCOMPLETE'
        end;

      when 'CLIENT_OWNER_ACTIVE' then
        v_passed :=
          v_installation.client_owner_user_id is not null
          and exists (
            select 1
            from public.atlas_internal_memberships as membership
            where membership.empresa_id = v_installation.empresa_id
              and membership.user_id =
                v_installation.client_owner_user_id
              and membership.role_code = 'OWNER'
              and membership.status = 'ACTIVE'
          );
        v_reason_code := case when v_passed
          then 'CLIENT_OWNER_ACTIVE_AND_MATCHED'
          else 'CLIENT_OWNER_MISSING_OR_INACTIVE'
        end;

      when 'CURRENT_MANIFEST_VALID' then
        v_passed :=
          v_manifest.id is not null
          and v_manifest.manifest_status in ('VALIDATED', 'APPROVED')
          and public.atlas_manifest_payload_is_valid(
            v_manifest.manifest_payload
          )
          and v_manifest.manifest_payload->>'installation_id' =
            v_installation.id::text
          and v_manifest.manifest_payload->>'package_id' =
            v_plan.package_id::text
          and not exists (
            select 1
            from public.atlas_installation_manifests as newer_manifest
            where newer_manifest.installation_id = v_installation.id
              and newer_manifest.manifest_status in (
                'VALIDATED', 'APPROVED'
              )
              and (
                newer_manifest.package_version >
                  v_manifest.package_version
                or (
                  newer_manifest.package_version =
                    v_manifest.package_version
                  and newer_manifest.created_at > v_manifest.created_at
                )
              )
          );
        v_reason_code := case when v_passed
          then 'CURRENT_VALIDATED_MANIFEST_PRESENT'
          else 'MANIFEST_MISSING_STALE_OR_INVALID'
        end;

      when 'CURRENT_CANONICAL_VERSION_VALID' then
        v_passed :=
          v_canonical.id is not null
          and v_canonical.version_status = 'APPROVED'
          and v_canonical.source_manifest_id = v_manifest.id
          and v_canonical.canonical_sha256 =
            public.atlas_normalization_sha256(
              v_canonical.canonical_payload::text
            )
          and not exists (
            select 1
            from public.atlas_canonical_data_versions as newer_canonical
            where newer_canonical.installation_id = v_installation.id
              and newer_canonical.canonical_version >
                v_canonical.canonical_version
          );
        v_reason_code := case when v_passed
          then 'CURRENT_CANONICAL_VERSION_HASH_VALID'
          else 'CANONICAL_VERSION_MISSING_STALE_OR_INVALID'
        end;

      when 'CONDITIONAL_INVENTORY_RESOLVED' then
        v_passed := not exists (
          select 1
          from public.atlas_installation_inventory_requirements
            as requirement
          where requirement.installation_id = v_installation.id
            and requirement.requirement_mode = 'CONDITIONAL'
        );
        v_reason_code := case when v_passed
          then 'NO_CONDITIONAL_REQUIREMENT_PENDING'
          else 'CONDITIONAL_REQUIREMENT_PENDING'
        end;

      when 'AGENT_PACKAGE_ACTIVE' then
        v_passed :=
          v_package.id is not null
          and v_package.status = 'ACTIVE'
          and v_package.version = v_plan.package_version
          and v_package.id = v_manifest.package_id
          and v_plan.plan_payload->>'package_code' =
            v_package.package_code;
        v_reason_code := case when v_passed
          then 'AGENT_PACKAGE_ACTIVE_AND_MATCHED'
          else 'AGENT_PACKAGE_MISSING_INACTIVE_OR_MISMATCHED'
        end;

      when 'PACKAGE_COMPONENTS_READY' then
        v_passed :=
          exists (
            select 1
            from public.atlas_agent_package_components as component
            where component.package_id = v_plan.package_id
              and component.active = true
              and component.required = true
          )
          and not exists (
            select 1
            from public.atlas_agent_package_components as component
            where component.package_id = v_plan.package_id
              and component.active = true
              and component.required = true
              and component.implementation_status <> 'READY'
          );
        v_reason_code := case when v_passed
          then 'REQUIRED_PACKAGE_COMPONENTS_READY'
          else 'REQUIRED_PACKAGE_COMPONENT_MISSING_OR_NOT_READY'
        end;

      when 'TENANT_IDENTITY_UNAMBIGUOUS' then
        v_passed :=
          v_installation.empresa_id is not null
          and v_plan.empresa_id = v_installation.empresa_id
          and v_manifest.empresa_id = v_installation.empresa_id
          and v_canonical.empresa_id = v_installation.empresa_id
          and exists (
            select 1
            from public.empresas as empresa
            where empresa.id = v_installation.empresa_id
          )
          and btrim(
            v_manifest.manifest_payload->'company'->>'legal_name'
          ) = btrim(v_installation.company_legal_name);
        v_reason_code := case when v_passed
          then 'TENANT_IDENTITY_SOURCES_MATCH'
          else 'TENANT_IDENTITY_COLLISION_OR_MISMATCH'
        end;

      when 'STORAGE_AUTHORITY_READY' then
        v_passed :=
          exists (
            select 1
            from public.atlas_installation_files as source_file
            join storage.buckets as bucket
              on bucket.id = source_file.storage_bucket
             and bucket.public = false
            join storage.objects as storage_object
              on storage_object.bucket_id = source_file.storage_bucket
             and storage_object.name = source_file.storage_object_path
             and storage_object.archived_at is null
             and storage_object.is_delete_marker = false
            where source_file.id = v_manifest.source_file_id
              and source_file.installation_id = v_installation.id
              and source_file.empresa_id = v_installation.empresa_id
              and source_file.validation_status = 'ACCEPTED'
              and source_file.storage_bucket = 'atlas-private'
              and split_part(
                source_file.storage_object_path, '/', 1
              ) = v_installation.empresa_id::text
          )
          and not exists (
            select 1
            from pg_policies
            where schemaname = 'storage'
              and tablename = 'objects'
              and cmd = 'DELETE'
              and 'authenticated' = any(roles)
          );
        v_reason_code := case when v_passed
          then 'PRIVATE_STORAGE_AUTHORITY_READY'
          else 'PRIVATE_STORAGE_OBJECT_OR_AUTHORITY_INVALID'
        end;

      when 'NO_EMBEDDED_SECRETS' then
        v_passed :=
          not public.atlas_jsonb_has_forbidden_secret_key(
            v_manifest.manifest_payload
          )
          and not public.atlas_jsonb_has_forbidden_secret_key(
            v_canonical.canonical_payload
          )
          and not public.atlas_jsonb_has_forbidden_secret_key(
            v_plan.plan_payload
          )
          and not exists (
            select 1
            from public.atlas_installation_provisioning_steps as step
            where step.provisioning_plan_id = v_plan.id
              and (
                public.atlas_jsonb_has_forbidden_secret_key(
                  step.target_reference
                )
                or public.atlas_jsonb_has_forbidden_secret_key(
                  step.input_payload
                )
              )
          );
        v_reason_code := case when v_passed
          then 'NO_FORBIDDEN_SECRET_KEY_FOUND'
          else 'FORBIDDEN_SECRET_KEY_FOUND'
        end;

      when 'NO_ACTIVE_PROVISIONING_PLAN' then
        v_passed := not exists (
          select 1
          from public.atlas_installation_provisioning_plans
            as other_plan
          where other_plan.installation_id = v_installation.id
            and other_plan.id <> v_plan.id
            and other_plan.plan_status in (
              'DRAFT', 'PREFLIGHT_PENDING', 'PREFLIGHT_FAILED',
              'PREFLIGHT_PASSED', 'EXECUTING', 'ROLLBACK_REQUIRED'
            )
        );
        v_reason_code := case when v_passed
          then 'NO_CONFLICTING_ACTIVE_PLAN'
          else 'CONFLICTING_ACTIVE_PLAN_FOUND'
        end;

      when 'IDEMPOTENCY_CONTRACT_READY' then
        v_passed :=
          v_step_count = jsonb_array_length(
            v_plan.plan_payload->'resources'
          )
          and v_step_count > 0
          and (
            select count(distinct step.idempotency_key)
            from public.atlas_installation_provisioning_steps as step
            where step.provisioning_plan_id = v_plan.id
          ) = v_step_count
          and (
            select count(distinct step.step_code)
            from public.atlas_installation_provisioning_steps as step
            where step.provisioning_plan_id = v_plan.id
          ) = v_step_count
          and not exists (
            select 1
            from public.atlas_installation_provisioning_steps as step
            where step.provisioning_plan_id = v_plan.id
              and step.input_sha256 <>
                public.atlas_normalization_sha256(
                  step.input_payload::text
                )
          );
        v_reason_code := case when v_passed
          then 'IDEMPOTENCY_KEYS_AND_HASHES_COMPLETE'
          else 'IDEMPOTENCY_KEY_STEP_OR_HASH_INVALID'
        end;

      when 'ROLLBACK_STRATEGIES_READY' then
        v_passed :=
          v_step_count > 0
          and not exists (
            select 1
            from public.atlas_installation_provisioning_steps as step
            left join public.atlas_provisioning_resource_definitions
              as resource
              on resource.resource_code = step.resource_code
             and resource.active = true
            where step.provisioning_plan_id = v_plan.id
              and (
                resource.resource_code is null
                or resource.operation_type <> step.operation_type
                or nullif(
                  btrim(resource.compensation_strategy), ''
                ) is null
                or exists (
                  select 1
                  from unnest(step.dependency_step_codes)
                    as dependency(step_code)
                  where not exists (
                    select 1
                    from public.atlas_installation_provisioning_steps
                      as dependency_step
                    where dependency_step.provisioning_plan_id = v_plan.id
                      and dependency_step.step_code = dependency.step_code
                  )
                )
              )
          );
        v_reason_code := case when v_passed
          then 'COMPENSATION_AND_DEPENDENCIES_COMPLETE'
          else 'COMPENSATION_OR_DEPENDENCY_INCOMPLETE'
        end;

      else
        v_passed := false;
        v_reason_code := 'UNKNOWN_PREFLIGHT_CHECK_CODE';
    end case;

    select coalesce(max(result_record.evaluation_version), 0) + 1
    into v_evaluation_version
    from public.atlas_installation_preflight_results as result_record
    where result_record.provisioning_plan_id = v_plan.id
      and result_record.check_code = v_definition.check_code;

    insert into public.atlas_installation_preflight_results (
      installation_id,
      empresa_id,
      provisioning_plan_id,
      check_code,
      evaluation_version,
      evaluated_plan_state_version,
      outcome,
      severity,
      evaluator_user_id,
      evaluator_role_code,
      request_id,
      evidence,
      details
    )
    values (
      v_installation.id,
      v_installation.empresa_id,
      v_plan.id,
      v_definition.check_code,
      v_evaluation_version,
      v_new_plan_state_version,
      case when v_passed then 'PASSED' else 'FAILED' end,
      v_definition.severity,
      v_actor_user_id,
      v_actor_role_code,
      p_request_id,
      jsonb_build_object(
        'evidence_reference', format(
          'B2_G2_PREFLIGHT:%s:%s:%s',
          v_plan.id,
          v_definition.check_code,
          v_evaluation_version
        ),
        'assertion_code',
          v_definition.evaluation_contract->>'assertion_code',
        'evaluated_at', now()
      ),
      jsonb_build_object(
        'passed', v_passed,
        'reason_code', v_reason_code,
        'required', v_definition.required,
        'plan_sha256', v_plan.plan_sha256,
        'source_installation_version',
          v_plan.plan_payload->'source_installation_version',
        'current_installation_version', v_installation.version
      )
    );

    v_result_count := v_result_count + 1;

    if v_passed then
      v_passed_count := v_passed_count + 1;
    else
      v_failed_count := v_failed_count + 1;
    end if;
  end loop;

  select count(*)
  into v_required_count
  from public.atlas_provisioning_preflight_definitions as definition
  where definition.active = true
    and definition.required = true;

  if v_result_count <> 14
     or v_required_count <> 14
     or v_passed_count + v_failed_count <> v_result_count then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_PREFLIGHT_RESULT_SET_INCOMPLETE';
  end if;

  v_new_plan_status := case
    when v_failed_count = 0 then 'PREFLIGHT_PASSED'
    else 'PREFLIGHT_FAILED'
  end;

  update public.atlas_installation_provisioning_plans
  set
    plan_status = v_new_plan_status,
    state_version = v_new_plan_state_version,
    metadata = metadata || jsonb_build_object(
      'last_preflight_request_id', p_request_id,
      'last_preflight_at', now(),
      'last_preflight_passed_checks', v_passed_count,
      'last_preflight_failed_checks', v_failed_count
    ),
    updated_at = now()
  where id = v_plan.id
    and state_version = p_expected_plan_state_version;

  if not found then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
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
    v_plan.id,
    'PREFLIGHT',
    v_plan.id,
    'PROVISIONING_PREFLIGHT_COMPLETED',
    v_plan.plan_status,
    v_new_plan_status,
    v_actor_user_id,
    v_actor_role_code,
    'Preflight ejecutado contra fuentes, autoridad y plan vigentes.',
    p_request_id,
    jsonb_build_object(
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'resulting_plan_state_version',
        v_new_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'result_count', v_result_count,
      'passed_checks', v_passed_count,
      'failed_checks', v_failed_count,
      'plan_sha256', v_plan.plan_sha256
    ),
    p_metadata
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
    'INSTALLATION_PROVISIONING_PREFLIGHT_EXECUTED',
    'B2_PROVISIONING_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'provisioning_plan_id', v_plan.id,
      'request_id', p_request_id,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version
    ),
    jsonb_build_object(
      'plan_status', v_new_plan_status,
      'resulting_plan_state_version',
        v_new_plan_state_version,
      'result_count', v_result_count,
      'passed_checks', v_passed_count,
      'failed_checks', v_failed_count,
      'ready_for_provisioning', v_failed_count = 0
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_failed_count = 0
        then 'PROVISIONING_PREFLIGHT_PASSED'
      else 'PROVISIONING_PREFLIGHT_FAILED'
    end,
    'installation_id', v_installation.id,
    'provisioning_plan_id', v_plan.id,
    'plan_status', v_new_plan_status,
    'state_version', v_new_plan_state_version,
    'result_count', v_result_count,
    'passed_checks', v_passed_count,
    'failed_checks', v_failed_count,
    'ready_for_provisioning', v_failed_count = 0,
    'next_action', case
      when v_failed_count = 0 then 'START_PROVISIONING'
      else 'REMEDIATE_AND_RERUN_PREFLIGHT'
    end
  );
end;
$$;

revoke all on function
public.atlas_run_installation_provisioning_preflight(
  uuid, uuid, bigint, bigint, jsonb
)
  from public, anon, authenticated;
grant execute on function
public.atlas_run_installation_provisioning_preflight(
  uuid, uuid, bigint, bigint, jsonb
)
  to authenticated, service_role;

comment on function
public.atlas_run_installation_provisioning_preflight(
  uuid, uuid, bigint, bigint, jsonb
) is
  'B2: evalua 14 controles, registra resultados append-only y versiona el plan.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2G2B_PREFLIGHT_EXECUTION_RPC_INSTALLED',
  'next_action', 'CERTIFY_G2B_PREFLIGHT_RPC_GUARDS',
  'preflight_execution_rpc_enabled', true,
  'preflight_definition_count', (
    select count(*)
    from public.atlas_provisioning_preflight_definitions
    where active = true
  ),
  'required_preflight_count', (
    select count(*)
    from public.atlas_provisioning_preflight_definitions
    where active = true
      and required = true
  ),
  'preflight_results', (
    select count(*)
    from public.atlas_installation_preflight_results
  ),
  'provisioning_plans', (
    select count(*)
    from public.atlas_installation_provisioning_plans
  ),
  'provisioning_events', (
    select count(*)
    from public.atlas_installation_provisioning_events
  ),
  'optimistic_concurrency_enabled', true,
  'request_idempotency_enabled', true,
  'plan_hash_revalidation_enabled', true,
  'g02_revalidation_enabled', true,
  'append_only_results_enabled', true,
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
