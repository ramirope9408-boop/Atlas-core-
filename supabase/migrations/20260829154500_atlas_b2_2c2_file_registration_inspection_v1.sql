-- ATLAS B2.2C.2
-- Registro gobernado de objetos reales e inspecciones de archivo.
-- Corte: 2026-08-29
--
-- Prerrequisitos:
--   B2.2C.1 y B2.2C.2A certificados.
--
-- Alcance:
-- - registra solo objetos existentes en atlas-private;
-- - valida empresa, expediente, ruta, formato, MIME, tamano y SHA-256;
-- - registra siete tipos de inspeccion append-only;
-- - una falla pone el archivo en cuarentena o rechazo inmediatamente;
-- - ningun archivo puede quedar ACCEPTED hasta B2.2C.3.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_files') is null
     or to_regclass('public.atlas_installation_file_events') is null
     or to_regclass('storage.objects') is null
     or to_regprocedure('public.usuario_puede_acceder_storage(text)') is null then
    raise exception 'B2.2C.2 requiere B2.2C.1/C.2A certificados';
  end if;
end;
$$;

insert into public.atlas_installation_file_rejection_reasons (
  reason_code,
  display_name,
  description,
  default_disposition,
  active
)
values
  (
    'MIME_TYPE_MISMATCH',
    'MIME incompatible',
    'El tipo detectado no corresponde con la extension y politica permitida.',
    'QUARANTINED',
    true
  )
