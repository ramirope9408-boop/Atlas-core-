-- ATLAS B2.2L.5
-- Cierre de capa de activacion y continuidad integral del Motor B2.
-- Corte: 2026-09-06
--
-- Instala una proyeccion interna, segura y solo lectura. No ejecuta el
-- piloto, no crea evidencia ficticia y no cambia estados gobernados.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_compute_installation_post_activation_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_get_installation_post_activation_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_complete_installation_activation_handoff(uuid,text,text,text,uuid,bigint,jsonb)'
     ) is null then
    raise exception
      'B2.2L.5 requiere B2.2L.4 instalado y certificado';
  end if;

  if to_regprocedure(
       'public.atlas_compute_installation_engine_continuity(uuid)'
     ) is not null
     or to_regprocedure(
       'public.atlas_get_installation_engine_continuity(uuid)'
     ) is not null then
    raise exception
      'B2.2L.5 detecto RPC previas; reconciliar antes de instalar';
  end if;
end;
$$;

insert into public.atlas_internal_permissions(
  permission_code, description
)
values (
  'INSTALLATION_ENGINE_CONTINUITY_READ',
  'Consultar continuidad estructural y readiness del Motor B2.'
)
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions(
  role_code, permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_ENGINE_CONTINUITY_READ'),
  (
    'ATLAS_IMPLEMENTATION_OPERATOR',
    'INSTALLATION_ENGINE_CONTINUITY_READ'
  ),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_ENGINE_CONTINUITY_READ'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_ENGINE_CONTINUITY_READ'),
  ('ATLAS_SUPPORT_OPERATOR', 'INSTALLATION_ENGINE_CONTINUITY_READ')
on conflict (role_code, permission_code) do nothing;

