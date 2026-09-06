-- ATLAS B2.2I.1
-- Nucleo de planes, casos, ejecuciones y resultados de prueba.
-- Corte: 2026-09-02
--
-- Alcance deliberado:
-- - cataloga las 18 pruebas minimas de B2 V1;
-- - vincula cada prueba con criterios objetivos de G03;
-- - instala ledgers de planes, casos, runs, resultados y eventos;
-- - preserva intentos, dependencias, evidencia y errores redactados;
-- - no genera planes, no ejecuta pruebas, no decide G03 y no mueve FingerFood.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_get_installation_integration_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_integration_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null
     or to_regprocedure('public.atlas_set_updated_at()') is null
     or to_regclass(
       'public.atlas_installation_gate_definitions'
     ) is null then
    raise exception
      'B2.2I.1 requiere B2.2H.4 instalado y certificado';
  end if;

  if not exists (
    select 1
    from public.atlas_installation_gate_definitions as definition
    where definition.gate_code = 'G03'
      and definition.review_state_code = 'TESTING'
      and definition.approved_target_state_code = 'FINAL_APPROVAL'
      and definition.active
  ) then
    raise exception 'B2.2I.1 requiere contrato G03 activo';
  end if;

  if to_regclass('public.atlas_installation_test_definitions')
       is not null
     or to_regclass('public.atlas_installation_test_plans')
       is not null
     or to_regclass('public.atlas_installation_test_plan_cases')
       is not null
     or to_regclass('public.atlas_installation_test_runs')
       is not null
     or to_regclass('public.atlas_installation_test_results')
       is not null
     or to_regclass('public.atlas_installation_test_events')
       is not null then
    raise exception
      'B2.2I.1 detecto estructuras de pruebas previas; reconciliar antes de instalar';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_TEST_READ',
    'Consultar planes, ejecuciones, resultados y evidencia de pruebas.'
  ),
  (
    'INSTALLATION_TEST_PLAN',
    'Generar y materializar planes de prueba gobernados.'
  ),
  (
    'INSTALLATION_TEST_EXECUTE',
    'Iniciar runs y registrar resultados verificables de pruebas.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_TEST_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_TEST_PLAN'),
  ('ATLAS_OWNER', 'INSTALLATION_TEST_EXECUTE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_TEST_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_TEST_PLAN'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_TEST_EXECUTE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_TEST_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_TEST_EXECUTE')
on conflict (role_code, permission_code) do nothing;

create or replace function
public.atlas_test_evidence_reference_is_safe(
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
      '^(audit|storage|receipt|integration-test|test-evidence)://[A-Za-z0-9][A-Za-z0-9._:/-]+$'
$$;

revoke all on function
public.atlas_test_evidence_reference_is_safe(text)
from public, anon, authenticated;
grant execute on function
public.atlas_test_evidence_reference_is_safe(text)
to service_role;

create or replace function
public.atlas_text_array_has_unique_values(
  p_values text[]
)
returns boolean
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select cardinality(p_values) = (
    select count(distinct value)
    from unnest(p_values) as item(value)
  )
$$;

revoke all on function
public.atlas_text_array_has_unique_values(text[])
from public, anon, authenticated;
grant execute on function
public.atlas_text_array_has_unique_values(text[])
to service_role;

create table public.atlas_installation_test_definitions (
  test_code text primary key,
  display_name text not null,
  description text not null,
  test_group text not null,
  execution_type text not null,
  test_contract_version text not null,
  requirement_mode text not null,
  applicability_rule jsonb not null,
  blocking_by_default boolean not null default true,
  max_attempts integer not null default 3,
  timeout_seconds integer not null default 300,
  required_evidence_kinds text[] not null,
  g03_criterion_codes text[] not null,
  sort_order integer not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_test_definitions_code_check
    check (
      test_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(test_code) between 5 and 100
    ),
  constraint atlas_test_definitions_text_check
    check (
      length(btrim(display_name)) between 5 and 160
      and length(btrim(description)) between 20 and 1000
    ),
  constraint atlas_test_definitions_group_check
    check (
      test_group in (
        'IDENTITY', 'SECURITY', 'STORAGE', 'DATA', 'FUNCTIONAL',
        'CHANNEL', 'INTEGRATION', 'GOVERNANCE', 'RELIABILITY',
        'DOCUMENT', 'VOICE', 'PERFORMANCE'
      )
    ),
  constraint atlas_test_definitions_execution_check
    check (execution_type in ('AUTOMATED', 'HYBRID', 'MANUAL')),
  constraint atlas_test_definitions_version_check
    check (test_contract_version ~ '^B2_TEST_[A-Z0-9_]+_V[0-9]+$'),
  constraint atlas_test_definitions_requirement_check
    check (requirement_mode in ('REQUIRED', 'CONDITIONAL')),
  constraint atlas_test_definitions_applicability_check
    check (
      jsonb_typeof(applicability_rule) = 'object'
      and applicability_rule <> '{}'::jsonb
      and nullif(btrim(applicability_rule->>'reason'), '') is not null
      and not public.atlas_jsonb_has_forbidden_secret_key(
        applicability_rule
      )
    ),
  constraint atlas_test_definitions_attempts_timeout_check
    check (
      max_attempts between 1 and 10
      and timeout_seconds between 5 and 86400
    ),
  constraint atlas_test_definitions_evidence_check
    check (
      cardinality(required_evidence_kinds) >= 1
      and required_evidence_kinds <@ array[
        'TECHNICAL_ASSERTION', 'HUMAN_APPROVAL',
        'CHANNEL_RECEIPT', 'AUDIT_REFERENCE',
        'STORAGE_REFERENCE', 'METRIC'
      ]::text[]
      and public.atlas_text_array_has_unique_values(
        required_evidence_kinds
      )
    ),
  constraint atlas_test_definitions_g03_check
    check (
      cardinality(g03_criterion_codes) >= 1
      and g03_criterion_codes <@ array[
        'TENANT_PROVISIONED',
        'RLS_AND_ISOLATION_VALIDATED',
        'OWNER_ROLES_PERMISSIONS_TESTED',
        'STORAGE_CLASSIFICATION_VALIDATED',
        'INTEGRATIONS_SECURELY_CONNECTED',
        'CERTIFIED_FLOWS_INSTALLED',
        'CHANNELS_TESTED',
        'AUDIT_AND_IDEMPOTENCY_OPERATIONAL',
        'ERROR_AND_RECOVERY_TESTS_APPROVED'
      ]::text[]
      and public.atlas_text_array_has_unique_values(
        g03_criterion_codes
      )
    ),
  constraint atlas_test_definitions_order_check
    check (sort_order between 1 and 1000),
  constraint atlas_test_definitions_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_installation_test_definitions (
  test_code,
  display_name,
  description,
  test_group,
  execution_type,
  test_contract_version,
  requirement_mode,
  applicability_rule,
  blocking_by_default,
  max_attempts,
  timeout_seconds,
  required_evidence_kinds,
  g03_criterion_codes,
  sort_order,
  active
)
values
  (
    'TENANT_IDENTITY_MEMBERSHIP',
    'Identidad y pertenencia al tenant',
    'Verifica identidad del tenant, empresa asociada y membresias autorizadas.',
    'IDENTITY', 'AUTOMATED', 'B2_TEST_TENANT_IDENTITY_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Toda instalacion requiere identidad y pertenencia valida.'
    ),
    true, 3, 120,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['TENANT_PROVISIONED']::text[], 10, true
  ),
  (
    'RLS_CROSS_TENANT_ISOLATION',
    'Aislamiento RLS multiempresa',
    'Prueba acceso autorizado y denegacion cruzada entre empresas distintas.',
    'SECURITY', 'AUTOMATED', 'B2_TEST_RLS_ISOLATION_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'El aislamiento multiempresa es una defensa obligatoria.'
    ),
    true, 3, 300,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['RLS_AND_ISOLATION_VALIDATED']::text[], 20, true
  ),
  (
    'OWNER_ROLES_PERMISSIONS',
    'OWNER, roles y permisos',
    'Verifica el OWNER, los roles instalados y sus permisos efectivos.',
    'SECURITY', 'HYBRID', 'B2_TEST_OWNER_PERMISSIONS_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'La autoridad efectiva debe coincidir con el contrato.'
    ),
    true, 3, 300,
    array['TECHNICAL_ASSERTION', 'HUMAN_APPROVAL']::text[],
    array['OWNER_ROLES_PERMISSIONS_TESTED']::text[], 30, true
  ),
  (
    'SECURE_FILE_ACCESS',
    'Carga y acceso seguro a archivos',
    'Valida Storage privado, rutas por empresa y clasificacion de archivos.',
    'STORAGE', 'AUTOMATED', 'B2_TEST_SECURE_FILE_ACCESS_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Los archivos deben respetar clasificacion y aislamiento.'
    ),
    true, 3, 300,
    array['TECHNICAL_ASSERTION', 'STORAGE_REFERENCE']::text[],
    array['STORAGE_CLASSIFICATION_VALIDATED']::text[], 40, true
  ),
  (
    'KNOWLEDGE_SEARCH_ACCURACY',
    'Busqueda y conocimiento',
    'Comprueba recuperacion de conocimiento autorizado y precision minima.',
    'DATA', 'HYBRID', 'B2_TEST_KNOWLEDGE_SEARCH_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'El agente debe consultar conocimiento canónico y vigente.'
    ),
    true, 3, 600,
    array['TECHNICAL_ASSERTION', 'METRIC']::text[],
    array['CERTIFIED_FLOWS_INSTALLED']::text[], 50, true
  ),
  (
    'COMMERCIAL_RULES_ENFORCEMENT',
    'Reglas comerciales',
    'Valida precios, descuentos, anticipos, restricciones y prohibiciones.',
    'FUNCTIONAL', 'HYBRID', 'B2_TEST_COMMERCIAL_RULES_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Las acciones comerciales deben respetar reglas aprobadas.'
    ),
    true, 3, 600,
    array['TECHNICAL_ASSERTION', 'HUMAN_APPROVAL']::text[],
    array['CERTIFIED_FLOWS_INSTALLED']::text[], 60, true
  ),
  (
    'EXTERNAL_CONVERSATION_E2E',
    'Conversacion externa de extremo a extremo',
    'Prueba recepcion, decision, registro y respuesta por canal contratado.',
    'CHANNEL', 'HYBRID', 'B2_TEST_EXTERNAL_CONVERSATION_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Todo canal contratado requiere prueba entrante y saliente.'
    ),
    true, 3, 900,
    array['TECHNICAL_ASSERTION', 'CHANNEL_RECEIPT']::text[],
    array['CERTIFIED_FLOWS_INSTALLED', 'CHANNELS_TESTED']::text[],
    70, true
  ),
  (
    'INTERNAL_CHAT_AUTHORIZATION',
    'Chat interno autorizado',
    'Verifica autenticacion, pertenencia y autorizacion del chat interno.',
    'SECURITY', 'AUTOMATED', 'B2_TEST_INTERNAL_CHAT_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'El chat interno no debe aceptar identidades no autorizadas.'
    ),
    true, 3, 300,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['CERTIFIED_FLOWS_INSTALLED']::text[], 80, true
  ),
  (
    'HUMAN_CONTROL_HANDOFF',
    'Entrega y devolución del control humano',
    'Prueba toma de control, silencio del agente y devolucion autorizada.',
    'FUNCTIONAL', 'HYBRID', 'B2_TEST_HUMAN_CONTROL_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'El control humano gobernado es una defensa operativa.'
    ),
    true, 3, 600,
    array['TECHNICAL_ASSERTION', 'HUMAN_APPROVAL']::text[],
    array['CERTIFIED_FLOWS_INSTALLED', 'CHANNELS_TESTED']::text[],
    90, true
  ),
  (
    'TOOL_ACTION_EXECUTION',
    'Herramientas y acciones',
    'Valida herramientas autorizadas, efectos esperados y auditoria asociada.',
    'FUNCTIONAL', 'HYBRID', 'B2_TEST_TOOL_ACTIONS_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Las capacidades de escritura requieren prueba verificable.'
    ),
    true, 3, 900,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['CERTIFIED_FLOWS_INSTALLED']::text[], 100, true
  ),
  (
    'AUDIT_TRACEABILITY',
    'Auditoria y trazabilidad',
    'Comprueba que decisiones y operaciones produzcan auditoria correlacionada.',
    'GOVERNANCE', 'AUTOMATED', 'B2_TEST_AUDIT_TRACEABILITY_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Toda operacion material debe conservar trazabilidad.'
    ),
    true, 3, 300,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['AUDIT_AND_IDEMPOTENCY_OPERATIONAL']::text[], 110, true
  ),
  (
    'IDEMPOTENCY_REPLAY',
    'Idempotencia y replay',
    'Verifica repeticion segura y rechazo de colisiones de solicitudes.',
    'RELIABILITY', 'AUTOMATED', 'B2_TEST_IDEMPOTENCY_REPLAY_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Los reintentos no deben duplicar efectos materiales.'
    ),
    true, 3, 300,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['AUDIT_AND_IDEMPOTENCY_OPERATIONAL']::text[], 120, true
  ),
  (
    'ERROR_HANDLING',
    'Manejo seguro de errores',
    'Prueba fallos controlados, mensajes redactados y ausencia de secretos.',
    'RELIABILITY', 'AUTOMATED', 'B2_TEST_ERROR_HANDLING_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Los errores deben fallar de forma segura y auditable.'
    ),
    true, 3, 300,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['ERROR_AND_RECOVERY_TESTS_APPROVED']::text[], 130, true
  ),
  (
    'RETRY_RECOVERY',
    'Reintentos y recuperación',
    'Valida limites de reintento, recuperacion y rutas de compensacion.',
    'RELIABILITY', 'AUTOMATED', 'B2_TEST_RETRY_RECOVERY_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'La recuperacion debe ser acotada, verificable y trazable.'
    ),
    true, 3, 900,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['ERROR_AND_RECOVERY_TESTS_APPROVED']::text[], 140, true
  ),
  (
    'INTEGRATION_HEALTH',
    'Integraciones y salud',
    'Revalida integraciones contratadas, configuracion y evidencia vigente.',
    'INTEGRATION', 'AUTOMATED', 'B2_TEST_INTEGRATION_HEALTH_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Las integraciones deben permanecer verificadas y saludables.'
    ),
    true, 3, 600,
    array['TECHNICAL_ASSERTION', 'AUDIT_REFERENCE']::text[],
    array['INTEGRATIONS_SECURELY_CONNECTED']::text[], 150, true
  ),
  (
    'DOCUMENT_TEMPLATE_OUTPUT',
    'Plantillas y documentos',
    'Comprueba generacion autorizada, contenido esperado e integridad documental.',
    'DOCUMENT', 'HYBRID', 'B2_TEST_DOCUMENT_OUTPUT_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Los documentos contratados requieren validacion funcional.'
    ),
    true, 3, 900,
    array['TECHNICAL_ASSERTION', 'HUMAN_APPROVAL']::text[],
    array['CERTIFIED_FLOWS_INSTALLED']::text[], 160, true
  ),
  (
    'VOICE_AUDIO_CALLS',
    'Voz, audio y llamadas',
    'Prueba capacidades de voz, audio o llamadas cuando fueron contratadas.',
    'VOICE', 'HYBRID', 'B2_TEST_VOICE_AUDIO_CALLS_V1',
    'CONDITIONAL',
    jsonb_build_object(
      'mode', 'CONDITIONAL',
      'condition', 'VOICE_OR_CALLS_ENABLED',
      'reason', 'Solo aplica si el alcance incluye voz, audio o llamadas.'
    ),
    true, 3, 1200,
    array['TECHNICAL_ASSERTION', 'CHANNEL_RECEIPT']::text[],
    array['CERTIFIED_FLOWS_INSTALLED', 'CHANNELS_TESTED']::text[],
    170, true
  ),
  (
    'PERFORMANCE_LIMITS',
    'Rendimiento y límites acordados',
    'Valida latencia, concurrencia y limites definidos para el servicio.',
    'PERFORMANCE', 'AUTOMATED', 'B2_TEST_PERFORMANCE_LIMITS_V1',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'La instalacion debe cumplir los limites operativos acordados.'
    ),
    true, 3, 1800,
    array['TECHNICAL_ASSERTION', 'METRIC']::text[],
    array['ERROR_AND_RECOVERY_TESTS_APPROVED']::text[], 180, true
  )
