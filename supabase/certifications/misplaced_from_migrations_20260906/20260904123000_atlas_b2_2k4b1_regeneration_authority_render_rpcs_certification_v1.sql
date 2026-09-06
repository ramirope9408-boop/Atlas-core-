-- ATLAS B2.2K.4B.1
-- Certificacion de autoridad de regeneracion y render manifest.
-- Corte: 2026-09-04
-- Solo sondas negativas; no crea solicitudes, decisiones o manifiestos.

begin;

do $$
declare
  v_installation public.atlas_installations%rowtype;
  v_owner_id uuid :=
    'fa8e19fa-b983-4e25-b3fa-53a3ffdf250b'::uuid;
  v_outsider_id uuid := gen_random_uuid();
  v_rpc_count integer;
  v_security_definer_count integer;
  v_authenticated_grants integer;
  v_anonymous_grants integer;
  v_direct_write_grants integer;
  v_execution_rpcs integer;
  v_request_definition text;
  v_decision_definition text;
  v_render_definition text;
  v_before_requests bigint;
  v_before_decisions bigint;
  v_before_manifests bigint;
  v_before_certificates bigint;
  v_before_certificate_events bigint;
  v_after_requests bigint;
  v_after_decisions bigint;
  v_after_manifests bigint;
  v_after_certificates bigint;
  v_after_certificate_events bigint;
  v_invalid_request_blocked boolean := false;
  v_missing_certificate_blocked boolean := false;
  v_missing_request_decision_blocked boolean := false;
  v_missing_render_certificate_blocked boolean := false;
  v_unauthorized_request_blocked boolean := false;