create or replace function
public.atlas_compute_installation_engine_continuity(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_installation public.atlas_installations%rowtype;
  v_post_activation jsonb := '{}'::jsonb;
  v_expected_tables integer := 0;
  v_missing_tables integer := 0;
  v_expected_functions integer := 0;
  v_missing_functions integer := 0;
  v_expected_triggers integer := 0;
  v_missing_triggers integer := 0;
  v_rls_gaps integer := 0;
  v_read_policy_gaps integer := 0;
  v_direct_client_writes integer := 0;
  v_anonymous_table_grants integer := 0;
  v_insecure_definers integer := 0;
  v_catalogs_valid boolean := false;
  v_l_contracts_valid boolean := false;
  v_architecture_ready boolean := false;
  v_operationally_closed boolean := false;
  v_fingerprint_payload jsonb;
  v_architecture_sha256 text;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'engine_contract_version', 'B2_INSTALLATION_ENGINE_V1',
      'architecture_ready', false
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_NOT_FOUND',
      'engine_contract_version', 'B2_INSTALLATION_ENGINE_V1',
      'installation_id', p_installation_id,
      'architecture_ready', false
    );
  end if;

  with expected_tables(object_name) as (
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
  ), table_checks as (
    select
      expected.object_name,
      to_regclass(format('public.%I', expected.object_name))
        as relation_id
    from expected_tables as expected
  )
  select
    count(*)::integer,
    count(*) filter (
      where relation_id is null
    )::integer,
    count(*) filter (
      where relation_id is not null
        and not exists (
          select 1
          from pg_class as relation
          where relation.oid = relation_id
            and relation.relrowsecurity
        )
    )::integer,
    count(*) filter (
      where relation_id is not null
        and not exists (
          select 1
          from pg_policies as policy
          where policy.schemaname = 'public'
            and policy.tablename = table_checks.object_name
            and policy.cmd = 'SELECT'
        )
    )::integer
  into
    v_expected_tables,
    v_missing_tables,
    v_rls_gaps,
    v_read_policy_gaps
  from table_checks;

  with expected_functions(object_name) as (
    values
      ('atlas_create_installation'),
      ('atlas_transition_installation'),
      ('atlas_bootstrap_platform_owner'),
      ('atlas_platform_has_permission'),
      ('atlas_initialize_installation_gates'),
      ('atlas_decide_installation_gate'),
      ('atlas_block_unapproved_platform_control'),
      ('usuario_puede_acceder_storage'),
      ('atlas_register_installation_file'),
      ('atlas_record_installation_file_inspection'),
      ('atlas_decide_installation_file'),
      ('atlas_register_installation_manifest'),
      ('atlas_materialize_installation_inventory'),
      ('atlas_decide_conditional_requirement'),
      ('atlas_register_installation_contract'),
      ('atlas_review_installation_contract'),
      ('atlas_sign_installation_contract'),
      ('atlas_compute_installation_g01_readiness'),
      ('atlas_decide_g01_readiness_criterion'),
      ('atlas_create_normalization_batch'),
      ('atlas_register_normalized_record'),
      ('atlas_analyze_normalization_batch'),
      ('atlas_submit_normalization_for_client_review'),
      ('atlas_decide_normalized_record'),
      ('atlas_promote_normalization_batch'),
      ('atlas_compute_installation_g02_readiness'),
      ('atlas_generate_installation_provisioning_plan'),
      ('atlas_run_installation_provisioning_preflight'),
      ('atlas_begin_installation_provisioning_step'),
      ('atlas_complete_installation_provisioning_step'),
      ('atlas_finalize_installation_provisioning_plan'),
      ('atlas_request_installation_provisioning_rollback'),
      ('atlas_begin_installation_provisioning_compensation'),
      ('atlas_complete_installation_provisioning_compensation'),
      ('atlas_compute_installation_provisioning_rollback_readiness'),
      ('atlas_decide_installation_provisioning_rollback'),
      ('atlas_get_installation_provisioning_observability'),
      ('atlas_list_installation_provisioning_timeline'),
      ('atlas_list_installation_provisioned_resource_observability'),
      ('atlas_list_installation_provisioning_attempt_observability'),
      ('atlas_get_installation_provisioning_verification_evidence'),
      ('atlas_get_installation_certificate_readiness'),
      ('atlas_register_installation_integration'),
      ('atlas_configure_installation_integration_reference'),
      ('atlas_begin_installation_integration_validation'),
      ('atlas_complete_installation_integration_validation'),
      ('atlas_compute_installation_integration_readiness'),
      ('atlas_materialize_installation_test_plan'),
      ('atlas_start_installation_test_run'),
      ('atlas_begin_installation_test_case'),
      ('atlas_register_installation_test_case_result'),
      ('atlas_compute_installation_g03_readiness'),
      ('atlas_materialize_installation_acceptance_package'),
      ('atlas_submit_installation_acceptance_package'),
      ('atlas_register_installation_training_record'),
      ('atlas_complete_installation_training_record'),
      ('atlas_register_installation_exception'),
      ('atlas_resolve_installation_exception'),
      ('atlas_decide_installation_acceptance'),
      ('atlas_compute_installation_g04_readiness'),
      ('atlas_issue_installation_certificate'),
      ('atlas_verify_installation_certificate'),
      ('atlas_revoke_installation_certificate'),
      ('atlas_get_installation_certificate_safe_projection'),
      ('atlas_list_installation_certificate_history'),
      ('atlas_request_installation_certificate_regeneration'),
      ('atlas_decide_installation_certificate_regeneration'),
      ('atlas_prepare_installation_certificate_render_manifest'),
      ('atlas_execute_installation_certificate_regeneration'),
      ('atlas_verify_installation_certificate_history_integrity'),
      ('atlas_activation_evidence_reference_is_safe'),
      ('atlas_block_activation_append_only_mutation'),
      ('atlas_activation_platform_role_for_permission'),
      ('atlas_compute_installation_activation_readiness'),
      ('atlas_get_installation_activation_readiness'),
      ('atlas_authorize_installation_activation'),
      ('atlas_enforce_activation_execution_context'),
      ('atlas_compute_installation_activation_closure_integrity'),
      ('atlas_get_installation_activation_closure'),
      ('atlas_execute_installation_activation'),
      ('atlas_compute_installation_post_activation_readiness'),
      ('atlas_get_installation_post_activation_readiness'),
      ('atlas_complete_installation_activation_handoff'),
      ('atlas_compute_installation_engine_continuity'),
      ('atlas_get_installation_engine_continuity')
  )
  select
    count(*)::integer,
    count(*) filter (
      where not exists (
        select 1
        from pg_proc as procedure_record
        join pg_namespace as namespace
          on namespace.oid = procedure_record.pronamespace
        where namespace.nspname = 'public'
          and procedure_record.proname =
            expected_functions.object_name
      )
    )::integer
  into v_expected_functions, v_missing_functions
  from expected_functions;

  with expected_triggers(object_name) as (
    values
      ('trg_atlas_installation_state_events_append_only'),
      ('trg_atlas_installation_approvals_append_only'),
      ('trg_atlas_installations_platform_control_guard'),
      ('trg_atlas_platform_control_decisions_append_only'),
      ('trg_atlas_installation_file_events_append_only'),
      ('trg_atlas_installation_file_inspections_append_only'),
      ('trg_atlas_installation_file_decisions_append_only'),
      ('trg_atlas_installations_security_file_completion'),
      ('trg_atlas_manifest_events_append_only'),
      ('trg_atlas_inventory_events_append_only'),
      ('trg_atlas_diagnostic_decisions_append_only'),
      ('trg_atlas_contract_events_append_only'),
      ('trg_atlas_legal_readiness_decisions_append_only'),
      ('trg_atlas_g01_approval_readiness'),
      ('trg_atlas_installations_g01_transition_readiness'),
      ('trg_atlas_normalization_events_append_only'),
      ('trg_atlas_norm_review_decisions_append_only'),
      ('trg_atlas_canonical_data_versions_append_only'),
      ('trg_atlas_g02_approval_readiness'),
      ('trg_atlas_provisioning_events_append_only'),
      ('trg_atlas_preflight_results_append_only'),
      ('trg_atlas_provisioning_receipts_append_only'),
      ('trg_atlas_provisioned_resource_identity'),
      ('trg_atlas_integration_events_append_only'),
      ('trg_atlas_integration_validation_append_only'),
      ('trg_atlas_integration_testing_entry_readiness'),
      ('trg_atlas_test_events_append_only'),
      ('trg_atlas_test_results_append_only'),
      ('trg_atlas_g03_approval_readiness'),
      ('trg_atlas_installations_g03_transition_readiness'),
      ('trg_atlas_acceptance_decisions_append_only'),
      ('trg_atlas_acceptance_events_append_only'),
      ('trg_atlas_g04_approval_readiness'),
      ('trg_atlas_certificates_append_only'),
      ('trg_atlas_certificate_sources_append_only'),
      ('trg_atlas_certificate_events_append_only'),
      ('trg_atlas_certificate_regeneration_requests_append_only'),
      ('trg_atlas_certificate_regeneration_decisions_append_only'),
      ('trg_atlas_certificate_render_manifests_append_only'),
      ('trg_atlas_activation_authorizations_append_only'),
      ('trg_atlas_activation_closures_append_only'),
      ('trg_atlas_activation_events_append_only'),
      ('trg_atlas_installations_g04_active_readiness'),
      ('trg_atlas_activation_execution_context')
  )
  select
    count(*)::integer,
    count(*) filter (
      where not exists (
        select 1
        from pg_trigger as trigger_record
        join pg_class as relation
          on relation.oid = trigger_record.tgrelid
        join pg_namespace as namespace
          on namespace.oid = relation.relnamespace
        where namespace.nspname = 'public'
          and trigger_record.tgname = expected_triggers.object_name
          and not trigger_record.tgisinternal
          and trigger_record.tgenabled <> 'D'
      )
    )::integer
  into v_expected_triggers, v_missing_triggers
  from expected_triggers;

  with expected_tables(object_name) as (
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
  select
    count(*) filter (
      where grant_record.grantee in ('anon', 'authenticated')
        and grant_record.privilege_type in (
          'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'TRIGGER'
        )
    )::integer,
    count(*) filter (
      where grant_record.grantee = 'anon'
    )::integer
  into v_direct_client_writes, v_anonymous_table_grants
  from information_schema.role_table_grants as grant_record
  join expected_tables as expected
    on expected.object_name = grant_record.table_name
  where grant_record.table_schema = 'public';

  with expected_functions(object_name) as (
    values
      ('atlas_create_installation'),
      ('atlas_transition_installation'),
      ('atlas_bootstrap_platform_owner'),
      ('atlas_platform_has_permission'),
      ('atlas_initialize_installation_gates'),
      ('atlas_decide_installation_gate'),
      ('atlas_block_unapproved_platform_control'),
      ('usuario_puede_acceder_storage'),
      ('atlas_register_installation_file'),
      ('atlas_record_installation_file_inspection'),
      ('atlas_decide_installation_file'),
      ('atlas_register_installation_manifest'),
      ('atlas_materialize_installation_inventory'),
      ('atlas_decide_conditional_requirement'),
      ('atlas_register_installation_contract'),
      ('atlas_review_installation_contract'),
      ('atlas_sign_installation_contract'),
      ('atlas_compute_installation_g01_readiness'),
      ('atlas_decide_g01_readiness_criterion'),
      ('atlas_create_normalization_batch'),
      ('atlas_register_normalized_record'),
      ('atlas_analyze_normalization_batch'),
      ('atlas_submit_normalization_for_client_review'),
      ('atlas_decide_normalized_record'),
      ('atlas_promote_normalization_batch'),
      ('atlas_compute_installation_g02_readiness'),
      ('atlas_generate_installation_provisioning_plan'),
      ('atlas_run_installation_provisioning_preflight'),
      ('atlas_begin_installation_provisioning_step'),
      ('atlas_complete_installation_provisioning_step'),
      ('atlas_finalize_installation_provisioning_plan'),
      ('atlas_request_installation_provisioning_rollback'),
      ('atlas_begin_installation_provisioning_compensation'),
      ('atlas_complete_installation_provisioning_compensation'),
      ('atlas_compute_installation_provisioning_rollback_readiness'),
      ('atlas_decide_installation_provisioning_rollback'),
      ('atlas_get_installation_provisioning_observability'),
      ('atlas_list_installation_provisioning_timeline'),
      ('atlas_list_installation_provisioned_resource_observability'),
      ('atlas_list_installation_provisioning_attempt_observability'),
      ('atlas_get_installation_provisioning_verification_evidence'),
      ('atlas_get_installation_certificate_readiness'),
      ('atlas_register_installation_integration'),
      ('atlas_configure_installation_integration_reference'),
      ('atlas_begin_installation_integration_validation'),
      ('atlas_complete_installation_integration_validation'),
      ('atlas_compute_installation_integration_readiness'),
      ('atlas_materialize_installation_test_plan'),
      ('atlas_start_installation_test_run'),
      ('atlas_begin_installation_test_case'),
      ('atlas_register_installation_test_case_result'),
      ('atlas_compute_installation_g03_readiness'),
      ('atlas_materialize_installation_acceptance_package'),
      ('atlas_submit_installation_acceptance_package'),
      ('atlas_register_installation_training_record'),
      ('atlas_complete_installation_training_record'),
      ('atlas_register_installation_exception'),
      ('atlas_resolve_installation_exception'),
      ('atlas_decide_installation_acceptance'),
      ('atlas_compute_installation_g04_readiness'),
      ('atlas_issue_installation_certificate'),
      ('atlas_verify_installation_certificate'),
      ('atlas_revoke_installation_certificate'),
      ('atlas_get_installation_certificate_safe_projection'),
      ('atlas_list_installation_certificate_history'),
      ('atlas_request_installation_certificate_regeneration'),
      ('atlas_decide_installation_certificate_regeneration'),
      ('atlas_prepare_installation_certificate_render_manifest'),
      ('atlas_execute_installation_certificate_regeneration'),
      ('atlas_verify_installation_certificate_history_integrity'),
      ('atlas_activation_evidence_reference_is_safe'),
      ('atlas_block_activation_append_only_mutation'),
      ('atlas_activation_platform_role_for_permission'),
      ('atlas_compute_installation_activation_readiness'),
      ('atlas_get_installation_activation_readiness'),
      ('atlas_authorize_installation_activation'),
      ('atlas_enforce_activation_execution_context'),
      ('atlas_compute_installation_activation_closure_integrity'),
      ('atlas_get_installation_activation_closure'),
      ('atlas_execute_installation_activation'),
      ('atlas_compute_installation_post_activation_readiness'),
      ('atlas_get_installation_post_activation_readiness'),
      ('atlas_complete_installation_activation_handoff'),
      ('atlas_compute_installation_engine_continuity'),
      ('atlas_get_installation_engine_continuity')
  )
  select count(distinct procedure_record.oid)::integer
  into v_insecure_definers
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  join expected_functions as expected
    on expected.object_name = procedure_record.proname
  where namespace.nspname = 'public'
    and procedure_record.prosecdef
    and not exists (
      select 1
      from unnest(
        coalesce(procedure_record.proconfig, array[]::text[])
      ) as setting
      where setting like 'search_path=%'
    );

  select
    (select count(*) from public.atlas_installation_states) = 18
    and (
      select count(*)
      from public.atlas_installation_state_transitions
    ) = 51
    and (
      select count(*)
      from public.atlas_installation_gate_definitions
      where active
    ) = 4
    and (
      select count(*)
      from public.atlas_installation_file_inspection_types
      where active
    ) = 7
    and (
      select count(*)
      from public.atlas_installation_inventory_definitions
      where active
    ) = 37
    and (
      select count(*)
      from public.atlas_legal_document_definitions
      where active
    ) = 15
    and (
      select count(*)
      from public.atlas_normalization_issue_definitions
      where active
    ) = 7
    and (
      select count(*)
      from public.atlas_provisioning_resource_definitions
      where active
    ) = 16
    and (
      select count(*)
      from public.atlas_provisioning_preflight_definitions
      where active
    ) = 14
    and (
      select count(*)
      from public.atlas_integration_adapter_definitions
    ) = 8
    and (
      select count(*)
      from public.atlas_integration_adapter_definitions
      where active
    ) = 6
    and (
      select count(*)
      from public.atlas_installation_test_definitions
      where active
    ) = 18
    and (
      select count(*)
      from public.atlas_installation_acceptance_requirement_definitions
      where active
    ) = 8
    and (
      select count(*)
      from public.atlas_installation_certificate_contracts
      where active
    ) = 1
    and (
      select count(*)
      from public.atlas_installation_certificate_render_contracts
      where active
    ) = 1
    and (
      select count(*)
      from public.atlas_installation_activation_requirement_definitions
      where active and blocking
    ) = 8
  into v_catalogs_valid;

  select
    exists (
      select 1
      from public.atlas_internal_permissions as permission
      where permission.permission_code =
        'INSTALLATION_ACTIVATION_AUTHORIZE'
    )
    and exists (
      select 1
      from public.atlas_internal_permissions as permission
      where permission.permission_code =
        'INSTALLATION_ACTIVATION_EXECUTE'
    )
    and exists (
      select 1
      from public.atlas_internal_permissions as permission
      where permission.permission_code =
        'INSTALLATION_ACTIVATION_HANDOFF'
    )
    and exists (
      select 1
      from public.atlas_internal_permissions as permission
      where permission.permission_code =
        'INSTALLATION_ENGINE_CONTINUITY_READ'
    )
    and (
      select count(*)
      from public.atlas_internal_role_permissions as mapping
      where mapping.permission_code =
        'INSTALLATION_ACTIVATION_AUTHORIZE'
    ) = 1
    and (
      select count(*)
      from public.atlas_internal_role_permissions as mapping
      where mapping.permission_code =
        'INSTALLATION_ACTIVATION_EXECUTE'
    ) = 2
    and (
      select count(*)
      from public.atlas_internal_role_permissions as mapping
      where mapping.permission_code =
        'INSTALLATION_ACTIVATION_HANDOFF'
    ) = 3
    and (
      select count(*)
      from public.atlas_internal_role_permissions as mapping
      where mapping.permission_code =
        'INSTALLATION_ENGINE_CONTINUITY_READ'
    ) = 5
    and exists (
      select 1
      from pg_indexes as index_record
      where index_record.schemaname = 'public'
        and index_record.tablename =
          'atlas_installation_activation_events'
        and index_record.indexname =
          'uq_atlas_activation_one_observation_completion'
        and index_record.indexdef ilike '%unique%'
    )
  into v_l_contracts_valid;

  v_post_activation :=
    public.atlas_compute_installation_post_activation_readiness(
      v_installation.id
    );

  v_architecture_ready :=
    v_expected_tables = 71
    and v_missing_tables = 0
    and v_expected_functions = 85
    and v_missing_functions = 0
    and v_expected_triggers = 44
    and v_missing_triggers = 0
    and v_rls_gaps = 0
    and v_read_policy_gaps = 0
    and v_direct_client_writes = 0
    and v_anonymous_table_grants = 0
    and v_insecure_definers = 0
    and v_catalogs_valid
    and v_l_contracts_valid;

  v_operationally_closed :=
    coalesce(
      (v_post_activation->>'handoff_completed')::boolean,
      false
    )
    and v_installation.current_state_code = 'ACTIVE';

  v_fingerprint_payload := jsonb_build_object(
    'engine_contract_version', 'B2_INSTALLATION_ENGINE_V1',
    'expected_tables', v_expected_tables,
    'expected_function_markers', v_expected_functions,
    'expected_critical_triggers', v_expected_triggers,
    'catalogs_valid', v_catalogs_valid,
    'activation_layer_contracts_valid', v_l_contracts_valid,
    'direct_client_write_grants', v_direct_client_writes,
    'anonymous_table_grants', v_anonymous_table_grants,
    'insecure_security_definers', v_insecure_definers
  );
  v_architecture_sha256 := public.atlas_normalization_sha256(
    v_fingerprint_payload::text
  );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when not v_architecture_ready
        then 'INSTALLATION_ENGINE_CONTINUITY_FAILED'
      when v_operationally_closed
        then 'INSTALLATION_ENGINE_OPERATIONAL_HANDOFF_COMPLETE'
      else 'INSTALLATION_ENGINE_READY_FOR_CONTROLLED_PILOT'
    end,
    'engine_contract_version', 'B2_INSTALLATION_ENGINE_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'architecture_ready', v_architecture_ready,
    'operational_handoff_complete', v_operationally_closed,
    'expected_tables', v_expected_tables,
    'missing_tables', v_missing_tables,
    'expected_function_markers', v_expected_functions,
    'missing_function_markers', v_missing_functions,
    'expected_critical_triggers', v_expected_triggers,
    'missing_critical_triggers', v_missing_triggers,
    'rls_gaps', v_rls_gaps,
    'read_policy_gaps', v_read_policy_gaps,
    'direct_client_write_grants', v_direct_client_writes,
    'anonymous_table_grants', v_anonymous_table_grants,
    'insecure_security_definers', v_insecure_definers,
    'catalogs_valid', v_catalogs_valid,
    'activation_layer_contracts_valid', v_l_contracts_valid,
    'architecture_sha256', v_architecture_sha256,
    'pilot_execution_pending',
      not v_operationally_closed,
    'raw_payloads_exposed', false,
    'raw_error_messages_exposed', false,
    'credential_values_exposed', false,
    'actor_identities_exposed', false,
    'next_action', case
      when not v_architecture_ready
        then 'RECONCILE_B2_ARCHITECTURE'
      when v_operationally_closed
        then 'BEGIN_OPERATIONAL_MONITORING'
      else 'BEGIN_CONTROLLED_PILOT_EXECUTION'
    end
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_engine_continuity(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_engine_continuity(uuid)
to service_role;

create or replace function
public.atlas_get_installation_engine_continuity(
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
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_platform_has_permission(
       'INSTALLATION_ENGINE_CONTINUITY_READ'
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ENGINE_CONTINUITY_READ_FORBIDDEN';
  end if;

  return public.atlas_compute_installation_engine_continuity(
    p_installation_id
  );
end;
$$;

revoke all on function
public.atlas_get_installation_engine_continuity(uuid)
from public, anon;
grant execute on function
public.atlas_get_installation_engine_continuity(uuid)
to authenticated, service_role;

comment on function
public.atlas_get_installation_engine_continuity(uuid) is
  'B2: proyeccion interna segura de continuidad estructural y readiness para ejecucion controlada.';

commit;

select continuity as result
from (
  select public.atlas_compute_installation_engine_continuity(
    installation.id
  ) || jsonb_build_object(
    'code',
      'B2_2L5_ACTIVATION_LAYER_END_TO_END_CONTINUITY_INSTALLED',
    'next_block',
      'B2.3_CONTROLLED_PILOT_EXECUTION_AND_OPERATIONAL_VALIDATION',
    'activation_layer_closed', true,
    'engine_architecture_closed', true,
    'controlled_pilot_execution_enabled', false,
    'current_installation_state', installation.current_state_code,
    'current_installation_version', installation.version
  ) as continuity
  from public.atlas_installations as installation
  order by installation.created_at asc, installation.id asc
  limit 1
) as installed;
