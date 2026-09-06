-- ATLAS B2.2K.4A
-- Certificacion del nucleo de regeneracion y render manifest.
-- Corte: 2026-09-04
-- Solo catalogo y estructura; no crea registros gobernados.

begin;

do $$
declare
  v_installation public.atlas_installations%rowtype;
  v_tables integer;
  v_rls integer;
  v_policies integer;
  v_permissions integer;
  v_append_only integer;
  v_constraints integer;
  v_direct_writes integer;
  v_anon_grants integer;
  v_write_rpcs integer;
  v_helper_count integer;
  v_contract
    public.atlas_installation_certificate_render_contracts%rowtype;
  v_requests bigint;
  v_decisions bigint;
  v_manifests bigint;
begin
  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id =
    'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if not found then
    raise exception 'B2.2K.4A pilot installation missing';
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION'
     or v_installation.version <> 3 then
    raise exception
      'B2.2K.4A pilot changed unexpectedly: state %, version %',
      v_installation.current_state_code,
      v_installation.version;
  end if;

  select count(*) into v_tables
  from pg_class as relation
  join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  where namespace.nspname = 'public'
    and relation.relname in (
      'atlas_installation_certificate_render_contracts',
      'atlas_installation_certificate_regeneration_requests',
      'atlas_installation_certificate_regeneration_decisions',
      'atlas_installation_certificate_render_manifests'
    )
    and relation.relkind in ('r', 'p');

  if v_tables <> 4 then
    raise exception 'B2.2K.4A expected 4 tables, found %', v_tables;
  end if;

  select count(*) into v_rls
  from pg_class as relation
  join pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  where namespace.nspname = 'public'
    and relation.relname in (
      'atlas_installation_certificate_render_contracts',
      'atlas_installation_certificate_regeneration_requests',
      'atlas_installation_certificate_regeneration_decisions',
      'atlas_installation_certificate_render_manifests'
    )
    and relation.relrowsecurity;

  if v_rls <> 4 then
    raise exception 'B2.2K.4A expected RLS on 4 tables, found %', v_rls;
  end if;

  select count(*) into v_policies
  from pg_policies
  where schemaname = 'public'
    and tablename in (
      'atlas_installation_certificate_render_contracts',
      'atlas_installation_certificate_regeneration_requests',
      'atlas_installation_certificate_regeneration_decisions',
      'atlas_installation_certificate_render_manifests'
    )
    and cmd = 'SELECT'
    and 'authenticated' = any(roles);

  if v_policies <> 4 then
    raise exception
      'B2.2K.4A expected 4 read policies, found %', v_policies;
  end if;

  select count(*) into v_permissions
  from public.atlas_internal_permissions
  where permission_code in (
    'INSTALLATION_CERTIFICATE_REGENERATE',
    'INSTALLATION_CERTIFICATE_RENDER_PREPARE'
  );

  if v_permissions <> 2 then
    raise exception
      'B2.2K.4A expected 2 permissions, found %', v_permissions;
  end if;

  select count(*) into v_append_only
  from pg_trigger as trigger_record
  where trigger_record.tgname in (
    'trg_atlas_certificate_regeneration_requests_append_only',
    'trg_atlas_certificate_regeneration_decisions_append_only',
    'trg_atlas_certificate_render_manifests_append_only'
  )
    and not trigger_record.tgisinternal
    and trigger_record.tgenabled <> 'D';

  if v_append_only <> 3 then
    raise exception
      'B2.2K.4A expected 3 append-only triggers, found %',
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
      'atlas_installation_certificate_render_contracts',
      'atlas_installation_certificate_regeneration_requests',
      'atlas_installation_certificate_regeneration_decisions',
      'atlas_installation_certificate_render_manifests'
    )
    and constraint_record.contype in ('c', 'f', 'u');

  if v_constraints < 31 then
    raise exception
      'B2.2K.4A critical constraints incomplete: %',
      v_constraints;
  end if;

  select count(*) into v_direct_writes
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'atlas_installation_certificate_render_contracts',
      'atlas_installation_certificate_regeneration_requests',
      'atlas_installation_certificate_regeneration_decisions',
      'atlas_installation_certificate_render_manifests'
    )
    and grantee = 'authenticated'
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');

  if v_direct_writes <> 0 then
    raise exception
      'B2.2K.4A authenticated direct writes found: %',
      v_direct_writes;
  end if;

  select count(*) into v_anon_grants
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name in (
      'atlas_installation_certificate_render_contracts',
      'atlas_installation_certificate_regeneration_requests',
      'atlas_installation_certificate_regeneration_decisions',
      'atlas_installation_certificate_render_manifests'
    )
    and grantee = 'anon';

  if v_anon_grants <> 0 then
    raise exception
      'B2.2K.4A anonymous table grants found: %',
      v_anon_grants;
  end if;

  select * into v_contract
  from public.atlas_installation_certificate_render_contracts
  where contract_code = 'B2_INSTALLATION_CERTIFICATE_RENDER_V1'
    and active;

  if not found
     or v_contract.schema_version <> 1
     or cardinality(v_contract.allowed_output_formats) <> 2
     or not v_contract.allowed_output_formats @>
       array['PDF', 'PDF_A_3']::text[]
     or cardinality(v_contract.required_projection_fields) < 12
     or coalesce(
       (v_contract.render_contract
          ->>'credential_values_allowed')::boolean,
       true
     )
     or coalesce(
       (v_contract.render_contract
          ->>'raw_payloads_allowed')::boolean,
       true
     )
     or coalesce(
       (v_contract.render_contract
          ->>'evidence_references_allowed')::boolean,
       true
     )
     or coalesce(
       (v_contract.render_contract
          ->>'actor_identities_allowed')::boolean,
       true
     )
     or coalesce(
       (v_contract.render_contract
          ->>'renderer_executes_authority_actions')::boolean,
       true
     )
     or coalesce(
       (v_contract.render_contract
          ->>'rendering_changes_certificate_state')::boolean,
       true
     ) then
    raise exception 'B2.2K.4A canonical render contract invalid';
  end if;

  select count(*) into v_helper_count
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname =
      'atlas_block_certificate_artifact_append_only_mutation'
    and procedure_record.prosecdef
    and procedure_record.proconfig @> array[
      'search_path=public, pg_temp'
    ];

  if v_helper_count <> 1 then
    raise exception 'B2.2K.4A append-only helper invalid';
  end if;

  select count(*) into v_write_rpcs
  from pg_proc as procedure_record
  join pg_namespace as namespace
    on namespace.oid = procedure_record.pronamespace
  where namespace.nspname = 'public'
    and procedure_record.proname in (
      'atlas_request_installation_certificate_regeneration',
      'atlas_decide_installation_certificate_regeneration',
      'atlas_execute_installation_certificate_regeneration',
      'atlas_prepare_installation_certificate_render_manifest'
    );

  if v_write_rpcs <> 0 then
    raise exception
      'B2.2K.4A authority enabled prematurely: %',
      v_write_rpcs;
  end if;

  select count(*) into v_requests
  from public.atlas_installation_certificate_regeneration_requests;
  select count(*) into v_decisions
  from public.atlas_installation_certificate_regeneration_decisions;
  select count(*) into v_manifests
  from public.atlas_installation_certificate_render_manifests;

  if v_requests <> 0 or v_decisions <> 0 or v_manifests <> 0 then
    raise exception 'B2.2K.4A governed records changed unexpectedly';
  end if;
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K4A_REGENERATION_RENDER_MANIFEST_CORE_CERTIFIED',
  'state', installation.current_state_code,
  'version', installation.version,
  'next_block',
    'B2.2K.4B_CONTROLLED_REGENERATION_AND_RENDER_RPCS',
  'governance_tables', 4,
  'rls_tables', 4,
  'read_policies', 4,
  'append_only_tables', 3,
  'critical_constraints_minimum', 31,
  'regeneration_permissions', 2,
  'canonical_render_contracts', 1,
  'allowed_output_formats', 2,
  'direct_client_write_grants', 0,
  'anonymous_table_grants', 0,
  'regeneration_requests', 0,
  'regeneration_decisions', 0,
  'render_manifests', 0,
  'write_rpcs', 0,
  'governed_records_unchanged', true,
  'immutable_regeneration_requests', true,
  'immutable_regeneration_decisions', true,
  'immutable_render_manifests', true,
  'safe_projection_required', true,
  'credential_values_allowed', false,
  'raw_payloads_allowed', false,
  'evidence_references_allowed', false,
  'actor_identities_allowed', false,
  'renderer_authority_actions_allowed', false,
  'rendering_changes_certificate_state', false,
  'certificate_regeneration_enabled', false,
  'certificate_rendering_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false
) as certification
from public.atlas_installations as installation
where installation.id =
  'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;
