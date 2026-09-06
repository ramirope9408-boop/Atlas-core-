-- ATLAS B2.2L.5
-- Certificacion del cierre de activacion y continuidad integral B2.
-- Corte: 2026-09-06
--
-- Solo inspecciona arquitectura y ejecuta sondas negativas. No activa el
-- piloto, no crea evidencia y no modifica registros gobernados.

begin;

do $$
declare
  v_installation public.atlas_installations%rowtype;
  v_owner_id uuid :=
    'fa8e19fa-b983-4e25-b3fa-53a3ffdf250b'::uuid;
  v_outsider_id uuid := gen_random_uuid();
  v_continuity jsonb;
  v_public_continuity jsonb;
  v_missing_projection jsonb;
  v_null_projection jsonb;
  v_function_count integer;
  v_security_definer_count integer;
  v_stable_function_count integer;
  v_authenticated_grants integer;
  v_anonymous_grants integer;
  v_permission_roles integer;
  v_direct_write_grants integer;
  v_compute_definition text;
  v_get_definition text;
  v_before_authorizations bigint;
  v_before_closures bigint;
  v_before_activation_events bigint;
  v_before_state_events bigint;
  v_before_audit bigint;
  v_after_authorizations bigint;
  v_after_closures bigint;
  v_after_activation_events bigint;
  v_after_state_events bigint;
  v_after_audit bigint;
  v_unauthorized_read_blocked boolean := false;
