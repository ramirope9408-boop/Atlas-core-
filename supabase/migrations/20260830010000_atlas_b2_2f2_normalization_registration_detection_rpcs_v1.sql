-- ATLAS B2.2F.2
-- RPC gobernadas de lotes, propuestas normalizadas y deteccion de incidencias.
-- Corte: 2026-08-30
--
-- Principios:
-- - solo opera durante DATA_NORMALIZATION;
-- - todo lote se liga al manifest vigente y sus 37 requisitos;
-- - todo registro se liga a un archivo ACCEPTED, actual y presente en Storage;
-- - el hash SHA-256 del JSONB se calcula dentro de PostgreSQL;
-- - el analisis es reejecutable e idempotente;
-- - no aprueba al cliente ni promueve valores a tablas canonicas.

begin;

do $$
begin
  if to_regclass('public.atlas_normalization_batches') is null
     or to_regclass('public.atlas_normalized_records') is null
     or to_regclass('public.atlas_normalization_issues') is null
     or to_regclass('public.atlas_normalization_events') is null then
    raise exception 'B2.2F.2 requiere B2.2F.1 instalado y certificado';
  end if;

  if not exists (
    select 1
    from pg_proc as procedure_definition
    join pg_namespace as namespace_definition
      on namespace_definition.oid = procedure_definition.pronamespace
    where procedure_definition.proname = 'digest'
      and procedure_definition.pronargs = 2
      and procedure_definition.proargtypes[0] = 'bytea'::regtype
      and procedure_definition.proargtypes[1] = 'text'::regtype
  ) then
    raise exception 'B2.2F.2 requiere pgcrypto.digest(bytea,text)';
  end if;
end;
$$;

alter table public.atlas_normalization_batches
  add column if not exists state_version bigint not null default 1;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.atlas_normalization_batches'::regclass
      and conname = 'atlas_normalization_batches_state_version_check'
  ) then
    alter table public.atlas_normalization_batches
      add constraint atlas_normalization_batches_state_version_check
      check (state_version >= 1);
  end if;
end;
$$;

create or replace function public.atlas_normalization_sha256(
  p_value text
)
returns text
language plpgsql
stable
strict
security definer
set search_path = public, pg_temp
as $$
declare
  v_digest_schema text;
  v_result text;
begin
  select namespace_definition.nspname
  into v_digest_schema
  from pg_proc as procedure_definition
  join pg_namespace as namespace_definition
    on namespace_definition.oid = procedure_definition.pronamespace
  where procedure_definition.proname = 'digest'
    and procedure_definition.pronargs = 2
    and procedure_definition.proargtypes[0] = 'bytea'::regtype
    and procedure_definition.proargtypes[1] = 'text'::regtype
  order by
    case when namespace_definition.nspname = 'extensions' then 0 else 1 end,
    namespace_definition.nspname
  limit 1;

  if v_digest_schema is null then
    raise exception using
      errcode = '55000',
      message = 'SHA256_PROVIDER_NOT_AVAILABLE';
  end if;

  execute format(
    'select encode(%I.digest(convert_to($1, ''UTF8''), ''sha256''), ''hex'')',
    v_digest_schema
  )
  using p_value
  into v_result;

  return v_result;
end;
$$;

revoke all on function public.atlas_normalization_sha256(text)
  from public, anon, authenticated;
grant execute on function public.atlas_normalization_sha256(text)
  to service_role;

