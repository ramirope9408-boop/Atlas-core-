-- ATLAS B2.2F.1
-- Nucleo gobernado de normalizacion de datos empresariales.
-- Corte: 2026-08-30
--
-- Alcance deliberado:
-- - separa fuente recibida, propuesta normalizada y dato canonico aprobado;
-- - conserva linaje hacia manifest, requisito y archivo aceptado;
-- - modela lotes, registros propuestos, incidencias y eventos;
-- - cataloga faltantes, duplicados, contradicciones y vencimientos;
-- - no habilita escritura ni promocion canonica hasta B2.2F.2/F.3.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_manifests') is null
     or to_regclass(
       'public.atlas_installation_inventory_requirements'
     ) is null
     or to_regclass('public.atlas_installation_files') is null
     or to_regprocedure(
       'public.atlas_compute_installation_g01_readiness(uuid)'
     ) is null then
    raise exception 'B2.2F.1 requiere B2.2A-E instalado y certificado';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_NORMALIZATION_READ',
    'Consultar lotes, propuestas, incidencias y eventos de normalizacion.'
  ),
  (
    'INSTALLATION_NORMALIZATION_MANAGE',
    'Ejecutar normalizacion gobernada mediante RPC de plataforma.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_NORMALIZATION_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_NORMALIZATION_MANAGE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_NORMALIZATION_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_NORMALIZATION_MANAGE'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_NORMALIZATION_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_NORMALIZATION_READ')
on conflict (role_code, permission_code) do nothing;

create table if not exists public.atlas_normalization_issue_definitions (
  issue_code text primary key,
  display_name text not null,
  description text not null,
  default_severity text not null,
  blocks_client_review boolean not null default true,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_norm_issue_definitions_code_check
    check (issue_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_norm_issue_definitions_name_check
    check (length(btrim(display_name)) >= 3),
  constraint atlas_norm_issue_definitions_description_check
    check (length(btrim(description)) >= 10),
  constraint atlas_norm_issue_definitions_severity_check
    check (default_severity in ('INFO', 'WARNING', 'ERROR', 'CRITICAL')),
  constraint atlas_norm_issue_definitions_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_normalization_issue_definitions (
  issue_code,
  display_name,
  description,
  default_severity,
  blocks_client_review,
  active,
  metadata
)
values
  (
    'MISSING_REQUIRED_VALUE',
    'Dato obligatorio faltante',
    'No existe un valor utilizable para un requisito obligatorio.',
    'ERROR',
    true,
    true,
    jsonb_build_object('category', 'COMPLETENESS')
  ),
  (
    'DUPLICATE_VALUE',
    'Dato duplicado',
    'Dos o mas fuentes proponen el mismo dato sin diferenciacion util.',
    'WARNING',
    true,
    true,
    jsonb_build_object('category', 'DUPLICATION')
  ),
  (
    'CONTRADICTORY_VALUE',
    'Datos contradictorios',
    'Fuentes vigentes proponen valores incompatibles para el mismo dato.',
    'ERROR',
    true,
    true,
    jsonb_build_object('category', 'CONSISTENCY')
  ),
  (
    'EXPIRED_VALUE',
    'Dato vencido',
    'El valor o su evidencia perdio vigencia antes de la revision.',
    'ERROR',
    true,
    true,
    jsonb_build_object('category', 'VALIDITY')
  ),
  (
    'INVALID_FORMAT',
    'Formato invalido',
    'El valor no cumple el esquema, tipo o formato canonico esperado.',
    'ERROR',
    true,
    true,
    jsonb_build_object('category', 'SCHEMA')
  ),
  (
    'AMBIGUOUS_VALUE',
    'Dato ambiguo',
    'La fuente admite mas de una interpretacion y requiere confirmacion.',
    'WARNING',
    true,
    true,
    jsonb_build_object('category', 'SEMANTICS')
  ),
  (
    'SOURCE_STALE_OR_SUPERSEDED',
    'Fuente desactualizada',
    'El dato proviene de una version de archivo reemplazada o no vigente.',
    'CRITICAL',
    true,
    true,
    jsonb_build_object('category', 'LINEAGE')
  )
on conflict (issue_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  default_severity = excluded.default_severity,
  blocks_client_review = excluded.blocks_client_review,
  active = excluded.active,
  metadata = excluded.metadata,
  updated_at = now();

create table if not exists public.atlas_normalization_batches (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  source_manifest_id uuid not null,
  batch_version integer not null,
  schema_version text not null default 'B2_NORM_V1',
  batch_status text not null default 'DRAFT',
  source_manifest_sha256 text not null,
  started_at timestamptz,
  completed_at timestamptz,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_normalization_batches_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_normalization_batches_version_key
    unique (installation_id, batch_version),
  constraint atlas_normalization_batches_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_normalization_batches_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_normalization_batches_manifest_fkey
    foreign key (source_manifest_id)
    references public.atlas_installation_manifests(id)
    on delete restrict,
  constraint atlas_normalization_batches_creator_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_normalization_batches_version_check
    check (batch_version >= 1),
  constraint atlas_normalization_batches_schema_check
    check (schema_version ~ '^B2_NORM_V[0-9]+$'),
  constraint atlas_normalization_batches_status_check
    check (
      batch_status in (
        'DRAFT',
        'EXTRACTING',
        'NORMALIZING',
        'READY_FOR_REVIEW',
        'IN_CLIENT_REVIEW',
        'APPROVED',
        'REJECTED',
        'SUPERSEDED'
      )
    ),
  constraint atlas_normalization_batches_hash_check
    check (source_manifest_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_normalization_batches_timeline_check
    check (
      completed_at is null
      or (started_at is not null and completed_at >= started_at)
    ),
  constraint atlas_normalization_batches_completion_check
    check (
      batch_status not in ('READY_FOR_REVIEW', 'APPROVED', 'REJECTED')
      or completed_at is not null
    ),
  constraint atlas_normalization_batches_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create table if not exists public.atlas_normalized_records (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  normalization_batch_id uuid not null,
  inventory_requirement_id uuid not null,
  inventory_code text not null,
  source_file_id uuid not null,
  record_key text not null,
  record_version integer not null,
  normalization_status text not null default 'EXTRACTED',
  proposed_value jsonb not null,
  value_sha256 text not null,
  source_locator jsonb not null,
  confidence numeric(6,5),
  valid_from timestamptz,
  valid_until timestamptz,
  supersedes_record_id uuid,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_normalized_records_request_key
    unique (normalization_batch_id, idempotency_key),
  constraint atlas_normalized_records_version_key
    unique (
      normalization_batch_id,
      inventory_requirement_id,
      record_key,
      record_version
    ),
  constraint atlas_normalized_records_value_hash_key
    unique (
      normalization_batch_id,
      inventory_requirement_id,
      record_key,
      value_sha256
    ),
  constraint atlas_normalized_records_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_normalized_records_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_normalized_records_batch_fkey
    foreign key (normalization_batch_id)
    references public.atlas_normalization_batches(id)
    on delete restrict,
  constraint atlas_normalized_records_requirement_fkey
    foreign key (inventory_requirement_id)
    references public.atlas_installation_inventory_requirements(id)
    on delete restrict,
  constraint atlas_normalized_records_inventory_code_fkey
    foreign key (inventory_code)
    references public.atlas_installation_inventory_definitions(inventory_code)
    on delete restrict,
  constraint atlas_normalized_records_source_file_fkey
    foreign key (source_file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_normalized_records_supersedes_fkey
    foreign key (supersedes_record_id)
    references public.atlas_normalized_records(id)
    on delete restrict,
  constraint atlas_normalized_records_creator_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_normalized_records_key_check
    check (
      record_key ~ '^[A-Z0-9][A-Z0-9_.:-]*$'
      and length(record_key) <= 180
    ),
  constraint atlas_normalized_records_version_check
    check (record_version >= 1),
  constraint atlas_normalized_records_status_check
    check (
      normalization_status in (
        'EXTRACTED',
        'NORMALIZED',
        'NEEDS_REVIEW',
        'CLIENT_APPROVED',
        'CLIENT_REJECTED',
        'SUPERSEDED'
      )
    ),
  constraint atlas_normalized_records_value_check
    check (
      proposed_value <> 'null'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(proposed_value)
    ),
  constraint atlas_normalized_records_hash_check
    check (value_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_normalized_records_locator_check
    check (
      jsonb_typeof(source_locator) = 'object'
      and source_locator <> '{}'::jsonb
      and nullif(btrim(source_locator->>'source_reference'), '') is not null
      and not public.atlas_jsonb_has_forbidden_secret_key(source_locator)
    ),
  constraint atlas_normalized_records_confidence_check
    check (confidence is null or confidence between 0 and 1),
  constraint atlas_normalized_records_validity_check
    check (
      valid_until is null
      or valid_from is null
      or valid_until > valid_from
    ),
  constraint atlas_normalized_records_no_self_supersede_check
    check (supersedes_record_id is null or supersedes_record_id <> id),
  constraint atlas_normalized_records_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create table if not exists public.atlas_normalization_issues (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  normalization_batch_id uuid not null,
  normalized_record_id uuid,
  inventory_requirement_id uuid not null,
  inventory_code text not null,
  issue_code text not null,
  severity text not null,
  issue_status text not null default 'OPEN',
  fingerprint_sha256 text not null,
  description text not null,
  evidence jsonb not null,
  resolution jsonb not null default '{}'::jsonb,
  detected_by_user_id uuid,
  resolved_by_user_id uuid,
  resolved_at timestamptz,
  request_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_normalization_issues_request_key
    unique (normalization_batch_id, request_id),
  constraint atlas_normalization_issues_fingerprint_key
    unique (normalization_batch_id, fingerprint_sha256),
  constraint atlas_normalization_issues_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_normalization_issues_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_normalization_issues_batch_fkey
    foreign key (normalization_batch_id)
    references public.atlas_normalization_batches(id)
    on delete restrict,
  constraint atlas_normalization_issues_record_fkey
    foreign key (normalized_record_id)
    references public.atlas_normalized_records(id)
    on delete restrict,
  constraint atlas_normalization_issues_requirement_fkey
    foreign key (inventory_requirement_id)
    references public.atlas_installation_inventory_requirements(id)
    on delete restrict,
  constraint atlas_normalization_issues_inventory_code_fkey
    foreign key (inventory_code)
    references public.atlas_installation_inventory_definitions(inventory_code)
    on delete restrict,
  constraint atlas_normalization_issues_definition_fkey
    foreign key (issue_code)
    references public.atlas_normalization_issue_definitions(issue_code)
    on delete restrict,
  constraint atlas_normalization_issues_detected_by_fkey
    foreign key (detected_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_normalization_issues_resolved_by_fkey
    foreign key (resolved_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_normalization_issues_severity_check
    check (severity in ('INFO', 'WARNING', 'ERROR', 'CRITICAL')),
  constraint atlas_normalization_issues_status_check
    check (issue_status in ('OPEN', 'RESOLVED', 'ACCEPTED_RISK')),
  constraint atlas_normalization_issues_fingerprint_check
    check (fingerprint_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_normalization_issues_description_check
    check (length(btrim(description)) >= 10),
  constraint atlas_normalization_issues_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
      and nullif(btrim(evidence->>'source_reference'), '') is not null
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
    ),
  constraint atlas_normalization_issues_resolution_check
    check (
      jsonb_typeof(resolution) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(resolution)
      and (
        (
          issue_status = 'OPEN'
          and resolution = '{}'::jsonb
          and resolved_by_user_id is null
          and resolved_at is null
        ) or (
          issue_status in ('RESOLVED', 'ACCEPTED_RISK')
          and resolution <> '{}'::jsonb
          and resolved_by_user_id is not null
          and resolved_at is not null
        )
      )
    ),
  constraint atlas_normalization_issues_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create table if not exists public.atlas_normalization_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  normalization_batch_id uuid not null,
  entity_type text not null,
  entity_id uuid not null,
  event_code text not null,
  from_status text,
  to_status text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  reason text not null,
  request_id uuid not null,
  evidence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_normalization_events_request_key
    unique (normalization_batch_id, request_id),
  constraint atlas_normalization_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_normalization_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_normalization_events_batch_fkey
    foreign key (normalization_batch_id)
    references public.atlas_normalization_batches(id)
    on delete restrict,
  constraint atlas_normalization_events_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_normalization_events_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_normalization_events_entity_check
    check (entity_type in ('BATCH', 'RECORD', 'ISSUE')),
  constraint atlas_normalization_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_normalization_events_status_check
    check (
      length(btrim(to_status)) >= 2
      and (from_status is null or length(btrim(from_status)) >= 2)
    ),
  constraint atlas_normalization_events_reason_check
    check (length(btrim(reason)) >= 10),
  constraint atlas_normalization_events_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
    ),
  constraint atlas_normalization_events_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index if not exists idx_atlas_normalization_batches_state
  on public.atlas_normalization_batches (
    installation_id,
    batch_status,
    batch_version desc
  );

create index if not exists idx_atlas_normalized_records_requirement
  on public.atlas_normalized_records (
    normalization_batch_id,
    inventory_requirement_id,
    normalization_status,
    record_key
  );

create index if not exists idx_atlas_normalized_records_source
  on public.atlas_normalized_records (
    source_file_id,
    value_sha256
  );

create index if not exists idx_atlas_normalization_issues_open
  on public.atlas_normalization_issues (
    normalization_batch_id,
    issue_status,
    severity,
    inventory_code
  );

create index if not exists idx_atlas_normalization_events_timeline
  on public.atlas_normalization_events (
    normalization_batch_id,
    created_at desc,
    id desc
  );

create or replace function public.atlas_block_normalization_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_NORMALIZATION_EVENTS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_normalization_event_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_normalization_event_mutation()
  to service_role;

drop trigger if exists trg_atlas_normalization_events_append_only
  on public.atlas_normalization_events;
create trigger trg_atlas_normalization_events_append_only
before update or delete on public.atlas_normalization_events
for each row execute function public.atlas_block_normalization_event_mutation();

drop trigger if exists trg_atlas_norm_issue_definitions_updated_at
  on public.atlas_normalization_issue_definitions;
create trigger trg_atlas_norm_issue_definitions_updated_at
before update on public.atlas_normalization_issue_definitions
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_normalization_batches_updated_at
  on public.atlas_normalization_batches;
create trigger trg_atlas_normalization_batches_updated_at
before update on public.atlas_normalization_batches
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_normalized_records_updated_at
  on public.atlas_normalized_records;
create trigger trg_atlas_normalized_records_updated_at
before update on public.atlas_normalized_records
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_normalization_issues_updated_at
  on public.atlas_normalization_issues;
create trigger trg_atlas_normalization_issues_updated_at
before update on public.atlas_normalization_issues
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_normalization_issue_definitions
  enable row level security;
alter table public.atlas_normalization_batches
  enable row level security;
alter table public.atlas_normalized_records
  enable row level security;
alter table public.atlas_normalization_issues
  enable row level security;
alter table public.atlas_normalization_events
  enable row level security;

revoke all on table public.atlas_normalization_issue_definitions
  from anon, authenticated;
revoke all on table public.atlas_normalization_batches
  from anon, authenticated;
revoke all on table public.atlas_normalized_records
  from anon, authenticated;
revoke all on table public.atlas_normalization_issues
  from anon, authenticated;
revoke all on table public.atlas_normalization_events
  from anon, authenticated;

grant select on table public.atlas_normalization_issue_definitions
  to authenticated;
grant select on table public.atlas_normalization_batches
  to authenticated;
grant select on table public.atlas_normalized_records
  to authenticated;
grant select on table public.atlas_normalization_issues
  to authenticated;
grant select on table public.atlas_normalization_events
  to authenticated;

grant all on table public.atlas_normalization_issue_definitions
  to service_role;
grant all on table public.atlas_normalization_batches
  to service_role;
grant all on table public.atlas_normalized_records
  to service_role;
grant all on table public.atlas_normalization_issues
  to service_role;
grant all on table public.atlas_normalization_events
  to service_role;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_normalization_issue_definitions'
      and policyname = 'atlas_normalization_issue_definitions_read'
  ) then
    execute $policy$
      create policy atlas_normalization_issue_definitions_read
        on public.atlas_normalization_issue_definitions
        for select to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_normalization_batches'
      and policyname = 'atlas_normalization_batches_read'
  ) then
    execute $policy$
      create policy atlas_normalization_batches_read
        on public.atlas_normalization_batches
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_normalized_records'
      and policyname = 'atlas_normalized_records_read'
  ) then
    execute $policy$
      create policy atlas_normalized_records_read
        on public.atlas_normalized_records
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_normalization_issues'
      and policyname = 'atlas_normalization_issues_read'
  ) then
    execute $policy$
      create policy atlas_normalization_issues_read
        on public.atlas_normalization_issues
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_normalization_events'
      and policyname = 'atlas_normalization_events_read'
  ) then
    execute $policy$
      create policy atlas_normalization_events_read
        on public.atlas_normalization_events
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_normalization_issue_definitions is
  'B2: catalogo canonico de incidencias detectables durante normalizacion.';

comment on table public.atlas_normalization_batches is
  'B2: ejecuciones versionadas de normalizacion ligadas al manifest vigente.';

comment on table public.atlas_normalized_records is
  'B2: propuestas normalizadas con fuente, hash y vigencia; aun no son datos canonicos.';

comment on table public.atlas_normalization_issues is
  'B2: faltantes, duplicados, contradicciones, vencimientos y otros bloqueos.';

comment on table public.atlas_normalization_events is
  'B2: historial append-only de lotes, registros e incidencias de normalizacion.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2F1_DATA_NORMALIZATION_CORE_INSTALLED',
  'next_block', 'B2.2F.2_NORMALIZATION_REGISTRATION_AND_ISSUE_DETECTION_RPCS',
  'normalization_tables_rls', 5,
  'issue_definitions', (
    select count(*)
    from public.atlas_normalization_issue_definitions
    where active = true
  ),
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
  'normalization_write_rpcs', 0,
  'canonical_promotion_enabled', false,
  'source_lineage_required', true,
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
