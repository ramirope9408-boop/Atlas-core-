-- ATLAS B2.2D.2
-- Registro gobernado de manifest y materializacion de inventario.
-- Corte: 2026-08-29
--
-- Prerrequisito: B2.2D.1 instalado y certificado.
--
-- Invariantes:
-- - el manifest proviene de un archivo JSON real y ACCEPTED;
-- - el SHA-256 declarado coincide con el archivo fuente;
-- - el manifest refleja todos los archivos vigentes no MANIFEST;
-- - no contiene secretos y conserva identidad/tenant/paquete;
-- - el inventario materializa exactamente las 37 definiciones activas;
-- - SECURITY_VALIDATION no avanza sin archivos, manifest e inventario.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_manifests') is null
     or to_regclass('public.atlas_installation_inventory_requirements') is null
     or to_regprocedure('public.atlas_manifest_payload_is_valid(jsonb)') is null
     or to_regprocedure(
       'public.atlas_enforce_security_file_completion()'
     ) is null then
    raise exception 'B2.2D.2 requiere B2.2D.1 y B2.2C.3 certificados';
  end if;
end;
$$;

alter table public.atlas_installation_inventory_requirements
  add column if not exists source_manifest_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid =
      'public.atlas_installation_inventory_requirements'::regclass
      and conname = 'atlas_inventory_requirements_source_manifest_fkey'
  ) then
    alter table public.atlas_installation_inventory_requirements
      add constraint atlas_inventory_requirements_source_manifest_fkey
      foreign key (source_manifest_id)
      references public.atlas_installation_manifests(id)
      on delete restrict;
  end if;
end;
$$;

alter table public.atlas_installation_inventory_requirements
  alter column source_manifest_id set not null;

create index if not exists idx_atlas_inventory_requirements_manifest
  on public.atlas_installation_inventory_requirements (
    installation_id,
    source_manifest_id,
    fulfillment_status
  );

