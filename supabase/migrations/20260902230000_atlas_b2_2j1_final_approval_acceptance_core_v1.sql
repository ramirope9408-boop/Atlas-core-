-- ATLAS B2.2J.1
-- Nucleo de aprobacion final, entrega, capacitacion y aceptacion.
-- Corte: 2026-09-02
--
-- Alcance deliberado:
-- - cataloga los ocho criterios canonicos de G04 y su bloque responsable;
-- - crea paquetes de aceptacion ligados a manifest, pruebas y G03 vigentes;
-- - modela evidencia, capacitacion, excepciones, decisiones y eventos;
-- - preserva separacion entre autoridad Atlas y autoridad cliente;
-- - no registra datos ficticios, no decide G04, no emite certificados;
-- - no habilita ACTIVE y no concede escritura directa al cliente.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_get_installation_g03_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_g03_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null
     or to_regprocedure('public.atlas_set_updated_at()') is null
     or to_regclass('public.atlas_installation_test_plans') is null
     or to_regclass('public.atlas_installation_test_runs') is null
     or to_regclass('public.atlas_installation_test_results') is null
     or to_regclass('public.atlas_installation_gates') is null
     or to_regclass('public.atlas_installation_approvals') is null
     or to_regclass('public.atlas_installation_contracts') is null then
    raise exception
      'B2.2J.1 requiere B2.2I.3 instalado y certificado';
  end if;

  if not exists (
    select 1
    from public.atlas_installation_gate_definitions as definition
    where definition.gate_code = 'G04'
      and definition.review_state_code = 'FINAL_APPROVAL'
      and definition.approved_target_state_code = 'ACTIVE'
      and definition.requires_platform_approval
      and definition.requires_client_approval
      and definition.active
  ) then
    raise exception 'B2.2J.1 requiere contrato G04 dual activo';
  end if;

  if (
    select count(*)
    from public.atlas_installation_gate_definitions as definition
    cross join lateral jsonb_array_elements(
      definition.criteria
    ) as criterion(value)
    where definition.gate_code = 'G04'
      and definition.active
      and coalesce(
        (criterion.value->>'required')::boolean,
        false
      )
  ) <> 8 then
    raise exception 'B2.2J.1 requiere ocho criterios G04 canonicos';
  end if;

  if to_regclass(
       'public.atlas_installation_acceptance_requirement_definitions'
     ) is not null
     or to_regclass(
       'public.atlas_installation_acceptance_packages'
     ) is not null
     or to_regclass(
       'public.atlas_installation_acceptance_requirements'
     ) is not null
     or to_regclass(
       'public.atlas_installation_training_records'
     ) is not null
     or to_regclass(
       'public.atlas_installation_exception_records'
     ) is not null
     or to_regclass(
       'public.atlas_installation_acceptance_decisions'
     ) is not null
     or to_regclass(
       'public.atlas_installation_acceptance_events'
     ) is not null then
    raise exception
      'B2.2J.1 detecto estructuras de aceptacion previas; reconciliar antes de instalar';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_ACCEPTANCE_READ',
    'Consultar entrega, capacitacion, excepciones y aceptacion final.'
  ),
  (
    'INSTALLATION_ACCEPTANCE_PREPARE',
    'Preparar paquetes y evidencias de aceptacion mediante RPC gobernada.'
  ),
  (
    'INSTALLATION_ACCEPTANCE_REVIEW',
    'Revisar la aceptacion final mediante autoridad gobernada.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_ACCEPTANCE_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_ACCEPTANCE_PREPARE'),
  ('ATLAS_OWNER', 'INSTALLATION_ACCEPTANCE_REVIEW'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_ACCEPTANCE_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_ACCEPTANCE_PREPARE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_ACCEPTANCE_READ'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_ACCEPTANCE_READ')
on conflict (role_code, permission_code) do nothing;

create or replace function
public.atlas_acceptance_evidence_reference_is_safe(
  p_reference text
)
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
      '^(audit|storage|receipt|test-evidence|training|exception|acceptance|gate|certificate)://[A-Za-z0-9][A-Za-z0-9._:/-]+$'
$$;

revoke all on function
public.atlas_acceptance_evidence_reference_is_safe(text)
from public, anon, authenticated;
grant execute on function
public.atlas_acceptance_evidence_reference_is_safe(text)
to service_role;

