-- ATLAS B2.2K.4A
-- Nucleo de regeneracion controlada y manifiesto de renderizado.
-- Corte: 2026-09-04
--
-- Crea contratos y libros append-only. No regenera certificados,
-- no produce PDF y no modifica la autoridad G04/ACTIVE.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_compute_installation_certificate_lifecycle(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_get_installation_certificate_safe_projection(uuid)'
     ) is null
     or to_regclass('public.atlas_installation_certificates') is null then
    raise exception 'B2.2K.4A requiere B2.2K.3 instalado y certificado';
  end if;

  if to_regclass(
       'public.atlas_installation_certificate_regeneration_requests'
     ) is not null
     or to_regclass(
       'public.atlas_installation_certificate_regeneration_decisions'
     ) is not null
     or to_regclass(
       'public.atlas_installation_certificate_render_contracts'
     ) is not null
     or to_regclass(
       'public.atlas_installation_certificate_render_manifests'
     ) is not null then
    raise exception
      'B2.2K.4A detecto estructuras previas; reconciliar antes de instalar';
  end if;
end;
$$;

insert into public.atlas_internal_permissions(
  permission_code, description
)
values
  (
    'INSTALLATION_CERTIFICATE_REGENERATE',
    'Solicitar, decidir y ejecutar regeneracion controlada de certificados.'
  ),
  (
    'INSTALLATION_CERTIFICATE_RENDER_PREPARE',
    'Preparar manifiestos seguros para el renderizador documental.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions(
  role_code, permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_CERTIFICATE_REGENERATE'),
  ('ATLAS_OWNER', 'INSTALLATION_CERTIFICATE_RENDER_PREPARE'),
  (
    'ATLAS_IMPLEMENTATION_OPERATOR',
    'INSTALLATION_CERTIFICATE_RENDER_PREPARE'
  )
on conflict (role_code, permission_code) do nothing;

create table
public.atlas_installation_certificate_render_contracts (
  contract_code text primary key,
  schema_version integer not null,
  display_name text not null,
  description text not null,
  allowed_output_formats text[] not null,
  required_projection_fields text[] not null,
  render_contract jsonb not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_certificate_render_contracts_code_check
    check (
      contract_code = 'B2_INSTALLATION_CERTIFICATE_RENDER_V1'
      and schema_version >= 1
    ),
  constraint atlas_certificate_render_contracts_formats_check
    check (
      cardinality(allowed_output_formats) = 2
      and public.atlas_text_array_has_unique_values(
        allowed_output_formats
      )
      and allowed_output_formats @> array['PDF', 'PDF_A_3']::text[]
    ),
  constraint atlas_certificate_render_contracts_fields_check
    check (
      cardinality(required_projection_fields) >= 10
      and public.atlas_text_array_has_unique_values(
        required_projection_fields
      )
      and required_projection_fields @> array[
        'certificate_id', 'certificate_code',
        'certificate_version', 'installation_id', 'empresa_id',
        'company_legal_name', 'engine_version', 'issued_at',
        'lifecycle_status', 'cryptographically_verified',
        'certificate_sha256', 'evidence_root_sha256'
      ]::text[]
    ),
  constraint atlas_certificate_render_contracts_payload_check
    check (
      jsonb_typeof(render_contract) = 'object'
      and render_contract->>'contract_version' = contract_code
      and coalesce(
        (render_contract->>'credential_values_allowed')::boolean,
        true
      ) = false
      and coalesce(
        (render_contract->>'raw_payloads_allowed')::boolean,
        true
      ) = false
      and coalesce(
        (render_contract->>'evidence_references_allowed')::boolean,
        true
      ) = false
      and not public.atlas_jsonb_has_forbidden_secret_key(
        render_contract
      )
    ),
  constraint atlas_certificate_render_contracts_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_installation_certificate_render_contracts(
  contract_code, schema_version, display_name, description,
  allowed_output_formats, required_projection_fields,
  render_contract, metadata
)
values (
  'B2_INSTALLATION_CERTIFICATE_RENDER_V1',
  1,
  'Manifiesto seguro de renderizado del certificado Atlas',
  'Contrato no secreto para preparar PDF sin exponer arquitectura interna.',
  array['PDF', 'PDF_A_3']::text[],
  array[
    'certificate_id', 'certificate_code', 'certificate_version',
    'installation_id', 'empresa_id', 'company_legal_name',
    'engine_version', 'issued_at', 'lifecycle_status',
    'cryptographically_verified', 'certificate_sha256',
    'evidence_root_sha256', 'source_domains', 'module_summary'
  ]::text[],
  jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_CERTIFICATE_RENDER_V1',
    'input_projection_contract',
      'B2_INSTALLATION_CERTIFICATE_SAFE_PROJECTION_V1',
    'default_template_code', 'ATLAS_INSTALLATION_CERTIFICATE',
    'default_template_version', 'V1',
    'default_locale', 'es-CO',
    'credential_values_allowed', false,
    'raw_payloads_allowed', false,
    'evidence_references_allowed', false,
    'actor_identities_allowed', false,
    'renderer_executes_authority_actions', false,
    'rendering_changes_certificate_state', false
  ),
  jsonb_build_object(
    'architecture_decision', 'B2-ADR-CERTIFICATE-RENDER-V1',
    'legal_copy_scope', 'ATLAS_LEGAL'
  )
);

create table
public.atlas_installation_certificate_regeneration_requests (
  id uuid primary key default gen_random_uuid(),
  predecessor_certificate_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  requested_certificate_version integer not null,
  reason_code text not null,
  reason text not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  request_id uuid not null,
  request_sha256 text not null,
  expected_predecessor_version integer not null,
  requested_by_user_id uuid not null,
  requested_by_role_code text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_certificate_regeneration_requests_key
    unique (installation_id, request_id),
  constraint atlas_certificate_regeneration_requests_version_key
    unique (installation_id, requested_certificate_version),
  constraint atlas_certificate_regeneration_requests_identity_key
    unique (
      id, predecessor_certificate_id, installation_id, empresa_id
    ),
  constraint atlas_certificate_regeneration_requests_certificate_fkey
    foreign key (
      predecessor_certificate_id, installation_id, empresa_id
    )
    references public.atlas_installation_certificates(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_certificate_regeneration_requests_actor_fkey
    foreign key (requested_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_certificate_regeneration_requests_version_check
    check (
      requested_certificate_version >= 2
      and expected_predecessor_version >= 1
      and requested_certificate_version =
        expected_predecessor_version + 1
    ),
  constraint atlas_certificate_regeneration_requests_reason_check
    check (
      reason_code ~ '^[A-Z][A-Z0-9_]{4,99}$'
      and length(btrim(reason)) between 10 and 2000
    ),
  constraint atlas_certificate_regeneration_requests_evidence_check
    check (
      public.atlas_certificate_reference_is_safe(evidence_reference)
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
      and request_sha256 ~ '^[0-9a-f]{64}$'
      and requested_by_role_code ~ '^[A-Z][A-Z0-9_]*$'
    ),
  constraint atlas_certificate_regeneration_requests_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create table
public.atlas_installation_certificate_regeneration_decisions (
  id uuid primary key default gen_random_uuid(),
  regeneration_request_id uuid not null,
  predecessor_certificate_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  decision text not null,
  reason text not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  decision_request_id uuid not null,
  decision_sha256 text not null,
  expected_predecessor_version integer not null,
  decided_by_user_id uuid not null,
  decided_by_role_code text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_certificate_regeneration_decisions_request_key
    unique (regeneration_request_id),
  constraint atlas_certificate_regeneration_decisions_idempotency_key
    unique (installation_id, decision_request_id),
  constraint atlas_certificate_regeneration_decisions_request_fkey
    foreign key (
      regeneration_request_id, predecessor_certificate_id,
      installation_id, empresa_id
    )
    references
      public.atlas_installation_certificate_regeneration_requests(
        id, predecessor_certificate_id, installation_id, empresa_id
      )
    on delete restrict,
  constraint atlas_certificate_regeneration_decisions_actor_fkey
    foreign key (decided_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_certificate_regeneration_decisions_value_check
    check (
      decision in ('APPROVED', 'REJECTED')
      and length(btrim(reason)) between 10 and 2000
      and expected_predecessor_version >= 1
    ),
  constraint atlas_certificate_regeneration_decisions_evidence_check
    check (
      public.atlas_certificate_reference_is_safe(evidence_reference)
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
      and decision_sha256 ~ '^[0-9a-f]{64}$'
      and decided_by_role_code = 'ATLAS_OWNER'
    ),
  constraint atlas_certificate_regeneration_decisions_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create table
public.atlas_installation_certificate_render_manifests (
  id uuid primary key default gen_random_uuid(),
  certificate_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  render_version integer not null,
  render_contract_code text not null,
  template_code text not null,
  template_version text not null,
  output_format text not null,
  locale text not null,
  render_status text not null default 'READY_FOR_RENDER',
  safe_projection jsonb not null,
  safe_projection_sha256 text not null,
  render_manifest jsonb not null,
  render_manifest_sha256 text not null,
  idempotency_key uuid not null,
  prepared_by_user_id uuid not null,
  prepared_by_role_code text not null,
  supersedes_render_manifest_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_certificate_render_manifests_request_key
    unique (certificate_id, idempotency_key),
  constraint atlas_certificate_render_manifests_version_key
    unique (certificate_id, render_version),
  constraint atlas_certificate_render_manifests_identity_key
    unique (id, certificate_id, installation_id, empresa_id),
  constraint atlas_certificate_render_manifests_certificate_fkey
    foreign key (certificate_id, installation_id, empresa_id)
    references public.atlas_installation_certificates(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_certificate_render_manifests_contract_fkey
    foreign key (render_contract_code)
    references public.atlas_installation_certificate_render_contracts(
      contract_code
    )
    on delete restrict,
  constraint atlas_certificate_render_manifests_actor_fkey
    foreign key (prepared_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_certificate_render_manifests_supersedes_fkey
    foreign key (supersedes_render_manifest_id)
    references public.atlas_installation_certificate_render_manifests(id)
    on delete restrict,
  constraint atlas_certificate_render_manifests_identity_check
    check (
      render_version >= 1
      and render_contract_code =
        'B2_INSTALLATION_CERTIFICATE_RENDER_V1'
      and template_code ~ '^[A-Z][A-Z0-9_]*$'
      and template_version ~ '^V[0-9]+$'
      and output_format in ('PDF', 'PDF_A_3')
      and locale ~ '^[a-z]{2}-[A-Z]{2}$'
      and render_status = 'READY_FOR_RENDER'
      and prepared_by_role_code ~ '^[A-Z][A-Z0-9_]*$'
    ),
  constraint atlas_certificate_render_manifests_projection_check
    check (
      jsonb_typeof(safe_projection) = 'object'
      and safe_projection->>'projection_contract_version' =
        'B2_INSTALLATION_CERTIFICATE_SAFE_PROJECTION_V1'
      and safe_projection->>'certificate_id' = certificate_id::text
      and coalesce(
        (safe_projection->>'credential_values_exposed')::boolean,
        true
      ) = false
      and coalesce(
        (safe_projection->>'raw_payloads_exposed')::boolean,
        true
      ) = false
      and coalesce(
        (safe_projection->>'evidence_references_exposed')::boolean,
        true
      ) = false
      and not public.atlas_jsonb_has_forbidden_secret_key(
        safe_projection
      )
      and safe_projection_sha256 =
        public.atlas_normalization_sha256(safe_projection::text)
    ),
  constraint atlas_certificate_render_manifests_payload_check
    check (
      jsonb_typeof(render_manifest) = 'object'
      and render_manifest->>'contract_version' =
        render_contract_code
      and render_manifest->>'certificate_id' = certificate_id::text
      and render_manifest->>'render_version' = render_version::text
      and render_manifest->>'safe_projection_sha256' =
        safe_projection_sha256
      and not public.atlas_jsonb_has_forbidden_secret_key(
        render_manifest
      )
      and render_manifest_sha256 =
        public.atlas_normalization_sha256(render_manifest::text)
    ),
  constraint atlas_certificate_render_manifests_hashes_check
    check (
      safe_projection_sha256 ~ '^[0-9a-f]{64}$'
      and render_manifest_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_certificate_render_manifests_no_self_supersede_check
    check (
      supersedes_render_manifest_id is null
      or supersedes_render_manifest_id <> id
    ),
  constraint atlas_certificate_render_manifests_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_certificate_regeneration_timeline
  on public.atlas_installation_certificate_regeneration_requests(
    installation_id, created_at desc, id desc
  );
create index idx_atlas_certificate_render_manifest_timeline
  on public.atlas_installation_certificate_render_manifests(
    installation_id, certificate_id, render_version desc
  );

create or replace function
public.atlas_block_certificate_artifact_append_only_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'INSTALLATION_CERTIFICATE_ARTIFACT_IMMUTABLE';
end;
$$;

revoke all on function
public.atlas_block_certificate_artifact_append_only_mutation()
from public, anon, authenticated;
grant execute on function
public.atlas_block_certificate_artifact_append_only_mutation()
to service_role;

create trigger trg_atlas_certificate_regeneration_requests_append_only
before update or delete
on public.atlas_installation_certificate_regeneration_requests
for each row execute function
public.atlas_block_certificate_artifact_append_only_mutation();

create trigger trg_atlas_certificate_regeneration_decisions_append_only
before update or delete
on public.atlas_installation_certificate_regeneration_decisions
for each row execute function
public.atlas_block_certificate_artifact_append_only_mutation();

create trigger trg_atlas_certificate_render_manifests_append_only
before update or delete
on public.atlas_installation_certificate_render_manifests
for each row execute function
public.atlas_block_certificate_artifact_append_only_mutation();

create trigger trg_atlas_certificate_render_contracts_updated_at
before update
on public.atlas_installation_certificate_render_contracts
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_installation_certificate_render_contracts
  enable row level security;
alter table
  public.atlas_installation_certificate_regeneration_requests
  enable row level security;
alter table
  public.atlas_installation_certificate_regeneration_decisions
  enable row level security;
alter table public.atlas_installation_certificate_render_manifests
  enable row level security;

revoke all on table
  public.atlas_installation_certificate_render_contracts,
  public.atlas_installation_certificate_regeneration_requests,
  public.atlas_installation_certificate_regeneration_decisions,
  public.atlas_installation_certificate_render_manifests
from anon, authenticated;

grant select on table
  public.atlas_installation_certificate_render_contracts,
  public.atlas_installation_certificate_regeneration_requests,
  public.atlas_installation_certificate_regeneration_decisions,
  public.atlas_installation_certificate_render_manifests
to authenticated;

grant all on table
  public.atlas_installation_certificate_render_contracts,
  public.atlas_installation_certificate_regeneration_requests,
  public.atlas_installation_certificate_regeneration_decisions,
  public.atlas_installation_certificate_render_manifests
to service_role;

create policy atlas_certificate_render_contracts_read
on public.atlas_installation_certificate_render_contracts
for select to authenticated
using (active);

create policy atlas_certificate_regeneration_requests_read
on public.atlas_installation_certificate_regeneration_requests
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

create policy atlas_certificate_regeneration_decisions_read
on public.atlas_installation_certificate_regeneration_decisions
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

create policy atlas_certificate_render_manifests_read
on public.atlas_installation_certificate_render_manifests
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

comment on table
public.atlas_installation_certificate_regeneration_requests is
  'B2: solicitudes inmutables de nueva version; nunca reescriben el certificado previo.';
comment on table
public.atlas_installation_certificate_regeneration_decisions is
  'B2: autoridad humana append-only previa a cualquier regeneracion.';
comment on table
public.atlas_installation_certificate_render_manifests is
  'B2: entrada segura e inmutable para un renderizador documental externo al core.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K4A_REGENERATION_RENDER_MANIFEST_CORE_INSTALLED',
  'next_block',
    'B2.2K.4B_CONTROLLED_REGENERATION_AND_RENDER_RPCS',
  'governance_tables', 4,
  'rls_tables', 4,
  'append_only_tables', 3,
  'regeneration_permissions', 2,
  'canonical_render_contracts', 1,
  'allowed_output_formats', 2,
  'regeneration_requests', 0,
  'regeneration_decisions', 0,
  'render_manifests', 0,
  'regeneration_write_rpcs', 0,
  'render_write_rpcs', 0,
  'credential_values_allowed', false,
  'raw_payloads_allowed', false,
  'evidence_references_allowed', false,
  'certificate_regeneration_enabled', false,
  'certificate_rendering_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'direct_authenticated_write', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