on conflict (reason_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  default_disposition = excluded.default_disposition,
  active = excluded.active,
  updated_at = now();

create table if not exists public.atlas_installation_file_inspection_types (
  inspection_type_code text primary key,
  display_name text not null,
  description text not null,
  required_by_default boolean not null default true,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_file_inspection_type_code_check
    check (inspection_type_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_installation_file_inspection_type_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

insert into public.atlas_installation_file_inspection_types (
  inspection_type_code,
  display_name,
  description,
  required_by_default,
  active,
  metadata
)
values
  ('MIME_DETECTION', 'Deteccion MIME', 'Compara contenido detectado con extension y politica.', true, true, '{}'::jsonb),
  ('MALWARE_SCAN', 'Escaneo antimalware', 'Busca contenido malicioso antes de cualquier procesamiento.', true, true, '{}'::jsonb),
  ('MACRO_SCAN', 'Escaneo de macros', 'Detecta macros y automatizaciones embebidas.', true, true, jsonb_build_object('not_applicable_extensions', jsonb_build_array('csv', 'json', 'pdf', 'png', 'jpg'))),
  ('ENCRYPTION_SCAN', 'Deteccion de cifrado', 'Detecta archivos cifrados sin proceso aprobado.', true, true, '{}'::jsonb),
  ('NESTED_ARCHIVE_SCAN', 'Contenedores anidados', 'Detecta comprimidos o contenedores anidados no autorizados.', true, true, '{}'::jsonb),
  ('EMBEDDED_SECRET_SCAN', 'Secretos embebidos', 'Busca credenciales, tokens y secretos dentro del contenido.', true, true, '{}'::jsonb),
  ('CONTENT_AUTHORIZATION', 'Autorizacion de contenido', 'Registra la declaracion o evidencia de autorizacion de entrega.', true, true, jsonb_build_object('human_evidence_required', true))
on conflict (inspection_type_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  required_by_default = excluded.required_by_default,
  active = excluded.active,
  metadata = excluded.metadata,
  updated_at = now();

create table if not exists public.atlas_installation_file_inspections (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  file_id uuid not null,
  inspection_type_code text not null,
  inspection_status text not null,
  engine_name text not null,
  engine_version text,
  detected_mime_type text,
  rejection_reason_code text,
  findings jsonb not null default '{}'::jsonb,
  evidence jsonb not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  request_id uuid not null,
  created_at timestamptz not null default now(),

  constraint atlas_installation_file_inspections_request_key
    unique (file_id, request_id),
  constraint atlas_installation_file_inspections_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_file_inspections_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_file_inspections_file_fkey
    foreign key (file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_installation_file_inspections_type_fkey
    foreign key (inspection_type_code)
    references public.atlas_installation_file_inspection_types(inspection_type_code)
    on delete restrict,
  constraint atlas_installation_file_inspections_rejection_reason_fkey
    foreign key (rejection_reason_code)
    references public.atlas_installation_file_rejection_reasons(reason_code)
    on delete restrict,
  constraint atlas_installation_file_inspections_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_file_inspections_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_installation_file_inspections_status_check
    check (
      inspection_status in (
        'PASSED',
        'FAILED',
        'ERROR',
        'NOT_APPLICABLE'
      )
    ),
  constraint atlas_installation_file_inspections_engine_check
    check (length(btrim(engine_name)) >= 2),
  constraint atlas_installation_file_inspections_failure_reason_check
    check (
      (inspection_status = 'FAILED' and rejection_reason_code is not null)
      or (inspection_status <> 'FAILED' and rejection_reason_code is null)
    ),
  constraint atlas_installation_file_inspections_findings_object_check
    check (jsonb_typeof(findings) = 'object'),
  constraint atlas_installation_file_inspections_evidence_object_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
    )
);

create index if not exists idx_atlas_file_inspections_file_timeline
  on public.atlas_installation_file_inspections (
    file_id,
    inspection_type_code,
    created_at desc
  );

create index if not exists idx_atlas_file_inspections_installation
  on public.atlas_installation_file_inspections (
    installation_id,
    inspection_status,
    created_at desc
  );

create or replace function public.atlas_block_installation_file_inspection_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_FILE_INSPECTIONS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_installation_file_inspection_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_installation_file_inspection_mutation()
  to service_role;

drop trigger if exists trg_atlas_installation_file_inspections_append_only
  on public.atlas_installation_file_inspections;
create trigger trg_atlas_installation_file_inspections_append_only
before update or delete on public.atlas_installation_file_inspections
for each row execute function public.atlas_block_installation_file_inspection_mutation();

drop trigger if exists trg_atlas_installation_file_inspection_types_updated_at
  on public.atlas_installation_file_inspection_types;
create trigger trg_atlas_installation_file_inspection_types_updated_at
before update on public.atlas_installation_file_inspection_types
for each row execute function public.atlas_set_updated_at();

create or replace function public.atlas_register_installation_file(
  p_installation_id uuid,
  p_original_file_name text,
  p_canonical_file_name text,
  p_logical_section text,
  p_extension text,
  p_reported_mime_type text,
  p_size_bytes bigint,
  p_sha256 text,
  p_security_classification text,
  p_source_type text,
  p_source_owner text,
  p_file_version integer,
  p_effective_at timestamptz,
  p_expires_at timestamptz,
  p_storage_object_path text,
  p_retention_policy_code text,
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
  v_extension text := lower(nullif(btrim(p_extension), ''));
  v_logical_section text := upper(nullif(btrim(p_logical_section), ''));
  v_sha256 text := lower(nullif(btrim(p_sha256), ''));
  v_canonical_file_name text := nullif(btrim(p_canonical_file_name), '');
  v_reported_mime_type text := nullif(btrim(p_reported_mime_type), '');
  v_storage_object_path text := nullif(btrim(p_storage_object_path), '');
  v_retention_policy_code text := upper(
    nullif(btrim(p_retention_policy_code), '')
  );
  v_installation public.atlas_installations%rowtype;
  v_type_policy public.atlas_installation_file_type_policies%rowtype;
  v_existing public.atlas_installation_files%rowtype;
  v_created public.atlas_installation_files%rowtype;
  v_storage_object storage.objects%rowtype;
  v_expected_prefix text;
  v_bucket_limit bigint;
  v_object_size bigint;
  v_object_mime text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_FILE_REGISTER'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_FILE_REGISTER_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or v_extension is null
     or v_logical_section is null
     or v_sha256 is null
     or nullif(btrim(p_original_file_name), '') is null
     or v_canonical_file_name is null
     or v_reported_mime_type is null
     or v_storage_object_path is null
     or nullif(btrim(p_security_classification), '') is null
     or nullif(btrim(p_source_type), '') is null
     or nullif(btrim(p_source_owner), '') is null
     or v_retention_policy_code is null
     or p_size_bytes is null
     or p_file_version is null then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_FILE_REQUIRED_FIELDS_MISSING';
  end if;

  if v_extension = 'jpeg' then
    v_extension := 'jpg';
  end if;

  if p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or nullif(p_metadata->>'sha256_computed_by', '') is null
     or nullif(p_metadata->>'sha256_computed_at', '') is null then
    raise exception using
      errcode = '22023',
      message = 'SHA256_COMPUTATION_EVIDENCE_REQUIRED';
  end if;

  begin
    perform (p_metadata->>'sha256_computed_at')::timestamptz;
  exception
    when others then
      raise exception using
        errcode = '22023',
        message = 'SHA256_COMPUTED_AT_INVALID';
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

  if v_installation.empresa_id is null then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_EMPRESA_REQUIRED_FOR_FILES';
  end if;

  select f.*
  into v_existing
  from public.atlas_installation_files as f
  where f.installation_id = p_installation_id
    and f.idempotency_key = p_request_id
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'file_id', v_existing.id,
      'installation_id', v_existing.installation_id,
      'sha256', v_existing.sha256,
      'validation_status', v_existing.validation_status,
      'file_version', v_existing.file_version
    );
  end if;

  if v_installation.current_state_code not in (
    'PACKAGE_RECEIVED',
    'SECURITY_VALIDATION'
  ) then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_ACCEPTING_FILES';
  end if;

  select f.*
  into v_existing
  from public.atlas_installation_files as f
  where f.installation_id = p_installation_id
    and f.sha256 = v_sha256
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'FILE_ALREADY_REGISTERED_BY_HASH',
      'file_id', v_existing.id,
      'installation_id', v_existing.installation_id,
      'sha256', v_existing.sha256,
      'validation_status', v_existing.validation_status,
      'file_version', v_existing.file_version
    );
  end if;

  select p.*
  into v_type_policy
  from public.atlas_installation_file_type_policies as p
  where p.extension = v_extension
    and p.active = true;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_FILE_TYPE_NOT_ALLOWED';
  end if;

  if not (v_reported_mime_type = any(v_type_policy.allowed_mime_types)) then
    raise exception using
      errcode = '22023',
      message = 'REPORTED_MIME_TYPE_NOT_ALLOWED_FOR_EXTENSION';
  end if;

  if lower(v_canonical_file_name)
       not like '%.' || v_extension then
    raise exception using
      errcode = '22023',
      message = 'CANONICAL_FILE_EXTENSION_MISMATCH';
  end if;

  select b.file_size_limit
  into v_bucket_limit
  from storage.buckets as b
  where b.id = 'atlas-private'
    and b.public = false;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'PRIVATE_STORAGE_BUCKET_NOT_FOUND';
  end if;

  if p_size_bytes <= 0
     or (
       coalesce(v_type_policy.max_size_bytes, v_bucket_limit) is not null
       and p_size_bytes > coalesce(
         v_type_policy.max_size_bytes,
         v_bucket_limit
       )
     ) then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_FILE_SIZE_NOT_ALLOWED';
  end if;

  v_expected_prefix := v_installation.empresa_id::text
    || '/installations/'
    || v_installation.id::text
    || '/'
    || lower(replace(v_logical_section, '_', '-'))
    || '/';

  if v_storage_object_path not like v_expected_prefix || '%'
     or right(
       v_storage_object_path,
       length(v_canonical_file_name)
     ) <> v_canonical_file_name then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_FILE_STORAGE_PATH_INVALID';
  end if;

  select o.*
  into v_storage_object
  from storage.objects as o
  where o.bucket_id = 'atlas-private'
    and o.name = v_storage_object_path
    and o.archived_at is null
    and o.is_delete_marker = false
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'STORAGE_OBJECT_NOT_FOUND';
  end if;

  if v_storage_object.metadata->>'size' ~ '^[0-9]+$' then
    v_object_size := (v_storage_object.metadata->>'size')::bigint;
    if v_object_size <> p_size_bytes then
      raise exception using
        errcode = '22023',
        message = 'STORAGE_OBJECT_SIZE_MISMATCH';
    end if;
  end if;

  v_object_mime := coalesce(
    nullif(v_storage_object.metadata->>'mimetype', ''),
    nullif(v_storage_object.metadata->>'contentType', '')
  );

  if v_object_mime is not null
     and v_object_mime <> v_reported_mime_type then
    raise exception using
      errcode = '22023',
      message = 'STORAGE_OBJECT_MIME_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.atlas_installation_retention_policies as rp
    where rp.retention_policy_code = v_retention_policy_code
      and rp.active = true
  ) then
    raise exception using
      errcode = '22023',
      message = 'RETENTION_POLICY_INVALID';
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

  insert into public.atlas_installation_files (
    installation_id,
    empresa_id,
    original_file_name,
    canonical_file_name,
    logical_section,
    extension,
    reported_mime_type,
    detected_mime_type,
    size_bytes,
    sha256,
    security_classification,
    source_type,
    source_owner,
    file_version,
    effective_at,
    expires_at,
    validation_status,
    rejection_reason_code,
    storage_bucket,
    storage_object_path,
    retention_policy_code,
    registered_by_user_id,
    idempotency_key,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    btrim(p_original_file_name),
    v_canonical_file_name,
    v_logical_section,
    v_extension,
    v_reported_mime_type,
    null,
    p_size_bytes,
    v_sha256,
    upper(btrim(p_security_classification)),
    upper(btrim(p_source_type)),
    btrim(p_source_owner),
    p_file_version,
    p_effective_at,
    p_expires_at,
    'INSPECTION_PENDING',
    null,
    'atlas-private',
    v_storage_object_path,
    v_retention_policy_code,
    v_actor_user_id,
    p_request_id,
    p_metadata || jsonb_build_object(
      'storage_object_id', v_storage_object.id,
      'registered_via', 'atlas_register_installation_file'
    )
  )
  returning * into v_created;

  insert into public.atlas_installation_file_events (
    installation_id,
    empresa_id,
    file_id,
    event_code,
    from_validation_status,
    to_validation_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    file_version,
    sha256,
    evidence,
    metadata
  )
  values (
    v_created.installation_id,
    v_created.empresa_id,
    v_created.id,
    'FILE_REGISTERED',
    null,
    v_created.validation_status,
    v_actor_user_id,
    v_actor_role_code,
    'Objeto privado registrado para inspeccion B2.',
    p_request_id,
    v_created.file_version,
    v_created.sha256,
    jsonb_build_object(
      'storage_bucket', v_created.storage_bucket,
      'storage_object_path', v_created.storage_object_path,
      'reported_mime_type', v_created.reported_mime_type,
      'size_bytes', v_created.size_bytes
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
    'INSTALLATION_FILE_REGISTERED',
    'B2_SECURE_FILE_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'logical_section', v_created.logical_section,
      'extension', v_created.extension
    ),
    jsonb_build_object(
      'installation_id', v_created.installation_id,
      'file_id', v_created.id,
      'sha256', v_created.sha256,
      'validation_status', v_created.validation_status
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_FILE_REGISTERED',
    'file_id', v_created.id,
    'installation_id', v_created.installation_id,
    'sha256', v_created.sha256,
    'validation_status', v_created.validation_status,
    'file_version', v_created.file_version,
    'storage_object_path', v_created.storage_object_path
  );
end;
$$;

revoke all on function public.atlas_register_installation_file(
  uuid, text, text, text, text, text, bigint, text, text, text,
  text, integer, timestamptz, timestamptz, text, text, uuid, jsonb
) from public, anon;
grant execute on function public.atlas_register_installation_file(
  uuid, text, text, text, text, text, bigint, text, text, text,
  text, integer, timestamptz, timestamptz, text, text, uuid, jsonb
) to authenticated, service_role;

create or replace function public.atlas_record_installation_file_inspection(
  p_file_id uuid,
  p_inspection_type_code text,
  p_inspection_status text,
  p_engine_name text,
  p_engine_version text,
  p_detected_mime_type text,
  p_rejection_reason_code text,
  p_findings jsonb,
  p_evidence jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_type_code text := upper(nullif(btrim(p_inspection_type_code), ''));
  v_status text := upper(nullif(btrim(p_inspection_status), ''));
  v_file public.atlas_installation_files%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_installation_file_inspections%rowtype;
  v_created public.atlas_installation_file_inspections%rowtype;
  v_reason public.atlas_installation_file_rejection_reasons%rowtype;
  v_from_file_status text;
  v_new_file_status text;
  v_event_code text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_FILE_INSPECT'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_FILE_INSPECT_FORBIDDEN';
  end if;

  if p_file_id is null
     or p_request_id is null
     or v_type_code is null
     or v_status is null
     or nullif(btrim(p_engine_name), '') is null then
    raise exception using
      errcode = '22023',
      message = 'FILE_INSPECTION_REQUIRED_FIELDS_MISSING';
  end if;

  if p_findings is null or jsonb_typeof(p_findings) <> 'object'
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb then
    raise exception using
      errcode = '22023',
      message = 'FILE_INSPECTION_FINDINGS_AND_EVIDENCE_REQUIRED';
  end if;

  if v_status not in ('PASSED', 'FAILED', 'ERROR', 'NOT_APPLICABLE') then
    raise exception using
      errcode = '22023',
      message = 'FILE_INSPECTION_STATUS_INVALID';
  end if;

  select f.*
  into v_file
  from public.atlas_installation_files as f
  where f.id = p_file_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_FILE_NOT_FOUND';
  end if;

  v_from_file_status := v_file.validation_status;

  select i.*
  into v_installation
  from public.atlas_installations as i
  where i.id = v_file.installation_id;

  select inspection.*
  into v_existing
  from public.atlas_installation_file_inspections as inspection
  where inspection.file_id = p_file_id
    and inspection.request_id = p_request_id
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'inspection_id', v_existing.id,
      'file_id', v_existing.file_id,
      'inspection_type', v_existing.inspection_type_code,
      'inspection_status', v_existing.inspection_status,
      'file_status', v_file.validation_status
    );
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_SECURITY_VALIDATION';
  end if;

  if not exists (
    select 1
    from public.atlas_installation_file_inspection_types as it
    where it.inspection_type_code = v_type_code
      and it.active = true
  ) then
    raise exception using
      errcode = '22023',
      message = 'FILE_INSPECTION_TYPE_INVALID';
  end if;

  if v_status = 'FAILED' then
    select rr.*
    into v_reason
    from public.atlas_installation_file_rejection_reasons as rr
    where rr.reason_code = upper(nullif(btrim(p_rejection_reason_code), ''))
      and rr.active = true;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'FILE_INSPECTION_FAILURE_REASON_REQUIRED';
    end if;
  elsif p_rejection_reason_code is not null then
    raise exception using
      errcode = '22023',
      message = 'REJECTION_REASON_ONLY_ALLOWED_FOR_FAILED_INSPECTION';
  end if;

  if v_type_code = 'MIME_DETECTION'
     and v_status = 'PASSED' then
    if nullif(btrim(p_detected_mime_type), '') is null then
      raise exception using
        errcode = '22023',
        message = 'DETECTED_MIME_REQUIRED';
    end if;

    if not exists (
      select 1
      from public.atlas_installation_file_type_policies as fp
      where fp.extension = v_file.extension
        and btrim(p_detected_mime_type) = any(fp.allowed_mime_types)
        and fp.active = true
    ) then
      raise exception using
        errcode = '22023',
        message = 'DETECTED_MIME_NOT_ALLOWED_FOR_EXTENSION';
    end if;
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

  insert into public.atlas_installation_file_inspections (
    installation_id,
    empresa_id,
    file_id,
    inspection_type_code,
    inspection_status,
    engine_name,
    engine_version,
    detected_mime_type,
    rejection_reason_code,
    findings,
    evidence,
    actor_user_id,
    actor_role_code,
    request_id
  )
  values (
    v_file.installation_id,
    v_file.empresa_id,
    v_file.id,
    v_type_code,
    v_status,
    btrim(p_engine_name),
    nullif(btrim(p_engine_version), ''),
    nullif(btrim(p_detected_mime_type), ''),
    case when v_status = 'FAILED' then v_reason.reason_code else null end,
    p_findings,
    p_evidence,
    v_actor_user_id,
    v_actor_role_code,
    p_request_id
  )
  returning * into v_created;

  if v_status = 'FAILED' then
    v_new_file_status := case
      when v_file.validation_status = 'REJECTED' then 'REJECTED'
      when v_file.validation_status = 'QUARANTINED'
           and v_reason.default_disposition = 'REJECTED' then 'REJECTED'
      when v_file.validation_status = 'QUARANTINED' then 'QUARANTINED'
      else v_reason.default_disposition
    end;
    v_event_code := 'FILE_' || v_new_file_status;
  else
    v_new_file_status := v_file.validation_status;
    v_event_code := 'FILE_INSPECTION_' || v_status;
  end if;

  update public.atlas_installation_files
  set
    detected_mime_type = case
      when v_type_code = 'MIME_DETECTION'
           and v_status = 'PASSED'
        then btrim(p_detected_mime_type)
      else detected_mime_type
    end,
    validation_status = v_new_file_status,
    rejection_reason_code = case
      when v_status = 'FAILED'
           and v_file.validation_status = 'REJECTED'
        then rejection_reason_code
      when v_status = 'FAILED' then v_reason.reason_code
      else rejection_reason_code
    end,
    updated_at = now()
  where id = v_file.id
  returning * into v_file;

  insert into public.atlas_installation_file_events (
    installation_id,
    empresa_id,
    file_id,
    event_code,
    from_validation_status,
    to_validation_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    file_version,
    sha256,
    evidence,
    metadata
  )
  values (
    v_file.installation_id,
    v_file.empresa_id,
    v_file.id,
    v_event_code,
    v_from_file_status,
    v_file.validation_status,
    v_actor_user_id,
    v_actor_role_code,
    case
      when v_status = 'FAILED' then v_reason.description
      else 'Inspeccion de archivo registrada.'
    end,
    p_request_id,
    v_file.file_version,
    v_file.sha256,
    jsonb_build_object(
      'inspection_id', v_created.id,
      'inspection_type', v_created.inspection_type_code,
      'inspection_status', v_created.inspection_status,
      'engine_name', v_created.engine_name,
      'engine_version', v_created.engine_version,
      'inspection_rejection_reason', v_created.rejection_reason_code
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
    v_file.empresa_id,
    v_actor_user_id,
    null,
    null,
    'INSTALLATION_FILE_INSPECTION_RECORDED',
    'B2_SECURE_FILE_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'file_id', v_file.id,
      'inspection_type', v_type_code,
      'inspection_status', v_status
    ),
    jsonb_build_object(
      'inspection_id', v_created.id,
      'file_status', v_file.validation_status,
      'rejection_reason', v_file.rejection_reason_code
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_FILE_INSPECTION_RECORDED',
    'inspection_id', v_created.id,
    'file_id', v_file.id,
    'inspection_type', v_created.inspection_type_code,
    'inspection_status', v_created.inspection_status,
    'file_status', v_file.validation_status,
    'rejection_reason', v_file.rejection_reason_code
  );
end;
$$;

revoke all on function public.atlas_record_installation_file_inspection(
  uuid, text, text, text, text, text, text, jsonb, jsonb, uuid
) from public, anon;
grant execute on function public.atlas_record_installation_file_inspection(
  uuid, text, text, text, text, text, text, jsonb, jsonb, uuid
) to authenticated, service_role;

alter table public.atlas_installation_file_inspection_types
  enable row level security;
alter table public.atlas_installation_file_inspections
  enable row level security;

revoke all on table public.atlas_installation_file_inspection_types
  from anon, authenticated;
revoke all on table public.atlas_installation_file_inspections
  from anon, authenticated;

grant select on table public.atlas_installation_file_inspection_types
  to authenticated;
grant select on table public.atlas_installation_file_inspections
  to authenticated;

grant all on table public.atlas_installation_file_inspection_types
  to service_role;
grant all on table public.atlas_installation_file_inspections
  to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_file_inspection_types'
      and policyname = 'atlas_installation_file_inspection_types_read'
  ) then
    execute $policy$
      create policy atlas_installation_file_inspection_types_read
        on public.atlas_installation_file_inspection_types
        for select
        to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_file_inspections'
      and policyname = 'atlas_installation_file_inspections_read'
  ) then
    execute $policy$
      create policy atlas_installation_file_inspections_read
        on public.atlas_installation_file_inspections
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_installation_file_inspection_types is
  'B2: siete inspecciones canonicas previas a aceptar un archivo.';

comment on table public.atlas_installation_file_inspections is
  'B2: resultados append-only de inspeccion con motor, hallazgos y evidencia.';

comment on function public.atlas_register_installation_file(
  uuid, text, text, text, text, text, bigint, text, text, text,
  text, integer, timestamptz, timestamptz, text, text, uuid, jsonb
) is
  'B2: registra un objeto real de atlas-private con ruta tenant, formato, tamano y SHA-256 gobernados.';

comment on function public.atlas_record_installation_file_inspection(
  uuid, text, text, text, text, text, text, jsonb, jsonb, uuid
) is
  'B2: registra inspecciones inmutables y aplica cuarentena o rechazo inmediato ante fallas.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2C2_FILE_REGISTRATION_INSPECTION_INSTALLED',
  'inspection_types', (
    select count(*)
    from public.atlas_installation_file_inspection_types
    where active = true
  ),
  'rejection_reasons', (
    select count(*)
    from public.atlas_installation_file_rejection_reasons
    where active = true
  ),
  'secure_file_rpcs', (
    select count(*)
    from pg_proc as p
    join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'atlas_register_installation_file',
        'atlas_record_installation_file_inspection'
      )
      and p.prosecdef = true
  ),
  'registered_files', (
    select count(*)
    from public.atlas_installation_files
  ),
  'inspection_records', (
    select count(*)
    from public.atlas_installation_file_inspections
  ),
  'acceptance_enabled', false,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'next_action', 'CERTIFY_FILE_RPCS_WITHOUT_REGISTERING_FAKE_OBJECTS'
) as result;
