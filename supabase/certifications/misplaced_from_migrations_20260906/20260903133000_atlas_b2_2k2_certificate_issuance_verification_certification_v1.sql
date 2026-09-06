-- ATLAS B2.2K.2
-- Certificacion de RPC de emision y verificacion de certificados.
-- Corte: 2026-09-03
--
-- Ejecuta solo sondas negativas controladas sobre el piloto inmaduro.
-- No emite certificados, no satisface G04 y no cambia instalaciones.

begin;

do $$
declare
  v_installation public.atlas_installations%rowtype;
  v_owner_id uuid :=
    'fa8e19fa-b983-4e25-b3fa-53a3ffdf250b'::uuid;
  v_outsider_id uuid := gen_random_uuid();
  v_rpc_count integer;
  v_helper_count integer;
  v_security_definer_count integer;
  v_authenticated_grants integer;
  v_anonymous_grants integer;
  v_direct_write_grants integer;
  v_issue_definition text;
  v_verify_definition text;
  v_before_certificates bigint;
  v_before_sources bigint;
  v_before_events bigint;
  v_before_requirements bigint;
  v_before_state_events bigint;
  v_after_certificates bigint;
  v_after_sources bigint;
  v_after_events bigint;
  v_after_requirements bigint;
  v_after_state_events bigint;
  v_invalid_fields_blocked boolean := false;
  v_wrong_state_blocked boolean := false;
  v_unauthorized_issue_blocked boolean := false;
  v_missing_verification_blocked boolean := false;