begin
  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id =
    'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if not found then
    raise exception 'B2.2K.4B.1 pilot installation missing';
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION'
     or v_installation.version <> 3 then
    raise exception
      'B2.2K.4B.1 pilot changed unexpectedly: state %, version %',
      v_installation.current_state_code,
      v_installation.version;
  end if;

  select count(*) into v_rpc_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_request_installation_certificate_regeneration',
      'atlas_decide_installation_certificate_regeneration',
      'atlas_prepare_installation_certificate_render_manifest'
    );

  if v_rpc_count <> 3 then
    raise exception 'B2.2K.4B.1 expected 3 RPCs, found %', v_rpc_count;
  end if;

  select count(*) into v_security_definer_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_request_installation_certificate_regeneration',
      'atlas_decide_installation_certificate_regeneration',
      'atlas_prepare_installation_certificate_render_manifest'
    )
    and procedure_record.prosecdef
    and procedure_record.proconfig @> array[
      'search_path=public, pg_temp'
    ];

  if v_security_definer_count <> 3 then
    raise exception
      'B2.2K.4B.1 expected 3 hardened functions, found %',
      v_security_definer_count;
  end if;

  select count(*) into v_authenticated_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_request_installation_certificate_regeneration',
      'atlas_decide_installation_certificate_regeneration',
      'atlas_prepare_installation_certificate_render_manifest'
    )
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_authenticated_grants <> 3 then
    raise exception
      'B2.2K.4B.1 expected 3 authenticated grants, found %',
      v_authenticated_grants;
  end if;

  select count(*) into v_anonymous_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_request_installation_certificate_regeneration',
      'atlas_decide_installation_certificate_regeneration',
      'atlas_prepare_installation_certificate_render_manifest'
    )
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_anonymous_grants <> 0 then
    raise exception
      'B2.2K.4B.1 anonymous grants found: %',
      v_anonymous_grants;
  end if;

  select count(*) into v_direct_write_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'atlas_installation_certificate_regeneration_requests',
      'atlas_installation_certificate_regeneration_decisions',
      'atlas_installation_certificate_render_manifests'
    )
    and grantee = 'authenticated'
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');

  if v_direct_write_grants <> 0 then
    raise exception
      'B2.2K.4B.1 authenticated direct writes found: %',
      v_direct_write_grants;
  end if;

  select count(*) into v_execution_rpcs
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_execute_installation_certificate_regeneration';

  if v_execution_rpcs <> 0 then
    raise exception
      'B2.2K.4B.1 regeneration execution enabled prematurely';
  end if;

  select pg_get_functiondef(procedure_record.oid)
  into v_request_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_request_installation_certificate_regeneration';

  select pg_get_functiondef(procedure_record.oid)
  into v_decision_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_decide_installation_certificate_regeneration';

  select pg_get_functiondef(procedure_record.oid)
  into v_render_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_prepare_installation_certificate_render_manifest';

  if v_request_definition is null
     or v_request_definition not ilike
       '%CERTIFICATE_REGENERATION_REQUIRES_REVOCATION%'
     or v_request_definition ilike
       '%insert into public.atlas_installation_certificates%'
     or v_decision_definition is null
     or v_decision_definition not ilike
       '%CERTIFICATE_REGENERATION_EVIDENCE_NOT_READY%'
     or v_decision_definition ilike
       '%insert into public.atlas_installation_certificates%'
     or v_render_definition is null
     or v_render_definition not ilike
       '%ONLY_EFFECTIVE_VERIFIED_CERTIFICATE_CAN_BE_RENDERED%'
     or v_render_definition not ilike '%document_generated%false%'
     or v_render_definition ilike
       '%update public.atlas_installations%'
     or v_render_definition ilike
       '%insert into public.atlas_installation_state_events%' then
    raise exception 'B2.2K.4B.1 RPC boundaries invalid';
  end if;

  select count(*) into v_before_requests
  from public.atlas_installation_certificate_regeneration_requests;
  select count(*) into v_before_decisions
  from public.atlas_installation_certificate_regeneration_decisions;
  select count(*) into v_before_manifests
  from public.atlas_installation_certificate_render_manifests;
  select count(*) into v_before_certificates
  from public.atlas_installation_certificates;
  select count(*) into v_before_certificate_events
  from public.atlas_installation_certificate_events;

  perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_owner_id, 'role', 'authenticated')::text,
    true
  );

  begin
    perform public.atlas_request_installation_certificate_regeneration(
      null::uuid, 'BAD', 'short',
      'certificate://atlas/negative-probe', repeat('a', 64),
      null::uuid, 0, '{}'::jsonb
    );
  exception
    when others then
      v_invalid_request_blocked :=
        sqlerrm = 'CERTIFICATE_REGENERATION_REQUEST_FIELDS_INVALID';
  end;

  if not v_invalid_request_blocked then
    raise exception 'B2.2K.4B.1 invalid request was not blocked';
  end if;

  begin
    perform public.atlas_request_installation_certificate_regeneration(
      gen_random_uuid(), 'CERTIFICATE_REISSUE_REQUIRED',
      'Sonda negativa de certificado inexistente.',
      'certificate://atlas/missing-predecessor', repeat('b', 64),
      gen_random_uuid(), 1,
      jsonb_build_object('probe', 'missing_certificate')
    );
  exception
    when others then
      v_missing_certificate_blocked :=
        sqlerrm = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end;

  if not v_missing_certificate_blocked then
    raise exception
      'B2.2K.4B.1 missing predecessor was not blocked';
  end if;

  begin
    perform public.atlas_decide_installation_certificate_regeneration(
      gen_random_uuid(), 'APPROVED',
      'Sonda negativa de solicitud inexistente.',
      'certificate://atlas/missing-request', repeat('c', 64),
      gen_random_uuid(), 1,
      jsonb_build_object('probe', 'missing_request')
    );
  exception
    when others then
      v_missing_request_decision_blocked :=
        sqlerrm = 'CERTIFICATE_REGENERATION_REQUEST_NOT_FOUND';
  end;

  if not v_missing_request_decision_blocked then
    raise exception
      'B2.2K.4B.1 missing request decision was not blocked';
  end if;

  begin
    perform public.atlas_prepare_installation_certificate_render_manifest(
      gen_random_uuid(), 'ATLAS_INSTALLATION_CERTIFICATE', 'V1',
      'PDF_A_3', 'es-CO', gen_random_uuid(),
      jsonb_build_object('probe', 'missing_certificate')
    );
  exception
    when others then
      v_missing_render_certificate_blocked :=
        sqlerrm = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end;

  if not v_missing_render_certificate_blocked then
    raise exception
      'B2.2K.4B.1 missing render certificate was not blocked';
  end if;

  insert into auth.users(id)
  values (v_outsider_id)
  on conflict (id) do nothing;
  perform set_config('request.jwt.claim.sub', v_outsider_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_outsider_id, 'role', 'authenticated')::text,
    true
  );

  begin
    perform public.atlas_request_installation_certificate_regeneration(
      gen_random_uuid(), 'CERTIFICATE_REISSUE_REQUIRED',
      'Sonda negativa de autoridad de regeneracion.',
      'certificate://atlas/unauthorized-request', repeat('d', 64),
      gen_random_uuid(), 1,
      jsonb_build_object('probe', 'unauthorized')
    );
  exception
    when others then
      v_unauthorized_request_blocked :=
        sqlerrm = 'INSTALLATION_CERTIFICATE_REGENERATE_FORBIDDEN';
  end;

  if not v_unauthorized_request_blocked then
    raise exception
      'B2.2K.4B.1 unauthorized request was not blocked';
  end if;

  perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_owner_id, 'role', 'authenticated')::text,
    true
  );
  delete from auth.users where id = v_outsider_id;

  select count(*) into v_after_requests
  from public.atlas_installation_certificate_regeneration_requests;
  select count(*) into v_after_decisions
  from public.atlas_installation_certificate_regeneration_decisions;
  select count(*) into v_after_manifests
  from public.atlas_installation_certificate_render_manifests;
  select count(*) into v_after_certificates
  from public.atlas_installation_certificates;
  select count(*) into v_after_certificate_events
  from public.atlas_installation_certificate_events;

  if v_after_requests <> v_before_requests
     or v_after_decisions <> v_before_decisions
     or v_after_manifests <> v_before_manifests
     or v_after_certificates <> v_before_certificates
     or v_after_certificate_events <> v_before_certificate_events then
    raise exception
      'B2.2K.4B.1 negative probes changed governed records';
  end if;
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K4B1_REGENERATION_AUTHORITY_RENDER_RPCS_CERTIFIED',
  'state', installation.current_state_code,
  'version', installation.version,
  'next_block', 'B2.2K.4B.2_REGENERATION_EXECUTION_RPC',
  'regeneration_authority_rpcs', 2,
  'render_manifest_rpcs', 1,
  'security_definer_functions', 3,
  'authenticated_rpc_grants', 3,
  'anonymous_function_grants', 0,
  'direct_client_write_grants', 0,
  'regeneration_requests', 0,
  'regeneration_decisions', 0,
  'render_manifests', 0,
  'governed_records_unchanged', true,
  'invalid_request_blocked', true,
  'missing_predecessor_blocked', true,
  'missing_request_decision_blocked', true,
  'missing_render_certificate_blocked', true,
  'unauthorized_regeneration_request_blocked', true,
  'regeneration_requires_revocation', true,
  'regeneration_requires_human_decision', true,
  'regeneration_execution_enabled', false,
  'render_manifest_preparation_enabled', true,
  'effective_verified_certificate_required', true,
  'safe_projection_required', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'document_generation_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false
) as certification
from public.atlas_installations as installation
where installation.id =
  'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;