on conflict (test_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  test_group = excluded.test_group,
  execution_type = excluded.execution_type,
  test_contract_version = excluded.test_contract_version,
  requirement_mode = excluded.requirement_mode,
  applicability_rule = excluded.applicability_rule,
  blocking_by_default = excluded.blocking_by_default,
  max_attempts = excluded.max_attempts,
  timeout_seconds = excluded.timeout_seconds,
  required_evidence_kinds = excluded.required_evidence_kinds,
  g03_criterion_codes = excluded.g03_criterion_codes,
  sort_order = excluded.sort_order,
  active = excluded.active,
  updated_at = now();

do $$
begin
  if (
    select count(*)
    from public.atlas_installation_test_definitions
    where active
  ) <> 18 then
    raise exception 'B2.2I.1 requiere 18 pruebas canonicas activas';
  end if;

  if exists (
    select criterion.value->>'code'
    from public.atlas_installation_gate_definitions as gate_definition
    cross join lateral jsonb_array_elements(
      gate_definition.criteria
    ) as criterion(value)
    where gate_definition.gate_code = 'G03'
      and (criterion.value->>'required')::boolean
    except
    select unnest(definition.g03_criterion_codes)
    from public.atlas_installation_test_definitions as definition
    where definition.active
      and definition.blocking_by_default
  ) then
    raise exception 'B2.2I.1 cobertura G03 incompleta';
  end if;
end;
$$;

create table public.atlas_installation_test_plans (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  source_manifest_id uuid not null,
  plan_code text not null,
  plan_version integer not null,
  test_contract_version text not null,
  plan_status text not null default 'DRAFT',
  expected_installation_version bigint not null,
  required_case_count integer not null,
  conditional_case_count integer not null,
  plan_payload jsonb not null,
  plan_sha256 text not null,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  ready_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_test_plans_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_test_plans_version_key
    unique (installation_id, plan_version),
  constraint atlas_test_plans_identity_key
    unique (id, installation_id, empresa_id),
  constraint atlas_test_plans_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_test_plans_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_test_plans_manifest_fkey
    foreign key (source_manifest_id)
    references public.atlas_installation_manifests(id)
    on delete restrict,
  constraint atlas_test_plans_actor_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_test_plans_code_check
    check (
      plan_code ~ '^[A-Z][A-Z0-9_-]*$'
      and length(plan_code) between 5 and 100
    ),
  constraint atlas_test_plans_versions_check
    check (
      plan_version >= 1
      and expected_installation_version >= 1
      and test_contract_version = 'B2_INSTALLATION_TEST_PLAN_V1'
    ),
  constraint atlas_test_plans_status_check
    check (
      plan_status in (
        'DRAFT', 'READY', 'RUNNING', 'PASSED',
        'FAILED', 'CANCELLED', 'SUPERSEDED'
      )
    ),
  constraint atlas_test_plans_counts_check
    check (
      required_case_count >= 1
      and conditional_case_count >= 0
      and required_case_count + conditional_case_count <= 1000
    ),
  constraint atlas_test_plans_payload_check
    check (
      jsonb_typeof(plan_payload) = 'object'
      and plan_payload->>'contract_version' = test_contract_version
      and plan_payload->>'installation_id' = installation_id::text
      and plan_payload->>'empresa_id' = empresa_id::text
      and plan_payload->>'source_manifest_id' = source_manifest_id::text
      and plan_payload->>'plan_version' = plan_version::text
      and not public.atlas_jsonb_has_forbidden_secret_key(plan_payload)
      and plan_sha256 = public.atlas_normalization_sha256(
        plan_payload::text
      )
    ),
  constraint atlas_test_plans_hash_check
    check (plan_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_test_plans_timeline_check
    check (
      (ready_at is null or ready_at >= created_at)
      and (started_at is null or started_at >= created_at)
      and (
        completed_at is null
        or (
          started_at is not null
          and completed_at >= started_at
        )
      )
      and (plan_status <> 'READY' or ready_at is not null)
      and (plan_status <> 'RUNNING' or started_at is not null)
      and (
        plan_status not in ('PASSED', 'FAILED', 'CANCELLED')
        or completed_at is not null
      )
    ),
  constraint atlas_test_plans_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create unique index uq_atlas_test_plans_one_active
  on public.atlas_installation_test_plans(installation_id)
  where plan_status in ('DRAFT', 'READY', 'RUNNING');

create index idx_atlas_test_plans_installation_status
  on public.atlas_installation_test_plans(
    installation_id,
    plan_status,
    plan_version desc
  );

create table public.atlas_installation_test_plan_cases (
  id uuid primary key default gen_random_uuid(),
  test_plan_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  test_code text not null,
  case_order integer not null,
  requirement_mode text not null,
  applicability_status text not null default 'PENDING',
  case_status text not null default 'PENDING',
  blocking boolean not null,
  max_attempts integer not null,
  attempt_count integer not null default 0,
  executor_type text not null,
  executor_code text,
  dependency_test_codes text[] not null default array[]::text[],
  expected_assertions jsonb not null,
  input_contract_sha256 text not null,
  started_at timestamptz,
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_test_cases_plan_code_key
    unique (test_plan_id, test_code),
  constraint atlas_test_cases_plan_order_key
    unique (test_plan_id, case_order),
  constraint atlas_test_cases_identity_key
    unique (id, test_plan_id, installation_id, empresa_id),
  constraint atlas_test_cases_plan_fkey
    foreign key (test_plan_id, installation_id, empresa_id)
    references public.atlas_installation_test_plans(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_test_cases_definition_fkey
    foreign key (test_code)
    references public.atlas_installation_test_definitions(test_code)
    on delete restrict,
  constraint atlas_test_cases_requirement_check
    check (requirement_mode in ('REQUIRED', 'CONDITIONAL')),
  constraint atlas_test_cases_applicability_check
    check (
      applicability_status in (
        'PENDING', 'APPLICABLE', 'NOT_APPLICABLE'
      )
    ),
  constraint atlas_test_cases_status_check
    check (
      case_status in (
        'PENDING', 'RUNNING', 'PASSED', 'FAILED',
        'RETRYING', 'BLOCKED', 'SKIPPED'
      )
    ),
  constraint atlas_test_cases_attempt_check
    check (
      max_attempts between 1 and 10
      and attempt_count between 0 and max_attempts
    ),
  constraint atlas_test_cases_executor_check
    check (
      executor_type in ('AUTOMATED', 'HYBRID', 'MANUAL')
      and (
        executor_code is null
        or (
          executor_code ~ '^[A-Z][A-Z0-9_]*$'
          and length(executor_code) between 3 and 100
        )
      )
    ),
  constraint atlas_test_cases_dependencies_check
    check (
      coalesce(array_to_string(dependency_test_codes, ','), '')
        ~ '^([A-Z][A-Z0-9_]*(,[A-Z][A-Z0-9_]*)*)?$'
      and public.atlas_text_array_has_unique_values(
        dependency_test_codes
      )
      and not (test_code = any(dependency_test_codes))
    ),
  constraint atlas_test_cases_assertions_check
    check (
      jsonb_typeof(expected_assertions) = 'array'
      and jsonb_array_length(expected_assertions) >= 1
      and not public.atlas_jsonb_has_forbidden_secret_key(
        expected_assertions
      )
      and input_contract_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_test_cases_order_check
    check (case_order between 1 and 1000),
  constraint atlas_test_cases_state_timeline_check
    check (
      (
        applicability_status <> 'NOT_APPLICABLE'
        or case_status = 'SKIPPED'
      )
      and (started_at is null or started_at >= created_at)
      and (
        completed_at is null
        or (
          started_at is not null
          and completed_at >= started_at
        )
      )
      and (case_status <> 'RUNNING' or started_at is not null)
      and (
        case_status not in ('PASSED', 'FAILED', 'BLOCKED', 'SKIPPED')
        or completed_at is not null
      )
    ),
  constraint atlas_test_cases_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_test_cases_plan_status
  on public.atlas_installation_test_plan_cases(
    test_plan_id,
    case_status,
    case_order
  );

create table public.atlas_installation_test_runs (
  id uuid primary key default gen_random_uuid(),
  test_plan_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  run_number integer not null,
  run_status text not null default 'CREATED',
  expected_installation_version bigint not null,
  executor_code text not null,
  initiated_by_user_id uuid not null,
  idempotency_key uuid not null,
  total_cases integer not null,
  passed_cases integer not null default 0,
  failed_cases integer not null default 0,
  blocked_cases integer not null default 0,
  skipped_cases integer not null default 0,
  evidence_root_sha256 text,
  started_at timestamptz,
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_test_runs_plan_number_key
    unique (test_plan_id, run_number),
  constraint atlas_test_runs_request_key
    unique (test_plan_id, idempotency_key),
  constraint atlas_test_runs_identity_key
    unique (id, test_plan_id, installation_id, empresa_id),
  constraint atlas_test_runs_plan_fkey
    foreign key (test_plan_id, installation_id, empresa_id)
    references public.atlas_installation_test_plans(
      id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_test_runs_actor_fkey
    foreign key (initiated_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_test_runs_number_version_check
    check (
      run_number between 1 and 100
      and expected_installation_version >= 1
    ),
  constraint atlas_test_runs_status_check
    check (
      run_status in (
        'CREATED', 'RUNNING', 'PASSED', 'FAILED', 'CANCELLED'
      )
    ),
  constraint atlas_test_runs_executor_check
    check (
      executor_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(executor_code) between 3 and 100
    ),
  constraint atlas_test_runs_counts_check
    check (
      total_cases >= 1
      and passed_cases >= 0
      and failed_cases >= 0
      and blocked_cases >= 0
      and skipped_cases >= 0
      and passed_cases + failed_cases + blocked_cases + skipped_cases
        <= total_cases
    ),
  constraint atlas_test_runs_evidence_check
    check (
      evidence_root_sha256 is null
      or evidence_root_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_test_runs_timeline_check
    check (
      (started_at is null or started_at >= created_at)
      and (
        completed_at is null
        or (
          started_at is not null
          and completed_at >= started_at
        )
      )
      and (run_status <> 'RUNNING' or started_at is not null)
      and (
        run_status not in ('PASSED', 'FAILED', 'CANCELLED')
        or (
          completed_at is not null
          and evidence_root_sha256 is not null
          and passed_cases + failed_cases + blocked_cases + skipped_cases
            = total_cases
        )
      )
    ),
  constraint atlas_test_runs_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create unique index uq_atlas_test_runs_one_running
  on public.atlas_installation_test_runs(test_plan_id)
  where run_status = 'RUNNING';

create index idx_atlas_test_runs_installation_status
  on public.atlas_installation_test_runs(
    installation_id,
    run_status,
    run_number desc
  );

create table public.atlas_installation_test_results (
  id uuid primary key default gen_random_uuid(),
  test_run_id uuid not null,
  test_case_id uuid not null,
  test_plan_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  test_code text not null,
  attempt_number integer not null,
  outcome text not null,
  executor_code text not null,
  actor_user_id uuid not null,
  request_id uuid not null,
  assertion_results jsonb not null,
  assertion_results_sha256 text not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  error_code text,
  redacted_error_summary text,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_test_results_case_attempt_key
    unique (test_case_id, attempt_number),
  constraint atlas_test_results_request_key
    unique (test_plan_id, request_id),
  constraint atlas_test_results_run_fkey
    foreign key (
      test_run_id, test_plan_id, installation_id, empresa_id
    )
    references public.atlas_installation_test_runs(
      id, test_plan_id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_test_results_case_fkey
    foreign key (
      test_case_id, test_plan_id, installation_id, empresa_id
    )
    references public.atlas_installation_test_plan_cases(
      id, test_plan_id, installation_id, empresa_id
    )
    on delete restrict,
  constraint atlas_test_results_definition_fkey
    foreign key (test_code)
    references public.atlas_installation_test_definitions(test_code)
    on delete restrict,
  constraint atlas_test_results_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_test_results_attempt_check
    check (attempt_number between 1 and 10),
  constraint atlas_test_results_outcome_check
    check (outcome in ('PASSED', 'FAILED', 'BLOCKED', 'SKIPPED')),
  constraint atlas_test_results_executor_check
    check (
      executor_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(executor_code) between 3 and 100
    ),
  constraint atlas_test_results_assertions_check
    check (
      jsonb_typeof(assertion_results) = 'array'
      and jsonb_array_length(assertion_results) >= 1
      and not public.atlas_jsonb_has_forbidden_secret_key(
        assertion_results
      )
      and assertion_results_sha256 =
        public.atlas_normalization_sha256(assertion_results::text)
    ),
  constraint atlas_test_results_evidence_check
    check (
      public.atlas_test_evidence_reference_is_safe(
        evidence_reference
      )
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_test_results_error_check
    check (
      (
        outcome = 'PASSED'
        and error_code is null
        and redacted_error_summary is null
      )
      or (
        outcome in ('FAILED', 'BLOCKED', 'SKIPPED')
        and error_code ~ '^[A-Z][A-Z0-9_]*$'
        and length(btrim(redacted_error_summary)) between 5 and 500
      )
    ),
  constraint atlas_test_results_timeline_check
    check (completed_at >= started_at),
  constraint atlas_test_results_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_test_results_run_case
  on public.atlas_installation_test_results(
    test_run_id,
    test_code,
    attempt_number desc
  );

create table public.atlas_installation_test_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  test_plan_id uuid not null,
  test_run_id uuid,
  test_case_id uuid,
  event_code text not null,
  from_status text,
  to_status text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  executor_code text,
  request_id uuid not null,
  evidence jsonb not null,
  evidence_sha256 text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_test_events_request_key
    unique (installation_id, request_id),
  constraint atlas_test_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_test_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_test_events_plan_fkey
    foreign key (test_plan_id)
    references public.atlas_installation_test_plans(id)
    on delete restrict,
  constraint atlas_test_events_run_fkey
    foreign key (test_run_id)
    references public.atlas_installation_test_runs(id)
    on delete restrict,
  constraint atlas_test_events_case_fkey
    foreign key (test_case_id)
    references public.atlas_installation_test_plan_cases(id)
    on delete restrict,
  constraint atlas_test_events_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_test_events_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_test_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_test_events_status_check
    check (
      from_status is null
      or from_status in (
        'DRAFT', 'READY', 'CREATED', 'PENDING', 'RUNNING',
        'RETRYING', 'PASSED', 'FAILED', 'BLOCKED',
        'SKIPPED', 'CANCELLED', 'SUPERSEDED'
      )
    ),
  constraint atlas_test_events_to_status_check
    check (
      to_status in (
        'DRAFT', 'READY', 'CREATED', 'PENDING', 'RUNNING',
        'RETRYING', 'PASSED', 'FAILED', 'BLOCKED',
        'SKIPPED', 'CANCELLED', 'SUPERSEDED'
      )
    ),
  constraint atlas_test_events_executor_check
    check (
      executor_code is null
      or (
        executor_code ~ '^[A-Z][A-Z0-9_]*$'
        and length(executor_code) between 3 and 100
      )
    ),
  constraint atlas_test_events_association_check
    check (test_case_id is null or test_run_id is not null),
  constraint atlas_test_events_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
      and evidence_sha256 = public.atlas_normalization_sha256(
        evidence::text
      )
    ),
  constraint atlas_test_events_hash_check
    check (evidence_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_test_events_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_test_events_timeline
  on public.atlas_installation_test_events(
    installation_id,
    created_at,
    id
  );

create or replace function public.atlas_block_test_append_only_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'INSTALLATION_TEST_LEDGER_IS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_test_append_only_mutation()
from public, anon, authenticated;
grant execute on function public.atlas_block_test_append_only_mutation()
to service_role;

create trigger trg_atlas_test_results_append_only
before update or delete
on public.atlas_installation_test_results
for each row execute function
public.atlas_block_test_append_only_mutation();

create trigger trg_atlas_test_events_append_only
before update or delete
on public.atlas_installation_test_events
for each row execute function
public.atlas_block_test_append_only_mutation();

create trigger trg_atlas_test_definitions_updated_at
before update on public.atlas_installation_test_definitions
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_test_plans_updated_at
before update on public.atlas_installation_test_plans
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_test_cases_updated_at
before update on public.atlas_installation_test_plan_cases
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_test_runs_updated_at
before update on public.atlas_installation_test_runs
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_installation_test_definitions enable row level security;
alter table public.atlas_installation_test_plans enable row level security;
alter table public.atlas_installation_test_plan_cases enable row level security;
alter table public.atlas_installation_test_runs enable row level security;
alter table public.atlas_installation_test_results enable row level security;
alter table public.atlas_installation_test_events enable row level security;

drop policy if exists atlas_test_definitions_internal_read
on public.atlas_installation_test_definitions;
create policy atlas_test_definitions_internal_read
on public.atlas_installation_test_definitions
for select to authenticated
using (
  active
  and public.atlas_platform_has_permission('INSTALLATION_TEST_READ')
);

drop policy if exists atlas_test_plans_internal_read
on public.atlas_installation_test_plans;
create policy atlas_test_plans_internal_read
on public.atlas_installation_test_plans
for select to authenticated
using (public.atlas_platform_has_permission('INSTALLATION_TEST_READ'));

drop policy if exists atlas_test_cases_internal_read
on public.atlas_installation_test_plan_cases;
create policy atlas_test_cases_internal_read
on public.atlas_installation_test_plan_cases
for select to authenticated
using (public.atlas_platform_has_permission('INSTALLATION_TEST_READ'));

drop policy if exists atlas_test_runs_internal_read
on public.atlas_installation_test_runs;
create policy atlas_test_runs_internal_read
on public.atlas_installation_test_runs
for select to authenticated
using (public.atlas_platform_has_permission('INSTALLATION_TEST_READ'));

drop policy if exists atlas_test_results_internal_read
on public.atlas_installation_test_results;
create policy atlas_test_results_internal_read
on public.atlas_installation_test_results
for select to authenticated
using (public.atlas_platform_has_permission('INSTALLATION_TEST_READ'));

drop policy if exists atlas_test_events_internal_read
on public.atlas_installation_test_events;
create policy atlas_test_events_internal_read
on public.atlas_installation_test_events
for select to authenticated
using (public.atlas_platform_has_permission('INSTALLATION_TEST_READ'));

revoke all on table
  public.atlas_installation_test_definitions,
  public.atlas_installation_test_plans,
  public.atlas_installation_test_plan_cases,
  public.atlas_installation_test_runs,
  public.atlas_installation_test_results,
  public.atlas_installation_test_events
from public, anon, authenticated;

grant select on table
  public.atlas_installation_test_definitions,
  public.atlas_installation_test_plans,
  public.atlas_installation_test_plan_cases,
  public.atlas_installation_test_runs,
  public.atlas_installation_test_results,
  public.atlas_installation_test_events
to authenticated;

grant all on table
  public.atlas_installation_test_definitions,
  public.atlas_installation_test_plans,
  public.atlas_installation_test_plan_cases,
  public.atlas_installation_test_runs,
  public.atlas_installation_test_results,
  public.atlas_installation_test_events
to service_role;

comment on table public.atlas_installation_test_definitions is
  'B2: catalogo versionado de pruebas minimas y cobertura G03.';
comment on table public.atlas_installation_test_plans is
  'B2: planes de prueba ligados a instalacion y manifest vigente.';
comment on table public.atlas_installation_test_plan_cases is
  'B2: casos materializados con dependencias, intentos y estado visible.';
comment on table public.atlas_installation_test_runs is
  'B2: ejecuciones gobernadas de un plan de pruebas.';
comment on table public.atlas_installation_test_results is
  'B2: resultados append-only por caso e intento con evidencia.';
comment on table public.atlas_installation_test_events is
  'B2: timeline append-only de planes, runs y casos de prueba.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2I1_TEST_PLAN_TEST_RUN_CORE_INSTALLED',
  'next_block', 'B2.2I.2_TEST_PLAN_MATERIALIZATION_AND_RUN_RPCS',
  'test_definitions', (
    select count(*)
    from public.atlas_installation_test_definitions
    where active
  ),
  'g03_criteria_covered', (
    select count(distinct criterion_code)
    from public.atlas_installation_test_definitions as definition
    cross join lateral unnest(
      definition.g03_criterion_codes
    ) as criterion(criterion_code)
    where definition.active
  ),
  'test_ledger_tables', 5,
  'test_tables_with_rls', 6,
  'append_only_event_tables', 2,
  'test_write_rpcs', 0,
  'test_execution_enabled', false,
  'required_test_definitions', (
    select count(*)
    from public.atlas_installation_test_definitions
    where active and requirement_mode = 'REQUIRED'
  ),
  'conditional_test_definitions', (
    select count(*)
    from public.atlas_installation_test_definitions
    where active and requirement_mode = 'CONDITIONAL'
  ),
  'test_plan_records', (
    select count(*) from public.atlas_installation_test_plans
  ),
  'test_run_records', (
    select count(*) from public.atlas_installation_test_runs
  ),
  'test_result_records', (
    select count(*) from public.atlas_installation_test_results
  ),
  'attempt_tracking_enabled', true,
  'dependency_tracking_enabled', true,
  'redacted_error_contract_enabled', true,
  'evidence_hash_lineage_enabled', true,
  'raw_test_payloads_stored', false,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id =
      'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id =
      'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'direct_authenticated_write', false
) as result;
