-- ATLAS B2.2C.1
-- Nucleo de recepcion segura, hashes y trazabilidad de archivos.
-- Corte: 2026-08-29
--
-- Prerrequisitos:
--   B2.2A y B2.2B certificados.
--
-- Alcance deliberado:
-- - cataloga formatos iniciales, rechazos y retencion;
-- - crea inventario de archivos con SHA-256, version y storage privado;
-- - crea eventos append-only de archivo;
-- - mantiene las cargas y cambios deshabilitados hasta B2.2C.2;
-- - no inventa plazos legales de retencion aun no aprobados.

begin;

do $$
begin
  if to_regclass('public.atlas_installations') is null
     or to_regprocedure('public.atlas_can_read_installation(uuid)') is null
     or to_regclass('public.atlas_internal_roles') is null then
    raise exception 'B2.2C.1 requiere B2.2A/B instalados y certificados';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_FILE_REGISTER',
    'Registrar fuentes y archivos de instalacion mediante RPC gobernada.'
  ),
  (
    'INSTALLATION_FILE_INSPECT',
    'Registrar inspecciones y decidir aceptacion o cuarentena de archivos.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_FILE_REGISTER'),
  ('ATLAS_OWNER', 'INSTALLATION_FILE_INSPECT'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_FILE_REGISTER'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_FILE_INSPECT')
on conflict (role_code, permission_code) do nothing;

