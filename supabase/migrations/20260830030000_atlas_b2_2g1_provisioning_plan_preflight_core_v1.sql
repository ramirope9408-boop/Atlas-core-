-- ATLAS B2.2G.1
-- Nucleo de planes de aprovisionamiento y preflight gobernado.
-- Corte: 2026-08-30
--
-- Principios:
-- - el plan nace de manifest + version canonica aprobada;
-- - preflight valida antes de crear o modificar recursos del tenant;
-- - la logica interna solo es visible para personal Atlas autorizado;
-- - pasos, intentos, evidencias y compensaciones son trazables;
-- - DATA_APPROVED no entra a PROVISIONING sin preflight vigente;
-- - esta migracion no crea planes ni aprovisiona FingerFood.

begin;

do $$
begin
  if to_regclass('public.atlas_installations') is null
     or to_regclass('public.atlas_installation_manifests') is null
     or to_regclass('public.atlas_canonical_data_versions') is null
     or to_regclass('public.atlas_agent_packages') is null
     or to_regclass('public.atlas_agent_package_components') is null
     or to_regclass('public.atlas_internal_roles') is null
     or to_regclass('public.atlas_internal_permissions') is null
     or to_regclass('public.atlas_internal_role_permissions') is null
     or to_regprocedure(
       'public.atlas_platform_has_permission(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_set_updated_at()'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_g02_readiness(uuid)'
     ) is null then
    raise exception 'B2.2G.1 requiere B2.2A-F.3 instalado y certificado';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_PROVISIONING_READ',
    'Consultar planes, pasos, preflight y eventos internos de aprovisionamiento.'
  ),
  (
    'INSTALLATION_PROVISIONING_MANAGE',
    'Crear y ejecutar planes gobernados de aprovisionamiento.'
  ),
  (
    'INSTALLATION_PREFLIGHT_EXECUTE',
    'Ejecutar verificaciones preflight y registrar sus resultados.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_PROVISIONING_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_PROVISIONING_MANAGE'),
  ('ATLAS_OWNER', 'INSTALLATION_PREFLIGHT_EXECUTE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_PROVISIONING_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_PROVISIONING_MANAGE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_PREFLIGHT_EXECUTE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_PROVISIONING_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_PREFLIGHT_EXECUTE')
on conflict (role_code, permission_code) do nothing;

