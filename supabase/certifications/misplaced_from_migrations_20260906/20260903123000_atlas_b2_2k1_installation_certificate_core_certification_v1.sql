-- ATLAS B2.2K.1 - Certificacion del nucleo inmutable de certificados.
-- Corte: 2026-09-03
-- Solo lecturas y sondas en memoria; no emite ni modifica certificados.

begin;

do $$
declare
  v_installation public.atlas_installations%rowtype;
  v_tables integer;
  v_rls integer;
  v_policies integer;
  v_permissions integer;
  v_direct_writes integer;
  v_anon_grants integer;
  v_append_only integer;
  v_constraints integer;
  v_write_rpcs integer;
  v_contract public.atlas_installation_certificate_contracts%rowtype;
  v_safe_reference boolean;
  v_unsafe_reference boolean;
  v_before_certificates bigint;
  v_before_sources bigint;
  v_before_events bigint;
begin
  select * into v_installation
  from public.atlas_installations
  where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if not found then
    raise exception 'B2.2K.1 pilot installation missing';
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION'
     or v_installation.version <> 3 then
    raise exception
      'B2.2K.1 pilot changed unexpectedly: state %, version %',
      v_installation.current_state_code,
      v_installation.version;
  end if;

  select count(*) into v_tables
  from pg_class as relation
  join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  where namespace.nspname = 'public'
    and relation.relname in (
      'atlas_installation_certificate_contracts',
      'atlas_installation_certificates',
      'atlas_installation_certificate_sources',
      'atlas_installation_certificate_events'
    )
    and relation.relkind in ('r', 'p');

  if v_tables <> 4 then
    raise exception 'B2.2K.1 expected 4 tables, found %', v_tables;
  end if;

  select count(*) into v_rls
  from pg_class as relation
  join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  where namespace.nspname = 'public'
    and relation.relname in (
      'atlas_installation_certificate_contracts',
      'atlas_installation_certificates',
      'atlas_installation_certificate_sources',
      'atlas_installation_certificate_events'
    )
    and relation.relrowsecurity;

  if v_rls <> 4 then
    raise exception 'B2.2K.1 expected RLS on 4 tables, found %', v_rls;
  end if;

  select count(*) into v_policies
  from pg_policies
  where schemaname = 'public'
    and tablename in (
      'atlas_installation_certificate_contracts',
      'atlas_installation_certificates',
      'atlas_installation_certificate_sources',
      'atlas_installation_certificate_events'
    )
    and cmd = 'SELECT'
    and 'authenticated' = any(roles);

  if v_policies <> 4 then
    raise exception 'B2.2K.1 expected 4 read policies, found %', v_policies;
  end if;

  select count(*) into v_permissions
  from public.atlas_internal_permissions
  where permission_code in (
    'INSTALLATION_CERTIFICATE_READ',
    'INSTALLATION_CERTIFICATE_ISSUE',
    'INSTALLATION_CERTIFICATE_REVOKE'
  );

  if v_permissions <> 3 then
    raise exception
      'B2.2K.1 expected 3 certificate permissions, found %',
      v_permissions;
  end if;

  select count(*) into v_direct_writes
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'atlas_installation_certificate_contracts',
      'atlas_installation_certificates',
      'atlas_installation_certificate_sources',
      'atlas_installation_certificate_events'
    )
    and grantee = 'authenticated'
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');

  if v_direct_writes <> 0 then
    raise exception
      'B2.2K.1 authenticated direct writes found: %',
      v_direct_writes;
  end if;

  select count(*) into v_anon_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'atlas_installation_certificate_contracts',
      'atlas_installation_certificates',
      'atlas_installation_certificate_sources',
      'atlas_installation_certificate_events'
    )
    and grantee = 'anon';

  if v_anon_grants <> 0 then
    raise exception 'B2.2K.1 anonymous table grants found: %', v_anon_grants;
  end if;

  select count(*) into v_append_only
  from pg_trigger as trigger_record
  where trigger_record.tgname in (
    'trg_atlas_certificates_append_only',
    'trg_atlas_certificate_sources_append_only',
    'trg_atlas_certificate_events_append_only'
  )
    and not trigger_record.tgisinternal
    and trigger_record.tgenabled <> 'D';

  if v_append_only <> 3 then
    raise exception
      'B2.2K.1 expected 3 append-only triggers, found %',
      v_append_only;
  end if;

  select count(*) into v_constraints
  from pg_constraint as constraint_record
  join pg_class as relation
    on relation.oid = constraint_record.conrelid
  join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  where namespace.nspname = 'public'
    and relation.relname in (
      'atlas_installation_certificate_contracts',
      'atlas_installation_certificates',
      'atlas_installation_certificate_sources',
      'atlas_installation_certificate_events'
    )
    and constraint_record.contype in ('c', 'f', 'u');

  if v_constraints < 27 then
    raise exception
      'B2.2K.1 critical constraints incomplete: %',
      v_constraints;
  end if;

  select * into v_contract
  from public.atlas_installation_certificate_contracts
  where contract_code = 'B2_INSTALLATION_CERTIFICATE_V1'
    and active;

  if not found
     or v_contract.schema_version <> 1
     or cardinality(v_contract.required_source_domains) <> 7
     or not v_contract.required_source_domains @> array[
       'MANIFEST', 'PROVISIONING', 'INTEGRATION', 'TESTING',
       'GATES', 'ACCEPTANCE', 'AUDIT'
     ]::text[]
     or coalesce(
       (v_contract.payload_contract->>'secret_values_allowed')::boolean,
       true
     )
     or coalesce(
       (v_contract.payload_contract->>'manual_assertions_allowed')::boolean,
       true
     ) then
    raise exception 'B2.2K.1 canonical certificate contract invalid';
  end if;

  v_safe_reference :=
    public.atlas_certificate_reference_is_safe(
      'certificate://atlas/pilot/verification'
    );
  v_unsafe_reference :=
    public.atlas_certificate_reference_is_safe(
      'https://provider.example/item?token=secret'
    );

  if not v_safe_reference or v_unsafe_reference then
    raise exception 'B2.2K.1 evidence reference guard invalid';
  end if;

  select count(*) into v_write_rpcs
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_issue_installation_certificate',
      'atlas_revoke_installation_certificate',
      'atlas_supersede_installation_certificate'
    );

  if v_write_rpcs <> 0 then
    raise exception
      'B2.2K.1 certificate authority enabled prematurely: %',
      v_write_rpcs;
  end if;

  select count(*) into v_before_certificates
  from public.atlas_installation_certificates;
  select count(*) into v_before_sources
  from public.atlas_installation_certificate_sources;
  select count(*) into v_before_events
  from public.atlas_installation_certificate_events;

  if v_before_certificates <> 0
     or v_before_sources <> 0
     or v_before_events <> 0 then
    raise exception
      'B2.2K.1 governed certificate ledgers changed unexpectedly';
  end if;
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2K1_INSTALLATION_CERTIFICATE_CORE_CERTIFIED',
  'state', installation.current_state_code,
  'version', installation.version,
  'next_block',
    'B2.2K.2_CERTIFICATE_ISSUANCE_AND_VERIFICATION_RPCS',
  'certificate_contracts', 1,
  'required_source_domains', 7,
  'certificate_tables', 4,
  'rls_tables', 4,
  'read_policies', 4,
  'certificate_permissions', 3,
  'append_only_tables', 3,
  'critical_constraints_minimum', 27,
  'direct_client_write_grants', 0,
  'anonymous_table_grants', 0,
  'safe_evidence_reference_guard', true,
  'secret_bearing_references_blocked', true,
  'canonical_payload_hash_required', true,
  'source_hash_lineage_required', true,
  'cross_tenant_lineage_required', true,
  'immutable_certificate_records', true,
  'historical_supersession_modelled', true,
  'historical_revocation_modelled', true,
  'certificate_records', 0,
  'certificate_source_records', 0,
  'certificate_event_records', 0,
  'certificate_write_rpcs', 0,
  'certificate_issuance_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'governed_records_unchanged', true
) as certification
from public.atlas_installations as installation
where installation.id =
  'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;