create table if not exists public.atlas_installation_file_type_policies (
  extension text primary key,
  display_name text not null,
  allowed_mime_types text[] not null,
  macros_allowed boolean not null default false,
  encryption_allowed boolean not null default false,
  archive_allowed boolean not null default false,
  max_size_bytes bigint,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_file_type_extension_check
    check (extension ~ '^[a-z0-9]{1,10}$'),
  constraint atlas_installation_file_type_mimes_check
    check (cardinality(allowed_mime_types) > 0),
  constraint atlas_installation_file_type_max_size_check
    check (max_size_bytes is null or max_size_bytes > 0),
  constraint atlas_installation_file_type_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

insert into public.atlas_installation_file_type_policies (
  extension,
  display_name,
  allowed_mime_types,
  macros_allowed,
  encryption_allowed,
  archive_allowed,
  max_size_bytes,
  active,
  metadata
)
values
  (
    'xlsx',
    'Microsoft Excel Open XML',
    array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
    false,
    false,
    false,
    null,
    true,
    jsonb_build_object('size_limit_status', 'PENDING_POLICY_APPROVAL')
  ),
  (
    'csv',
    'Comma-separated values',
    array['text/csv', 'application/csv', 'text/plain'],
    false,
    false,
    false,
    null,
    true,
    jsonb_build_object('size_limit_status', 'PENDING_POLICY_APPROVAL')
  ),
  (
    'json',
    'JavaScript Object Notation',
    array['application/json', 'text/json'],
    false,
    false,
    false,
    null,
    true,
    jsonb_build_object('size_limit_status', 'PENDING_POLICY_APPROVAL')
  ),
  (
    'pdf',
    'Portable Document Format',
    array['application/pdf'],
    false,
    false,
    false,
    null,
    true,
    jsonb_build_object('size_limit_status', 'PENDING_POLICY_APPROVAL')
  ),
  (
    'docx',
    'Microsoft Word Open XML',
    array['application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
    false,
    false,
    false,
    null,
    true,
    jsonb_build_object('size_limit_status', 'PENDING_POLICY_APPROVAL')
  ),
  (
    'png',
    'Portable Network Graphics',
    array['image/png'],
    false,
    false,
    false,
    null,
    true,
    jsonb_build_object('size_limit_status', 'PENDING_POLICY_APPROVAL')
  ),
  (
    'jpg',
    'JPEG image',
    array['image/jpeg'],
    false,
    false,
    false,
    null,
    true,
    jsonb_build_object(
      'aliases', jsonb_build_array('jpeg'),
      'size_limit_status', 'PENDING_POLICY_APPROVAL'
    )
  )
on conflict (extension) do update
set
  display_name = excluded.display_name,
  allowed_mime_types = excluded.allowed_mime_types,
  macros_allowed = excluded.macros_allowed,
  encryption_allowed = excluded.encryption_allowed,
  archive_allowed = excluded.archive_allowed,
  max_size_bytes = excluded.max_size_bytes,
  active = excluded.active,
  metadata = excluded.metadata,
  updated_at = now();

create table if not exists public.atlas_installation_file_rejection_reasons (
  reason_code text primary key,
  display_name text not null,
  description text not null,
  default_disposition text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_file_rejection_reason_code_check
    check (reason_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_installation_file_rejection_disposition_check
    check (default_disposition in ('REJECTED', 'QUARANTINED'))
);

insert into public.atlas_installation_file_rejection_reasons (
  reason_code,
  display_name,
  description,
  default_disposition,
  active
)
values
  ('EXECUTABLE_FILE', 'Archivo ejecutable', 'Ejecutable no admitido.', 'REJECTED', true),
  ('SCRIPT_FILE', 'Script', 'Script o codigo ejecutable no admitido.', 'REJECTED', true),
  ('UNAUTHORIZED_MACROS', 'Macros no autorizadas', 'El archivo contiene macros no autorizadas.', 'QUARANTINED', true),
  ('NESTED_ARCHIVE', 'Comprimido anidado', 'Contenedor o archivo comprimido anidado no admitido.', 'QUARANTINED', true),
  ('UNAPPROVED_ENCRYPTION', 'Cifrado no aprobado', 'Archivo cifrado sin proceso de intercambio aprobado.', 'QUARANTINED', true),
  ('MALWARE_DETECTED', 'Malware detectado', 'La inspeccion detecto contenido malicioso.', 'QUARANTINED', true),
  ('EMBEDDED_SECRET', 'Secreto embebido', 'Credencial, token o secreto detectado dentro del archivo.', 'QUARANTINED', true),
  ('UNAUTHORIZED_CONTENT', 'Contenido no autorizado', 'El cliente no acredita autorizacion para entregar el contenido.', 'REJECTED', true)
on conflict (reason_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  default_disposition = excluded.default_disposition,
  active = excluded.active,
  updated_at = now();

create table if not exists public.atlas_installation_retention_policies (
  retention_policy_code text primary key,
  display_name text not null,
  description text not null,
  retention_days integer,
  legal_review_status text not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_retention_policy_code_check
    check (retention_policy_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_installation_retention_days_check
    check (retention_days is null or retention_days >= 0),
  constraint atlas_installation_retention_review_status_check
    check (legal_review_status in ('PENDING', 'APPROVED', 'RETIRED')),
  constraint atlas_installation_retention_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

insert into public.atlas_installation_retention_policies (
  retention_policy_code,
  display_name,
  description,
  retention_days,
  legal_review_status,
  active,
  metadata
)
values
  (
    'PENDING_CONTRACTUAL_ASSIGNMENT',
    'Pendiente de asignacion contractual',
    'Politica temporal que impide inventar un plazo antes de revision juridica y contractual.',
    null,
    'PENDING',
    true,
    jsonb_build_object(
      'deletion_automation_enabled', false,
      'requires_professional_review', true
    )
  ),
  (
    'LEGAL_HOLD',
    'Retencion legal',
    'Conservacion excepcional por obligacion, disputa o investigacion documentada.',
    null,
    'PENDING',
    true,
    jsonb_build_object(
      'automatic_release_enabled', false,
      'requires_case_reference', true
    )
  )
on conflict (retention_policy_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  retention_days = excluded.retention_days,
  legal_review_status = excluded.legal_review_status,
  active = excluded.active,
  metadata = excluded.metadata,
  updated_at = now();

create table if not exists public.atlas_installation_files (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  original_file_name text not null,
  canonical_file_name text not null,
  logical_section text not null,
  extension text not null,
  reported_mime_type text,
  detected_mime_type text,
  size_bytes bigint not null,
  sha256 text not null,
  security_classification text not null,
  source_type text not null,
  source_owner text not null,
  file_version integer not null default 1,
  received_at timestamptz not null default now(),
  effective_at timestamptz,
  expires_at timestamptz,
  validation_status text not null default 'RECEIVED',
  rejection_reason_code text,
  storage_bucket text not null default 'atlas-private',
  storage_object_path text not null,
  retention_policy_code text not null
    default 'PENDING_CONTRACTUAL_ASSIGNMENT',
  derivative_of_file_id uuid,
  supersedes_file_id uuid,
  registered_by_user_id uuid not null,
  idempotency_key uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_files_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_installation_files_hash_key
    unique (installation_id, sha256),
  constraint atlas_installation_files_version_key
    unique (
      installation_id,
      logical_section,
      canonical_file_name,
      file_version
    ),
  constraint atlas_installation_files_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_files_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_files_extension_fkey
    foreign key (extension)
    references public.atlas_installation_file_type_policies(extension)
    on delete restrict,
  constraint atlas_installation_files_rejection_reason_fkey
    foreign key (rejection_reason_code)
    references public.atlas_installation_file_rejection_reasons(reason_code)
    on delete restrict,
  constraint atlas_installation_files_retention_policy_fkey
    foreign key (retention_policy_code)
    references public.atlas_installation_retention_policies(retention_policy_code)
    on delete restrict,
  constraint atlas_installation_files_derivative_fkey
    foreign key (derivative_of_file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_installation_files_supersedes_fkey
    foreign key (supersedes_file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_installation_files_registered_by_fkey
    foreign key (registered_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_files_names_check
    check (
      length(btrim(original_file_name)) >= 1
      and length(btrim(canonical_file_name)) >= 1
      and btrim(original_file_name) not in ('.', '..')
      and btrim(canonical_file_name) not in ('.', '..')
      and position('/' in original_file_name) = 0
      and position(chr(92) in original_file_name) = 0
      and position('/' in canonical_file_name) = 0
      and position(chr(92) in canonical_file_name) = 0
    ),
  constraint atlas_installation_files_logical_section_check
    check (
      logical_section in (
        'LEGAL',
        'COMPANY',
        'OWNERS_AND_USERS',
        'CATALOG',
        'KNOWLEDGE',
        'COMMERCIAL_RULES',
        'CHANNELS',
        'INTEGRATIONS',
        'PERSONALITY',
        'VOICE',
        'TEMPLATES',
        'SECURITY',
        'APPROVALS'
      )
    ),
  constraint atlas_installation_files_extension_check
    check (extension ~ '^[a-z0-9]{1,10}$'),
  constraint atlas_installation_files_size_check
    check (size_bytes > 0),
  constraint atlas_installation_files_sha256_check
    check (sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_installation_files_security_classification_check
    check (
      security_classification in (
        'PUBLIC',
        'INTERNAL',
        'CONFIDENTIAL',
        'RESTRICTED'
      )
    ),
  constraint atlas_installation_files_source_type_check
    check (
      source_type in (
        'CLIENT_UPLOAD',
        'ATLAS_IMPORT',
        'EXTERNAL_REFERENCE',
        'SYSTEM_GENERATED'
      )
    ),
  constraint atlas_installation_files_source_owner_check
    check (length(btrim(source_owner)) >= 2),
  constraint atlas_installation_files_version_check
    check (file_version >= 1),
  constraint atlas_installation_files_validity_check
    check (expires_at is null or effective_at is null or expires_at > effective_at),
  constraint atlas_installation_files_validation_status_check
    check (
      validation_status in (
        'RECEIVED',
        'INSPECTION_PENDING',
        'ACCEPTED',
        'QUARANTINED',
        'REJECTED'
      )
    ),
  constraint atlas_installation_files_rejection_state_check
    check (
      (
        validation_status in ('QUARANTINED', 'REJECTED')
        and rejection_reason_code is not null
      )
      or (
        validation_status not in ('QUARANTINED', 'REJECTED')
        and rejection_reason_code is null
      )
    ),
  constraint atlas_installation_files_accepted_detection_check
    check (
      validation_status <> 'ACCEPTED'
      or nullif(btrim(detected_mime_type), '') is not null
    ),
  constraint atlas_installation_files_private_bucket_check
    check (storage_bucket = 'atlas-private'),
  constraint atlas_installation_files_storage_path_check
    check (
      length(btrim(storage_object_path)) >= 3
      and left(storage_object_path, 1) <> '/'
      and position(chr(92) in storage_object_path) = 0
      and storage_object_path !~ '(^|/)\.\.(/|$)'
    ),
  constraint atlas_installation_files_lineage_check
    check (
      derivative_of_file_id is null
      or derivative_of_file_id <> id
    ),
  constraint atlas_installation_files_supersedes_check
    check (
      supersedes_file_id is null
      or supersedes_file_id <> id
    ),
  constraint atlas_installation_files_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create table if not exists public.atlas_installation_file_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  file_id uuid not null,
  event_code text not null,
  from_validation_status text,
  to_validation_status text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  reason text,
  request_id uuid not null,
  file_version integer not null,
  sha256 text not null,
  evidence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_installation_file_events_request_key
    unique (file_id, request_id),
  constraint atlas_installation_file_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_file_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_file_events_file_fkey
    foreign key (file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_installation_file_events_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_file_events_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_installation_file_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_installation_file_events_from_status_check
    check (
      from_validation_status is null
      or from_validation_status in (
        'RECEIVED',
        'INSPECTION_PENDING',
        'ACCEPTED',
        'QUARANTINED',
        'REJECTED'
      )
    ),
  constraint atlas_installation_file_events_to_status_check
    check (
      to_validation_status in (
        'RECEIVED',
        'INSPECTION_PENDING',
        'ACCEPTED',
        'QUARANTINED',
        'REJECTED'
      )
    ),
  constraint atlas_installation_file_events_version_check
    check (file_version >= 1),
  constraint atlas_installation_file_events_sha256_check
    check (sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_installation_file_events_evidence_object_check
    check (jsonb_typeof(evidence) = 'object'),
  constraint atlas_installation_file_events_metadata_object_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_atlas_installation_files_installation_status
  on public.atlas_installation_files (
    installation_id,
    validation_status,
    logical_section,
    created_at desc
  );

create index if not exists idx_atlas_installation_files_empresa
  on public.atlas_installation_files (
    empresa_id,
    validation_status,
    created_at desc
  );

create index if not exists idx_atlas_installation_files_hash
  on public.atlas_installation_files (sha256);

create index if not exists idx_atlas_installation_file_events_timeline
  on public.atlas_installation_file_events (
    installation_id,
    file_id,
    created_at desc
  );

create or replace function public.atlas_block_installation_file_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_FILE_EVENTS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_installation_file_event_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_installation_file_event_mutation()
  to service_role;

drop trigger if exists trg_atlas_installation_file_events_append_only
  on public.atlas_installation_file_events;
create trigger trg_atlas_installation_file_events_append_only
before update or delete on public.atlas_installation_file_events
for each row execute function public.atlas_block_installation_file_event_mutation();

drop trigger if exists trg_atlas_installation_file_type_policies_updated_at
  on public.atlas_installation_file_type_policies;
create trigger trg_atlas_installation_file_type_policies_updated_at
before update on public.atlas_installation_file_type_policies
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_installation_file_rejection_reasons_updated_at
  on public.atlas_installation_file_rejection_reasons;
create trigger trg_atlas_installation_file_rejection_reasons_updated_at
before update on public.atlas_installation_file_rejection_reasons
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_installation_retention_policies_updated_at
  on public.atlas_installation_retention_policies;
create trigger trg_atlas_installation_retention_policies_updated_at
before update on public.atlas_installation_retention_policies
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_installation_files_updated_at
  on public.atlas_installation_files;
create trigger trg_atlas_installation_files_updated_at
before update on public.atlas_installation_files
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_installation_file_type_policies enable row level security;
alter table public.atlas_installation_file_rejection_reasons enable row level security;
alter table public.atlas_installation_retention_policies enable row level security;
alter table public.atlas_installation_files enable row level security;
alter table public.atlas_installation_file_events enable row level security;

revoke all on table public.atlas_installation_file_type_policies
  from anon, authenticated;
revoke all on table public.atlas_installation_file_rejection_reasons
  from anon, authenticated;
revoke all on table public.atlas_installation_retention_policies
  from anon, authenticated;
revoke all on table public.atlas_installation_files
  from anon, authenticated;
revoke all on table public.atlas_installation_file_events
  from anon, authenticated;

grant select on table public.atlas_installation_file_type_policies
  to authenticated;
grant select on table public.atlas_installation_file_rejection_reasons
  to authenticated;
grant select on table public.atlas_installation_retention_policies
  to authenticated;
grant select on table public.atlas_installation_files
  to authenticated;
grant select on table public.atlas_installation_file_events
  to authenticated;

grant all on table public.atlas_installation_file_type_policies
  to service_role;
grant all on table public.atlas_installation_file_rejection_reasons
  to service_role;
grant all on table public.atlas_installation_retention_policies
  to service_role;
grant all on table public.atlas_installation_files
  to service_role;
grant all on table public.atlas_installation_file_events
  to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_file_type_policies'
      and policyname = 'atlas_installation_file_type_policies_read'
  ) then
    execute $policy$
      create policy atlas_installation_file_type_policies_read
        on public.atlas_installation_file_type_policies
        for select
        to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_file_rejection_reasons'
      and policyname = 'atlas_installation_file_rejection_reasons_read'
  ) then
    execute $policy$
      create policy atlas_installation_file_rejection_reasons_read
        on public.atlas_installation_file_rejection_reasons
        for select
        to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_retention_policies'
      and policyname = 'atlas_installation_retention_policies_read'
  ) then
    execute $policy$
      create policy atlas_installation_retention_policies_read
        on public.atlas_installation_retention_policies
        for select
        to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_files'
      and policyname = 'atlas_installation_files_read'
  ) then
    execute $policy$
      create policy atlas_installation_files_read
        on public.atlas_installation_files
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_file_events'
      and policyname = 'atlas_installation_file_events_read'
  ) then
    execute $policy$
      create policy atlas_installation_file_events_read
        on public.atlas_installation_file_events
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_installation_file_type_policies is
  'B2: formatos iniciales admitidos y controles de contenido por extension.';

comment on table public.atlas_installation_file_rejection_reasons is
  'B2: causas canonicas de rechazo o cuarentena de archivos.';

comment on table public.atlas_installation_retention_policies is
  'B2: politicas de retencion; plazos pendientes permanecen explicitamente sin automatizacion.';

comment on table public.atlas_installation_files is
  'B2: inventario versionado de archivos privados con SHA-256, fuente, clasificacion y retencion.';

comment on table public.atlas_installation_file_events is
  'B2: bitacora append-only de recepcion e inspeccion de archivos.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2C1_SECURE_FILE_CORE_INSTALLED',
  'allowed_file_types', (
    select count(*)
    from public.atlas_installation_file_type_policies
    where active = true
  ),
  'rejection_reasons', (
    select count(*)
    from public.atlas_installation_file_rejection_reasons
    where active = true
  ),
  'retention_policies', (
    select count(*)
    from public.atlas_installation_retention_policies
    where active = true
  ),
  'registered_files', (
    select count(*)
    from public.atlas_installation_files
  ),
  'file_events', (
    select count(*)
    from public.atlas_installation_file_events
  ),
  'direct_authenticated_write', false,
  'file_registration_enabled', false,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'next_block', 'B2.2C.2_FILE_REGISTRATION_AND_INSPECTION_RPCS'
) as result;