create table if not exists
public.atlas_provisioning_resource_definitions (
  resource_code text primary key,
  display_name text not null,
  description text not null,
  resource_group text not null,
  operation_type text not null,
  target_kind text not null,
  execution_order integer not null,
  required_by_default boolean not null default true,
  dependency_codes text[] not null default array[]::text[],
  compensation_strategy text not null,
  input_contract jsonb not null,
  verification_contract jsonb not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_provisioning_resources_code_check
    check (resource_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_provisioning_resources_order_key
    unique (execution_order),
  constraint atlas_provisioning_resources_name_check
    check (length(btrim(display_name)) >= 3),
  constraint atlas_provisioning_resources_description_check
    check (length(btrim(description)) >= 10),
  constraint atlas_provisioning_resources_group_check
    check (
      resource_group in (
        'TENANT',
        'ACCESS',
        'STORAGE',
        'AGENT',
        'DATA',
        'CHANNEL',
        'GOVERNANCE'
      )
    ),
  constraint atlas_provisioning_resources_operation_check
    check (
      operation_type in (
        'CREATE',
        'CONFIGURE',
        'LOAD',
        'REGISTER',
        'VERIFY'
      )
    ),
  constraint atlas_provisioning_resources_target_check
    check (target_kind ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_provisioning_resources_order_check
    check (execution_order >= 1),
  constraint atlas_provisioning_resources_dependencies_check
    check (
      array_position(dependency_codes, resource_code) is null
      and coalesce(array_to_string(dependency_codes, ','), '')
        ~ '^$|^[A-Z][A-Z0-9_]*(,[A-Z][A-Z0-9_]*)*$'
    ),
  constraint atlas_provisioning_resources_compensation_check
    check (
      compensation_strategy in (
        'DELETE_CREATED_RESOURCE',
        'RESTORE_PREVIOUS_VERSION',
        'REVOKE_AND_ARCHIVE',
        'MARK_INACTIVE',
        'MANUAL_REVIEW_REQUIRED',
        'NO_COMPENSATION_READ_ONLY'
      )
    ),
  constraint atlas_provisioning_resources_contracts_check
    check (
      jsonb_typeof(input_contract) = 'object'
      and input_contract <> '{}'::jsonb
      and jsonb_typeof(verification_contract) = 'object'
      and verification_contract <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(input_contract)
      and not public.atlas_jsonb_has_forbidden_secret_key(
        verification_contract
      )
    ),
  constraint atlas_provisioning_resources_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_provisioning_resource_definitions (
  resource_code, display_name, description, resource_group,
  operation_type, target_kind, execution_order,
  required_by_default, dependency_codes, compensation_strategy,
  input_contract, verification_contract, active, metadata
)
values
  (
    'TENANT_CORE', 'Tenant principal',
    'Crea la identidad tecnica y el limite aislado de la empresa.',
    'TENANT', 'CREATE', 'TENANT', 10, true, array[]::text[],
    'DELETE_CREATED_RESOURCE',
    jsonb_build_object('requires', jsonb_build_array(
      'installation_id', 'empresa_id', 'company_identity'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'TENANT_ID_MATCH', 'TENANT_ISOLATED'
    )), true, '{}'::jsonb
  ),
  (
    'COMPANY_PROFILE', 'Perfil empresarial',
    'Carga la identidad y configuracion regional canonica de la empresa.',
    'TENANT', 'CONFIGURE', 'COMPANY_PROFILE', 20, true,
    array['TENANT_CORE'], 'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'canonical_company', 'locale', 'timezone', 'currency'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'COMPANY_IDENTITY_MATCH', 'LOCALE_VALID'
    )), true, '{}'::jsonb
  ),
  (
    'OWNER_MEMBERSHIP', 'Membresia OWNER',
    'Registra al propietario verificado como autoridad inicial del tenant.',
    'ACCESS', 'REGISTER', 'MEMBERSHIP', 30, true,
    array['TENANT_CORE'], 'REVOKE_AND_ARCHIVE',
    jsonb_build_object('requires', jsonb_build_array(
      'client_owner_user_id', 'owner_authorization'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'OWNER_ACTIVE', 'OWNER_TENANT_MATCH'
    )), true, '{}'::jsonb
  ),
  (
    'BASE_ROLES', 'Roles base',
    'Materializa los roles iniciales aplicables al alcance contratado.',
    'ACCESS', 'LOAD', 'ROLE_SET', 40, true,
    array['TENANT_CORE'], 'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array('canonical_roles')),
    jsonb_build_object('asserts', jsonb_build_array(
      'ROLE_CODES_VALID', 'NO_UNDECLARED_ROLE'
    )), true, '{}'::jsonb
  ),
  (
    'ROLE_PERMISSIONS', 'Permisos de roles',
    'Asigna permisos explicitos con minimo privilegio a cada rol instalado.',
    'ACCESS', 'LOAD', 'ROLE_PERMISSION_SET', 50, true,
    array['BASE_ROLES'], 'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'canonical_role_permissions'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'MINIMUM_PRIVILEGE', 'NO_UNDECLARED_PERMISSION'
    )), true, '{}'::jsonb
  ),
  (
    'PRIVATE_STORAGE', 'Storage privado',
    'Prepara rutas privadas segregadas para los recursos del tenant.',
    'STORAGE', 'CONFIGURE', 'STORAGE_NAMESPACE', 60, true,
    array['TENANT_CORE'], 'DELETE_CREATED_RESOURCE',
    jsonb_build_object('requires', jsonb_build_array(
      'empresa_path', 'retention_contract'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'PRIVATE_BUCKET', 'TENANT_PATH_ISOLATED'
    )), true, '{}'::jsonb
  ),
  (
    'STORAGE_POLICIES', 'Politicas de Storage',
    'Configura lectura y escritura aisladas sin borrado directo del cliente.',
    'STORAGE', 'CONFIGURE', 'STORAGE_POLICY_SET', 70, true,
    array['PRIVATE_STORAGE', 'ROLE_PERMISSIONS'],
    'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'storage_access_matrix', 'retention_contract'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'RLS_ENABLED', 'CLIENT_DELETE_BLOCKED'
    )), true, '{}'::jsonb
  ),
  (
    'AGENT_PACKAGE', 'Paquete del agente',
    'Registra el paquete y la version contractual del agente instalado.',
    'AGENT', 'REGISTER', 'AGENT_PACKAGE', 80, true,
    array['TENANT_CORE'], 'REVOKE_AND_ARCHIVE',
    jsonb_build_object('requires', jsonb_build_array(
      'package_id', 'package_version', 'active_components'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'PACKAGE_ACTIVE', 'COMPONENTS_READY'
    )), true, '{}'::jsonb
  ),
  (
    'AGENT_IDENTITY', 'Identidad del agente',
    'Instala identidad, alcance y reglas de presentacion del agente.',
    'AGENT', 'LOAD', 'AGENT_IDENTITY', 90, true,
    array['AGENT_PACKAGE'], 'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'agent_identity', 'agent_scope'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'IDENTITY_VERSION_MATCH', 'SCOPE_DECLARED'
    )), true, '{}'::jsonb
  ),
  (
    'AGENT_PERSONALITY', 'Personalidad y regionalidad',
    'Carga el perfil aprobado de tono, formalidad y regionalidad.',
    'AGENT', 'LOAD', 'AGENT_PERSONALITY', 100, true,
    array['AGENT_IDENTITY'], 'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'personality_profile', 'regional_profile'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'PERSONALITY_APPROVED', 'NEUTRAL_FALLBACK_PRESENT'
    )), true, '{}'::jsonb
  ),
  (
    'KNOWLEDGE_BASE', 'Base de conocimiento',
    'Materializa conocimiento aprobado con fuente, version y vigencia.',
    'DATA', 'LOAD', 'KNOWLEDGE_BASE', 110, true,
    array['AGENT_PACKAGE'], 'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'canonical_knowledge', 'source_lineage'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'SOURCE_LINEAGE_VALID', 'KNOWLEDGE_VERSION_MATCH'
    )), true, '{}'::jsonb
  ),
  (
    'PRODUCT_CATALOG', 'Catalogo comercial',
    'Carga productos o servicios, precios, unidades y vigencias aprobadas.',
    'DATA', 'LOAD', 'PRODUCT_CATALOG', 120, true,
    array['AGENT_PACKAGE'], 'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'canonical_catalog', 'pricing_rules'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'CATALOG_VERSION_MATCH', 'PRICES_NOT_EXPIRED'
    )), true, '{}'::jsonb
  ),
  (
    'COMMERCIAL_RULES', 'Reglas comerciales',
    'Instala politicas, restricciones, pagos y autorizaciones comerciales.',
    'DATA', 'LOAD', 'COMMERCIAL_RULE_SET', 130, true,
    array['PRODUCT_CATALOG'], 'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'commercial_policies', 'payment_terms', 'authorization_rules'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'RULES_APPROVED', 'NO_UNDECLARED_PRICE_OVERRIDE'
    )), true, '{}'::jsonb
  ),
  (
    'MESSAGE_TEMPLATES', 'Plantillas operativas',
    'Carga plantillas aprobadas para respuestas y documentos contratados.',
    'DATA', 'LOAD', 'TEMPLATE_SET', 140, true,
    array['AGENT_IDENTITY', 'COMMERCIAL_RULES'],
    'RESTORE_PREVIOUS_VERSION',
    jsonb_build_object('requires', jsonb_build_array(
      'canonical_templates'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'TEMPLATE_SCOPE_VALID', 'TEMPLATE_VERSION_MATCH'
    )), true, '{}'::jsonb
  ),
  (
    'CHANNEL_CONFIGURATION', 'Configuracion de canales',
    'Registra referencias no secretas de los canales contratados.',
    'CHANNEL', 'CONFIGURE', 'CHANNEL_REFERENCE_SET', 150, true,
    array['AGENT_IDENTITY', 'ROLE_PERMISSIONS'],
    'MARK_INACTIVE',
    jsonb_build_object('requires', jsonb_build_array(
      'contracted_channels', 'non_secret_references'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'CHANNELS_IN_SCOPE', 'NO_EMBEDDED_SECRET'
    )), true, '{}'::jsonb
  ),
  (
    'AUDIT_BASELINE', 'Linea base de auditoria',
    'Verifica que recursos y operaciones queden sujetos a auditoria.',
    'GOVERNANCE', 'VERIFY', 'AUDIT_BASELINE', 160, true,
    array[
      'OWNER_MEMBERSHIP', 'STORAGE_POLICIES', 'AGENT_PACKAGE',
      'KNOWLEDGE_BASE', 'PRODUCT_CATALOG', 'COMMERCIAL_RULES',
      'CHANNEL_CONFIGURATION'
    ],
    'NO_COMPENSATION_READ_ONLY',
    jsonb_build_object('requires', jsonb_build_array(
      'provisioned_resource_ids'
    )),
    jsonb_build_object('asserts', jsonb_build_array(
      'AUDIT_EVENTS_PRESENT', 'IDEMPOTENCY_KEYS_PRESENT'
    )), true, '{}'::jsonb
  )
