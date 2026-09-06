-- ATLAS B2.2K.3
-- Certificacion de ciclo de vida y proyeccion segura del certificado.
-- Corte: 2026-09-04
--
-- Solo lecturas y sondas negativas. No crea ni revoca certificados.

begin;

do $$
declare
  v_installation public.atlas_installations%rowtype;
  v_owner_id uuid :=
    'fa8e19fa-b983-4e25-b3fa-53a3ffdf250b'::uuid;
  v_outsider_id uuid := gen_random_uuid();
  v_function_count integer;
  v_security_definer_count integer;
  v_authenticated_grants integer;
  v_anonymous_grants integer;
  v_direct_write_grants integer;
  v_revoke_definition text;
  v_safe_definition text;
  v_history_definition text;
  v_history jsonb;
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
  v_invalid_revocation_blocked boolean := false;
  v_missing_revocation_blocked boolean := false;
  v_unauthorized_revocation_blocked boolean := false;
  v_missing_projection_blocked boolean := false;
begin
  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id =
    'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if not found then
    raise exception 'B2.2K.3 pilot installation missing';
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION'
     or v_installation.version <> 3 then
    raise exception
      'B2.2K.3 pilot changed unexpectedly: state %, version %',
      v_installation.current_state_code,
      v_installation.version;
  end if;

  select count(*) into v_function_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_compute_installation_certificate_lifecycle',
      'atlas_revoke_installation_certificate',
      'atlas_get_installation_certificate_safe_projection',
      'atlas_list_installation_certificate_history'
    );

  if v_function_count <> 4 then
    raise exception
      'B2.2K.3 expected 4 functions, found %',
      v_function_count;
  end if;

  select count(*) into v_security_definer_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_compute_installation_certificate_lifecycle',
      'atlas_revoke_installation_certificate',
      'atlas_get_installation_certificate_safe_projection',
      'atlas_list_installation_certificate_history'
    )
    and procedure_record.prosecdef
    and procedure_record.proconfig @> array[
      'search_path=public, pg_temp'
    ];

  if v_security_definer_count <> 4 then
    raise exception
      'B2.2K.3 expected 4 hardened SECURITY DEFINER functions, found %',
      v_security_definer_count;
  end if;

  select count(*) into v_authenticated_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_revoke_installation_certificate',
      'atlas_get_installation_certificate_safe_projection',
      'atlas_list_installation_certificate_history'
    )
    and grantee = 'authenticated'
    and privilege_type = 'EXECUTE';

  if v_authenticated_grants <> 3 then
    raise exception
      'B2.2K.3 expected 3 authenticated RPC grants, found %',
      v_authenticated_grants;
  end if;

  select count(*) into v_anonymous_grants
  from information_schema.routine_privileges
  where routine_schema = 'public'
    and routine_name in (
      'atlas_compute_installation_certificate_lifecycle',
      'atlas_revoke_installation_certificate',
      'atlas_get_installation_certificate_safe_projection',
      'atlas_list_installation_certificate_history'
    )
    and grantee in ('PUBLIC', 'anon')
    and privilege_type = 'EXECUTE';

  if v_anonymous_grants <> 0 then
    raise exception
      'B2.2K.3 anonymous function grants found: %',
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
      'B2.2K.3 authenticated direct writes found: %',
      v_direct_write_grants;
  end if;

  select pg_get_functiondef(procedure_record.oid)
  into v_revoke_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_revoke_installation_certificate';

  select pg_get_functiondef(procedure_record.oid)
  into v_safe_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_get_installation_certificate_safe_projection';

  select pg_get_functiondef(procedure_record.oid)
  into v_history_definition
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_list_installation_certificate_history';

  if v_revoke_definition is null
     or v_revoke_definition not ilike
       '%insert into public.atlas_installation_certificate_events%'
     or v_revoke_definition ilike
       '%update public.atlas_installation_certificates%'
     or v_revoke_definition ilike
       '%delete from public.atlas_installation_certificates%'
     or v_revoke_definition ilike
       '%update public.atlas_installations%'
     or v_safe_definition is null
     or v_safe_definition not ilike
       '%evidence_references_exposed%false%'
     or v_safe_definition not ilike
       '%actor_identities_exposed%false%'
     or v_history_definition is null
     or v_history_definition ilike '%insert into%'
     or v_history_definition ilike '%update %'
     or v_history_definition ilike '%delete from%' then
    raise exception 'B2.2K.3 lifecycle or safe projection contract invalid';
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
    perform public.atlas_revoke_installation_certificate(
      null::uuid,
      'BAD',
      'short',
      'certificate://atlas/negative-probe',
      repeat('a', 64),
      null::uuid,
      0,
      '{}'::jsonb
    );
  exception
    when others then
      v_invalid_revocation_blocked :=
        sqlerrm = 'CERTIFICATE_REVOCATION_REQUIRED_FIELDS_INVALID';
  end;

  if not v_invalid_revocation_blocked then
    raise exception 'B2.2K.3 invalid revocation was not blocked';
  end if;

  begin
    perform public.atlas_revoke_installation_certificate(
      gen_random_uuid(),
      'SECURITY_EVIDENCE_INVALIDATED',
      'Sonda negativa sobre certificado inexistente.',
      'certificate://atlas/negative-revocation',
      repeat('b', 64),
      gen_random_uuid(),
      1,
      jsonb_build_object('probe', 'missing_certificate')
    );
  exception
    when others then
      v_missing_revocation_blocked :=
        sqlerrm = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end;

  if not v_missing_revocation_blocked then
    raise exception
      'B2.2K.3 missing certificate revocation was not blocked';
  end if;

  begin
    perform public.atlas_get_installation_certificate_safe_projection(
      gen_random_uuid()
    );
  exception
    when others then
      v_missing_projection_blocked :=
        sqlerrm = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end;

  if not v_missing_projection_blocked then
    raise exception
      'B2.2K.3 missing safe projection was not blocked';
  end if;

  v_history := public.atlas_list_installation_certificate_history(
    v_installation.id
  );

  if v_history->>'code' <> 'INSTALLATION_CERTIFICATE_HISTORY'
     or (v_history->>'certificate_count')::integer <> 0
     or jsonb_array_length(v_history->'certificates') <> 0
     or coalesce(
       (v_history->>'raw_payloads_exposed')::boolean,
       true
     )
     or coalesce(
       (v_history->>'evidence_references_exposed')::boolean,
       true
     )
     or coalesce(
       (v_history->>'actor_identities_exposed')::boolean,
       true
     ) then
    raise exception 'B2.2K.3 empty safe history contract invalid';
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
    perform public.atlas_revoke_installation_certificate(
      gen_random_uuid(),
      'SECURITY_EVIDENCE_INVALIDATED',
      'Sonda negativa de autoridad para revocacion.',
      'certificate://atlas/unauthorized-revocation',
      repeat('c', 64),
      gen_random_uuid(),
      1,
      jsonb_build_object('probe', 'unauthorized')
    );
  exception
    when others then
      v_unauthorized_revocation_blocked :=
        sqlerrm = 'INSTALLATION_CERTIFICATE_REVOKE_FORBIDDEN';
  end;

  if not v_unauthorized_revocation_blocked then
    raise exception
      'B2.2K.3 unauthorized revocation was not blocked';
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
      'B2.2K.3 negative probes changed governed records';
  end if;
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K3_CERTIFICATE_LIFECYCLE_SAFE_PROJECTION_CERTIFIED',
  'state', installation.current_state_code,
  'version', installation.version,
  'next_block',
    'B2.2K.4_CONTROLLED_REGENERATION_AND_RENDER_MANIFEST',
  'lifecycle_rpcs', 1,
  'safe_projection_rpcs', 2,
  'lifecycle_helpers', 1,
  'security_definer_functions', 4,
  'authenticated_rpc_grants', 3,
  'anonymous_function_grants', 0,
  'direct_client_write_grants', 0,
  'certificate_records', (
    select count(*) from public.atlas_installation_certificates
  ),
  'certificate_event_records', (
    select count(*)
    from public.atlas_installation_certificate_events
  ),
  'governed_records_unchanged', true,
  'invalid_revocation_blocked', true,
  'missing_certificate_revocation_blocked', true,
  'unauthorized_revocation_blocked', true,
  'missing_safe_projection_blocked', true,
  'empty_history_projection_valid', true,
  'revocation_authority', 'ATLAS_OWNER',
  'revocation_append_only', true,
  'historical_records_preserved', true,
  'cryptographic_verification_projected', true,
  'raw_payloads_exposed', false,
  'evidence_references_exposed', false,
  'actor_identities_exposed', false,
  'internal_metadata_exposed', false,
  'controlled_regeneration_enabled', false,
  'certificate_rendering_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false
) as certification
from public.atlas_installations as installation
where installation.id =
  'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;