create or replace function public.atlas_register_installation_manifest(
  p_installation_id uuid,
  p_package_id uuid,
  p_package_version integer,
  p_source_file_id uuid,
  p_manifest_payload jsonb,
  p_manifest_sha256 text,
  p_request_id uuid,
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
  v_sha256 text := lower(nullif(btrim(p_manifest_sha256), ''));
  v_installation public.atlas_installations%rowtype;
  v_source_file public.atlas_installation_files%rowtype;
  v_existing public.atlas_installation_manifests%rowtype;
  v_previous public.atlas_installation_manifests%rowtype;
  v_created public.atlas_installation_manifests%rowtype;
  v_latest_version integer;
  v_current_file_count integer;
  v_manifest_file_count integer;
  v_matched_file_count integer;
  v_manifest_owner_user_id uuid;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PACKAGE_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PACKAGE_MANAGE_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_package_id is null
     or p_source_file_id is null
     or p_request_id is null
     or p_package_version is null
     or p_package_version < 1
     or v_sha256 is null
     or v_sha256 !~ '^[0-9a-f]{64}$'
     or p_manifest_payload is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or nullif(btrim(p_metadata->>'parsed_by'), '') is null
     or nullif(btrim(p_metadata->>'parsed_at'), '') is null then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_REGISTRATION_REQUIRED_FIELDS_MISSING';
  end if;

  begin
    perform (p_metadata->>'parsed_at')::timestamptz;
    perform (p_manifest_payload->>'created_at')::timestamptz;
  exception
    when others then
      raise exception using
        errcode = '22023',
        message = 'MANIFEST_TIMESTAMP_INVALID';
  end;

  select i.*
  into v_installation
  from public.atlas_installations as i
  where i.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_NOT_FOUND';
  end if;

  select m.*
  into v_existing
  from public.atlas_installation_manifests as m
  where m.installation_id = v_installation.id
    and m.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.package_id <> p_package_id
       or v_existing.package_version <> p_package_version
       or v_existing.source_file_id <> p_source_file_id
       or v_existing.manifest_sha256 <> v_sha256
       or v_existing.manifest_payload <> p_manifest_payload then
      raise exception using
        errcode = '22023',
        message = 'MANIFEST_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'manifest_id', v_existing.id,
      'installation_id', v_existing.installation_id,
      'package_id', v_existing.package_id,
      'package_version', v_existing.package_version,
      'manifest_status', v_existing.manifest_status,
      'manifest_sha256', v_existing.manifest_sha256
    );
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_SECURITY_VALIDATION';
  end if;

  select f.*
  into v_source_file
  from public.atlas_installation_files as f
  where f.id = p_source_file_id
    and f.installation_id = v_installation.id
    and f.empresa_id = v_installation.empresa_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'MANIFEST_SOURCE_FILE_NOT_FOUND';
  end if;

  if v_source_file.logical_section <> 'MANIFEST'
     or lower(v_source_file.canonical_file_name) <> 'manifest.json'
     or v_source_file.extension <> 'json'
     or v_source_file.validation_status <> 'ACCEPTED' then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_SOURCE_FILE_NOT_ACCEPTED_JSON';
  end if;

  if exists (
    select 1
    from public.atlas_installation_files as newer
    where newer.installation_id = v_source_file.installation_id
      and newer.logical_section = v_source_file.logical_section
      and newer.canonical_file_name = v_source_file.canonical_file_name
      and (
        newer.file_version > v_source_file.file_version
        or (
          newer.file_version = v_source_file.file_version
          and newer.created_at > v_source_file.created_at
        )
      )
  ) then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_SOURCE_FILE_NOT_CURRENT_VERSION';
  end if;

  if v_source_file.sha256 <> v_sha256 then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_SOURCE_SHA256_MISMATCH';
  end if;

  if not exists (
    select 1
    from storage.objects as o
    where o.bucket_id = v_source_file.storage_bucket
      and o.name = v_source_file.storage_object_path
      and o.archived_at is null
      and o.is_delete_marker = false
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'MANIFEST_STORAGE_OBJECT_NOT_FOUND';
  end if;

  if not public.atlas_manifest_payload_is_valid(p_manifest_payload) then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_PAYLOAD_INVALID_OR_CONTAINS_SECRETS';
  end if;

  if p_manifest_payload->>'installation_id' <> v_installation.id::text
     or p_manifest_payload->>'package_id' <> p_package_id::text
     or p_manifest_payload->>'package_version' <> p_package_version::text
     or p_manifest_payload->>'manifest_version' <>
       v_installation.manifest_version then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_IDENTITY_OR_VERSION_MISMATCH';
  end if;

  if btrim(p_manifest_payload->'company'->>'legal_name') <>
       btrim(v_installation.company_legal_name)
     or btrim(p_manifest_payload->'company'->>'trade_name') <>
       btrim(coalesce(
         nullif(v_installation.company_trade_name, ''),
         v_installation.company_legal_name
       ))
     or p_manifest_payload->'company'->>'country' <>
       v_installation.country_code
     or btrim(p_manifest_payload->'company'->>'city') <>
       btrim(coalesce(v_installation.city, ''))
     or p_manifest_payload->'company'->>'timezone' <>
       v_installation.timezone
     or p_manifest_payload->'company'->>'currency' <>
       v_installation.currency_code
     or p_manifest_payload->'plan'->>'implementation_tier' <>
       v_installation.implementation_tier then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_INSTALLATION_PROFILE_MISMATCH';
  end if;

  begin
    v_manifest_owner_user_id := (
      p_manifest_payload->'owner'->>'identity_reference'
    )::uuid;
  exception
    when others then
      raise exception using
        errcode = '22023',
        message = 'MANIFEST_OWNER_IDENTITY_INVALID';
  end;

  if not exists (
    select 1
    from public.atlas_internal_memberships as im
    where im.empresa_id = v_installation.empresa_id
      and im.user_id = v_manifest_owner_user_id
      and im.role_code = 'OWNER'
      and im.status = 'ACTIVE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'MANIFEST_OWNER_NOT_ACTIVE_FOR_EMPRESA';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(
      p_manifest_payload->'files'
    ) as manifest_file(value)
    where jsonb_typeof(manifest_file.value) <> 'object'
       or not (manifest_file.value ?& array[
         'file_id',
         'sha256',
         'logical_section',
         'file_version'
       ])
       or coalesce(manifest_file.value->>'file_id', '') !~
         '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
       or coalesce(manifest_file.value->>'sha256', '') !~
         '^[0-9a-f]{64}$'
       or coalesce(manifest_file.value->>'logical_section', '') !~
         '^[A-Z][A-Z0-9_]*$'
       or coalesce(manifest_file.value->>'file_version', '') !~
         '^[1-9][0-9]*$'
  ) then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_FILE_REFERENCE_INVALID';
  end if;

  select count(*)
  into v_manifest_file_count
  from jsonb_array_elements(p_manifest_payload->'files');

  if (
    select count(distinct manifest_file.value->>'file_id')
    from jsonb_array_elements(
      p_manifest_payload->'files'
    ) as manifest_file(value)
  ) <> v_manifest_file_count then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_FILE_REFERENCE_DUPLICATED';
  end if;

  select count(*)
  into v_current_file_count
  from (
    select distinct on (
      current_file.logical_section,
      current_file.canonical_file_name
    )
      current_file.id
    from public.atlas_installation_files as current_file
    where current_file.installation_id = v_installation.id
      and current_file.logical_section <> 'MANIFEST'
    order by
      current_file.logical_section,
      current_file.canonical_file_name,
      current_file.file_version desc,
      current_file.created_at desc,
      current_file.id desc
  ) as latest_files;

  select count(*)
  into v_matched_file_count
  from jsonb_array_elements(
    p_manifest_payload->'files'
  ) as manifest_file(value)
  join public.atlas_installation_files as f
    on f.id = (manifest_file.value->>'file_id')::uuid
   and f.installation_id = v_installation.id
   and f.empresa_id = v_installation.empresa_id
   and f.sha256 = manifest_file.value->>'sha256'
   and f.logical_section = manifest_file.value->>'logical_section'
   and f.file_version = (manifest_file.value->>'file_version')::integer
   and f.validation_status = 'ACCEPTED'
  where f.logical_section <> 'MANIFEST'
    and not exists (
      select 1
      from public.atlas_installation_files as newer
      where newer.installation_id = f.installation_id
        and newer.logical_section = f.logical_section
        and newer.canonical_file_name = f.canonical_file_name
        and (
          newer.file_version > f.file_version
          or (
            newer.file_version = f.file_version
            and newer.created_at > f.created_at
          )
        )
    );

  if v_manifest_file_count <> v_current_file_count
     or v_matched_file_count <> v_current_file_count then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_CURRENT_FILE_INVENTORY_MISMATCH',
      detail = jsonb_build_object(
        'manifest_file_count', v_manifest_file_count,
        'current_file_count', v_current_file_count,
        'matched_accepted_file_count', v_matched_file_count
      )::text;
  end if;

  select m.*
  into v_existing
  from public.atlas_installation_manifests as m
  where m.installation_id = v_installation.id
    and m.manifest_sha256 = v_sha256
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'MANIFEST_ALREADY_REGISTERED_BY_HASH',
      'manifest_id', v_existing.id,
      'package_id', v_existing.package_id,
      'package_version', v_existing.package_version,
      'manifest_status', v_existing.manifest_status,
      'manifest_sha256', v_existing.manifest_sha256
    );
  end if;

  select m.*
  into v_previous
  from public.atlas_installation_manifests as m
  where m.installation_id = v_installation.id
  order by m.package_version desc, m.created_at desc, m.id desc
  limit 1
  for update;

  if found then
    if v_previous.package_id <> p_package_id then
      raise exception using
        errcode = '22023',
        message = 'MANIFEST_PACKAGE_ID_IMMUTABLE';
    end if;

    if v_previous.manifest_status = 'APPROVED' then
      raise exception using
        errcode = '42501',
        message = 'APPROVED_MANIFEST_CHANGE_REQUIRES_CHANGE_ORDER';
    end if;

    v_latest_version := v_previous.package_version;
  else
    v_latest_version := 0;
  end if;

  if p_package_version <> v_latest_version + 1 then
    raise exception using
      errcode = '40001',
      message = 'MANIFEST_PACKAGE_VERSION_CONFLICT';
  end if;

  select pm.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as pm
  join public.atlas_internal_roles as r
    on r.role_code = pm.role_code
   and r.active = true
  where pm.user_id = v_actor_user_id
    and pm.status = 'ACTIVE'
  order by r.priority asc, pm.created_at asc
  limit 1;

  if v_previous.id is not null then
    update public.atlas_installation_manifests
    set
      manifest_status = 'SUPERSEDED',
      updated_at = now()
    where id = v_previous.id;

    insert into public.atlas_installation_manifest_events (
      installation_id,
      empresa_id,
      manifest_id,
      event_code,
      from_manifest_status,
      to_manifest_status,
      actor_user_id,
      actor_role_code,
      reason,
      request_id,
      package_version,
      manifest_sha256,
      evidence,
      metadata
    )
    values (
      v_previous.installation_id,
      v_previous.empresa_id,
      v_previous.id,
      'MANIFEST_SUPERSEDED',
      v_previous.manifest_status,
      'SUPERSEDED',
      v_actor_user_id,
      v_actor_role_code,
      'Nueva version validada del paquete.',
      p_request_id,
      v_previous.package_version,
      v_previous.manifest_sha256,
      jsonb_build_object(
        'superseded_by_package_version', p_package_version
      ),
      '{}'::jsonb
    );
  end if;

  insert into public.atlas_installation_manifests (
    installation_id,
    empresa_id,
    package_id,
    package_version,
    manifest_version,
    source_file_id,
    manifest_status,
    manifest_payload,
    manifest_sha256,
    created_by_user_id,
    idempotency_key,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    p_package_id,
    p_package_version,
    v_installation.manifest_version,
    v_source_file.id,
    'VALIDATED',
    p_manifest_payload,
    v_sha256,
    v_actor_user_id,
    p_request_id,
    p_metadata || jsonb_build_object(
      'source_storage_bucket', v_source_file.storage_bucket,
      'source_storage_object_path', v_source_file.storage_object_path,
      'registered_via', 'atlas_register_installation_manifest'
    )
  )
  returning * into v_created;

  insert into public.atlas_installation_manifest_events (
    installation_id,
    empresa_id,
    manifest_id,
    event_code,
    from_manifest_status,
    to_manifest_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    package_version,
    manifest_sha256,
    evidence,
    metadata
  )
  values (
    v_created.installation_id,
    v_created.empresa_id,
    v_created.id,
    'MANIFEST_VALIDATED',
    null,
    v_created.manifest_status,
    v_actor_user_id,
    v_actor_role_code,
    'Manifest validado contra archivo fuente y expediente.',
    p_request_id,
    v_created.package_version,
    v_created.manifest_sha256,
    jsonb_build_object(
      'source_file_id', v_created.source_file_id,
      'current_file_count', v_current_file_count,
      'matched_file_count', v_matched_file_count,
      'secret_guard_passed', true
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
    v_created.empresa_id,
    v_actor_user_id,
    null,
    null,
    'INSTALLATION_MANIFEST_REGISTERED',
    'B2_PACKAGE_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'package_id', p_package_id,
      'package_version', p_package_version,
      'source_file_id', p_source_file_id
    ),
    jsonb_build_object(
      'manifest_id', v_created.id,
      'manifest_status', v_created.manifest_status,
      'manifest_sha256', v_created.manifest_sha256,
      'referenced_files', v_manifest_file_count
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_MANIFEST_REGISTERED',
    'manifest_id', v_created.id,
    'installation_id', v_created.installation_id,
    'package_id', v_created.package_id,
    'package_version', v_created.package_version,
    'manifest_status', v_created.manifest_status,
    'manifest_sha256', v_created.manifest_sha256,
    'referenced_files', v_manifest_file_count
  );
end;
$$;

revoke all on function public.atlas_register_installation_manifest(
  uuid, uuid, integer, uuid, jsonb, text, uuid, jsonb
) from public, anon;
grant execute on function public.atlas_register_installation_manifest(
  uuid, uuid, integer, uuid, jsonb, text, uuid, jsonb
) to authenticated, service_role;

create or replace function public.atlas_materialize_installation_inventory(
  p_installation_id uuid,
  p_manifest_id uuid,
  p_request_id uuid,
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
  v_definition public.atlas_installation_inventory_definitions%rowtype;
  v_requirement public.atlas_installation_inventory_requirements%rowtype;
  v_definition_count integer;
  v_existing_count integer;
  v_manifest_requirement_count integer;
  v_request_count integer;
  v_required_count integer;
  v_conditional_count integer;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_INVENTORY_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_INVENTORY_MANAGE_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_manifest_id is null
     or p_request_id is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'INVENTORY_MATERIALIZATION_REQUIRED_FIELDS_MISSING';
  end if;

  select i.*
  into v_installation
  from public.atlas_installations as i
  where i.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_SECURITY_VALIDATION';
  end if;

  select m.*
  into v_manifest
  from public.atlas_installation_manifests as m
  where m.id = p_manifest_id
    and m.installation_id = v_installation.id
    and m.empresa_id = v_installation.empresa_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_MANIFEST_NOT_FOUND';
  end if;

  if v_manifest.manifest_status not in ('VALIDATED', 'APPROVED') then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_NOT_READY_FOR_INVENTORY';
  end if;

  if exists (
    select 1
    from public.atlas_installation_manifests as newer
    where newer.installation_id = v_manifest.installation_id
      and newer.package_id = v_manifest.package_id
      and newer.package_version > v_manifest.package_version
      and newer.manifest_status in ('VALIDATED', 'APPROVED')
  ) then
    raise exception using
      errcode = '22023',
      message = 'MANIFEST_NOT_LATEST_VALIDATED_VERSION';
  end if;

  select count(*)
  into v_definition_count
  from public.atlas_installation_inventory_definitions
  where active = true;

  if v_definition_count <> 37 then
    raise exception using
      errcode = '23514',
      message = 'INVENTORY_DEFINITION_CATALOG_DRIFT',
      detail = jsonb_build_object(
        'expected_active_definitions', 37,
        'actual_active_definitions', v_definition_count
      )::text;
  end if;

  select count(*)
  into v_existing_count
  from public.atlas_installation_inventory_requirements
  where installation_id = v_installation.id;

  select count(*)
  into v_request_count
  from public.atlas_installation_inventory_requirements
  where installation_id = v_installation.id
    and idempotency_key = p_request_id;

  select count(*)
  into v_manifest_requirement_count
  from public.atlas_installation_inventory_requirements
  where installation_id = v_installation.id
    and source_manifest_id = v_manifest.id;

  if v_existing_count = v_definition_count
     and v_manifest_requirement_count = v_definition_count
     and v_request_count = v_definition_count then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_installation.id,
      'manifest_id', v_manifest.id,
      'inventory_requirements', v_existing_count
    );
  end if;

  if v_existing_count = v_definition_count
     and v_manifest_requirement_count = v_definition_count then
    return jsonb_build_object(
      'ok', true,
      'code', 'INVENTORY_ALREADY_MATERIALIZED',
      'installation_id', v_installation.id,
      'manifest_id', v_manifest.id,
      'inventory_requirements', v_existing_count
    );
  end if;

  if v_existing_count <> 0 then
    raise exception using
      errcode = '23514',
      message = case
        when v_existing_count = v_definition_count
          then 'INVENTORY_REBASE_REQUIRED_FOR_NEW_MANIFEST'
        else 'INVENTORY_PARTIAL_STATE_DETECTED'
      end,
      detail = jsonb_build_object(
        'existing_requirements', v_existing_count,
        'active_definitions', v_definition_count,
        'requirements_for_manifest', v_manifest_requirement_count,
        'manifest_id', v_manifest.id
      )::text;
  end if;

  select pm.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as pm
  join public.atlas_internal_roles as r
    on r.role_code = pm.role_code
   and r.active = true
  where pm.user_id = v_actor_user_id
    and pm.status = 'ACTIVE'
  order by r.priority asc, pm.created_at asc
  limit 1;

  for v_definition in
    select d.*
    from public.atlas_installation_inventory_definitions as d
    where d.active = true
    order by d.sort_order, d.inventory_code
  loop
    insert into public.atlas_installation_inventory_requirements (
      installation_id,
      empresa_id,
      source_manifest_id,
      inventory_code,
      requirement_mode,
      determination_reason,
      determination_source,
      fulfillment_status,
      requirement_version,
      determined_by_user_id,
      idempotency_key,
      rule_snapshot,
      metadata
    )
    values (
      v_installation.id,
      v_installation.empresa_id,
      v_manifest.id,
      v_definition.inventory_code,
      v_definition.default_requirement_mode,
      v_definition.applicability_rule->>'reason',
      'PLATFORM_DEFAULT',
      case
        when v_definition.default_requirement_mode = 'NOT_APPLICABLE'
          then 'NOT_APPLICABLE'
        else 'PENDING'
      end,
      1,
      v_actor_user_id,
      p_request_id,
      jsonb_build_object(
        'definition_code', v_definition.inventory_code,
        'definition_updated_at', v_definition.updated_at,
        'default_requirement_mode', v_definition.default_requirement_mode,
        'applicability_rule', v_definition.applicability_rule,
        'manifest_id', v_manifest.id,
        'manifest_sha256', v_manifest.manifest_sha256
      ),
      p_metadata || jsonb_build_object(
        'materialized_via', 'atlas_materialize_installation_inventory'
      )
    )
    returning * into v_requirement;

    insert into public.atlas_installation_inventory_events (
      installation_id,
      empresa_id,
      requirement_id,
      inventory_code,
      event_code,
      from_requirement_mode,
      to_requirement_mode,
      from_fulfillment_status,
      to_fulfillment_status,
      actor_user_id,
      actor_role_code,
      reason,
      request_id,
      requirement_version,
      evidence,
      metadata
    )
    values (
      v_requirement.installation_id,
      v_requirement.empresa_id,
      v_requirement.id,
      v_requirement.inventory_code,
      'INVENTORY_REQUIREMENT_MATERIALIZED',
      null,
      v_requirement.requirement_mode,
      null,
      v_requirement.fulfillment_status,
      v_actor_user_id,
      v_actor_role_code,
      v_requirement.determination_reason,
      p_request_id,
      v_requirement.requirement_version,
      jsonb_build_object(
        'manifest_id', v_manifest.id,
        'manifest_sha256', v_manifest.manifest_sha256,
        'determination_source', v_requirement.determination_source
      ),
      '{}'::jsonb
    );
  end loop;

  select
    count(*) filter (where requirement_mode = 'REQUIRED'),
    count(*) filter (where requirement_mode = 'CONDITIONAL')
  into
    v_required_count,
    v_conditional_count
  from public.atlas_installation_inventory_requirements
  where installation_id = v_installation.id;

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
    'INSTALLATION_INVENTORY_MATERIALIZED',
    'B2_PACKAGE_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'manifest_id', v_manifest.id,
      'package_version', v_manifest.package_version
    ),
    jsonb_build_object(
      'inventory_requirements', v_definition_count,
      'required', v_required_count,
      'conditional', v_conditional_count
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_INVENTORY_MATERIALIZED',
    'installation_id', v_installation.id,
    'manifest_id', v_manifest.id,
    'inventory_requirements', v_definition_count,
    'required', v_required_count,
    'conditional', v_conditional_count
  );