create or replace function public.atlas_create_normalization_batch(
  p_installation_id uuid,
  p_source_manifest_id uuid,
  p_schema_version text,
  p_request_id uuid,
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
  v_schema_version text := upper(nullif(btrim(p_schema_version), ''));
  v_actor_role_code text;
  v_installation public.atlas_installations%rowtype;
  v_manifest public.atlas_installation_manifests%rowtype;
  v_existing public.atlas_normalization_batches%rowtype;
  v_created public.atlas_normalization_batches%rowtype;
  v_next_batch_version integer;
  v_requirement_count bigint;
  v_unresolved_conditional_count bigint;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_NORMALIZATION_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_NORMALIZATION_MANAGE_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_source_manifest_id is null
     or v_schema_version is null
     or v_schema_version !~ '^B2_NORM_V[0-9]+$'
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_BATCH_REQUIRED_FIELDS_MISSING';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_BATCH_METADATA_CONTAINS_SECRET';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_NOT_FOUND';
  end if;

  select batch.*
  into v_existing
  from public.atlas_normalization_batches as batch
  where batch.installation_id = v_installation.id
    and batch.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.source_manifest_id <> p_source_manifest_id
       or v_existing.schema_version <> v_schema_version
       or v_existing.metadata->'creation_request_metadata' <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'NORMALIZATION_BATCH_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'normalization_batch_id', v_existing.id,
      'installation_id', v_existing.installation_id,
      'batch_version', v_existing.batch_version,
      'state_version', v_existing.state_version,
      'batch_status', v_existing.batch_status,
      'source_manifest_id', v_existing.source_manifest_id
    );
  end if;

  if v_installation.current_state_code <> 'DATA_NORMALIZATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_DATA_NORMALIZATION';
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001',
      message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  select manifest.*
  into v_manifest
  from public.atlas_installation_manifests as manifest
  where manifest.id = p_source_manifest_id
    and manifest.installation_id = v_installation.id
    and manifest.empresa_id = v_installation.empresa_id
    and manifest.manifest_status in ('VALIDATED', 'APPROVED');

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'NORMALIZATION_SOURCE_MANIFEST_NOT_FOUND_OR_VALID';
  end if;

  if exists (
    select 1
    from public.atlas_installation_manifests as newer_manifest
    where newer_manifest.installation_id = v_manifest.installation_id
      and newer_manifest.package_id = v_manifest.package_id
      and newer_manifest.package_version > v_manifest.package_version
  ) then
    raise exception using
      errcode = '40001',
      message = 'NORMALIZATION_SOURCE_MANIFEST_NOT_CURRENT';
  end if;

  if not exists (
    select 1
    from public.atlas_installation_files as manifest_file
    join storage.objects as storage_object
      on storage_object.bucket_id = manifest_file.storage_bucket
     and storage_object.name = manifest_file.storage_object_path
     and storage_object.archived_at is null
     and storage_object.is_delete_marker = false
    where manifest_file.id = v_manifest.source_file_id
      and manifest_file.validation_status = 'ACCEPTED'
      and manifest_file.sha256 = v_manifest.manifest_sha256
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'NORMALIZATION_MANIFEST_STORAGE_OBJECT_NOT_FOUND';
  end if;

  select count(*)
  into v_requirement_count
  from public.atlas_installation_inventory_requirements as requirement
  where requirement.installation_id = v_installation.id
    and requirement.source_manifest_id = v_manifest.id;

  if v_requirement_count <> (
    select count(*)
    from public.atlas_installation_inventory_definitions
    where active = true
  ) then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_INVENTORY_NOT_MATERIALIZED';
  end if;

  select count(*)
  into v_unresolved_conditional_count
  from public.atlas_installation_inventory_requirements as requirement
  join public.atlas_installation_inventory_definitions as definition
    on definition.inventory_code = requirement.inventory_code
   and definition.active = true
  where requirement.installation_id = v_installation.id
    and requirement.source_manifest_id = v_manifest.id
    and definition.default_requirement_mode = 'CONDITIONAL'
    and requirement.requirement_mode = 'CONDITIONAL';

  if v_unresolved_conditional_count > 0 then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_CONDITIONAL_REQUIREMENTS_UNRESOLVED';
  end if;

  if exists (
    select 1
    from public.atlas_normalization_batches as active_batch
    where active_batch.installation_id = v_installation.id
      and active_batch.batch_status not in (
        'APPROVED', 'REJECTED', 'SUPERSEDED'
      )
  ) then
    raise exception using
      errcode = '55000',
      message = 'NORMALIZATION_BATCH_ALREADY_ACTIVE';
  end if;

  select coalesce(max(batch.batch_version), 0) + 1
  into v_next_batch_version
  from public.atlas_normalization_batches as batch
  where batch.installation_id = v_installation.id;

  select platform_membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as platform_membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = platform_membership.role_code
   and role_definition.active = true
  where platform_membership.user_id = v_actor_user_id
    and platform_membership.status = 'ACTIVE'
  order by role_definition.priority asc, platform_membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PLATFORM_ACTOR_ROLE_NOT_FOUND';
  end if;

  insert into public.atlas_normalization_batches (
    installation_id,
    empresa_id,
    source_manifest_id,
    batch_version,
    schema_version,
    batch_status,
    source_manifest_sha256,
    started_at,
    created_by_user_id,
    idempotency_key,
    metadata,
    state_version
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_manifest.id,
    v_next_batch_version,
    v_schema_version,
    'DRAFT',
    v_manifest.manifest_sha256,
    now(),
    v_actor_user_id,
    p_request_id,
    p_metadata || jsonb_build_object(
      'creation_request_metadata', p_metadata
    ),
    1
  )
  returning * into v_created;

  insert into public.atlas_normalization_events (
    installation_id, empresa_id, normalization_batch_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, reason, request_id,
    evidence, metadata
  )
  values (
    v_created.installation_id, v_created.empresa_id, v_created.id,
    'BATCH', v_created.id, 'NORMALIZATION_BATCH_CREATED', null, 'DRAFT',
    v_actor_user_id, v_actor_role_code,
    'Lote de normalizacion creado desde manifest vigente.',
    p_request_id,
    jsonb_build_object(
      'source_manifest_id', v_manifest.id,
      'source_manifest_sha256', v_manifest.manifest_sha256,
      'inventory_requirements', v_requirement_count
    ),
    '{}'::jsonb
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_created.empresa_id, v_actor_user_id, null, null,
    'NORMALIZATION_BATCH_CREATED', 'B2_NORMALIZATION_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'source_manifest_id', v_manifest.id,
      'schema_version', v_schema_version
    ),
    jsonb_build_object(
      'normalization_batch_id', v_created.id,
      'batch_version', v_created.batch_version,
      'state_version', v_created.state_version
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'NORMALIZATION_BATCH_CREATED',
    'normalization_batch_id', v_created.id,
    'installation_id', v_created.installation_id,
    'batch_version', v_created.batch_version,
    'state_version', v_created.state_version,
    'batch_status', v_created.batch_status,
    'source_manifest_id', v_created.source_manifest_id,
    'inventory_requirements', v_requirement_count
  );
end;
$$;

revoke all on function public.atlas_create_normalization_batch(
  uuid, uuid, text, uuid, bigint, jsonb
) from public, anon;
grant execute on function public.atlas_create_normalization_batch(
  uuid, uuid, text, uuid, bigint, jsonb
) to authenticated, service_role;

create or replace function public.atlas_register_normalized_record(
  p_normalization_batch_id uuid,
  p_inventory_requirement_id uuid,
  p_source_file_id uuid,
  p_record_key text,
  p_proposed_value jsonb,
  p_source_locator jsonb,
  p_confidence numeric,
  p_valid_from timestamptz,
  p_valid_until timestamptz,
  p_request_id uuid,
  p_expected_batch_state_version bigint,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_record_key text := upper(nullif(btrim(p_record_key), ''));
  v_actor_role_code text;
  v_value_type text;
  v_format_valid boolean := false;
  v_value_sha256 text;
  v_record_version integer;
  v_record_status text;
  v_batch public.atlas_normalization_batches%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_requirement public.atlas_installation_inventory_requirements%rowtype;
  v_source_file public.atlas_installation_files%rowtype;
  v_existing public.atlas_normalized_records%rowtype;
  v_created public.atlas_normalized_records%rowtype;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_NORMALIZATION_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_NORMALIZATION_MANAGE_FORBIDDEN';
  end if;

  if p_normalization_batch_id is null
     or p_inventory_requirement_id is null
     or p_source_file_id is null
     or v_record_key is null
     or v_record_key !~ '^[A-Z0-9][A-Z0-9_.:-]*$'
     or length(v_record_key) > 180
     or p_proposed_value is null
     or jsonb_typeof(p_proposed_value) <> 'object'
     or not (p_proposed_value ?& array[
       'value', 'value_type', 'normalization_rule'
     ])
     or nullif(btrim(p_proposed_value->>'normalization_rule'), '') is null
     or p_source_locator is null
     or jsonb_typeof(p_source_locator) <> 'object'
     or nullif(btrim(p_source_locator->>'source_reference'), '') is null
     or p_request_id is null
     or p_expected_batch_state_version is null
     or p_expected_batch_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZED_RECORD_REQUIRED_FIELDS_MISSING';
  end if;

  if p_valid_until is not null
     and p_valid_from is not null
     and p_valid_until <= p_valid_from then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZED_RECORD_VALIDITY_RANGE_INVALID';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_proposed_value)
     or public.atlas_jsonb_has_forbidden_secret_key(p_source_locator)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZED_RECORD_CONTAINS_SECRET';
  end if;

  select batch.*
  into v_batch
  from public.atlas_normalization_batches as batch
  where batch.id = p_normalization_batch_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'NORMALIZATION_BATCH_NOT_FOUND';
  end if;

  select record.*
  into v_existing
  from public.atlas_normalized_records as record
  where record.normalization_batch_id = v_batch.id
    and record.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.inventory_requirement_id <>
         p_inventory_requirement_id
       or v_existing.source_file_id <> p_source_file_id
       or v_existing.record_key <> v_record_key
       or v_existing.proposed_value <> p_proposed_value
       or v_existing.source_locator <> p_source_locator
       or v_existing.confidence is distinct from p_confidence
       or v_existing.valid_from is distinct from p_valid_from
       or v_existing.valid_until is distinct from p_valid_until
       or v_existing.metadata->'registration_request_metadata' <>
         p_metadata then
      raise exception using
        errcode = '22023',
        message = 'NORMALIZED_RECORD_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'normalized_record_id', v_existing.id,
      'normalization_batch_id', v_existing.normalization_batch_id,
      'inventory_code', v_existing.inventory_code,
      'record_key', v_existing.record_key,
      'record_version', v_existing.record_version,
      'normalization_status', v_existing.normalization_status,
      'value_sha256', v_existing.value_sha256,
      'batch_state_version', v_batch.state_version
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_batch.installation_id;

  if v_installation.current_state_code <> 'DATA_NORMALIZATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_DATA_NORMALIZATION';
  end if;

  if v_batch.batch_status not in ('DRAFT', 'NORMALIZING') then
    raise exception using
      errcode = '55000',
      message = 'NORMALIZATION_BATCH_NOT_OPEN_FOR_RECORDS';
  end if;

  if v_batch.state_version <> p_expected_batch_state_version then
    raise exception using
      errcode = '40001',
      message = 'NORMALIZATION_BATCH_VERSION_CONFLICT';
  end if;

  select requirement.*
  into v_requirement
  from public.atlas_installation_inventory_requirements as requirement
  where requirement.id = p_inventory_requirement_id
    and requirement.installation_id = v_batch.installation_id
    and requirement.empresa_id = v_batch.empresa_id
    and requirement.source_manifest_id = v_batch.source_manifest_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'NORMALIZATION_INVENTORY_REQUIREMENT_NOT_FOUND';
  end if;

  if v_requirement.requirement_mode = 'NOT_APPLICABLE'
     or v_requirement.fulfillment_status = 'NOT_APPLICABLE' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_REQUIREMENT_NOT_APPLICABLE';
  end if;

  select source_file.*
  into v_source_file
  from public.atlas_installation_files as source_file
  where source_file.id = p_source_file_id
    and source_file.installation_id = v_batch.installation_id
    and source_file.empresa_id = v_batch.empresa_id;

  if not found
     or v_source_file.validation_status <> 'ACCEPTED' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_SOURCE_FILE_NOT_ACCEPTED';
  end if;

  if exists (
    select 1
    from public.atlas_installation_files as newer_source_file
    where newer_source_file.installation_id = v_source_file.installation_id
      and newer_source_file.logical_section = v_source_file.logical_section
      and newer_source_file.canonical_file_name =
        v_source_file.canonical_file_name
      and (
        newer_source_file.file_version > v_source_file.file_version
        or (
          newer_source_file.file_version = v_source_file.file_version
          and newer_source_file.created_at > v_source_file.created_at
        )
      )
  ) then
    raise exception using
      errcode = '40001',
      message = 'NORMALIZATION_SOURCE_FILE_NOT_CURRENT';
  end if;

  if not exists (
    select 1
    from storage.objects as storage_object
    where storage_object.bucket_id = v_source_file.storage_bucket
      and storage_object.name = v_source_file.storage_object_path
      and storage_object.archived_at is null
      and storage_object.is_delete_marker = false
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'NORMALIZATION_SOURCE_STORAGE_OBJECT_NOT_FOUND';
  end if;

  if p_source_locator->>'source_file_id' is distinct from
       v_source_file.id::text
     or p_source_locator->>'source_file_sha256' is distinct from
       v_source_file.sha256 then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_SOURCE_LOCATOR_IDENTITY_MISMATCH';
  end if;

  v_value_type := upper(nullif(btrim(p_proposed_value->>'value_type'), ''));
  v_format_valid := case v_value_type
    when 'TEXT' then jsonb_typeof(p_proposed_value->'value') = 'string'
    when 'NUMBER' then jsonb_typeof(p_proposed_value->'value') = 'number'
    when 'BOOLEAN' then jsonb_typeof(p_proposed_value->'value') = 'boolean'
    when 'OBJECT' then jsonb_typeof(p_proposed_value->'value') = 'object'
    when 'ARRAY' then jsonb_typeof(p_proposed_value->'value') = 'array'
    when 'DATE' then
      jsonb_typeof(p_proposed_value->'value') = 'string'
      and p_proposed_value->>'value' ~
        '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    when 'DATETIME' then
      jsonb_typeof(p_proposed_value->'value') = 'string'
      and p_proposed_value->>'value' ~
        '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
    else false
  end;

  v_value_sha256 := public.atlas_normalization_sha256(
    p_proposed_value::text
  );

  v_record_status := case
    when v_format_valid
      and p_confidence is not null
      and p_confidence >= 0.75000 then 'NORMALIZED'
    else 'NEEDS_REVIEW'
  end;

  select coalesce(max(record.record_version), 0) + 1
  into v_record_version
  from public.atlas_normalized_records as record
  where record.normalization_batch_id = v_batch.id
    and record.inventory_requirement_id = v_requirement.id
    and record.record_key = v_record_key;

  select platform_membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as platform_membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = platform_membership.role_code
   and role_definition.active = true
  where platform_membership.user_id = v_actor_user_id
    and platform_membership.status = 'ACTIVE'
  order by role_definition.priority asc, platform_membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PLATFORM_ACTOR_ROLE_NOT_FOUND';
  end if;

  insert into public.atlas_normalized_records (
    installation_id,
    empresa_id,
    normalization_batch_id,
    inventory_requirement_id,
    inventory_code,
    source_file_id,
    record_key,
    record_version,
    normalization_status,
    proposed_value,
    value_sha256,
    source_locator,
    confidence,
    valid_from,
    valid_until,
    created_by_user_id,
    idempotency_key,
    metadata
  )
  values (
    v_batch.installation_id,
    v_batch.empresa_id,
    v_batch.id,
    v_requirement.id,
    v_requirement.inventory_code,
    v_source_file.id,
    v_record_key,
    v_record_version,
    v_record_status,
    p_proposed_value,
    v_value_sha256,
    p_source_locator,
    p_confidence,
    p_valid_from,
    p_valid_until,
    v_actor_user_id,
    p_request_id,
    p_metadata || jsonb_build_object(
      'registration_request_metadata', p_metadata,
      'format_valid', v_format_valid,
      'source_file_sha256', v_source_file.sha256,
      'registered_at', now()
    )
  )
  returning * into v_created;

  update public.atlas_normalization_batches
  set
    batch_status = 'NORMALIZING',
    state_version = state_version + 1,
    completed_at = null,
    updated_at = now()
  where id = v_batch.id
  returning * into v_batch;

  insert into public.atlas_normalization_events (
    installation_id, empresa_id, normalization_batch_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, reason, request_id,
    evidence, metadata
  )
  values (
    v_batch.installation_id, v_batch.empresa_id, v_batch.id,
    'RECORD', v_created.id, 'NORMALIZED_RECORD_REGISTERED', null,
    v_created.normalization_status,
    v_actor_user_id, v_actor_role_code,
    'Propuesta normalizada registrada con linaje verificable.',
    p_request_id,
    jsonb_build_object(
      'inventory_requirement_id', v_requirement.id,
      'inventory_code', v_requirement.inventory_code,
      'source_file_id', v_source_file.id,
      'source_file_sha256', v_source_file.sha256,
      'value_sha256', v_created.value_sha256,
      'format_valid', v_format_valid,
      'confidence', p_confidence
    ),
    '{}'::jsonb
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_created.empresa_id, v_actor_user_id, null, null,
    'NORMALIZED_RECORD_REGISTERED',
    'B2_NORMALIZATION_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'normalization_batch_id', v_batch.id,
      'inventory_code', v_requirement.inventory_code,
      'record_key', v_record_key,
      'source_file_id', v_source_file.id
    ),
    jsonb_build_object(
      'normalized_record_id', v_created.id,
      'record_version', v_created.record_version,
      'normalization_status', v_created.normalization_status,
      'value_sha256', v_created.value_sha256,
      'batch_state_version', v_batch.state_version
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'NORMALIZED_RECORD_REGISTERED',
    'normalized_record_id', v_created.id,
    'normalization_batch_id', v_created.normalization_batch_id,
    'inventory_requirement_id', v_created.inventory_requirement_id,
    'inventory_code', v_created.inventory_code,
    'record_key', v_created.record_key,
    'record_version', v_created.record_version,
    'normalization_status', v_created.normalization_status,
    'value_sha256', v_created.value_sha256,
    'format_valid', v_format_valid,
    'batch_status', v_batch.batch_status,
    'batch_state_version', v_batch.state_version
  );
end;
$$;

revoke all on function public.atlas_register_normalized_record(
  uuid, uuid, uuid, text, jsonb, jsonb, numeric,
  timestamptz, timestamptz, uuid, bigint, jsonb
) from public, anon;
grant execute on function public.atlas_register_normalized_record(
  uuid, uuid, uuid, text, jsonb, jsonb, numeric,
  timestamptz, timestamptz, uuid, bigint, jsonb
) to authenticated, service_role;

create or replace function public.atlas_analyze_normalization_batch(
  p_normalization_batch_id uuid,
  p_request_id uuid,
  p_expected_batch_state_version bigint,
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
  v_batch public.atlas_normalization_batches%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing_event public.atlas_normalization_events%rowtype;
  v_detected_count bigint := 0;
  v_blocking_count bigint := 0;
  v_record_count bigint := 0;
  v_target_status text;
  v_from_status text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_NORMALIZATION_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_NORMALIZATION_MANAGE_FORBIDDEN';
  end if;

  if p_normalization_batch_id is null
     or p_request_id is null
     or p_expected_batch_state_version is null
     or p_expected_batch_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_ANALYSIS_REQUIRED_FIELDS_MISSING';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_ANALYSIS_METADATA_CONTAINS_SECRET';
  end if;

  select batch.*
  into v_batch
  from public.atlas_normalization_batches as batch
  where batch.id = p_normalization_batch_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'NORMALIZATION_BATCH_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_normalization_events as event_record
  where event_record.normalization_batch_id = v_batch.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <> 'NORMALIZATION_ANALYSIS_COMPLETED'
       or v_existing_event.metadata->'request_metadata' <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'NORMALIZATION_ANALYSIS_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'normalization_batch_id', v_batch.id,
      'batch_status', v_batch.batch_status,
      'batch_state_version', v_batch.state_version,
      'records', (v_existing_event.evidence->>'records')::bigint,
      'detected_issues',
        (v_existing_event.evidence->>'detected_issues')::bigint,
      'blocking_issues',
        (v_existing_event.evidence->>'blocking_issues')::bigint
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_batch.installation_id;

  if v_installation.current_state_code <> 'DATA_NORMALIZATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_DATA_NORMALIZATION';
  end if;

  if v_batch.batch_status not in ('DRAFT', 'NORMALIZING') then
    raise exception using
      errcode = '55000',
      message = 'NORMALIZATION_BATCH_NOT_ANALYZABLE';
  end if;

  if v_batch.state_version <> p_expected_batch_state_version then
    raise exception using
      errcode = '40001',
      message = 'NORMALIZATION_BATCH_VERSION_CONFLICT';
  end if;

  v_from_status := v_batch.batch_status;

  select platform_membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as platform_membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = platform_membership.role_code
   and role_definition.active = true
  where platform_membership.user_id = v_actor_user_id
    and platform_membership.status = 'ACTIVE'
  order by role_definition.priority asc, platform_membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PLATFORM_ACTOR_ROLE_NOT_FOUND';
  end if;

  update public.atlas_normalization_issues
  set
    issue_status = 'RESOLVED',
    resolution = jsonb_build_object(
      'resolution_type', 'AUTOMATIC_REANALYSIS_SUPERSEDED',
      'analysis_request_id', p_request_id
    ),
    resolved_by_user_id = v_actor_user_id,
    resolved_at = now(),
    updated_at = now()
  where normalization_batch_id = v_batch.id
    and issue_status = 'OPEN'
    and metadata->>'detector' = 'F2_AUTOMATIC';

  with active_records as (
    select record.*
    from public.atlas_normalized_records as record
    where record.normalization_batch_id = v_batch.id
      and record.normalization_status <> 'SUPERSEDED'
  ),
  issue_candidates as (
    select
      requirement.id as inventory_requirement_id,
      requirement.inventory_code,
      null::uuid as normalized_record_id,
      'MISSING_REQUIRED_VALUE'::text as issue_code,
      'No existe propuesta normalizada para el requisito obligatorio.'::text
        as description,
      'inventory_requirement:' || requirement.id::text as source_reference,
      requirement.id::text as fingerprint_material,
      jsonb_build_object(
        'requirement_mode', requirement.requirement_mode,
        'fulfillment_status', requirement.fulfillment_status
      ) as evidence_details
    from public.atlas_installation_inventory_requirements as requirement
    where requirement.installation_id = v_batch.installation_id
      and requirement.source_manifest_id = v_batch.source_manifest_id
      and requirement.requirement_mode = 'REQUIRED'
      and not exists (
        select 1
        from active_records as record
        where record.inventory_requirement_id = requirement.id
      )

    union all

    select
      record.inventory_requirement_id,
      record.inventory_code,
      null::uuid,
      'DUPLICATE_VALUE',
      'El mismo valor aparece en multiples registros del requisito.',
      'value_sha256:' || record.value_sha256,
      record.inventory_requirement_id::text || ':' || record.value_sha256,
      jsonb_build_object(
        'value_sha256', record.value_sha256,
        'duplicate_count', count(*)
      )
    from active_records as record
    group by
      record.inventory_requirement_id,
      record.inventory_code,
      record.value_sha256
    having count(*) > 1

    union all

    select
      record.inventory_requirement_id,
      record.inventory_code,
      null::uuid,
      'CONTRADICTORY_VALUE',
      'Existen valores incompatibles para la misma clave normalizada.',
      'record_key:' || record.record_key,
      record.inventory_requirement_id::text || ':' || record.record_key,
      jsonb_build_object(
        'record_key', record.record_key,
        'distinct_value_count', count(distinct record.value_sha256)
      )
    from active_records as record
    group by
      record.inventory_requirement_id,
      record.inventory_code,
      record.record_key
    having count(distinct record.value_sha256) > 1

    union all

    select
      record.inventory_requirement_id,
      record.inventory_code,
      record.id,
      'EXPIRED_VALUE',
      'El valor o el archivo fuente se encuentra vencido.',
      'normalized_record:' || record.id::text,
      record.id::text,
      jsonb_build_object(
        'record_valid_until', record.valid_until,
        'source_file_expires_at', source_file.expires_at
      )
    from active_records as record
    join public.atlas_installation_files as source_file
      on source_file.id = record.source_file_id
    where (record.valid_until is not null and record.valid_until <= now())
       or (source_file.expires_at is not null and source_file.expires_at <= now())

    union all

    select
      record.inventory_requirement_id,
      record.inventory_code,
      record.id,
      'INVALID_FORMAT',
      'El valor propuesto no cumple el tipo o estructura declarada.',
      'normalized_record:' || record.id::text,
      record.id::text,
      jsonb_build_object(
        'value_type', record.proposed_value->>'value_type',
        'format_valid', record.metadata->'format_valid'
      )
    from active_records as record
    where coalesce((record.metadata->>'format_valid')::boolean, false) = false

    union all

    select
      record.inventory_requirement_id,
      record.inventory_code,
      record.id,
      'AMBIGUOUS_VALUE',
      'La propuesta requiere confirmacion por confianza insuficiente.',
      'normalized_record:' || record.id::text,
      record.id::text,
      jsonb_build_object('confidence', record.confidence)
    from active_records as record
    where record.confidence is null or record.confidence < 0.75000

    union all

    select
      record.inventory_requirement_id,
      record.inventory_code,
      record.id,
      'SOURCE_STALE_OR_SUPERSEDED',
      'La propuesta se apoya en una version de archivo reemplazada.',
      'source_file:' || record.source_file_id::text,
      record.id::text || ':' || record.source_file_id::text,
      jsonb_build_object(
        'source_file_id', record.source_file_id,
        'newer_source_present', true
      )
    from active_records as record
    join public.atlas_installation_files as source_file
      on source_file.id = record.source_file_id
    where exists (
      select 1
      from public.atlas_installation_files as newer_source_file
      where newer_source_file.installation_id = source_file.installation_id
        and newer_source_file.logical_section = source_file.logical_section
        and newer_source_file.canonical_file_name =
          source_file.canonical_file_name
        and (
          newer_source_file.file_version > source_file.file_version
          or (
            newer_source_file.file_version = source_file.file_version
            and newer_source_file.created_at > source_file.created_at
          )
        )
    )
  )
  insert into public.atlas_normalization_issues (
    installation_id,
    empresa_id,
    normalization_batch_id,
    normalized_record_id,
    inventory_requirement_id,
    inventory_code,
    issue_code,
    severity,
    issue_status,
    fingerprint_sha256,
    description,
    evidence,
    detected_by_user_id,
    request_id,
    metadata
  )
  select
    v_batch.installation_id,
    v_batch.empresa_id,
    v_batch.id,
    candidate.normalized_record_id,
    candidate.inventory_requirement_id,
    candidate.inventory_code,
    candidate.issue_code,
    definition.default_severity,
    'OPEN',
    public.atlas_normalization_sha256(
      v_batch.id::text || ':' || candidate.issue_code || ':' ||
      candidate.fingerprint_material
    ),
    candidate.description,
    jsonb_build_object(
      'source_reference', candidate.source_reference,
      'analysis_request_id', p_request_id,
      'details', candidate.evidence_details
    ),
    v_actor_user_id,
    gen_random_uuid(),
    jsonb_build_object(
      'detector', 'F2_AUTOMATIC',
      'analysis_request_id', p_request_id
    )
  from issue_candidates as candidate
  join public.atlas_normalization_issue_definitions as definition
    on definition.issue_code = candidate.issue_code
   and definition.active = true
  on conflict (normalization_batch_id, fingerprint_sha256)
  do update set
    normalized_record_id = excluded.normalized_record_id,
    issue_code = excluded.issue_code,
    severity = excluded.severity,
    issue_status = 'OPEN',
    description = excluded.description,
    evidence = excluded.evidence,
    resolution = '{}'::jsonb,
    detected_by_user_id = excluded.detected_by_user_id,
    resolved_by_user_id = null,
    resolved_at = null,
    request_id = excluded.request_id,
    metadata = excluded.metadata,
    updated_at = now();

  select count(*)
  into v_record_count
  from public.atlas_normalized_records
  where normalization_batch_id = v_batch.id
    and normalization_status <> 'SUPERSEDED';

  select count(*)
  into v_detected_count
  from public.atlas_normalization_issues
  where normalization_batch_id = v_batch.id
    and issue_status = 'OPEN';

  select count(*)
  into v_blocking_count
  from public.atlas_normalization_issues as issue
  join public.atlas_normalization_issue_definitions as definition
    on definition.issue_code = issue.issue_code
   and definition.active = true
  where issue.normalization_batch_id = v_batch.id
    and issue.issue_status = 'OPEN'
    and definition.blocks_client_review = true;

  v_target_status := case
    when v_blocking_count = 0 then 'READY_FOR_REVIEW'
    else 'NORMALIZING'
  end;

  update public.atlas_normalization_batches
  set
    batch_status = v_target_status,
    state_version = state_version + 1,
    completed_at = case
      when v_target_status = 'READY_FOR_REVIEW' then now()
      else null
    end,
    metadata = metadata || jsonb_build_object(
      'latest_analysis_request_id', p_request_id,
      'latest_analysis_at', now(),
      'latest_record_count', v_record_count,
      'latest_detected_issue_count', v_detected_count,
      'latest_blocking_issue_count', v_blocking_count
    ),
    updated_at = now()
  where id = v_batch.id
  returning * into v_batch;

  insert into public.atlas_normalization_events (
    installation_id, empresa_id, normalization_batch_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, reason, request_id,
    evidence, metadata
  )
  values (
    v_batch.installation_id, v_batch.empresa_id, v_batch.id,
    'BATCH', v_batch.id, 'NORMALIZATION_ANALYSIS_COMPLETED',
    v_from_status, v_batch.batch_status,
    v_actor_user_id, v_actor_role_code,
    'Analisis deterministico de normalizacion completado.',
    p_request_id,
    jsonb_build_object(
      'records', v_record_count,
      'detected_issues', v_detected_count,
      'blocking_issues', v_blocking_count,
      'detection_types', 7
    ),
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_batch.empresa_id, v_actor_user_id, null, null,
    'NORMALIZATION_BATCH_ANALYZED',
    'B2_NORMALIZATION_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'normalization_batch_id', v_batch.id,
      'expected_batch_state_version',
        p_expected_batch_state_version
    ),
    jsonb_build_object(
      'batch_status', v_batch.batch_status,
      'batch_state_version', v_batch.state_version,
      'records', v_record_count,
      'detected_issues', v_detected_count,
      'blocking_issues', v_blocking_count
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'NORMALIZATION_ANALYSIS_COMPLETED',
    'normalization_batch_id', v_batch.id,
    'batch_status', v_batch.batch_status,
    'batch_state_version', v_batch.state_version,
    'records', v_record_count,
    'detected_issues', v_detected_count,
    'blocking_issues', v_blocking_count,
    'ready_for_client_review', v_blocking_count = 0
  );
end;
$$;

revoke all on function public.atlas_analyze_normalization_batch(
  uuid, uuid, bigint, jsonb
) from public, anon;
grant execute on function public.atlas_analyze_normalization_batch(
  uuid, uuid, bigint, jsonb
) to authenticated, service_role;

comment on column public.atlas_normalization_batches.state_version is
  'B2: version optimista del estado mutable del lote de normalizacion.';

comment on function public.atlas_normalization_sha256(text) is
  'B2: calcula SHA-256 mediante el proveedor pgcrypto disponible.';

comment on function public.atlas_create_normalization_batch(
  uuid, uuid, text, uuid, bigint, jsonb
) is
  'B2: crea un lote ligado al manifest actual y al inventario resuelto.';

comment on function public.atlas_register_normalized_record(
  uuid, uuid, uuid, text, jsonb, jsonb, numeric,
  timestamptz, timestamptz, uuid, bigint, jsonb
) is
  'B2: registra una propuesta normalizada con archivo real, hash y linaje.';

comment on function public.atlas_analyze_normalization_batch(
  uuid, uuid, bigint, jsonb
) is
  'B2: detecta siete clases de incidencia y determina readiness de revision.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2F2_NORMALIZATION_RPCS_INSTALLED',
  'next_action', 'CERTIFY_NORMALIZATION_RPC_GUARDS',
  'normalization_rpcs', 3,
  'internal_sha256_helper', true,
  'detection_types', 7,
  'optimistic_concurrency_enabled', true,
  'idempotency_enabled', true,
  'real_storage_source_required', true,
  'canonical_promotion_enabled', false,
  'normalization_batches', (
    select count(*) from public.atlas_normalization_batches
  ),
  'normalized_records', (
    select count(*) from public.atlas_normalized_records
  ),
  'normalization_issues', (
    select count(*) from public.atlas_normalization_issues
  ),
  'normalization_events', (
    select count(*) from public.atlas_normalization_events
  ),
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