on conflict (resource_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  resource_group = excluded.resource_group,
  operation_type = excluded.operation_type,
  target_kind = excluded.target_kind,
  execution_order = excluded.execution_order,
  required_by_default = excluded.required_by_default,
  dependency_codes = excluded.dependency_codes,
  compensation_strategy = excluded.compensation_strategy,
  input_contract = excluded.input_contract,
  verification_contract = excluded.verification_contract,
  active = excluded.active,
  metadata = excluded.metadata,
  updated_at = now();

create table if not exists
public.atlas_provisioning_preflight_definitions (
  check_code text primary key,
  display_name text not null,
  description text not null,
  check_group text not null,
  severity text not null,
  execution_order integer not null,
  required boolean not null default true,
  evaluation_contract jsonb not null,
  remediation_guidance text not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_preflight_definitions_code_check
    check (check_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_preflight_definitions_order_key
    unique (execution_order),
  constraint atlas_preflight_definitions_name_check
    check (length(btrim(display_name)) >= 3),
  constraint atlas_preflight_definitions_description_check
    check (length(btrim(description)) >= 10),
  constraint atlas_preflight_definitions_group_check
    check (
      check_group in (
        'STATE', 'AUTHORITY', 'SOURCE', 'PACKAGE',
        'SECURITY', 'CAPACITY', 'RECOVERY'
      )
    ),
  constraint atlas_preflight_definitions_severity_check
    check (severity in ('INFO', 'WARNING', 'ERROR', 'CRITICAL')),
  constraint atlas_preflight_definitions_order_check
    check (execution_order >= 1),
  constraint atlas_preflight_definitions_contract_check
    check (
      jsonb_typeof(evaluation_contract) = 'object'
      and evaluation_contract <> '{}'::jsonb
      and nullif(
        btrim(evaluation_contract->>'assertion_code'), ''
      ) is not null
      and not public.atlas_jsonb_has_forbidden_secret_key(
        evaluation_contract
      )
    ),
  constraint atlas_preflight_definitions_remediation_check
    check (length(btrim(remediation_guidance)) >= 10),
  constraint atlas_preflight_definitions_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_provisioning_preflight_definitions (
  check_code, display_name, description, check_group, severity,
  execution_order, required, evaluation_contract,
  remediation_guidance, active, metadata
)
values
  ('INSTALLATION_STATE_DATA_APPROVED', 'Estado de datos aprobado', 'Exige que el expediente se encuentre en DATA_APPROVED.', 'STATE', 'CRITICAL', 10, true, jsonb_build_object('assertion_code', 'STATE_EQUALS_DATA_APPROVED'), 'Completar G02 y transicionar el expediente a DATA_APPROVED.', true, '{}'::jsonb),
  ('G02_GATE_APPROVED', 'Gate G02 aprobado', 'Verifica aprobacion vigente del OWNER para datos y conocimiento.', 'AUTHORITY', 'CRITICAL', 20, true, jsonb_build_object('assertion_code', 'G02_STATUS_APPROVED'), 'Obtener aprobacion valida del OWNER mediante la RPC de gates.', true, '{}'::jsonb),
  ('CLIENT_OWNER_ACTIVE', 'OWNER cliente activo', 'Confirma identidad y membresia activa del OWNER autorizado.', 'AUTHORITY', 'CRITICAL', 30, true, jsonb_build_object('assertion_code', 'CLIENT_OWNER_ACTIVE_AND_MATCHED'), 'Restablecer una membresia OWNER valida y ligada al expediente.', true, '{}'::jsonb),
  ('CURRENT_MANIFEST_VALID', 'Manifest vigente', 'Confirma que el manifest fuente es vigente, aprobado y consistente.', 'SOURCE', 'CRITICAL', 40, true, jsonb_build_object('assertion_code', 'LATEST_MANIFEST_APPROVED'), 'Aprobar o regenerar el manifest vigente del paquete.', true, '{}'::jsonb),
  ('CURRENT_CANONICAL_VERSION_VALID', 'Version canonica vigente', 'Valida el snapshot aprobado, su hash y su enlace al manifest.', 'SOURCE', 'CRITICAL', 50, true, jsonb_build_object('assertion_code', 'CANONICAL_SHA256_AND_MANIFEST_MATCH'), 'Repetir la revision cliente y promocion canonica.', true, '{}'::jsonb),
  ('CONDITIONAL_INVENTORY_RESOLVED', 'Inventario condicionado resuelto', 'Comprueba que no existan requisitos condicionales pendientes.', 'SOURCE', 'ERROR', 60, true, jsonb_build_object('assertion_code', 'NO_CONDITIONAL_REQUIREMENT_PENDING'), 'Resolver el diagnostico condicionado antes de aprovisionar.', true, '{}'::jsonb),
  ('AGENT_PACKAGE_ACTIVE', 'Paquete activo', 'Verifica que el paquete declarado exista y permanezca activo.', 'PACKAGE', 'CRITICAL', 70, true, jsonb_build_object('assertion_code', 'PACKAGE_ID_VERSION_ACTIVE'), 'Seleccionar una version activa del paquete de agente.', true, '{}'::jsonb),
  ('PACKAGE_COMPONENTS_READY', 'Componentes listos', 'Exige que todos los componentes requeridos esten implementables.', 'PACKAGE', 'CRITICAL', 80, true, jsonb_build_object('assertion_code', 'REQUIRED_COMPONENTS_READY'), 'Completar o reemplazar componentes requeridos no disponibles.', true, '{}'::jsonb),
  ('TENANT_IDENTITY_UNAMBIGUOUS', 'Identidad de tenant unica', 'Evita colisiones entre empresa, expediente y recursos existentes.', 'SECURITY', 'CRITICAL', 90, true, jsonb_build_object('assertion_code', 'TENANT_IDENTITY_NO_COLLISION'), 'Reconciliar identificadores antes de crear recursos.', true, '{}'::jsonb),
  ('STORAGE_AUTHORITY_READY', 'Storage seguro disponible', 'Valida bucket privado, ruta tenant y ausencia de borrado directo.', 'SECURITY', 'CRITICAL', 100, true, jsonb_build_object('assertion_code', 'PRIVATE_STORAGE_AUTHORITY_READY'), 'Corregir bucket, rutas o politicas de Storage.', true, '{}'::jsonb),
  ('NO_EMBEDDED_SECRETS', 'Sin secretos embebidos', 'Busca claves prohibidas en manifest, canonico y payload del plan.', 'SECURITY', 'CRITICAL', 110, true, jsonb_build_object('assertion_code', 'NO_FORBIDDEN_SECRET_KEY'), 'Extraer secretos y conservar solo referencias seguras.', true, '{}'::jsonb),
  ('NO_ACTIVE_PROVISIONING_PLAN', 'Sin plan activo en conflicto', 'Impide ejecutar dos planes activos para el mismo expediente.', 'CAPACITY', 'CRITICAL', 120, true, jsonb_build_object('assertion_code', 'SINGLE_ACTIVE_PLAN'), 'Finalizar, fallar o revertir el plan anterior.', true, '{}'::jsonb),
  ('IDEMPOTENCY_CONTRACT_READY', 'Contrato idempotente', 'Comprueba claves unicas para plan, pasos y operaciones.', 'RECOVERY', 'ERROR', 130, true, jsonb_build_object('assertion_code', 'IDEMPOTENCY_KEYS_COMPLETE'), 'Regenerar el plan con claves idempotentes completas.', true, '{}'::jsonb),
  ('ROLLBACK_STRATEGIES_READY', 'Compensaciones disponibles', 'Exige una estrategia de compensacion para cada paso mutable.', 'RECOVERY', 'CRITICAL', 140, true, jsonb_build_object('assertion_code', 'COMPENSATION_STRATEGY_COMPLETE'), 'Definir rollback o revision manual para cada operacion.', true, '{}'::jsonb)
on conflict (check_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  check_group = excluded.check_group,
  severity = excluded.severity,
  execution_order = excluded.execution_order,
  required = excluded.required,
  evaluation_contract = excluded.evaluation_contract,
  remediation_guidance = excluded.remediation_guidance,
  active = excluded.active,
  metadata = excluded.metadata,
  updated_at = now();

do $$
begin
  if (
    select count(*)
    from public.atlas_provisioning_resource_definitions
    where active = true
  ) <> 16 then
    raise exception 'B2.2G.1 requiere 16 recursos activos canonicos';
  end if;

  if (
    select count(*)
    from public.atlas_provisioning_preflight_definitions
    where active = true
  ) <> 14 then
    raise exception 'B2.2G.1 requiere 14 verificaciones preflight activas';
  end if;

  if exists (
    select 1
    from public.atlas_provisioning_resource_definitions as resource
    cross join lateral unnest(resource.dependency_codes)
      as dependency(dependency_code)
    where resource.active = true
      and not exists (
        select 1
        from public.atlas_provisioning_resource_definitions
          as dependency_resource
        where dependency_resource.resource_code =
          dependency.dependency_code
          and dependency_resource.active = true
      )
  ) then
    raise exception 'B2.2G.1 dependencia de recurso inexistente';
  end if;

  if exists (
    with recursive dependency_walk as (
      select
        resource.resource_code as root_code,
        dependency.dependency_code as current_code,
        array[resource.resource_code]::text[] as visited,
        dependency.dependency_code = resource.resource_code as cycle
      from public.atlas_provisioning_resource_definitions as resource
      cross join lateral unnest(resource.dependency_codes)
        as dependency(dependency_code)
      where resource.active = true

      union all

      select
        dependency_walk.root_code,
        next_dependency.dependency_code,
        dependency_walk.visited || dependency_walk.current_code,
        next_dependency.dependency_code = any(
          dependency_walk.visited || dependency_walk.current_code
        )
      from dependency_walk
      join public.atlas_provisioning_resource_definitions
        as current_resource
        on current_resource.resource_code = dependency_walk.current_code
       and current_resource.active = true
      cross join lateral unnest(current_resource.dependency_codes)
        as next_dependency(dependency_code)
      where not dependency_walk.cycle
    )
    select 1
    from dependency_walk
    where cycle
  ) then
    raise exception 'B2.2G.1 ciclo detectado en recursos canonicos';
  end if;
end;
$$;

create table if not exists
public.atlas_installation_provisioning_plans (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  source_manifest_id uuid not null,
  canonical_data_version_id uuid not null,
  package_id uuid not null,
  package_version text not null,
  plan_version integer not null,
  plan_status text not null default 'DRAFT',
  state_version bigint not null default 1,
  plan_payload jsonb not null,
  plan_sha256 text not null,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  started_at timestamptz,
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_provisioning_plans_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_provisioning_plans_version_key
    unique (installation_id, plan_version),
  constraint atlas_provisioning_plans_hash_key
    unique (installation_id, plan_sha256),
  constraint atlas_provisioning_plans_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_provisioning_plans_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_provisioning_plans_manifest_fkey
    foreign key (source_manifest_id)
    references public.atlas_installation_manifests(id)
    on delete restrict,
  constraint atlas_provisioning_plans_canonical_fkey
    foreign key (canonical_data_version_id)
    references public.atlas_canonical_data_versions(id)
    on delete restrict,
  constraint atlas_provisioning_plans_package_fkey
    foreign key (package_id)
    references public.atlas_agent_packages(id)
    on delete restrict,
  constraint atlas_provisioning_plans_creator_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_provisioning_plans_package_version_check
    check (package_version ~ '^V[0-9]+$'),
  constraint atlas_provisioning_plans_version_check
    check (plan_version >= 1 and state_version >= 1),
  constraint atlas_provisioning_plans_status_check
    check (
      plan_status in (
        'DRAFT',
        'PREFLIGHT_PENDING',
        'PREFLIGHT_FAILED',
        'PREFLIGHT_PASSED',
        'EXECUTING',
        'COMPLETED',
        'FAILED',
        'ROLLBACK_REQUIRED',
        'ROLLED_BACK',
        'SUPERSEDED'
      )
    ),
  constraint atlas_provisioning_plans_payload_check
    check (
      jsonb_typeof(plan_payload) = 'object'
      and plan_payload ?& array[
        'schema_version',
        'installation_id',
        'empresa_id',
        'source_manifest_id',
        'canonical_data_version_id',
        'package_id',
        'package_version',
        'resources'
      ]
      and jsonb_typeof(plan_payload->'resources') = 'array'
      and jsonb_array_length(plan_payload->'resources') > 0
      and not public.atlas_jsonb_has_forbidden_secret_key(plan_payload)
    ),
  constraint atlas_provisioning_plans_payload_identity_check
    check (
      plan_payload->>'installation_id' = installation_id::text
      and plan_payload->>'empresa_id' = empresa_id::text
      and plan_payload->>'source_manifest_id' = source_manifest_id::text
      and plan_payload->>'canonical_data_version_id' =
        canonical_data_version_id::text
      and plan_payload->>'package_id' = package_id::text
      and plan_payload->>'package_version' = package_version
    ),
  constraint atlas_provisioning_plans_hash_check
    check (plan_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_provisioning_plans_timeline_check
    check (
      completed_at is null
      or (started_at is not null and completed_at >= started_at)
    ),
  constraint atlas_provisioning_plans_completion_check
    check (
      plan_status not in ('COMPLETED', 'ROLLED_BACK', 'SUPERSEDED')
      or completed_at is not null
    ),
  constraint atlas_provisioning_plans_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create unique index if not exists idx_atlas_provisioning_active_plan
  on public.atlas_installation_provisioning_plans (installation_id)
  where plan_status in (
    'DRAFT', 'PREFLIGHT_PENDING', 'PREFLIGHT_FAILED',
    'PREFLIGHT_PASSED', 'EXECUTING', 'ROLLBACK_REQUIRED'
  );

create index if not exists idx_atlas_provisioning_plans_status
  on public.atlas_installation_provisioning_plans (
    installation_id,
    plan_status,
    plan_version desc
  );

create table if not exists
public.atlas_installation_provisioning_steps (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  provisioning_plan_id uuid not null,
  resource_code text not null,
  step_code text not null,
  step_order integer not null,
  required boolean not null default true,
  step_status text not null default 'PENDING',
  state_version bigint not null default 1,
  operation_type text not null,
  target_reference jsonb not null,
  input_payload jsonb not null,
  input_sha256 text not null,
  dependency_step_codes text[] not null default array[]::text[],
  idempotency_key uuid not null,
  attempt_count integer not null default 0,
  max_attempts integer not null default 3,
  compensation_status text not null default 'NOT_REQUIRED',
  result_payload jsonb not null default '{}'::jsonb,
  evidence jsonb not null default '{}'::jsonb,
  last_error_code text,
  last_error_message text,
  started_at timestamptz,
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_provisioning_steps_request_key
    unique (provisioning_plan_id, idempotency_key),
  constraint atlas_provisioning_steps_code_key
    unique (provisioning_plan_id, step_code),
  constraint atlas_provisioning_steps_order_key
    unique (provisioning_plan_id, step_order),
  constraint atlas_provisioning_steps_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_provisioning_steps_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_provisioning_steps_plan_fkey
    foreign key (provisioning_plan_id)
    references public.atlas_installation_provisioning_plans(id)
    on delete restrict,
  constraint atlas_provisioning_steps_resource_fkey
    foreign key (resource_code)
    references public.atlas_provisioning_resource_definitions(resource_code)
    on delete restrict,
  constraint atlas_provisioning_steps_code_check
    check (step_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_provisioning_steps_order_check
    check (step_order >= 1),
  constraint atlas_provisioning_steps_status_check
    check (
      step_status in (
        'PENDING', 'BLOCKED', 'READY', 'EXECUTING',
        'SUCCEEDED', 'FAILED', 'COMPENSATING',
        'COMPENSATED', 'SKIPPED'
      )
    ),
  constraint atlas_provisioning_steps_version_check
    check (state_version >= 1),
  constraint atlas_provisioning_steps_operation_check
    check (
      operation_type in (
        'CREATE', 'CONFIGURE', 'LOAD', 'REGISTER', 'VERIFY'
      )
    ),
  constraint atlas_provisioning_steps_payload_check
    check (
      jsonb_typeof(target_reference) = 'object'
      and target_reference <> '{}'::jsonb
      and jsonb_typeof(input_payload) = 'object'
      and input_payload <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        target_reference
      )
      and not public.atlas_jsonb_has_forbidden_secret_key(input_payload)
    ),
  constraint atlas_provisioning_steps_hash_check
    check (input_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_provisioning_steps_dependencies_check
    check (
      array_position(dependency_step_codes, step_code) is null
      and coalesce(array_to_string(dependency_step_codes, ','), '')
        ~ '^$|^[A-Z][A-Z0-9_]*(,[A-Z][A-Z0-9_]*)*$'
    ),
  constraint atlas_provisioning_steps_attempts_check
    check (
      attempt_count >= 0
      and max_attempts between 1 and 10
      and attempt_count <= max_attempts
    ),
  constraint atlas_provisioning_steps_compensation_check
    check (
      compensation_status in (
        'NOT_REQUIRED', 'PENDING', 'EXECUTING',
        'COMPLETED', 'FAILED', 'MANUAL_REVIEW'
      )
    ),
  constraint atlas_provisioning_steps_result_check
    check (
      jsonb_typeof(result_payload) = 'object'
      and jsonb_typeof(evidence) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(result_payload)
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
    ),
  constraint atlas_provisioning_steps_error_check
    check (
      (last_error_code is null and last_error_message is null)
      or (
        nullif(btrim(last_error_code), '') is not null
        and nullif(btrim(last_error_message), '') is not null
      )
    ),
  constraint atlas_provisioning_steps_timeline_check
    check (
      completed_at is null
      or (started_at is not null and completed_at >= started_at)
    ),
  constraint atlas_provisioning_steps_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index if not exists idx_atlas_provisioning_steps_execution
  on public.atlas_installation_provisioning_steps (
    provisioning_plan_id,
    step_status,
    step_order
  );

create table if not exists
public.atlas_installation_preflight_results (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  provisioning_plan_id uuid not null,
  check_code text not null,
  evaluation_version integer not null,
  evaluated_plan_state_version bigint not null,
  outcome text not null,
  severity text not null,
  evaluator_user_id uuid not null,
  evaluator_role_code text not null,
  request_id uuid not null,
  evidence jsonb not null,
  details jsonb not null,
  created_at timestamptz not null default now(),

  constraint atlas_preflight_results_request_key
    unique (provisioning_plan_id, check_code, request_id),
  constraint atlas_preflight_results_version_key
    unique (provisioning_plan_id, check_code, evaluation_version),
  constraint atlas_preflight_results_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_preflight_results_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_preflight_results_plan_fkey
    foreign key (provisioning_plan_id)
    references public.atlas_installation_provisioning_plans(id)
    on delete restrict,
  constraint atlas_preflight_results_check_fkey
    foreign key (check_code)
    references public.atlas_provisioning_preflight_definitions(check_code)
    on delete restrict,
  constraint atlas_preflight_results_evaluator_fkey
    foreign key (evaluator_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_preflight_results_role_fkey
    foreign key (evaluator_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_preflight_results_versions_check
    check (
      evaluation_version >= 1
      and evaluated_plan_state_version >= 1
    ),
  constraint atlas_preflight_results_outcome_check
    check (outcome in ('PASSED', 'FAILED', 'WARNING', 'SKIPPED')),
  constraint atlas_preflight_results_severity_check
    check (severity in ('INFO', 'WARNING', 'ERROR', 'CRITICAL')),
  constraint atlas_preflight_results_payload_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
      and nullif(btrim(evidence->>'evidence_reference'), '') is not null
      and jsonb_typeof(details) = 'object'
      and details <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
      and not public.atlas_jsonb_has_forbidden_secret_key(details)
    )
);

create index if not exists idx_atlas_preflight_results_latest
  on public.atlas_installation_preflight_results (
    provisioning_plan_id,
    check_code,
    evaluation_version desc
  );

create table if not exists
public.atlas_installation_provisioning_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  provisioning_plan_id uuid not null,
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

  constraint atlas_provisioning_events_request_key
    unique (provisioning_plan_id, request_id),
  constraint atlas_provisioning_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_provisioning_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_provisioning_events_plan_fkey
    foreign key (provisioning_plan_id)
    references public.atlas_installation_provisioning_plans(id)
    on delete restrict,
  constraint atlas_provisioning_events_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_provisioning_events_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_provisioning_events_entity_check
    check (entity_type in ('PLAN', 'STEP', 'PREFLIGHT', 'RESOURCE')),
  constraint atlas_provisioning_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_provisioning_events_status_check
    check (
      length(btrim(to_status)) >= 2
      and (from_status is null or length(btrim(from_status)) >= 2)
    ),
  constraint atlas_provisioning_events_reason_check
    check (length(btrim(reason)) >= 10),
  constraint atlas_provisioning_events_payload_check
    check (
      jsonb_typeof(evidence) = 'object'
      and jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index if not exists idx_atlas_provisioning_events_timeline
  on public.atlas_installation_provisioning_events (
    provisioning_plan_id,
    created_at desc,
    id desc
  );

create or replace function
public.atlas_block_provisioning_append_only_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_PROVISIONING_RECORDS_APPEND_ONLY:' || tg_table_name;
end;
$$;

revoke all on function
public.atlas_block_provisioning_append_only_mutation()
  from public, anon, authenticated;
grant execute on function
public.atlas_block_provisioning_append_only_mutation()
  to service_role;

drop trigger if exists trg_atlas_preflight_results_append_only
  on public.atlas_installation_preflight_results;
create trigger trg_atlas_preflight_results_append_only
before update or delete on public.atlas_installation_preflight_results
for each row execute function
public.atlas_block_provisioning_append_only_mutation();

drop trigger if exists trg_atlas_provisioning_events_append_only
  on public.atlas_installation_provisioning_events;
create trigger trg_atlas_provisioning_events_append_only
before update or delete on public.atlas_installation_provisioning_events
for each row execute function
public.atlas_block_provisioning_append_only_mutation();

drop trigger if exists trg_atlas_provisioning_resources_updated_at
  on public.atlas_provisioning_resource_definitions;
create trigger trg_atlas_provisioning_resources_updated_at
before update on public.atlas_provisioning_resource_definitions
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_preflight_definitions_updated_at
  on public.atlas_provisioning_preflight_definitions;
create trigger trg_atlas_preflight_definitions_updated_at
before update on public.atlas_provisioning_preflight_definitions
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_provisioning_plans_updated_at
  on public.atlas_installation_provisioning_plans;
create trigger trg_atlas_provisioning_plans_updated_at
before update on public.atlas_installation_provisioning_plans
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_provisioning_steps_updated_at
  on public.atlas_installation_provisioning_steps;
create trigger trg_atlas_provisioning_steps_updated_at
before update on public.atlas_installation_provisioning_steps
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_provisioning_resource_definitions
  enable row level security;
alter table public.atlas_provisioning_preflight_definitions
  enable row level security;
alter table public.atlas_installation_provisioning_plans
  enable row level security;
alter table public.atlas_installation_provisioning_steps
  enable row level security;
alter table public.atlas_installation_preflight_results
  enable row level security;
alter table public.atlas_installation_provisioning_events
  enable row level security;

revoke all on table public.atlas_provisioning_resource_definitions
  from anon, authenticated;
revoke all on table public.atlas_provisioning_preflight_definitions
  from anon, authenticated;
revoke all on table public.atlas_installation_provisioning_plans
  from anon, authenticated;
revoke all on table public.atlas_installation_provisioning_steps
  from anon, authenticated;
revoke all on table public.atlas_installation_preflight_results
  from anon, authenticated;
revoke all on table public.atlas_installation_provisioning_events
  from anon, authenticated;

grant select on table public.atlas_provisioning_resource_definitions
  to authenticated;
grant select on table public.atlas_provisioning_preflight_definitions
  to authenticated;
grant select on table public.atlas_installation_provisioning_plans
  to authenticated;
grant select on table public.atlas_installation_provisioning_steps
  to authenticated;
grant select on table public.atlas_installation_preflight_results
  to authenticated;
grant select on table public.atlas_installation_provisioning_events
  to authenticated;

grant all on table public.atlas_provisioning_resource_definitions
  to service_role;
grant all on table public.atlas_provisioning_preflight_definitions
  to service_role;
grant all on table public.atlas_installation_provisioning_plans
  to service_role;
grant all on table public.atlas_installation_provisioning_steps
  to service_role;
grant all on table public.atlas_installation_preflight_results
  to service_role;
grant all on table public.atlas_installation_provisioning_events
  to service_role;

do $$
declare
  v_table_name text;
  v_policy_name text;
begin
  foreach v_table_name in array array[
    'atlas_provisioning_resource_definitions',
    'atlas_provisioning_preflight_definitions',
    'atlas_installation_provisioning_plans',
    'atlas_installation_provisioning_steps',
    'atlas_installation_preflight_results',
    'atlas_installation_provisioning_events'
  ] loop
    v_policy_name := v_table_name || '_platform_read';

    if not exists (
      select 1
      from pg_policies
      where schemaname = 'public'
        and tablename = v_table_name
        and policyname = v_policy_name
    ) then
      execute format(
        'create policy %I on public.%I for select to authenticated using (public.atlas_platform_has_permission(''INSTALLATION_PROVISIONING_READ''))',
        v_policy_name,
        v_table_name
      );
    end if;
  end loop;
end;
$$;

create or replace function
public.atlas_enforce_provisioning_entry_readiness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_required_check_count bigint;
  v_passed_check_count bigint;
  v_readiness jsonb;
begin
  if old.current_state_code = 'DATA_APPROVED'
     and new.current_state_code = 'PROVISIONING' then
    select plan.*
    into v_plan
    from public.atlas_installation_provisioning_plans as plan
    where plan.installation_id = old.id
      and plan.plan_status = 'PREFLIGHT_PASSED'
    order by plan.plan_version desc, plan.created_at desc
    limit 1;

    if not found then
      raise exception using
        errcode = '42501',
        message = 'PROVISIONING_PREFLIGHT_PASSED_PLAN_REQUIRED';
    end if;

    if v_plan.plan_sha256 <>
       public.atlas_normalization_sha256(v_plan.plan_payload::text) then
      raise exception using
        errcode = '42501',
        message = 'PROVISIONING_PLAN_HASH_MISMATCH';
    end if;

    select count(*)
    into v_required_check_count
    from public.atlas_provisioning_preflight_definitions as definition
    where definition.active = true
      and definition.required = true;

    select count(*)
    into v_passed_check_count
    from public.atlas_provisioning_preflight_definitions as definition
    where definition.active = true
      and definition.required = true
      and exists (
        select 1
        from public.atlas_installation_preflight_results as result_record
        where result_record.provisioning_plan_id = v_plan.id
          and result_record.check_code = definition.check_code
          and result_record.outcome = 'PASSED'
          and result_record.evaluated_plan_state_version =
            v_plan.state_version
          and result_record.evaluation_version = (
            select max(latest_result.evaluation_version)
            from public.atlas_installation_preflight_results as latest_result
            where latest_result.provisioning_plan_id = v_plan.id
              and latest_result.check_code = definition.check_code
          )
      );

    if v_required_check_count = 0
       or v_passed_check_count <> v_required_check_count then
      raise exception using
        errcode = '42501',
        message = 'PROVISIONING_PREFLIGHT_RESULTS_INCOMPLETE';
    end if;

    v_readiness := public.atlas_compute_installation_g02_readiness(old.id);

    if not coalesce((v_readiness->>'ready')::boolean, false)
       or (v_readiness->>'canonical_data_version_id') is distinct from
         v_plan.canonical_data_version_id::text
       or not exists (
         select 1
         from public.atlas_installation_gates as gate_record
         where gate_record.installation_id = old.id
           and gate_record.gate_code = 'G02'
           and gate_record.status = 'APPROVED'
           and gate_record.client_approved = true
       ) then
      raise exception using
        errcode = '42501',
        message = 'PROVISIONING_G02_STALE_OR_INCOMPLETE',
        detail = v_readiness::text;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_provisioning_entry_readiness()
  from public, anon, authenticated;
grant execute on function
public.atlas_enforce_provisioning_entry_readiness()
  to service_role;

drop trigger if exists trg_atlas_provisioning_entry_readiness
  on public.atlas_installations;
create trigger trg_atlas_provisioning_entry_readiness
before update of current_state_code on public.atlas_installations
for each row execute function
public.atlas_enforce_provisioning_entry_readiness();

comment on table public.atlas_provisioning_resource_definitions is
  'B2: catalogo interno y versionable de recursos aprovisionables.';
comment on table public.atlas_provisioning_preflight_definitions is
  'B2: verificaciones obligatorias antes de iniciar aprovisionamiento.';
comment on table public.atlas_installation_provisioning_plans is
  'B2: planes versionados por fuente y con control optimista.';
comment on table public.atlas_installation_provisioning_steps is
  'B2: pasos idempotentes, dependencias, reintentos y compensacion.';
comment on table public.atlas_installation_preflight_results is
  'B2: resultados append-only ligados a la version exacta del plan.';
comment on table public.atlas_installation_provisioning_events is
  'B2: bitacora append-only de planes, pasos, preflight y recursos.';
comment on function public.atlas_enforce_provisioning_entry_readiness() is
  'B2: bloquea PROVISIONING sin plan vigente, preflight completo y G02 actual.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2G1_PROVISIONING_PLAN_PREFLIGHT_CORE_INSTALLED',
  'next_block', 'B2.2G.2_PLAN_GENERATION_AND_PREFLIGHT_RPCS',
  'rls_tables', 6,
  'resource_definitions', (
    select count(*)
    from public.atlas_provisioning_resource_definitions
    where active = true
  ),
  'preflight_definitions', (
    select count(*)
    from public.atlas_provisioning_preflight_definitions
    where active = true
  ),
  'provisioning_plans', (
    select count(*)
    from public.atlas_installation_provisioning_plans
  ),
  'provisioning_steps', (
    select count(*)
    from public.atlas_installation_provisioning_steps
  ),
  'preflight_results', (
    select count(*)
    from public.atlas_installation_preflight_results
  ),
  'provisioning_events', (
    select count(*)
    from public.atlas_installation_provisioning_events
  ),
  'permission_mappings', 8,
  'append_only_event_tables', 2,
  'plan_write_rpcs', 0,
  'preflight_write_rpcs', 0,
  'internal_platform_visibility_only', true,
  'provisioning_entry_guard_enabled', true,
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