begin
  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id =
    'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if not found then
    raise exception 'B2.2L.5 pilot installation missing';
  end if;

  if v_installation.empresa_id <>
       'bf55a6aa-2e3f-4749-b2b8-135537a7c7bf'::uuid
     or v_installation.current_state_code <> 'SECURITY_VALIDATION'
     or v_installation.version <> 3 then
    raise exception
      'B2.2L.5 pilot changed unexpectedly';
  end if;

  select count(*)::integer
  into v_function_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_compute_installation_engine_continuity',
      'atlas_get_installation_engine_continuity'
    );

  if v_function_count <> 2 then
    raise exception
      'B2.2L.5 expected two functions, found %',
      v_function_count;
  end if;

  select count(*)::integer
  into v_security_definer_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_compute_installation_engine_continuity',
      'atlas_get_installation_engine_continuity'
    )
    and procedure_record.prosecdef
    and procedure_record.proconfig @> array[
      'search_path=public, pg_temp'
    ];

  if v_security_definer_count <> 2 then
    raise exception
      'B2.2L.5 hardened SECURITY DEFINER contract incomplete: %',
      v_security_definer_count;
  end if;

  select count(*)::integer
  into v_stable_function_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_compute_installation_engine_continuity',
      'atlas_get_installation_engine_continuity'
    )
    and procedure_record.provolatile = 's';

  if v_stable_function_count <> 2 then
    raise exception
      'B2.2L.5 stable read functions incomplete: %',
      v_stable_function_count;
  end if;

  select count(*)::integer
  into v_authenticated_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name =
      'atlas_get_installation_engine_continuity'
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_authenticated_grants <> 1 then
    raise exception
      'B2.2L.5 expected one authenticated RPC grant, found %',
      v_authenticated_grants;
  end if;

  select count(*)::integer
  into v_anonymous_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_compute_installation_engine_continuity',
      'atlas_get_installation_engine_continuity'
    )
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_anonymous_grants <> 0 then
    raise exception
      'B2.2L.5 anonymous function grants found: %',
      v_anonymous_grants;
  end if;

  select count(*)::integer
  into v_permission_roles
  from public.atlas_internal_role_permissions as mapping
  where mapping.permission_code =
    'INSTALLATION_ENGINE_CONTINUITY_READ';

  if v_permission_roles <> 5
     or exists (
       select 1
       from public.atlas_internal_role_permissions as mapping
       where mapping.permission_code =
           'INSTALLATION_ENGINE_CONTINUITY_READ'
         and mapping.role_code not in (
           'ATLAS_OWNER',
           'ATLAS_IMPLEMENTATION_OPERATOR',
           'ATLAS_SECURITY_REVIEWER',
           'ATLAS_LEGAL_REVIEWER',
           'ATLAS_SUPPORT_OPERATOR'
         )
     ) then
    raise exception
      'B2.2L.5 continuity authority mapping invalid';
  end if;

  with governed_tables(table_name) as (
    values
      ('atlas_installation_states'),
      ('atlas_installation_state_transitions'),
      ('atlas_installations'),
      ('atlas_installation_state_events'),
      ('atlas_platform_memberships'),
      ('atlas_installation_gate_definitions'),
      ('atlas_installation_gates'),
      ('atlas_installation_approvals'),
      ('atlas_installation_platform_control_decisions'),
      ('atlas_installation_file_type_policies'),
      ('atlas_installation_retention_policies'),
      ('atlas_installation_file_rejection_reasons'),
      ('atlas_installation_files'),
      ('atlas_installation_file_events'),
      ('atlas_installation_file_inspection_types'),
      ('atlas_installation_file_inspections'),
      ('atlas_installation_file_decisions'),
      ('atlas_installation_inventory_definitions'),
      ('atlas_installation_manifests'),
      ('atlas_installation_manifest_events'),
      ('atlas_installation_inventory_requirements'),
      ('atlas_installation_inventory_events'),
      ('atlas_installation_diagnostic_decisions'),
      ('atlas_legal_document_definitions'),
      ('atlas_installation_contracts'),
      ('atlas_installation_contract_events'),
      ('atlas_installation_legal_readiness_decisions'),
      ('atlas_normalization_issue_definitions'),
      ('atlas_normalization_batches'),
      ('atlas_normalized_records'),
      ('atlas_normalization_issues'),
      ('atlas_normalization_events'),
      ('atlas_normalization_review_decisions'),
      ('atlas_canonical_data_versions'),
      ('atlas_provisioning_resource_definitions'),
      ('atlas_provisioning_preflight_definitions'),
      ('atlas_installation_provisioning_plans'),
      ('atlas_installation_provisioning_steps'),
      ('atlas_installation_preflight_results'),
      ('atlas_installation_provisioning_events'),
      ('atlas_provisioned_resources'),
      ('atlas_provisioning_operation_receipts'),
      ('atlas_integration_adapter_definitions'),
      ('atlas_installation_integrations'),
      ('atlas_installation_integration_events'),
      ('atlas_installation_integration_validation_results'),
      ('atlas_installation_test_definitions'),
      ('atlas_installation_test_plans'),
      ('atlas_installation_test_plan_cases'),
      ('atlas_installation_test_runs'),
      ('atlas_installation_test_results'),
      ('atlas_installation_test_events'),
      ('atlas_installation_acceptance_requirement_definitions'),
      ('atlas_installation_acceptance_packages'),
      ('atlas_installation_acceptance_requirements'),
      ('atlas_installation_training_records'),
      ('atlas_installation_exception_records'),
      ('atlas_installation_acceptance_decisions'),
      ('atlas_installation_acceptance_events'),
      ('atlas_installation_certificate_contracts'),
      ('atlas_installation_certificates'),
      ('atlas_installation_certificate_sources'),
      ('atlas_installation_certificate_events'),
      ('atlas_installation_certificate_render_contracts'),
      ('atlas_installation_certificate_regeneration_requests'),
      ('atlas_installation_certificate_regeneration_decisions'),
      ('atlas_installation_certificate_render_manifests'),
      ('atlas_installation_activation_requirement_definitions'),
      ('atlas_installation_activation_authorizations'),
      ('atlas_installation_activation_closures'),
      ('atlas_installation_activation_events')
  )
  select count(*)::integer
  into v_direct_write_grants
  from information_schema.role_table_grants as grant_record
  join governed_tables as governed
    on governed.table_name = grant_record.table_name
  where grant_record.table_schema = 'public'
    and grant_record.grantee in ('anon', 'authenticated')
    and grant_record.privilege_type in (
      'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'TRIGGER'
    );

  if v_direct_write_grants <> 0 then
    raise exception
      'B2.2L.5 direct client writes found: %',
      v_direct_write_grants;
  end if;

  select pg_get_functiondef(procedure_record.oid)
  into v_compute_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_compute_installation_engine_continuity';

  select pg_get_functiondef(procedure_record.oid)
  into v_get_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_get_installation_engine_continuity';

  if v_compute_definition is null
     or v_compute_definition not ilike
       '%B2_INSTALLATION_ENGINE_V1%'
     or v_compute_definition not ilike '%expected_tables%'
     or v_compute_definition not ilike '%expected_functions%'
     or v_compute_definition not ilike '%expected_triggers%'
     or v_compute_definition not ilike '%relrowsecurity%'
     or v_compute_definition not ilike '%pg_policies%'
     or v_compute_definition not ilike
       '%uq_atlas_activation_one_observation_completion%'
     or v_compute_definition ilike '%insert into%'
     or v_compute_definition ilike '%update public.%'
     or v_compute_definition ilike '%delete from%'
     or v_get_definition is null
     or v_get_definition not ilike
       '%INSTALLATION_ENGINE_CONTINUITY_READ_FORBIDDEN%'
     or v_get_definition ilike '%insert into%'
     or v_get_definition ilike '%update public.%'
     or v_get_definition ilike '%delete from%' then
    raise exception
      'B2.2L.5 read-only continuity boundary invalid';
  end if;

  select count(*) into v_before_authorizations
  from public.atlas_installation_activation_authorizations;
  select count(*) into v_before_closures
  from public.atlas_installation_activation_closures;
  select count(*) into v_before_activation_events
  from public.atlas_installation_activation_events;
  select count(*) into v_before_state_events
  from public.atlas_installation_state_events;
  select count(*) into v_before_audit
  from public.atlas_internal_audit_log;

  v_continuity :=
    public.atlas_compute_installation_engine_continuity(
      v_installation.id
    );

  if not coalesce((v_continuity->>'ok')::boolean, false)
     or v_continuity->>'code' <>
       'INSTALLATION_ENGINE_READY_FOR_CONTROLLED_PILOT'
     or v_continuity->>'engine_contract_version' <>
       'B2_INSTALLATION_ENGINE_V1'
     or not coalesce(
       (v_continuity->>'architecture_ready')::boolean,
       false
     )
     or coalesce(
       (v_continuity->>'operational_handoff_complete')::boolean,
       true
     )
     or (v_continuity->>'expected_tables')::integer <> 71
     or (v_continuity->>'missing_tables')::integer <> 0
     or (v_continuity->>'expected_function_markers')::integer <> 85
     or (v_continuity->>'missing_function_markers')::integer <> 0
     or (v_continuity->>'expected_critical_triggers')::integer <> 44
     or (v_continuity->>'missing_critical_triggers')::integer <> 0
     or (v_continuity->>'rls_gaps')::integer <> 0
     or (v_continuity->>'read_policy_gaps')::integer <> 0
     or (v_continuity->>'direct_client_write_grants')::integer <> 0
     or (v_continuity->>'anonymous_table_grants')::integer <> 0
     or (v_continuity->>'insecure_security_definers')::integer <> 0
     or not coalesce(
       (v_continuity->>'catalogs_valid')::boolean,
       false
     )
     or not coalesce(
       (v_continuity->>'activation_layer_contracts_valid')::boolean,
       false
     )
     or v_continuity->>'architecture_sha256' !~ '^[0-9a-f]{64}$'
     or not coalesce(
       (v_continuity->>'pilot_execution_pending')::boolean,
       false
     )
     or v_continuity->>'next_action' <>
       'BEGIN_CONTROLLED_PILOT_EXECUTION'
     or coalesce(
       (v_continuity->>'raw_payloads_exposed')::boolean,
       true
     )
     or coalesce(
       (v_continuity->>'raw_error_messages_exposed')::boolean,
       true
     )
     or coalesce(
       (v_continuity->>'credential_values_exposed')::boolean,
       true
     )
     or coalesce(
       (v_continuity->>'actor_identities_exposed')::boolean,
       true
     ) then
    raise exception
      'B2.2L.5 continuity projection invalid: %',
      v_continuity;
  end if;

  v_null_projection :=
    public.atlas_compute_installation_engine_continuity(null::uuid);
  v_missing_projection :=
    public.atlas_compute_installation_engine_continuity(
      gen_random_uuid()
    );

  if v_null_projection->>'code' <> 'INSTALLATION_ID_REQUIRED'
     or v_missing_projection->>'code' <> 'INSTALLATION_NOT_FOUND'
     or coalesce(
       (v_null_projection->>'architecture_ready')::boolean,
       true
     )
     or coalesce(
       (v_missing_projection->>'architecture_ready')::boolean,
       true
     ) then
    raise exception
      'B2.2L.5 missing-installation projections invalid';
  end if;

  perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_owner_id,
      'role', 'authenticated'
    )::text,
    true
  );

  v_public_continuity :=
    public.atlas_get_installation_engine_continuity(
      v_installation.id
    );

  if v_public_continuity->>'architecture_sha256' <>
       v_continuity->>'architecture_sha256'
     or v_public_continuity->>'code' <>
       'INSTALLATION_ENGINE_READY_FOR_CONTROLLED_PILOT' then
    raise exception
      'B2.2L.5 public continuity projection diverged';
  end if;

  perform set_config('request.jwt.claim.sub', v_outsider_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_outsider_id,
      'role', 'authenticated'
    )::text,
    true
  );

  begin
    perform public.atlas_get_installation_engine_continuity(
      v_installation.id
    );
  exception
    when others then
      v_unauthorized_read_blocked :=
        sqlerrm = 'INSTALLATION_ENGINE_CONTINUITY_READ_FORBIDDEN';
  end;

  if not v_unauthorized_read_blocked then
    raise exception
      'B2.2L.5 unauthorized continuity read was not blocked';
  end if;

  perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_owner_id,
      'role', 'authenticated'
    )::text,
    true
  );

  select count(*) into v_after_authorizations
  from public.atlas_installation_activation_authorizations;
  select count(*) into v_after_closures
  from public.atlas_installation_activation_closures;
  select count(*) into v_after_activation_events
  from public.atlas_installation_activation_events;
  select count(*) into v_after_state_events
  from public.atlas_installation_state_events;
  select count(*) into v_after_audit
  from public.atlas_internal_audit_log;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id =
    'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if v_after_authorizations <> v_before_authorizations
     or v_after_closures <> v_before_closures
     or v_after_activation_events <> v_before_activation_events
     or v_after_state_events <> v_before_state_events
     or v_after_audit <> v_before_audit
     or v_installation.current_state_code <> 'SECURITY_VALIDATION'
     or v_installation.version <> 3 then
    raise exception
      'B2.2L.5 certification changed governed records';
  end if;
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2L5_ACTIVATION_LAYER_END_TO_END_CONTINUITY_CERTIFIED',
  'state', installation.current_state_code,
  'version', installation.version,
  'next_block',
    'B2.3_CONTROLLED_PILOT_EXECUTION_AND_OPERATIONAL_VALIDATION',
  'engine_contract_version', 'B2_INSTALLATION_ENGINE_V1',
  'engine_architecture_closed', true,
  'activation_layer_closed', true,
  'architecture_ready_for_controlled_pilot', true,
  'controlled_pilot_executed', false,
  'continuity_read_rpcs', 1,
  'internal_continuity_helpers', 1,
  'stable_read_functions', 2,
  'security_definer_functions', 2,
  'authenticated_read_grants', 1,
  'anonymous_function_grants', 0,
  'continuity_permission_roles', 5,
  'expected_tables', 71,
  'missing_tables', 0,
  'expected_function_markers', 85,
  'missing_function_markers', 0,
  'expected_critical_triggers', 44,
  'missing_critical_triggers', 0,
  'rls_gaps', 0,
  'read_policy_gaps', 0,
  'direct_client_write_grants', 0,
  'anonymous_table_grants', 0,
  'insecure_security_definers', 0,
  'catalogs_valid', true,
  'activation_layer_contracts_valid', true,
  'safe_projection_enabled', true,
  'raw_payloads_exposed', false,
  'raw_error_messages_exposed', false,
  'credential_values_exposed', false,
  'actor_identities_exposed', false,
  'governed_records_unchanged', true,
  'pilot_execution_pending', true
) as certification
from public.atlas_installations as installation
where installation.id =
  'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;