end;
$$;

revoke all on function public.atlas_materialize_installation_inventory(
  uuid, uuid, uuid, jsonb
) from public, anon;
grant execute on function public.atlas_materialize_installation_inventory(
  uuid, uuid, uuid, jsonb
) to authenticated, service_role;

create or replace function public.atlas_enforce_security_file_completion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total_files bigint;
  v_unaccepted_files bigint;
  v_valid_manifest_count bigint;
  v_valid_manifest_id uuid;
  v_active_definition_count bigint;
  v_inventory_requirement_count bigint;
begin
  if old.current_state_code = 'SECURITY_VALIDATION'
     and new.current_state_code = 'LEGAL_REVIEW' then
    select
      count(*),
      count(*) filter (where f.validation_status <> 'ACCEPTED')
    into
      v_total_files,
      v_unaccepted_files
    from (
      select distinct on (
        source_file.logical_section,
        source_file.canonical_file_name
      )
        source_file.validation_status
      from public.atlas_installation_files as source_file
      where source_file.installation_id = old.id
      order by
        source_file.logical_section,
        source_file.canonical_file_name,
        source_file.file_version desc,
        source_file.created_at desc,
        source_file.id desc
    ) as f;

    if v_total_files = 0 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_FILES_REQUIRED';
    end if;

    if v_unaccepted_files > 0 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_UNACCEPTED_FILES_REMAIN',
        detail = jsonb_build_object(
          'current_files', v_total_files,
          'unaccepted_files', v_unaccepted_files
        )::text;
    end if;

    select
      count(*),
      (array_agg(
        m.id
        order by m.package_version desc, m.created_at desc, m.id desc
      ))[1]
    into
      v_valid_manifest_count,
      v_valid_manifest_id
    from public.atlas_installation_manifests as m
    where m.installation_id = old.id
      and m.manifest_status in ('VALIDATED', 'APPROVED')
      and not exists (
        select 1
        from public.atlas_installation_manifests as newer
        where newer.installation_id = m.installation_id
          and newer.package_id = m.package_id
          and newer.package_version > m.package_version
      );

    if v_valid_manifest_count <> 1 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_VALID_MANIFEST_REQUIRED';
    end if;

    select count(*)
    into v_active_definition_count
    from public.atlas_installation_inventory_definitions
    where active = true;

    select count(*)
    into v_inventory_requirement_count
    from public.atlas_installation_inventory_requirements as requirement
    join public.atlas_installation_inventory_definitions as definition
      on definition.inventory_code = requirement.inventory_code
     and definition.active = true
    where requirement.installation_id = old.id
      and requirement.source_manifest_id = v_valid_manifest_id;

    if v_inventory_requirement_count <> v_active_definition_count then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_INVENTORY_NOT_MATERIALIZED',
        detail = jsonb_build_object(
          'active_definitions', v_active_definition_count,
          'materialized_requirements', v_inventory_requirement_count
        )::text;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.atlas_enforce_security_file_completion()
  from public, anon, authenticated;