create table
public.atlas_installation_acceptance_requirement_definitions (
  requirement_code text primary key,
  display_name text not null,
  description text not null,
  source_domain text not null,
  implementation_block text not null,
  objective_requirement boolean not null,
  requires_platform_confirmation boolean not null,
  requires_client_confirmation boolean not null,
  waiver_allowed boolean not null default false,
  sort_order integer not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_acceptance_requirement_code_check
    check (requirement_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_acceptance_requirement_text_check
    check (
      length(btrim(display_name)) between 5 and 160
      and length(btrim(description)) between 20 and 1000
    ),
  constraint atlas_acceptance_requirement_domain_check
    check (
      source_domain in (
        'TESTING', 'DEFECT', 'EXCEPTION', 'TRAINING',
        'CLIENT_ACCEPTANCE', 'CERTIFICATE', 'ACTIVATION_AUTHORITY'
      )
    ),
  constraint atlas_acceptance_requirement_block_check
    check (implementation_block in ('B2.2J', 'B2.2K', 'B2.2L')),
  constraint atlas_acceptance_requirement_authority_check
    check (
      objective_requirement
      or requires_platform_confirmation
      or requires_client_confirmation
    ),
  constraint atlas_acceptance_requirement_order_check
    check (sort_order between 1 and 100),
  constraint atlas_acceptance_requirement_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into
public.atlas_installation_acceptance_requirement_definitions (
  requirement_code,
  display_name,
  description,
  source_domain,
  implementation_block,
  objective_requirement,
  requires_platform_confirmation,
  requires_client_confirmation,
  waiver_allowed,
  sort_order,
  active
)
values
  (
    'FUNCTIONAL_CASES_APPROVED',
    'Casos funcionales aprobados',
    'Los casos funcionales aplicables terminaron satisfactoriamente y conservan evidencia vigente.',
    'TESTING', 'B2.2J', true, true, true, false, 10, true
  ),
  (
    'SECURITY_TESTS_APPROVED',
    'Pruebas de seguridad aprobadas',
    'Las pruebas de seguridad y aislamiento fueron aprobadas por la autoridad tecnica correspondiente.',
    'TESTING', 'B2.2J', true, true, false, false, 20, true
  ),
  (
    'ZERO_CRITICAL_DEFECTS',
    'Cero defectos criticos',
    'No existen defectos criticos abiertos, diferidos ni aceptados como riesgo para la activacion.',
    'DEFECT', 'B2.2J', true, true, false, false, 30, true
  ),
  (
    'EXCEPTIONS_ACCEPTED',
    'Excepciones documentadas',
    'Toda excepcion no critica vigente fue documentada y aceptada por las autoridades requeridas.',
    'EXCEPTION', 'B2.2J', true, true, true, false, 40, true
  ),
  (
    'TRAINING_COMPLETED',
    'Capacitacion completada',
    'La capacitacion requerida fue impartida a los responsables definidos y cuenta con evidencia verificable.',
    'TRAINING', 'B2.2J', true, true, true, false, 50, true
  ),
  (
    'ACCEPTANCE_RECORDED',
    'Aceptacion verificable registrada',
    'La entrega fue presentada y el cliente registro una aceptacion valida vinculada al alcance y sus evidencias.',
    'CLIENT_ACCEPTANCE', 'B2.2J', true, true, true, false, 60, true
  ),
  (
    'INSTALLATION_CERTIFICATE_ISSUED',
    'Certificado de instalacion emitido',
    'Existe un certificado tecnico vigente, inmutable y derivado de las fuentes canonicas de la instalacion.',
    'CERTIFICATE', 'B2.2K', true, true, false, false, 70, true
  ),
  (
    'ACTIVE_STATE_AUTHORIZED',
    'Activacion autorizada',
    'La autoridad final de Atlas autorizo expresamente el ingreso a ACTIVE sobre fuentes revalidadas.',
    'ACTIVATION_AUTHORITY', 'B2.2L', true, true, false, false, 80, true
  )
on conflict (requirement_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  source_domain = excluded.source_domain,
  implementation_block = excluded.implementation_block,
  objective_requirement = excluded.objective_requirement,
  requires_platform_confirmation =
    excluded.requires_platform_confirmation,
  requires_client_confirmation = excluded.requires_client_confirmation,
  waiver_allowed = excluded.waiver_allowed,
  sort_order = excluded.sort_order,
  active = excluded.active,
  updated_at = now();

do $$
begin
  if (
    select count(*)
    from public.atlas_installation_acceptance_requirement_definitions
    where active
  ) <> 8 then
    raise exception 'B2.2J.1 requiere ocho requisitos G04 activos';
  end if;

  if exists (
    select criterion.value->>'code'
    from public.atlas_installation_gate_definitions as definition
    cross join lateral jsonb_array_elements(
      definition.criteria
    ) as criterion(value)
    where definition.gate_code = 'G04'
      and definition.active
      and coalesce(
        (criterion.value->>'required')::boolean,
        false
      )
    except
    select requirement_code
    from public.atlas_installation_acceptance_requirement_definitions
    where active
  ) or exists (
    select requirement_code
    from public.atlas_installation_acceptance_requirement_definitions
    where active
    except
    select criterion.value->>'code'
    from public.atlas_installation_gate_definitions as definition
    cross join lateral jsonb_array_elements(
      definition.criteria
    ) as criterion(value)
    where definition.gate_code = 'G04'
      and definition.active
      and coalesce(
        (criterion.value->>'required')::boolean,
        false
      )
  ) then
    raise exception 'B2.2J.1 catalogo de aceptacion no coincide con G04';
  end if;
end;
$$;

create table public.atlas_installation_acceptance_packages (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  acceptance_code text not null,
  acceptance_version integer not null,
  acceptance_contract_version text not null,
  package_status text not null default 'DRAFT',
  expected_installation_version bigint not null,
  source_manifest_id uuid not null,
  source_manifest_sha256 text not null,
  source_test_plan_id uuid not null,
  source_test_run_id uuid not null,
  source_test_plan_sha256 text not null,
  source_test_evidence_root_sha256 text not null,
  source_g03_gate_id uuid not null,
  source_g03_gate_version bigint not null,
  source_g03_readiness_sha256 text not null,
  acceptance_contract_id uuid,
  package_payload jsonb not null,
  package_sha256 text not null,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  supersedes_package_id uuid,
  ready_at timestamptz,
  delivered_at timestamptz,
  closed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_acceptance_packages_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_acceptance_packages_version_key
    unique (installation_id, acceptance_version),
  constraint atlas_acceptance_packages_code_key
    unique (acceptance_code),
  constraint atlas_acceptance_packages_identity_key
    unique (id, installation_id, empresa_id),
  constraint atlas_acceptance_packages_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_acceptance_packages_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_acceptance_packages_manifest_fkey
    foreign key (source_manifest_id)
    references public.atlas_installation_manifests(id)
    on delete restrict,
  constraint atlas_acceptance_packages_test_plan_fkey
    foreign key (
      source_test_plan_id, installation_id, empresa_id
    )
    references public.atlas_installation_test_plans(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_acceptance_packages_test_run_fkey
    foreign key (
      source_test_run_id,
      source_test_plan_id,
      installation_id,
      empresa_id
    )
    references public.atlas_installation_test_runs(
      id, test_plan_id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_acceptance_packages_g03_gate_fkey
    foreign key (source_g03_gate_id)
    references public.atlas_installation_gates(id)
    on delete restrict,
  constraint atlas_acceptance_packages_contract_fkey
    foreign key (acceptance_contract_id)
    references public.atlas_installation_contracts(id)
    on delete restrict,
  constraint atlas_acceptance_packages_creator_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_acceptance_packages_supersedes_fkey
    foreign key (supersedes_package_id)
    references public.atlas_installation_acceptance_packages(id)
    on delete restrict,
  constraint atlas_acceptance_packages_code_check
    check (
      acceptance_code ~ '^B2-ACC-[A-Z0-9-]+$'
      and length(acceptance_code) between 12 and 100
    ),
  constraint atlas_acceptance_packages_version_check
    check (
      acceptance_version >= 1
      and expected_installation_version >= 1
      and source_g03_gate_version >= 2
      and acceptance_contract_version =
        'B2_INSTALLATION_ACCEPTANCE_V1'
    ),
  constraint atlas_acceptance_packages_status_check
    check (
      package_status in (
        'DRAFT', 'READY_FOR_DELIVERY', 'DELIVERED',
        'UNDER_CLIENT_REVIEW', 'ACCEPTED', 'REJECTED',
        'CHANGES_REQUIRED', 'SUPERSEDED'
      )
    ),
  constraint atlas_acceptance_packages_hashes_check
    check (
      source_manifest_sha256 ~ '^[0-9a-f]{64}$'
      and source_test_plan_sha256 ~ '^[0-9a-f]{64}$'
      and source_test_evidence_root_sha256 ~ '^[0-9a-f]{64}$'
      and source_g03_readiness_sha256 ~ '^[0-9a-f]{64}$'
      and package_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_acceptance_packages_payload_check
    check (
      jsonb_typeof(package_payload) = 'object'
      and package_payload->>'contract_version' =
        acceptance_contract_version
      and package_payload->>'installation_id' = installation_id::text
      and package_payload->>'empresa_id' = empresa_id::text
      and package_payload->>'acceptance_version' =
        acceptance_version::text
      and package_payload->>'source_manifest_id' =
        source_manifest_id::text
      and package_payload->>'source_test_plan_id' =
        source_test_plan_id::text
      and package_payload->>'source_test_run_id' =
        source_test_run_id::text
      and package_payload->>'source_g03_gate_id' =
        source_g03_gate_id::text
      and not public.atlas_jsonb_has_forbidden_secret_key(
        package_payload
      )
      and package_sha256 = public.atlas_normalization_sha256(
        package_payload::text
      )
    ),
  constraint atlas_acceptance_packages_timeline_check
    check (
      (ready_at is null or ready_at >= created_at)
      and (delivered_at is null or delivered_at >= created_at)
      and (closed_at is null or closed_at >= created_at)
      and (
        package_status <> 'READY_FOR_DELIVERY'
        or ready_at is not null
      )
      and (
        package_status not in (
          'DELIVERED', 'UNDER_CLIENT_REVIEW', 'ACCEPTED',
          'REJECTED', 'CHANGES_REQUIRED'
        )
        or delivered_at is not null
      )
      and (
        package_status not in (
          'ACCEPTED', 'REJECTED', 'CHANGES_REQUIRED', 'SUPERSEDED'
        )
        or closed_at is not null
      )
    ),
  constraint atlas_acceptance_packages_no_self_supersede_check
    check (supersedes_package_id is null or supersedes_package_id <> id),
  constraint atlas_acceptance_packages_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create unique index uq_atlas_acceptance_one_open_package
  on public.atlas_installation_acceptance_packages(installation_id)
  where package_status in (
    'DRAFT', 'READY_FOR_DELIVERY', 'DELIVERED',
    'UNDER_CLIENT_REVIEW', 'CHANGES_REQUIRED'
  );

create index idx_atlas_acceptance_packages_installation_status
  on public.atlas_installation_acceptance_packages(
    installation_id,
    package_status,
    acceptance_version desc
  );

create table public.atlas_installation_acceptance_requirements (
  id uuid primary key default gen_random_uuid(),
  acceptance_package_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  requirement_code text not null,
  requirement_status text not null default 'PENDING',
  evidence_kind text,
  evidence_reference text,
  evidence_sha256 text,
  verification_payload jsonb not null default '{}'::jsonb,
  verified_by_user_id uuid,
  verified_at timestamptz,
  blocking_reason_code text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_acceptance_requirements_package_key
    unique (acceptance_package_id, requirement_code),
  constraint atlas_acceptance_requirements_identity_key
    unique (id, acceptance_package_id, installation_id, empresa_id),
  constraint atlas_acceptance_requirements_package_fkey
    foreign key (
      acceptance_package_id, installation_id, empresa_id
    )
    references public.atlas_installation_acceptance_packages(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_acceptance_requirements_definition_fkey
    foreign key (requirement_code)
    references
      public.atlas_installation_acceptance_requirement_definitions(
        requirement_code
      )
    on delete restrict,
  constraint atlas_acceptance_requirements_verifier_fkey
    foreign key (verified_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_acceptance_requirements_status_check
    check (
      requirement_status in (
        'PENDING', 'SATISFIED', 'BLOCKED', 'INVALIDATED'
      )
    ),
  constraint atlas_acceptance_requirements_evidence_kind_check
    check (
      evidence_kind is null
      or evidence_kind in (
        'TEST_READINESS', 'TEST_RESULT', 'DEFECT_REPORT',
        'EXCEPTION_DECISION', 'TRAINING_RECORD',
        'SIGNED_ACCEPTANCE', 'CERTIFICATE',
        'ACTIVATION_AUTHORIZATION'
      )
    ),
  constraint atlas_acceptance_requirements_evidence_check
    check (
      (
        requirement_status = 'SATISFIED'
        and evidence_kind is not null
        and public.atlas_acceptance_evidence_reference_is_safe(
          evidence_reference
        )
        and evidence_sha256 ~ '^[0-9a-f]{64}$'
        and verification_payload <> '{}'::jsonb
        and verified_by_user_id is not null
        and verified_at is not null
      )
      or (
        requirement_status <> 'SATISFIED'
        and verified_by_user_id is null
        and verified_at is null
      )
    ),
  constraint atlas_acceptance_requirements_blocker_check
    check (
      requirement_status <> 'BLOCKED'
      or (
        blocking_reason_code ~ '^[A-Z][A-Z0-9_]*$'
        and length(blocking_reason_code) between 5 and 100
      )
    ),
  constraint atlas_acceptance_requirements_payload_check
    check (
      jsonb_typeof(verification_payload) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(
        verification_payload
      )
    ),
  constraint atlas_acceptance_requirements_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_acceptance_requirements_package_status
  on public.atlas_installation_acceptance_requirements(
    acceptance_package_id,
    requirement_status,
    requirement_code
  );

create table public.atlas_installation_training_records (
  id uuid primary key default gen_random_uuid(),
  acceptance_package_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  training_code text not null,
  training_version integer not null,
  training_status text not null default 'PLANNED',
  audience_scope jsonb not null,
  subject_scope text[] not null,
  scheduled_at timestamptz not null,
  started_at timestamptz,
  completed_at timestamptz,
  delivered_by_user_id uuid not null,
  evidence_reference text,
  evidence_sha256 text,
  training_payload jsonb not null,
  training_sha256 text not null,
  idempotency_key uuid not null,
  supersedes_training_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_training_records_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_training_records_version_key
    unique (acceptance_package_id, training_code, training_version),
  constraint atlas_training_records_identity_key
    unique (id, acceptance_package_id, installation_id, empresa_id),
  constraint atlas_training_records_package_fkey
    foreign key (
      acceptance_package_id, installation_id, empresa_id
    )
    references public.atlas_installation_acceptance_packages(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_training_records_actor_fkey
    foreign key (delivered_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_training_records_supersedes_fkey
    foreign key (supersedes_training_id)
    references public.atlas_installation_training_records(id)
    on delete restrict,
  constraint atlas_training_records_code_check
    check (
      training_code ~ '^TRN-[A-Z0-9_-]+$'
      and length(training_code) between 8 and 100
      and training_version >= 1
    ),
  constraint atlas_training_records_status_check
    check (
      training_status in (
        'PLANNED', 'IN_PROGRESS', 'COMPLETED',
        'CANCELLED', 'SUPERSEDED'
      )
    ),
  constraint atlas_training_records_scope_check
    check (
      jsonb_typeof(audience_scope) = 'object'
      and audience_scope <> '{}'::jsonb
      and cardinality(subject_scope) >= 1
      and public.atlas_text_array_has_unique_values(subject_scope)
      and not public.atlas_jsonb_has_forbidden_secret_key(
        audience_scope
      )
    ),
  constraint atlas_training_records_timeline_check
    check (
      (started_at is null or started_at >= scheduled_at)
      and (
        completed_at is null
        or (started_at is not null and completed_at >= started_at)
      )
      and (
        training_status <> 'IN_PROGRESS'
        or started_at is not null
      )
      and (
        training_status <> 'COMPLETED'
        or (
          started_at is not null
          and completed_at is not null
          and public.atlas_acceptance_evidence_reference_is_safe(
            evidence_reference
          )
          and evidence_sha256 ~ '^[0-9a-f]{64}$'
        )
      )
    ),
  constraint atlas_training_records_payload_check
    check (
      jsonb_typeof(training_payload) = 'object'
      and training_payload->>'training_code' = training_code
      and training_payload->>'training_version' =
        training_version::text
      and not public.atlas_jsonb_has_forbidden_secret_key(
        training_payload
      )
      and training_sha256 ~ '^[0-9a-f]{64}$'
      and training_sha256 = public.atlas_normalization_sha256(
        training_payload::text
      )
    ),
  constraint atlas_training_records_no_self_supersede_check
    check (supersedes_training_id is null or supersedes_training_id <> id),
  constraint atlas_training_records_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_training_records_installation_status
  on public.atlas_installation_training_records(
    installation_id,
    training_status,
    training_code
  );

create table public.atlas_installation_exception_records (
  id uuid primary key default gen_random_uuid(),
  acceptance_package_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  exception_code text not null,
  exception_version integer not null,
  severity text not null,
  exception_status text not null default 'OPEN',
  blocking boolean not null default true,
  client_acceptance_required boolean not null default true,
  source_test_result_id uuid,
  exception_payload jsonb not null,
  exception_sha256 text not null,
  accepted_by_user_id uuid,
  accepted_at timestamptz,
  acceptance_evidence_reference text,
  acceptance_evidence_sha256 text,
  idempotency_key uuid not null,
  supersedes_exception_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_exception_records_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_exception_records_version_key
    unique (acceptance_package_id, exception_code, exception_version),
  constraint atlas_exception_records_identity_key
    unique (id, acceptance_package_id, installation_id, empresa_id),
  constraint atlas_exception_records_package_fkey
    foreign key (
      acceptance_package_id, installation_id, empresa_id
    )
    references public.atlas_installation_acceptance_packages(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_exception_records_test_result_fkey
    foreign key (source_test_result_id)
    references public.atlas_installation_test_results(id)
    on delete restrict,
  constraint atlas_exception_records_acceptor_fkey
    foreign key (accepted_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_exception_records_supersedes_fkey
    foreign key (supersedes_exception_id)
    references public.atlas_installation_exception_records(id)
    on delete restrict,
  constraint atlas_exception_records_code_check
    check (
      exception_code ~ '^EXC-[A-Z0-9_-]+$'
      and length(exception_code) between 8 and 100
      and exception_version >= 1
    ),
  constraint atlas_exception_records_severity_check
    check (severity in ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
  constraint atlas_exception_records_status_check
    check (
      exception_status in (
        'OPEN', 'REMEDIATED', 'ACCEPTED_RISK',
        'REJECTED', 'SUPERSEDED'
      )
      and (
        severity <> 'CRITICAL'
        or exception_status in ('OPEN', 'REMEDIATED', 'SUPERSEDED')
      )
    ),
  constraint atlas_exception_records_blocking_check
    check (
      severity <> 'CRITICAL'
      or blocking
    ),
  constraint atlas_exception_records_acceptance_check
    check (
      (
        exception_status = 'ACCEPTED_RISK'
        and severity <> 'CRITICAL'
        and accepted_by_user_id is not null
        and accepted_at is not null
        and public.atlas_acceptance_evidence_reference_is_safe(
          acceptance_evidence_reference
        )
        and acceptance_evidence_sha256 ~ '^[0-9a-f]{64}$'
      )
      or (
        exception_status <> 'ACCEPTED_RISK'
        and accepted_by_user_id is null
        and accepted_at is null
      )
    ),
  constraint atlas_exception_records_payload_check
    check (
      jsonb_typeof(exception_payload) = 'object'
      and exception_payload->>'exception_code' = exception_code
      and exception_payload->>'exception_version' =
        exception_version::text
      and not public.atlas_jsonb_has_forbidden_secret_key(
        exception_payload
      )
      and exception_sha256 ~ '^[0-9a-f]{64}$'
      and exception_sha256 = public.atlas_normalization_sha256(
        exception_payload::text
      )
    ),
  constraint atlas_exception_records_no_self_supersede_check
    check (
      supersedes_exception_id is null
      or supersedes_exception_id <> id
    ),
  constraint atlas_exception_records_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_exception_records_installation_status
  on public.atlas_installation_exception_records(
    installation_id,
    exception_status,
    severity
  );

create table public.atlas_installation_acceptance_decisions (
  id uuid primary key default gen_random_uuid(),
  acceptance_package_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  authority_type text not null,
  decision text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  reason text not null,
  decision_evidence jsonb not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  package_sha256 text not null,
  acceptance_version integer not null,
  request_id uuid not null,
  created_at timestamptz not null default now(),

  constraint atlas_acceptance_decisions_request_key
    unique (acceptance_package_id, request_id),
  constraint atlas_acceptance_decisions_authority_key
    unique (acceptance_package_id, acceptance_version, authority_type),
  constraint atlas_acceptance_decisions_package_fkey
    foreign key (
      acceptance_package_id, installation_id, empresa_id
    )
    references public.atlas_installation_acceptance_packages(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_acceptance_decisions_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_acceptance_decisions_authority_check
    check (authority_type in ('PLATFORM', 'CLIENT')),
  constraint atlas_acceptance_decisions_decision_check
    check (
      decision in ('ACCEPTED', 'REJECTED', 'CHANGES_REQUIRED')
    ),
  constraint atlas_acceptance_decisions_actor_role_check
    check (
      actor_role_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(actor_role_code) between 3 and 100
    ),
  constraint atlas_acceptance_decisions_reason_check
    check (length(btrim(reason)) between 5 and 2000),
  constraint atlas_acceptance_decisions_evidence_check
    check (
      jsonb_typeof(decision_evidence) = 'object'
      and decision_evidence <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        decision_evidence
      )
      and public.atlas_acceptance_evidence_reference_is_safe(
        evidence_reference
      )
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
      and package_sha256 ~ '^[0-9a-f]{64}$'
      and acceptance_version >= 1
    )
);

create index idx_atlas_acceptance_decisions_timeline
  on public.atlas_installation_acceptance_decisions(
    installation_id,
    created_at desc,
    authority_type
  );

create table public.atlas_installation_acceptance_events (
  id uuid primary key default gen_random_uuid(),
  acceptance_package_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  entity_type text not null,
  entity_id uuid not null,
  event_code text not null,
  from_status text,
  to_status text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  executor_code text not null,
  reason_code text not null,
  request_id uuid not null,
  acceptance_version integer not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  event_payload jsonb not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_acceptance_events_request_key
    unique (acceptance_package_id, request_id),
  constraint atlas_acceptance_events_package_fkey
    foreign key (
      acceptance_package_id, installation_id, empresa_id
    )
    references public.atlas_installation_acceptance_packages(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_acceptance_events_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_acceptance_events_entity_check
    check (
      entity_type in (
        'PACKAGE', 'REQUIREMENT', 'TRAINING',
        'EXCEPTION', 'DECISION'
      )
    ),
  constraint atlas_acceptance_events_codes_check
    check (
      event_code ~ '^[A-Z][A-Z0-9_]*$'
      and actor_role_code ~ '^[A-Z][A-Z0-9_]*$'
      and executor_code ~ '^[A-Z][A-Z0-9_]*$'
      and reason_code ~ '^[A-Z][A-Z0-9_]*$'
      and acceptance_version >= 1
    ),
  constraint atlas_acceptance_events_evidence_check
    check (
      public.atlas_acceptance_evidence_reference_is_safe(
        evidence_reference
      )
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
      and jsonb_typeof(event_payload) = 'object'
      and event_payload <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        event_payload
      )
    ),
  constraint atlas_acceptance_events_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_acceptance_events_timeline
  on public.atlas_installation_acceptance_events(
    installation_id,
    created_at desc,
    id desc
  );

create or replace function
public.atlas_block_acceptance_append_only_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ACCEPTANCE_APPEND_ONLY_RECORD_IMMUTABLE';
end;
$$;

revoke all on function
public.atlas_block_acceptance_append_only_mutation()
from public, anon, authenticated;
grant execute on function
public.atlas_block_acceptance_append_only_mutation()
to service_role;

create trigger trg_atlas_acceptance_decisions_append_only
before update or delete
on public.atlas_installation_acceptance_decisions
for each row execute function
public.atlas_block_acceptance_append_only_mutation();

create trigger trg_atlas_acceptance_events_append_only
before update or delete
on public.atlas_installation_acceptance_events
for each row execute function
public.atlas_block_acceptance_append_only_mutation();

create trigger trg_atlas_acceptance_definitions_updated_at
before update
on public.atlas_installation_acceptance_requirement_definitions
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_acceptance_packages_updated_at
before update
on public.atlas_installation_acceptance_packages
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_acceptance_requirements_updated_at
before update
on public.atlas_installation_acceptance_requirements
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_training_records_updated_at
before update
on public.atlas_installation_training_records
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_exception_records_updated_at
before update
on public.atlas_installation_exception_records
for each row execute function public.atlas_set_updated_at();

alter table
  public.atlas_installation_acceptance_requirement_definitions
  enable row level security;
alter table public.atlas_installation_acceptance_packages
  enable row level security;
alter table public.atlas_installation_acceptance_requirements
  enable row level security;
alter table public.atlas_installation_training_records
  enable row level security;
alter table public.atlas_installation_exception_records
  enable row level security;
alter table public.atlas_installation_acceptance_decisions
  enable row level security;
alter table public.atlas_installation_acceptance_events
  enable row level security;

create policy atlas_acceptance_definitions_platform_read
on public.atlas_installation_acceptance_requirement_definitions
for select to authenticated
using (
  active
  and public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_READ'
  )
);

create policy atlas_acceptance_packages_platform_read
on public.atlas_installation_acceptance_packages
for select to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_READ'
  )
);

create policy atlas_acceptance_requirements_platform_read
on public.atlas_installation_acceptance_requirements
for select to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_READ'
  )
);

create policy atlas_training_records_platform_read
on public.atlas_installation_training_records
for select to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_READ'
  )
);

create policy atlas_exception_records_platform_read
on public.atlas_installation_exception_records
for select to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_READ'
  )
);

create policy atlas_acceptance_decisions_platform_read
on public.atlas_installation_acceptance_decisions
for select to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_READ'
  )
);

create policy atlas_acceptance_events_platform_read
on public.atlas_installation_acceptance_events
for select to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_ACCEPTANCE_READ'
  )
);

revoke all on table
  public.atlas_installation_acceptance_requirement_definitions,
  public.atlas_installation_acceptance_packages,
  public.atlas_installation_acceptance_requirements,
  public.atlas_installation_training_records,
  public.atlas_installation_exception_records,
  public.atlas_installation_acceptance_decisions,
  public.atlas_installation_acceptance_events
from public, anon, authenticated;

grant select on table
  public.atlas_installation_acceptance_requirement_definitions,
  public.atlas_installation_acceptance_packages,
  public.atlas_installation_acceptance_requirements,
  public.atlas_installation_training_records,
  public.atlas_installation_exception_records,
  public.atlas_installation_acceptance_decisions,
  public.atlas_installation_acceptance_events
to authenticated;

grant all on table
  public.atlas_installation_acceptance_requirement_definitions,
  public.atlas_installation_acceptance_packages,
  public.atlas_installation_acceptance_requirements,
  public.atlas_installation_training_records,
  public.atlas_installation_exception_records,
  public.atlas_installation_acceptance_decisions,
  public.atlas_installation_acceptance_events
to service_role;

comment on table
public.atlas_installation_acceptance_requirement_definitions is
  'B2: catalogo canonico de los ocho requisitos G04 y su bloque responsable.';
comment on table
public.atlas_installation_acceptance_packages is
  'B2: paquetes versionados de entrega y aceptacion ligados a manifest, pruebas y G03.';
comment on table
public.atlas_installation_acceptance_requirements is
  'B2: estado verificable por requisito G04 dentro de cada paquete de aceptacion.';
comment on table
public.atlas_installation_training_records is
  'B2: capacitaciones versionadas con alcance, participantes y evidencia segura.';
comment on table
public.atlas_installation_exception_records is
  'B2: defectos o excepciones versionados; un riesgo critico nunca puede aceptarse.';
comment on table
public.atlas_installation_acceptance_decisions is
  'B2: decisiones append-only y separadas de Atlas y del cliente.';
comment on table
public.atlas_installation_acceptance_events is
  'B2: timeline append-only de entrega, capacitacion, excepciones y aceptacion.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2J1_FINAL_APPROVAL_ACCEPTANCE_CORE_INSTALLED',
  'next_block',
    'B2.2J.2_ACCEPTANCE_PACKAGE_TRAINING_EXCEPTION_RPCS',
  'acceptance_tables', 7,
  'g04_requirement_definitions', (
    select count(*)
    from public.atlas_installation_acceptance_requirement_definitions
    where active
  ),
  'j_scope_requirements', (
    select count(*)
    from public.atlas_installation_acceptance_requirement_definitions
    where active
      and implementation_block = 'B2.2J'
  ),
  'downstream_certificate_activation_requirements', (
    select count(*)
    from public.atlas_installation_acceptance_requirement_definitions
    where active
      and implementation_block in ('B2.2K', 'B2.2L')
  ),
  'acceptance_package_records', (
    select count(*)
    from public.atlas_installation_acceptance_packages
  ),
  'training_records', (
    select count(*)
    from public.atlas_installation_training_records
  ),
  'exception_records', (
    select count(*)
    from public.atlas_installation_exception_records
  ),
  'acceptance_decision_records', (
    select count(*)
    from public.atlas_installation_acceptance_decisions
  ),
  'acceptance_event_records', (
    select count(*)
    from public.atlas_installation_acceptance_events
  ),
  'acceptance_write_rpcs', 0,
  'g04_decision_enabled', false,
  'certificate_issuance_enabled', false,
  'active_auto_transition_enabled', false,
  'critical_risk_acceptance_enabled', false,
  'dual_authority_model_enabled', true,
  'source_hash_lineage_required', true,
  'credential_values_stored', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version,
  'direct_authenticated_write', false
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