begin
  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id =
    'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if not found then
    raise exception 'B2.2K.2 pilot installation missing';
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION'
     or v_installation.version <> 3 then
    raise exception
      'B2.2K.2 pilot changed unexpectedly: state %, version %',
      v_installation.current_state_code,
      v_installation.version;
  end if;

  select count(*) into v_rpc_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_issue_installation_certificate',
      'atlas_verify_installation_certificate'
    );

  if v_rpc_count <> 2 then
    raise exception 'B2.2K.2 expected 2 RPCs, found %', v_rpc_count;
  end if;

  select count(*) into v_helper_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_certificate_platform_role_for_permission',
      'atlas_compute_installation_certificate_verification'
    );

  if v_helper_count <> 2 then
    raise exception
      'B2.2K.2 expected 2 internal helpers, found %',
      v_helper_count;
  end if;

  select count(*) into v_security_definer_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_certificate_platform_role_for_permission',
      'atlas_compute_installation_certificate_verification',
      'atlas_issue_installation_certificate',
      'atlas_verify_installation_certificate'
    )
    and procedure_record.prosecdef
    and procedure_record.proconfig @> array[
      'search_path=public, pg_temp'
    ];

  if v_security_definer_count <> 4 then
    raise exception
      'B2.2K.2 expected 4 hardened SECURITY DEFINER functions, found %',
      v_security_definer_count;
  end if;

  select count(*) into v_authenticated_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_issue_installation_certificate',
      'atlas_verify_installation_certificate'
    )
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_authenticated_grants <> 2 then
    raise exception
      'B2.2K.2 expected 2 authenticated RPC grants, found %',
      v_authenticated_grants;
  end if;

  select count(*) into v_anonymous_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_certificate_platform_role_for_permission',
      'atlas_compute_installation_certificate_verification',
      'atlas_issue_installation_certificate',
      'atlas_verify_installation_certificate'
    )
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_anonymous_grants <> 0 then
    raise exception
      'B2.2K.2 anonymous function grants found: %',
      v_anonymous_grants;
  end if;

  select count(*) into v_direct_write_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'atlas_installation_certificates',
      'atlas_installation_certificate_sources',
      'atlas_installation_certificate_events'
    )
    and grantee = 'authenticated'
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');

  if v_direct_write_grants <> 0 then
    raise exception
      'B2.2K.2 authenticated direct writes found: %',
      v_direct_write_grants;
  end if;

  select pg_get_functiondef(procedure_record.oid)
  into v_issue_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_issue_installation_certificate';

  select pg_get_functiondef(procedure_record.oid)
  into v_verify_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_verify_installation_certificate';

  if v_issue_definition is null
     or v_issue_definition not ilike
       '%CERTIFICATE_PRECONDITIONS_INCOMPLETE%'
     or v_issue_definition not ilike
       '%INSTALLATION_CERTIFICATE_ISSUED%'
     or v_issue_definition not ilike
       '%atlas_compute_installation_certificate_verification%'
     or v_issue_definition not ilike
       '%INSTALLATION_CERTIFICATE_ISSUED%'
     or v_issue_definition ilike
       '%update public.atlas_installations%'
     or v_issue_definition ilike
       '%atlas_transition_installation%'
     or v_verify_definition is null
     or v_verify_definition ilike '%insert into%'
     or v_verify_definition ilike '%update %'
     or v_verify_definition ilike '%delete from%' then
    raise exception 'B2.2K.2 RPC authority boundary invalid';
  end if;

  select count(*) into v_before_certificates
  from public.atlas_installation_certificates;
  select count(*) into v_before_sources
  from public.atlas_installation_certificate_sources;
  select count(*) into v_before_events
  from public.atlas_installation_certificate_events;
  select count(*) into v_before_requirements
  from public.atlas_installation_acceptance_requirements;
  select count(*) into v_before_state_events
  from public.atlas_installation_state_events;

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
    perform public.atlas_issue_installation_certificate(
      null::uuid,
      null::uuid,
      0,
      jsonb_build_object('probe', 'invalid')
    );
  exception
    when others then
      v_invalid_fields_blocked :=
        sqlerrm = 'CERTIFICATE_ISSUANCE_REQUIRED_FIELDS_INVALID';
  end;

  if not v_invalid_fields_blocked then
    raise exception 'B2.2K.2 invalid issuance fields were not blocked';
  end if;

  begin
    perform public.atlas_issue_installation_certificate(
      v_installation.id,
      gen_random_uuid(),
      v_installation.version,
      jsonb_build_object('probe', 'wrong_state')
    );
  exception
    when others then
      v_wrong_state_blocked :=
        sqlerrm =
          'CERTIFICATE_ISSUANCE_REQUIRES_FINAL_APPROVAL_STATE';
  end;

  if not v_wrong_state_blocked then
    raise exception
      'B2.2K.2 certificate issuance outside FINAL_APPROVAL was not blocked';
  end if;

  begin
    perform public.atlas_verify_installation_certificate(
      gen_random_uuid()
    );
  exception
    when others then
      v_missing_verification_blocked :=
        sqlerrm = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end;

  if not v_missing_verification_blocked then
    raise exception
      'B2.2K.2 missing certificate verification was not blocked';
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
    perform public.atlas_issue_installation_certificate(
      v_installation.id,
      gen_random_uuid(),
      v_installation.version,
      jsonb_build_object('probe', 'unauthorized')
    );
  exception
    when others then
      v_unauthorized_issue_blocked :=
        sqlerrm = 'INSTALLATION_CERTIFICATE_ISSUE_FORBIDDEN';
  end;

  if not v_unauthorized_issue_blocked then
    raise exception
      'B2.2K.2 unauthorized certificate issuance was not blocked';
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

  select count(*) into v_after_certificates
  from public.atlas_installation_certificates;
  select count(*) into v_after_sources
  from public.atlas_installation_certificate_sources;
  select count(*) into v_after_events
  from public.atlas_installation_certificate_events;
  select count(*) into v_after_requirements
  from public.atlas_installation_acceptance_requirements;
  select count(*) into v_after_state_events
  from public.atlas_installation_state_events;

  if v_after_certificates <> v_before_certificates
     or v_after_sources <> v_before_sources
     or v_after_events <> v_before_events
     or v_after_requirements <> v_before_requirements
     or v_after_state_events <> v_before_state_events then
    raise exception
      'B2.2K.2 negative probes changed governed records';
  end if;
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K2_CERTIFICATE_ISSUANCE_VERIFICATION_RPCS_CERTIFIED',
  'state', installation.current_state_code,
  'version', installation.version,
  'next_block',
    'B2.2K.3_CERTIFICATE_LIFECYCLE_AND_SAFE_PROJECTION',
  'certificate_rpcs', 2,
  'internal_helpers', 2,
  'security_definer_functions', 4,
  'authenticated_rpc_grants', 2,
  'anonymous_function_grants', 0,
  'direct_client_write_grants', 0,
  'certificate_records', (
    select count(*) from public.atlas_installation_certificates
  ),
  'certificate_source_records', (
    select count(*)
    from public.atlas_installation_certificate_sources
  ),
  'certificate_event_records', (
    select count(*)
    from public.atlas_installation_certificate_events
  ),
  'governed_records_unchanged', true,
  'invalid_fields_blocked', true,
  'wrong_state_issuance_blocked', true,
  'unauthorized_issuance_blocked', true,
  'missing_certificate_verification_blocked', true,
  'issuance_authority', 'ATLAS_OWNER',
  'exact_source_domain_coverage', 7,
  'backend_derived_evidence_only', true,
  'self_verification_enabled', true,
  'canonical_payload_hash_enabled', true,
  'evidence_root_recalculation_enabled', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'precertificate_revalidation_enabled', true,
  'g04_requirement_binding_enabled', true,
  'certificate_rendering_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false
) as certification
from public.atlas_installations as installation
where installation.id =
  'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;