grant execute on function public.atlas_enforce_security_file_completion()
  to service_role;

comment on function public.atlas_register_installation_manifest(
  uuid, uuid, integer, uuid, jsonb, text, uuid, jsonb
) is
  'B2: registra un manifest validado desde archivo ACCEPTED, con identidad, hash e inventario de archivos coincidentes.';

comment on function public.atlas_materialize_installation_inventory(
  uuid, uuid, uuid, jsonb
) is
  'B2: materializa las definiciones activas sin decidir condiciones que corresponden al diagnostico.';

comment on function public.atlas_enforce_security_file_completion() is
  'B2: exige archivos ACCEPTED, manifest VALIDATED/APPROVED e inventario completo antes de LEGAL_REVIEW.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2D2_MANIFEST_INVENTORY_RPCS_INSTALLED',
  'next_action', 'CERTIFY_D2_RPCS_WITH_NEGATIVE_PROBES',
  'manifest_registration_enabled', (
    to_regprocedure(
      'public.atlas_register_installation_manifest(uuid,uuid,integer,uuid,jsonb,text,uuid,jsonb)'
    ) is not null
  ),
  'inventory_materialization_enabled', (
    to_regprocedure(
      'public.atlas_materialize_installation_inventory(uuid,uuid,uuid,jsonb)'
    ) is not null
  ),
  'security_exit_requires_manifest', true,
  'security_exit_requires_inventory', true,
  'inventory_bound_to_source_manifest', true,
  'manifest_records', (
    select count(*)
    from public.atlas_installation_manifests
  ),
  'inventory_requirement_records', (
    select count(*)
    from public.atlas_installation_inventory_requirements
  ),
  'inventory_definitions', (
    select count(*)
    from public.atlas_installation_inventory_definitions
    where active = true
  ),
  'direct_authenticated_write', false,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  )
) as result;
