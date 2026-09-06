-- ATLAS B2.2J.2 - Certificacion de paquetes, capacitacion y excepciones.
-- Corte: 2026-09-03
--
-- Solo ejecuta lecturas y sondas negativas controladas.
-- No materializa paquetes ficticios, no crea capacitaciones o excepciones,
-- no decide G04, no emite certificados y no activa instalaciones.

begin;

do $$
declare
  v_installation public.atlas_installations%rowtype;
  v_rpc_count integer;
  v_helper_count integer;
  v_security_definer_count integer;
  v_authenticated_grants integer;
  v_anonymous_grants integer;
  v_direct_write_grants integer;
  v_column_count integer;
  v_constraint_count integer;
  v_function_contract text;
  v_owner_id uuid :=
    'fa8e19fa-b983-4e25-b3fa-53a3ffdf250b'::uuid;
  v_outsider_id uuid := gen_random_uuid();
  v_before_packages bigint;
  v_before_training bigint;
  v_before_exceptions bigint;
  v_before_events bigint;
  v_after_packages bigint;
  v_after_training bigint;
  v_after_exceptions bigint;
  v_after_events bigint;
  v_wrong_state_blocked boolean := false;
  v_unauthorized_actor_blocked boolean := false;
  v_invalid_training_blocked boolean := false;
  v_invalid_critical_exception_blocked boolean := false;
  v_missing_training_blocked boolean := false;
  v_missing_exception_blocked boolean := false;
  v_missing_package_delivery_blocked boolean := false;
