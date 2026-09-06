-- ATLAS B2.2K.1 - Nucleo inmutable del Certificado de Instalacion.
-- Corte: 2026-09-03
--
-- Crea contratos, certificados, fuentes y eventos append-only.
-- No emite certificados, no satisface G04 y no habilita ACTIVE.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_compute_installation_g04_readiness(uuid)'
     ) is null
     or to_regclass(
       'public.atlas_installation_acceptance_packages'
     ) is null
     or to_regclass(
       'public.atlas_installation_acceptance_requirements'
     ) is null then
    raise exception 'B2.2K.1 requiere B2.2J.3 instalado y certificado';
  end if;

  if to_regclass('public.atlas_installation_certificates') is not null
     or to_regclass(
       'public.atlas_installation_certificate_sources'
     ) is not null
     or to_regclass(
       'public.atlas_installation_certificate_events'
     ) is not null
     or to_regclass(
       'public.atlas_installation_certificate_contracts'
     ) is not null then
    raise exception
      'B2.2K.1 detecto estructuras de certificado previas; reconciliar antes de instalar';
  end if;
end;
$$;

insert into public.atlas_internal_permissions(
  permission_code, description
)
values
  (
    'INSTALLATION_CERTIFICATE_READ',
    'Consultar certificados de instalacion y sus fuentes no secretas.'
  ),
  (
    'INSTALLATION_CERTIFICATE_ISSUE',
    'Emitir certificados desde fuentes canonicas revalidadas.'
  ),
  (
    'INSTALLATION_CERTIFICATE_REVOKE',
    'Revocar certificados mediante autoridad y evidencia gobernadas.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions(
  role_code, permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_CERTIFICATE_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_CERTIFICATE_ISSUE'),
  ('ATLAS_OWNER', 'INSTALLATION_CERTIFICATE_REVOKE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_CERTIFICATE_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_CERTIFICATE_READ'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_CERTIFICATE_READ')
on conflict (role_code, permission_code) do nothing;

create or replace function
public.atlas_certificate_reference_is_safe(p_reference text)
returns boolean
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select
    length(p_reference) between 12 and 500
    and p_reference = btrim(p_reference)
    and p_reference !~ '[[:space:]?#@=]'
    and p_reference ~
      '^(audit|storage|receipt|test-evidence|training|exception|acceptance|gate|certificate|manifest|integration|provisioning)://[A-Za-z0-9][A-Za-z0-9._:/-]+$'
$$;

revoke all on function
public.atlas_certificate_reference_is_safe(text)
from public, anon, authenticated;
grant execute on function
public.atlas_certificate_reference_is_safe(text)
to service_role;

create table public.atlas_installation_certificate_contracts (
  contract_code text primary key,
  schema_version integer not null,
  display_name text not null,
  description text not null,
  required_source_domains text[] not null,
  payload_contract jsonb not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_certificate_contracts_code_check
    check (
      contract_code = 'B2_INSTALLATION_CERTIFICATE_V1'
      and schema_version >= 1
    ),
  constraint atlas_certificate_contracts_sources_check
    check (
      cardinality(required_source_domains) = 7
      and public.atlas_text_array_has_unique_values(
        required_source_domains
      )
      and required_source_domains @> array[
        'MANIFEST', 'PROVISIONING', 'INTEGRATION', 'TESTING',
        'GATES', 'ACCEPTANCE', 'AUDIT'
      ]::text[]
    ),
  constraint atlas_certificate_contracts_payload_check
    check (
      jsonb_typeof(payload_contract) = 'object'
      and payload_contract->>'contract_version' = contract_code
      and not public.atlas_jsonb_has_forbidden_secret_key(
        payload_contract
      )
    ),
  constraint atlas_certificate_contracts_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_installation_certificate_contracts(
  contract_code, schema_version, display_name, description,
  required_source_domains, payload_contract, metadata
)
values (
  'B2_INSTALLATION_CERTIFICATE_V1',
  1,
  'Certificado tecnico de instalacion Atlas',
  'Snapshot inmutable, verificable y no secreto derivado del backend.',
  array[
    'MANIFEST', 'PROVISIONING', 'INTEGRATION', 'TESTING',
    'GATES', 'ACCEPTANCE', 'AUDIT'
  ]::text[],
  jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_CERTIFICATE_V1',
    'required_identity_fields', jsonb_build_array(
      'certificate_id', 'certificate_code', 'certificate_version',
      'installation_id', 'installation_code', 'empresa_id'
    ),
    'required_lineage_fields', jsonb_build_array(
      'engine_version', 'manifest', 'provisioning', 'integrations',
      'tests', 'gates', 'acceptance', 'audit_references'
    ),
    'required_integrity_fields', jsonb_build_array(
      'evidence_root_sha256', 'certificate_sha256'
    ),
    'secret_values_allowed', false,
    'manual_assertions_allowed', false
  ),
  jsonb_build_object(
    'architecture_decision', 'B2-ADR-CONSOLE-CERTIFICATE-V1',
    'legal_rendering_scope', 'OUTSIDE_BACKEND_CORE'
  )
);

create table public.atlas_installation_certificates (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  acceptance_package_id uuid not null,
  certificate_code text not null,
  certificate_version integer not null,
  certificate_contract_code text not null,
  engine_version text not null,
  certified_state_code text not null,
  issuance_status text not null default 'ISSUED',
  certificate_payload jsonb not null,
  certificate_sha256 text not null,
  evidence_root_sha256 text not null,
  request_id uuid not null,
  request_sha256 text not null,
  issued_by_user_id uuid not null,
  issued_by_role_code text not null,
  issued_at timestamptz not null,
  supersedes_certificate_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_certificates_request_key
    unique (installation_id, request_id),
  constraint atlas_certificates_version_key
    unique (installation_id, certificate_version),
  constraint atlas_certificates_code_key
    unique (certificate_code),
  constraint atlas_certificates_identity_key
    unique (id, installation_id, empresa_id),
  constraint atlas_certificates_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_certificates_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_certificates_acceptance_package_fkey
    foreign key (
      acceptance_package_id, installation_id, empresa_id
    )
    references public.atlas_installation_acceptance_packages(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_certificates_contract_fkey
    foreign key (certificate_contract_code)
    references public.atlas_installation_certificate_contracts(
      contract_code
    )
    on delete restrict,
  constraint atlas_certificates_issuer_fkey
    foreign key (issued_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_certificates_supersedes_fkey
    foreign key (supersedes_certificate_id)
    references public.atlas_installation_certificates(id)
    on delete restrict,
  constraint atlas_certificates_code_check
    check (
      certificate_code ~ '^ATLAS-CERT-[A-Z0-9-]+$'
      and length(certificate_code) between 20 and 120
    ),
  constraint atlas_certificates_version_status_check
    check (
      certificate_version >= 1
      and certificate_contract_code =
        'B2_INSTALLATION_CERTIFICATE_V1'
      and certified_state_code = 'FINAL_APPROVAL'
      and issuance_status = 'ISSUED'
    ),
  constraint atlas_certificates_hashes_check
    check (
      certificate_sha256 ~ '^[0-9a-f]{64}$'
      and evidence_root_sha256 ~ '^[0-9a-f]{64}$'
      and request_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_certificates_payload_check
    check (
      jsonb_typeof(certificate_payload) = 'object'
      and certificate_payload->>'contract_version' =
        certificate_contract_code
      and certificate_payload->>'certificate_id' = id::text
      and certificate_payload->>'certificate_code' = certificate_code
      and certificate_payload->>'certificate_version' =
        certificate_version::text
      and certificate_payload->>'installation_id' =
        installation_id::text
      and certificate_payload->>'empresa_id' = empresa_id::text
      and certificate_payload->>'acceptance_package_id' =
        acceptance_package_id::text
      and certificate_payload->>'evidence_root_sha256' =
        evidence_root_sha256
      and not public.atlas_jsonb_has_forbidden_secret_key(
        certificate_payload
      )
      and certificate_sha256 = public.atlas_normalization_sha256(
        certificate_payload::text
      )
    ),
  constraint atlas_certificates_issuer_check
    check (
      issued_by_role_code ~ '^[A-Z][A-Z0-9_]*$'
      and issued_at >= created_at
    ),
  constraint atlas_certificates_no_self_supersede_check
    check (
      supersedes_certificate_id is null
      or supersedes_certificate_id <> id
    ),
  constraint atlas_certificates_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create unique index uq_atlas_certificates_one_initial
  on public.atlas_installation_certificates(installation_id)
  where supersedes_certificate_id is null;

create index idx_atlas_certificates_installation_timeline
  on public.atlas_installation_certificates(
    installation_id, certificate_version desc, issued_at desc
  );

create table public.atlas_installation_certificate_sources (
  id uuid primary key default gen_random_uuid(),
  certificate_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  source_domain text not null,
  source_code text not null,
  source_record_id uuid,
  source_version text not null,
  source_sha256 text not null,
  evidence_reference text not null,
  required boolean not null default true,
  verification_payload jsonb not null,
  verified_by_user_id uuid not null,
  verified_at timestamptz not null,
  created_at timestamptz not null default now(),

  constraint atlas_certificate_sources_key
    unique (certificate_id, source_domain, source_code),
  constraint atlas_certificate_sources_certificate_fkey
    foreign key (
      certificate_id, installation_id, empresa_id
    )
    references public.atlas_installation_certificates(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_certificate_sources_verifier_fkey
    foreign key (verified_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_certificate_sources_domain_check
    check (
      source_domain in (
        'MANIFEST', 'PROVISIONING', 'INTEGRATION', 'TESTING',
        'GATES', 'ACCEPTANCE', 'AUDIT'
      )
      and source_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(source_version) between 1 and 100
    ),
  constraint atlas_certificate_sources_evidence_check
    check (
      source_sha256 ~ '^[0-9a-f]{64}$'
      and public.atlas_certificate_reference_is_safe(
        evidence_reference
      )
      and jsonb_typeof(verification_payload) = 'object'
      and verification_payload <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        verification_payload
      )
      and verified_at >= created_at
    )
);

create index idx_atlas_certificate_sources_domain
  on public.atlas_installation_certificate_sources(
    installation_id, certificate_id, source_domain
  );

create table public.atlas_installation_certificate_events (
  id uuid primary key default gen_random_uuid(),
  certificate_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  event_type text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  request_id uuid not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  event_payload jsonb not null,
  created_at timestamptz not null default now(),

  constraint atlas_certificate_events_request_key
    unique (certificate_id, request_id),
  constraint atlas_certificate_events_certificate_fkey
    foreign key (
      certificate_id, installation_id, empresa_id
    )
    references public.atlas_installation_certificates(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_certificate_events_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_certificate_events_type_check
    check (
      event_type in (
        'ISSUED', 'VERIFIED', 'SUPERSEDED', 'REVOKED'
      )
      and actor_role_code ~ '^[A-Z][A-Z0-9_]*$'
    ),
  constraint atlas_certificate_events_evidence_check
    check (
      public.atlas_certificate_reference_is_safe(
        evidence_reference
      )
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
      and jsonb_typeof(event_payload) = 'object'
      and event_payload <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        event_payload
      )
    )
);

create index idx_atlas_certificate_events_timeline
  on public.atlas_installation_certificate_events(
    installation_id, created_at desc, id desc
  );

create or replace function
public.atlas_block_certificate_append_only_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'INSTALLATION_CERTIFICATE_RECORD_IMMUTABLE';
end;
$$;

revoke all on function
public.atlas_block_certificate_append_only_mutation()
from public, anon, authenticated;
grant execute on function
public.atlas_block_certificate_append_only_mutation()
to service_role;

create trigger trg_atlas_certificates_append_only
before update or delete
on public.atlas_installation_certificates
for each row execute function
public.atlas_block_certificate_append_only_mutation();

create trigger trg_atlas_certificate_sources_append_only
before update or delete
on public.atlas_installation_certificate_sources
for each row execute function
public.atlas_block_certificate_append_only_mutation();

create trigger trg_atlas_certificate_events_append_only
before update or delete
on public.atlas_installation_certificate_events
for each row execute function
public.atlas_block_certificate_append_only_mutation();

create trigger trg_atlas_certificate_contracts_updated_at
before update on public.atlas_installation_certificate_contracts
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_installation_certificate_contracts
  enable row level security;
alter table public.atlas_installation_certificates
  enable row level security;
alter table public.atlas_installation_certificate_sources
  enable row level security;
alter table public.atlas_installation_certificate_events
  enable row level security;

revoke all on table
  public.atlas_installation_certificate_contracts,
  public.atlas_installation_certificates,
  public.atlas_installation_certificate_sources,
  public.atlas_installation_certificate_events
from anon, authenticated;

grant select on table
  public.atlas_installation_certificate_contracts,
  public.atlas_installation_certificates,
  public.atlas_installation_certificate_sources,
  public.atlas_installation_certificate_events
to authenticated;

grant all on table
  public.atlas_installation_certificate_contracts,
  public.atlas_installation_certificates,
  public.atlas_installation_certificate_sources,
  public.atlas_installation_certificate_events
to service_role;

create policy atlas_certificate_contracts_read
on public.atlas_installation_certificate_contracts
for select to authenticated
using (active);

create policy atlas_certificates_read
on public.atlas_installation_certificates
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

create policy atlas_certificate_sources_read
on public.atlas_installation_certificate_sources
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

create policy atlas_certificate_events_read
on public.atlas_installation_certificate_events
for select to authenticated
using (public.atlas_can_read_installation(installation_id));

comment on table public.atlas_installation_certificates is
  'B2: certificados tecnicos inmutables; supersesion y revocacion se expresan mediante nuevos registros/eventos.';
comment on table public.atlas_installation_certificate_sources is
  'B2: linaje verificable por dominio de cada afirmacion certificada.';
comment on table public.atlas_installation_certificate_events is
  'B2: ciclo historico append-only ISSUED/VERIFIED/SUPERSEDED/REVOKED.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2K1_INSTALLATION_CERTIFICATE_CORE_INSTALLED',
  'next_block', 'B2.2K.2_CERTIFICATE_ISSUANCE_AND_VERIFICATION_RPCS',
  'certificate_contracts', (
    select count(*)
    from public.atlas_installation_certificate_contracts
  ),
  'required_source_domains', 7,
  'certificate_records', (
    select count(*) from public.atlas_installation_certificates
  ),
  'certificate_source_records', (
    select count(*)
    from public.atlas_installation_certificate_sources
  ),
  'certificate_event_records', (
    select count(*)
    from public.atlas_installation_certificate_events
  ),
  'certificate_tables_rls', 4,
  'append_only_tables', 3,
  'certificate_write_rpcs', 0,
  'certificate_issuance_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'secret_values_allowed', false,
  'direct_authenticated_write', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