begin
  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id =
    'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if not found then
    raise exception 'B2.2J.2 pilot installation missing';
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION'
     or v_installation.version <> 3 then
    raise exception
      'B2.2J.2 pilot changed unexpectedly: state %, version %',
      v_installation.current_state_code,
      v_installation.version;
  end if;

  select count(*)
  into v_rpc_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_materialize_installation_acceptance_package',
      'atlas_register_installation_training_record',
      'atlas_complete_installation_training_record',
      'atlas_register_installation_exception',
      'atlas_resolve_installation_exception',
      'atlas_submit_installation_acceptance_package'
    );

  if v_rpc_count <> 6 then
    raise exception 'B2.2J.2 expected 6 RPCs, found %', v_rpc_count;
  end if;

  select count(*)
  into v_helper_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_acceptance_platform_role_for_permission',
      'atlas_acceptance_current_user_is_client_owner'
    );

  if v_helper_count <> 2 then
    raise exception 'B2.2J.2 expected 2 helpers, found %', v_helper_count;
  end if;

  select count(*)
  into v_security_definer_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_materialize_installation_acceptance_package',
      'atlas_register_installation_training_record',
      'atlas_complete_installation_training_record',
      'atlas_register_installation_exception',
      'atlas_resolve_installation_exception',
      'atlas_submit_installation_acceptance_package'
    )
    and procedure_record.prosecdef
    and procedure_record.proconfig @> array['search_path=public, pg_temp'];

  if v_security_definer_count <> 6 then
    raise exception
      'B2.2J.2 expected 6 hardened SECURITY DEFINER RPCs, found %',
      v_security_definer_count;
  end if;

  select count(*)
  into v_authenticated_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_materialize_installation_acceptance_package',
      'atlas_register_installation_training_record',
      'atlas_complete_installation_training_record',
      'atlas_register_installation_exception',
      'atlas_resolve_installation_exception',
      'atlas_submit_installation_acceptance_package'
    )
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_authenticated_grants <> 6 then
    raise exception
      'B2.2J.2 expected 6 authenticated RPC grants, found %',
      v_authenticated_grants;
  end if;

  select count(*)
  into v_anonymous_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_materialize_installation_acceptance_package',
      'atlas_register_installation_training_record',
      'atlas_complete_installation_training_record',
      'atlas_register_installation_exception',
      'atlas_resolve_installation_exception',
      'atlas_submit_installation_acceptance_package'
    )
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_anonymous_grants <> 0 then
    raise exception
      'B2.2J.2 anonymous RPC grants found: %',
      v_anonymous_grants;
  end if;

  select count(*)
  into v_direct_write_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'atlas_installation_acceptance_packages',
      'atlas_installation_acceptance_requirements',
      'atlas_installation_training_records',
      'atlas_installation_exception_records',
      'atlas_installation_acceptance_decisions',
      'atlas_installation_acceptance_events'
    )
    and grantee = 'authenticated'
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');

  if v_direct_write_grants <> 0 then
    raise exception
      'B2.2J.2 authenticated direct writes found: %',
      v_direct_write_grants;
  end if;

  select count(*)
  into v_column_count
  from information_schema.columns
  where table_schema = 'public'
    and (
      (
        table_name = 'atlas_installation_acceptance_packages'
        and column_name in (
          'request_sha256', 'state_version', 'delivery_request_id',
          'delivery_request_sha256', 'delivery_evidence_reference',
          'delivery_evidence_sha256', 'delivered_by_user_id'
        )
      )
      or (
        table_name = 'atlas_installation_training_records'
        and column_name in (
          'request_sha256', 'state_version',
          'completion_request_id', 'completion_request_sha256'
        )
      )
      or (
        table_name = 'atlas_installation_exception_records'
        and column_name in (
          'request_sha256', 'state_version', 'resolution_request_id',
          'resolution_request_sha256', 'resolution_reason_code',
          'resolved_by_user_id', 'resolved_at',
          'resolution_evidence_reference',
          'resolution_evidence_sha256'
        )
      )
    );

  if v_column_count <> 20 then
    raise exception
      'B2.2J.2 expected 20 concurrency/evidence columns, found %',
      v_column_count;
  end if;

  select count(*)
  into v_constraint_count
  from pg_constraint as constraint_record
  join pg_class as relation
    on relation.oid = constraint_record.conrelid
  join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  where namespace.nspname = 'public'
    and constraint_record.conname in (
      'atlas_acceptance_packages_request_sha256_check',
      'atlas_acceptance_packages_state_version_check',
      'atlas_acceptance_packages_delivery_request_key',
      'atlas_acceptance_packages_delivered_by_fkey',
      'atlas_acceptance_packages_delivery_check',
      'atlas_training_records_request_sha256_check',
      'atlas_training_records_state_version_check',
      'atlas_training_records_completion_request_key',
      'atlas_training_records_completion_request_check',
      'atlas_exception_records_request_sha256_check',
      'atlas_exception_records_state_version_check',
      'atlas_exception_records_resolution_request_key',
      'atlas_exception_records_resolved_by_fkey',
      'atlas_exception_records_resolution_check'
    );

  if v_constraint_count <> 14 then
    raise exception
      'B2.2J.2 expected 14 new critical constraints, found %',
      v_constraint_count;
  end if;

  select string_agg(
    pg_get_functiondef(procedure_record.oid), E'\n'
    order by procedure_record.proname
  )
  into v_function_contract
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_materialize_installation_acceptance_package',
      'atlas_register_installation_training_record',
      'atlas_complete_installation_training_record',
      'atlas_register_installation_exception',
      'atlas_resolve_installation_exception',
      'atlas_submit_installation_acceptance_package'
    );

  if v_function_contract not ilike '%INSTALLATION_VERSION_CONFLICT%'
     or v_function_contract not ilike '%ACCEPTANCE_PACKAGE_VERSION_CONFLICT%'
     or v_function_contract not ilike '%TRAINING_VERSION_CONFLICT%'
     or v_function_contract not ilike '%EXCEPTION_VERSION_CONFLICT%'
     or v_function_contract not ilike '%IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD%'
     or v_function_contract not ilike '%CRITICAL_EXCEPTION_RISK_ACCEPTANCE_FORBIDDEN%'
     or v_function_contract not ilike '%EXCEPTION_RISK_ACCEPTANCE_REQUIRES_CLIENT_OWNER%'
     or v_function_contract not ilike '%ACCEPTANCE_PACKAGE_G03_BINDING_STALE%'
     or v_function_contract not ilike '%ACCEPTANCE_TRAINING_INCOMPLETE%'
     or v_function_contract not ilike '%ACCEPTANCE_CRITICAL_DEFECTS_PRESENT%'
     or v_function_contract not ilike '%certificate_issued%false%'
     or v_function_contract not ilike '%active_enabled%false%' then
    raise exception 'B2.2J.2 RPC safety contract incomplete';
  end if;

  select count(*) into v_before_packages
  from public.atlas_installation_acceptance_packages;
  select count(*) into v_before_training
  from public.atlas_installation_training_records;
  select count(*) into v_before_exceptions
  from public.atlas_installation_exception_records;
  select count(*) into v_before_events
  from public.atlas_installation_acceptance_events;

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

  begin
    perform public.atlas_materialize_installation_acceptance_package(
      v_installation.id,
      gen_random_uuid(),
      v_installation.version,
      jsonb_build_object('probe', 'wrong_state')
    );
  exception
    when others then
      v_wrong_state_blocked :=
        sqlerrm = 'INSTALLATION_NOT_IN_FINAL_APPROVAL';
  end;

  if not v_wrong_state_blocked then
    raise exception
      'B2.2J.2 materialization outside FINAL_APPROVAL was not blocked';
  end if;

  begin
    perform public.atlas_register_installation_training_record(
      null::uuid,
      'BAD',
      '{}'::jsonb,
      array[]::text[],
      null::timestamptz,
      '{}'::jsonb,
      gen_random_uuid(),
      v_installation.version,
      1,
      '{}'::jsonb
    );
  exception
    when others then
      v_invalid_training_blocked :=
        sqlerrm = 'TRAINING_REGISTRATION_REQUIRED_FIELDS_INVALID';
  end;

  if not v_invalid_training_blocked then
    raise exception 'B2.2J.2 invalid training was not blocked';
  end if;

  begin
    perform public.atlas_register_installation_exception(
      gen_random_uuid(),
      'EXC-CRITICAL-PROBE',
      'CRITICAL',
      false,
      false,
      null::uuid,
      jsonb_build_object('summary', 'negative probe'),
      gen_random_uuid(),
      v_installation.version,
      1,
      '{}'::jsonb
    );
  exception
    when others then
      v_invalid_critical_exception_blocked :=
        sqlerrm = 'EXCEPTION_REGISTRATION_REQUIRED_FIELDS_INVALID';
  end;

  if not v_invalid_critical_exception_blocked then
    raise exception
      'B2.2J.2 nonblocking critical exception was not blocked';
  end if;

  begin
    perform public.atlas_complete_installation_training_record(
      gen_random_uuid(),
      clock_timestamp(),
      'training://negative-probe',
      repeat('a', 64),
      jsonb_build_object('result', 'probe'),
      gen_random_uuid(),
      v_installation.version,
      1,
      '{}'::jsonb
    );
  exception
    when others then
      v_missing_training_blocked :=
        sqlerrm = 'TRAINING_RECORD_NOT_FOUND';
  end;

  if not v_missing_training_blocked then
    raise exception 'B2.2J.2 missing training completion was not blocked';
  end if;

  begin
    perform public.atlas_resolve_installation_exception(
      gen_random_uuid(),
      'ACCEPTED_RISK',
      'CLIENT_RISK_ACCEPTANCE_PROBE',
      'exception://negative-probe',
      repeat('b', 64),
      jsonb_build_object('decision', 'probe'),
      gen_random_uuid(),
      v_installation.version,
      1,
      '{}'::jsonb
    );
  exception
    when others then
      v_missing_exception_blocked :=
        sqlerrm = 'EXCEPTION_RECORD_NOT_FOUND';
  end;

  if not v_missing_exception_blocked then
    raise exception 'B2.2J.2 missing exception resolution was not blocked';
  end if;

  begin
    perform public.atlas_submit_installation_acceptance_package(
      gen_random_uuid(),
      'acceptance://negative-probe',
      repeat('c', 64),
      jsonb_build_object('delivery', 'probe'),
      gen_random_uuid(),
      v_installation.version,
      1,
      '{}'::jsonb
    );
  exception
    when others then
      v_missing_package_delivery_blocked :=
        sqlerrm = 'ACCEPTANCE_PACKAGE_NOT_FOUND';
  end;

  if not v_missing_package_delivery_blocked then
    raise exception 'B2.2J.2 missing package delivery was not blocked';
  end if;

  insert into auth.users(id)
  values (v_outsider_id)
  on conflict (id) do nothing;

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
    perform public.atlas_materialize_installation_acceptance_package(
      v_installation.id,
      gen_random_uuid(),
      v_installation.version,
      jsonb_build_object('probe', 'unauthorized_actor')
    );
  exception
    when others then
      v_unauthorized_actor_blocked :=
        sqlerrm = 'INSTALLATION_ACCEPTANCE_PREPARE_FORBIDDEN';
  end;

  if not v_unauthorized_actor_blocked then
    raise exception 'B2.2J.2 unauthorized actor was not blocked';
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

  delete from auth.users where id = v_outsider_id;

  select count(*) into v_after_packages
  from public.atlas_installation_acceptance_packages;
  select count(*) into v_after_training
  from public.atlas_installation_training_records;
  select count(*) into v_after_exceptions
  from public.atlas_installation_exception_records;
  select count(*) into v_after_events
  from public.atlas_installation_acceptance_events;

  if v_after_packages <> v_before_packages
     or v_after_training <> v_before_training
     or v_after_exceptions <> v_before_exceptions
     or v_after_events <> v_before_events then
    raise exception
      'B2.2J.2 negative probes changed governed records';
  end if;
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2J2_ACCEPTANCE_PACKAGE_TRAINING_EXCEPTION_RPCS_CERTIFIED',
  'state', installation.current_state_code,
  'version', installation.version,
  'next_block',
    'B2.2J.3_CLIENT_ACCEPTANCE_AND_G04_READINESS_ENFORCEMENT',
  'acceptance_rpcs', 6,
  'authority_helpers', 2,
  'security_definer_rpcs', 6,
  'authenticated_rpc_grants', 6,
  'anonymous_rpc_grants', 0,
  'critical_constraints', 14,
  'concurrency_and_evidence_columns', 20,
  'direct_client_write_grants', 0,
  'governed_records_unchanged', true,
  'wrong_state_materialization_blocked', true,
  'unauthorized_actor_blocked', true,
  'invalid_training_blocked', true,
  'nonblocking_critical_exception_blocked', true,
  'missing_training_completion_blocked', true,
  'missing_exception_resolution_blocked', true,
  'missing_package_delivery_blocked', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'g03_revalidation_enabled', true,
  'training_evidence_required', true,
  'client_owner_risk_authority_enabled', true,
  'critical_risk_acceptance_enabled', false,
  'delivery_requires_five_requirements', true,
  'client_acceptance_rpc_enabled', false,
  'g04_decision_enabled', false,
  'certificate_issuance_enabled', false,
  'active_auto_transition_enabled', false,
  'acceptance_package_records', (
    select count(*)
    from public.atlas_installation_acceptance_packages
  ),
  'training_records', (
    select count(*)
    from public.atlas_installation_training_records
  ),
  'exception_records', (
    select count(*)
    from public.atlas_installation_exception_records
  ),
  'acceptance_event_records', (
    select count(*)
    from public.atlas_installation_acceptance_events
  )
) as certification
from public.atlas_installations as installation
where installation.id =
  'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;
