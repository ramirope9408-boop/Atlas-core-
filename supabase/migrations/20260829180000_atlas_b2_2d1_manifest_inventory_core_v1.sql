-- ATLAS B2.2D.1
-- Nucleo de manifest canonico e inventario condicionado.
-- Corte: 2026-08-29
--
-- Alcance deliberado:
-- - define el contrato estructural de manifest.json;
-- - bloquea claves de secretos dentro del manifest;
-- - cataloga 37 requisitos empresariales canonicos;
-- - crea inventarios y eventos versionados por expediente;
-- - mantiene toda escritura cliente deshabilitada hasta B2.2D.2.

begin;

do $$
begin
  if to_regclass('public.atlas_installations') is null
     or to_regclass('public.atlas_installation_files') is null
     or to_regclass('public.atlas_installation_file_decisions') is null
     or to_regprocedure('public.atlas_can_read_installation(uuid)') is null then
    raise exception 'B2.2D.1 requiere B2.2A-C instalados y certificados';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_PACKAGE_READ',
    'Consultar manifests y eventos del paquete de instalacion.'
  ),
  (
    'INSTALLATION_PACKAGE_MANAGE',
    'Registrar y versionar manifests mediante RPC gobernada.'
  ),
  (
    'INSTALLATION_INVENTORY_READ',
    'Consultar requisitos e inventario condicionado de instalacion.'
  ),
  (
    'INSTALLATION_INVENTORY_MANAGE',
    'Determinar y actualizar requisitos mediante RPC gobernada.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_PACKAGE_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_PACKAGE_MANAGE'),
  ('ATLAS_OWNER', 'INSTALLATION_INVENTORY_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_INVENTORY_MANAGE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_PACKAGE_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_PACKAGE_MANAGE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_INVENTORY_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_INVENTORY_MANAGE'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_PACKAGE_READ'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_INVENTORY_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_PACKAGE_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_INVENTORY_READ')
on conflict (role_code, permission_code) do nothing;

-- El manifest es una pieza propia del paquete. En Storage se conserva bajo
-- .../manifest/manifest.json aunque en la representacion logica sea la raiz.
alter table public.atlas_installation_files
  drop constraint if exists atlas_installation_files_logical_section_check;

alter table public.atlas_installation_files
  add constraint atlas_installation_files_logical_section_check
  check (
    logical_section in (
      'MANIFEST',
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
  );

create or replace function public.atlas_jsonb_has_forbidden_secret_key(
  p_value jsonb
)
returns boolean
language plpgsql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text;
  v_child jsonb;
begin
  case jsonb_typeof(p_value)
    when 'object' then
      for v_key, v_child in
        select entry.key, entry.value
        from jsonb_each(p_value) as entry
      loop
        if lower(v_key) = any(array[
          'token',
          'access_token',
          'refresh_token',
          'password',
          'secret',
          'client_secret',
          'api_key',
          'private_key',
          'authorization',
          'bearer',
          'webhook_secret',
          'credential',
          'credentials'
        ]) then
          return true;
        end if;

        if public.atlas_jsonb_has_forbidden_secret_key(v_child) then
          return true;
        end if;
      end loop;

    when 'array' then
      for v_child in
        select element.value
        from jsonb_array_elements(p_value) as element
      loop
        if public.atlas_jsonb_has_forbidden_secret_key(v_child) then
          return true;
        end if;
      end loop;

    else
      return false;
  end case;

  return false;
end;
$$;

revoke all on function public.atlas_jsonb_has_forbidden_secret_key(jsonb)
  from public, anon, authenticated;
grant execute on function public.atlas_jsonb_has_forbidden_secret_key(jsonb)
  to service_role;

create or replace function public.atlas_manifest_payload_is_valid(
  p_payload jsonb
)
returns boolean
language plpgsql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
begin
  if jsonb_typeof(p_payload) <> 'object' then
    return false;
  end if;

  if not (p_payload ?& array[
    'manifest_version',
    'installation_id',
    'package_id',
    'package_version',
    'company',
    'owner',
    'plan',
    'capabilities',
    'agents',
    'channels',
    'integrations',
    'data_domains',
    'required_permissions',
    'regional_profile',
    'voice_policy',
    'files',
    'approvals',
    'legal_documents',
    'retention_policy',
    'test_plan_code',
    'created_at'
  ]) then
    return false;
  end if;

  if coalesce(p_payload->>'manifest_version', '') !~ '^B2_V[0-9]+$'
     or coalesce(p_payload->>'installation_id', '') !~
       '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or coalesce(p_payload->>'package_id', '') !~
       '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or jsonb_typeof(p_payload->'package_version') <> 'number'
     or coalesce(p_payload->>'package_version', '') !~ '^[1-9][0-9]*$'
     or nullif(btrim(p_payload->>'test_plan_code'), '') is null
     or nullif(btrim(p_payload->>'created_at'), '') is null then
    return false;
  end if;

  if jsonb_typeof(p_payload->'company') <> 'object'
     or not ((p_payload->'company') ?& array[
       'legal_name',
       'trade_name',
       'country',
       'city',
       'timezone',
       'currency'
     ])
     or nullif(btrim(p_payload->'company'->>'legal_name'), '') is null
     or nullif(btrim(p_payload->'company'->>'trade_name'), '') is null
     or coalesce(p_payload->'company'->>'country', '') !~ '^[A-Z]{2}$'
     or nullif(btrim(p_payload->'company'->>'city'), '') is null
     or nullif(btrim(p_payload->'company'->>'timezone'), '') is null
     or coalesce(p_payload->'company'->>'currency', '') !~ '^[A-Z]{3}$' then
    return false;
  end if;

  if jsonb_typeof(p_payload->'owner') <> 'object'
     or not ((p_payload->'owner') ?& array[
       'identity_reference',
       'authorization_status'
     ])
     or coalesce(p_payload->'owner'->>'identity_reference', '') !~
       '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
     or coalesce(
       p_payload->'owner'->>'authorization_status',
       ''
     ) <> 'APPROVED' then
    return false;
  end if;

  if jsonb_typeof(p_payload->'plan') <> 'object'
     or not ((p_payload->'plan') ?& array[
       'code',
       'implementation_tier',
       'billing_reference'
     ])
     or nullif(btrim(p_payload->'plan'->>'code'), '') is null
     or coalesce(
       p_payload->'plan'->>'implementation_tier',
       ''
     ) not in (
       'STANDARD',
       'INTERMEDIATE',
       'SPECIAL'
     )
     or jsonb_typeof(p_payload->'plan'->'billing_reference') <> 'string' then
    return false;
  end if;

  if jsonb_typeof(p_payload->'capabilities') <> 'array'
     or jsonb_typeof(p_payload->'agents') <> 'array'
     or jsonb_typeof(p_payload->'channels') <> 'array'
     or jsonb_typeof(p_payload->'integrations') <> 'array'
     or jsonb_typeof(p_payload->'data_domains') <> 'array'
     or jsonb_typeof(p_payload->'required_permissions') <> 'array'
     or jsonb_typeof(p_payload->'files') <> 'array'
     or jsonb_typeof(p_payload->'approvals') <> 'array'
     or jsonb_typeof(p_payload->'legal_documents') <> 'array'
     or jsonb_typeof(p_payload->'regional_profile') <> 'object'
     or jsonb_typeof(p_payload->'voice_policy') <> 'object'
     or jsonb_typeof(p_payload->'retention_policy') <> 'object' then
    return false;
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_payload) then
    return false;
  end if;

  return true;
end;
$$;

revoke all on function public.atlas_manifest_payload_is_valid(jsonb)
  from public, anon, authenticated;
grant execute on function public.atlas_manifest_payload_is_valid(jsonb)
  to service_role;

create table if not exists public.atlas_installation_inventory_definitions (
  inventory_code text primary key,
  display_name text not null,
  description text not null,
  category_code text not null,
  logical_section text not null,
  default_requirement_mode text not null,
  applicability_rule jsonb not null,
  default_security_classification text not null,
  sort_order integer not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_inventory_definitions_code_check
    check (inventory_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_inventory_definitions_category_check
    check (category_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_inventory_definitions_logical_section_check
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
  constraint atlas_inventory_definitions_mode_check
    check (
      default_requirement_mode in (
        'REQUIRED',
        'CONDITIONAL',
        'OPTIONAL',
        'NOT_APPLICABLE'
      )
    ),
  constraint atlas_inventory_definitions_applicability_check
    check (
      jsonb_typeof(applicability_rule) = 'object'
      and applicability_rule <> '{}'::jsonb
      and nullif(btrim(applicability_rule->>'reason'), '') is not null
    ),
  constraint atlas_inventory_definitions_security_check
    check (
      default_security_classification in (
        'PUBLIC',
        'INTERNAL',
        'CONFIDENTIAL',
        'RESTRICTED'
      )
    ),
  constraint atlas_inventory_definitions_order_check
    check (sort_order >= 1),
  constraint atlas_inventory_definitions_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

insert into public.atlas_installation_inventory_definitions (
  inventory_code,
  display_name,
  description,
  category_code,
  logical_section,
  default_requirement_mode,
  applicability_rule,
  default_security_classification,
  sort_order,
  active,
  metadata
)
values
  ('COMPANY_LEGAL_NAME', 'Razon social', 'Nombre legal vigente de la empresa.', 'COMPANY_IDENTITY', 'COMPANY', 'REQUIRED', jsonb_build_object('reason', 'Identifica juridicamente a la empresa.'), 'INTERNAL', 10, true, '{}'::jsonb),
  ('COMPANY_TRADE_NAME', 'Nombre comercial', 'Nombre utilizado frente a clientes.', 'COMPANY_IDENTITY', 'COMPANY', 'REQUIRED', jsonb_build_object('reason', 'Define la identidad comercial visible.'), 'PUBLIC', 20, true, '{}'::jsonb),
  ('TAX_IDENTIFIER', 'Identificacion tributaria', 'Identificacion fiscal cuando corresponda.', 'COMPANY_IDENTITY', 'LEGAL', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando la empresa posee obligacion o registro tributario.', 'condition', 'TAX_REGISTRATION_APPLIES'), 'CONFIDENTIAL', 30, true, '{}'::jsonb),
  ('LOCATION_AND_LOCALE', 'Ubicacion y localizacion', 'Pais, ciudad, zona horaria y moneda.', 'COMPANY_IDENTITY', 'COMPANY', 'REQUIRED', jsonb_build_object('reason', 'Gobierna horarios, moneda y regionalizacion.'), 'INTERNAL', 40, true, '{}'::jsonb),
  ('AUTHORIZED_REPRESENTATIVE_OWNER', 'Representante y OWNER', 'Representante y OWNER autorizado.', 'OWNERSHIP', 'OWNERS_AND_USERS', 'REQUIRED', jsonb_build_object('reason', 'Establece autoridad y responsabilidad verificable.'), 'RESTRICTED', 50, true, '{}'::jsonb),
  ('BUSINESS_CONTACT', 'Contacto empresarial', 'Canales de contacto oficiales.', 'COMPANY_IDENTITY', 'COMPANY', 'REQUIRED', jsonb_build_object('reason', 'Permite notificaciones y coordinacion operacional.'), 'CONFIDENTIAL', 60, true, '{}'::jsonb),
  ('BUSINESS_ACTIVITY', 'Actividad economica', 'Actividad y descripcion del negocio.', 'COMPANY_PROFILE', 'COMPANY', 'REQUIRED', jsonb_build_object('reason', 'Contextualiza reglas, riesgos y alcance.'), 'INTERNAL', 70, true, '{}'::jsonb),
  ('PRODUCTS_SERVICES', 'Productos y servicios', 'Catalogo o fuente canonica equivalente.', 'CATALOG', 'CATALOG', 'REQUIRED', jsonb_build_object('reason', 'Define lo que el agente puede ofrecer.'), 'INTERNAL', 80, true, '{}'::jsonb),
  ('PRICING_TAX_UNITS_VALIDITY', 'Precios, impuestos y vigencias', 'Precios, impuestos, unidades y vigencias aplicables.', 'COMMERCIAL', 'COMMERCIAL_RULES', 'REQUIRED', jsonb_build_object('reason', 'Evita valores inventados o vencidos.'), 'CONFIDENTIAL', 90, true, '{}'::jsonb),
  ('SERVICE_HOURS_ZONES', 'Horarios y zonas', 'Horarios y zonas de atencion.', 'OPERATIONS', 'COMPANY', 'REQUIRED', jsonb_build_object('reason', 'Limita disponibilidad y promesas operativas.'), 'PUBLIC', 100, true, '{}'::jsonb),
  ('COMMERCIAL_POLICIES', 'Politicas comerciales', 'Politicas y prohibiciones comerciales.', 'COMMERCIAL', 'COMMERCIAL_RULES', 'REQUIRED', jsonb_build_object('reason', 'Gobierna decisiones comerciales del agente.'), 'INTERNAL', 110, true, '{}'::jsonb),
  ('PAYMENT_METHODS_TERMS', 'Medios y condiciones de pago', 'Medios, anticipos y condiciones de pago.', 'COMMERCIAL', 'COMMERCIAL_RULES', 'REQUIRED', jsonb_build_object('reason', 'Evita compromisos financieros incorrectos.'), 'CONFIDENTIAL', 120, true, '{}'::jsonb),
  ('CONTRACTED_CHANNELS', 'Canales contratados', 'Canales incluidos en el alcance.', 'CHANNELS', 'CHANNELS', 'REQUIRED', jsonb_build_object('reason', 'Delimita los canales que Atlas debe instalar.'), 'INTERNAL', 130, true, '{}'::jsonb),
  ('FAQ_SERVICE_LIMITS', 'Preguntas y limites', 'Preguntas frecuentes y limites de atencion.', 'KNOWLEDGE', 'KNOWLEDGE', 'REQUIRED', jsonb_build_object('reason', 'Define respuestas autorizadas y escalamiento.'), 'INTERNAL', 140, true, '{}'::jsonb),
  ('AGENT_PERSONALITY_PROFILE', 'Personalidad del agente', 'Tono, formalidad y regionalidad.', 'AGENT', 'PERSONALITY', 'REQUIRED', jsonb_build_object('reason', 'Controla identidad y estilo de comunicacion.'), 'INTERNAL', 150, true, '{}'::jsonb),
  ('INITIAL_USERS_ROLES_PERMISSIONS', 'Usuarios y permisos iniciales', 'Usuarios, roles y permisos iniciales.', 'ACCESS', 'OWNERS_AND_USERS', 'REQUIRED', jsonb_build_object('reason', 'Aplica minimo privilegio desde el aprovisionamiento.'), 'RESTRICTED', 160, true, '{}'::jsonb),
  ('DATA_PRIVACY_POLICY', 'Politica de datos y privacidad', 'Politica aplicable al tratamiento de datos.', 'LEGAL_COMPLIANCE', 'LEGAL', 'REQUIRED', jsonb_build_object('reason', 'Define tratamiento autorizado y obligaciones.'), 'CONFIDENTIAL', 170, true, '{}'::jsonb),
  ('SUPPORT_INCIDENT_CONTACT', 'Contacto de soporte e incidentes', 'Contacto autorizado para soporte e incidentes.', 'OPERATIONS', 'SECURITY', 'REQUIRED', jsonb_build_object('reason', 'Habilita respuesta y escalamiento verificable.'), 'CONFIDENTIAL', 180, true, '{}'::jsonb),
  ('DESIGNATED_APPROVERS', 'Aprobadores designados', 'Personas y roles autorizados para aprobar.', 'APPROVALS', 'APPROVALS', 'REQUIRED', jsonb_build_object('reason', 'Impide aprobaciones por actores no autorizados.'), 'RESTRICTED', 190, true, '{}'::jsonb),
  ('INVENTORY_AVAILABILITY', 'Inventario y disponibilidad', 'Existencias y disponibilidad operativa.', 'OPERATIONS', 'CATALOG', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando se venden bienes o cupos limitados.', 'condition', 'INVENTORY_MANAGED'), 'INTERNAL', 200, true, '{}'::jsonb),
  ('LOCATIONS_WAREHOUSES_COVERAGE', 'Sedes y cobertura', 'Sedes, bodegas y zonas de cobertura.', 'OPERATIONS', 'COMPANY', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica a operaciones con multiples ubicaciones o cobertura.', 'condition', 'MULTI_LOCATION_OR_COVERAGE'), 'INTERNAL', 210, true, '{}'::jsonb),
  ('SCHEDULING_RESERVATIONS', 'Agenda y reservas', 'Agenda, citas, eventos o reservas.', 'OPERATIONS', 'INTEGRATIONS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando el servicio depende de disponibilidad temporal.', 'condition', 'SCHEDULING_ENABLED'), 'CONFIDENTIAL', 220, true, '{}'::jsonb),
  ('LOGISTICS_DELIVERIES', 'Logistica y entregas', 'Entregas, rutas y transportadores.', 'OPERATIONS', 'INTEGRATIONS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando existe despacho o entrega.', 'condition', 'DELIVERY_ENABLED'), 'CONFIDENTIAL', 230, true, '{}'::jsonb),
  ('CRM_PIPELINE', 'CRM y etapas comerciales', 'Clientes, oportunidades y etapas comerciales.', 'COMMERCIAL', 'INTEGRATIONS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando se gestiona un embudo comercial.', 'condition', 'CRM_ENABLED'), 'CONFIDENTIAL', 240, true, '{}'::jsonb),
  ('DISCOUNTS_PROMOTIONS_AUTHORIZATIONS', 'Descuentos y promociones', 'Reglas, promociones y autorizaciones.', 'COMMERCIAL', 'COMMERCIAL_RULES', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando existen descuentos o excepciones.', 'condition', 'DISCOUNTS_ENABLED'), 'CONFIDENTIAL', 250, true, '{}'::jsonb),
  ('QUOTES_AND_TEMPLATES', 'Cotizaciones y plantillas', 'Reglas y plantillas de cotizacion.', 'COMMERCIAL', 'TEMPLATES', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando Atlas genera cotizaciones.', 'condition', 'QUOTING_ENABLED'), 'CONFIDENTIAL', 260, true, '{}'::jsonb),
  ('BILLING_AND_TAXES', 'Facturacion e impuestos', 'Reglas e integraciones de facturacion.', 'FINANCE', 'INTEGRATIONS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando Atlas participa en facturacion.', 'condition', 'BILLING_ENABLED'), 'RESTRICTED', 270, true, '{}'::jsonb),
  ('HUMAN_RESOURCES', 'Recursos humanos', 'Datos y procesos de personal.', 'PEOPLE', 'OWNERS_AND_USERS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando se contratan capacidades de RRHH.', 'condition', 'HR_CAPABILITY_ENABLED'), 'RESTRICTED', 280, true, '{}'::jsonb),
  ('SUPPLIERS_AND_PURCHASES', 'Proveedores y compras', 'Proveedores, abastecimiento y compras.', 'OPERATIONS', 'INTEGRATIONS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando el alcance incluye abastecimiento.', 'condition', 'PROCUREMENT_ENABLED'), 'CONFIDENTIAL', 290, true, '{}'::jsonb),
  ('MEDIA_TECHNICAL_DOCUMENTS', 'Imagenes y fichas tecnicas', 'Medios, fichas y documentos de producto.', 'CATALOG', 'CATALOG', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando productos requieren activos visuales o tecnicos.', 'condition', 'CATALOG_MEDIA_REQUIRED'), 'INTERNAL', 300, true, '{}'::jsonb),
  ('HISTORICAL_DATA_MIGRATION', 'Datos historicos', 'Datos existentes que deben migrarse.', 'DATA', 'KNOWLEDGE', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando el contrato incluye migracion.', 'condition', 'DATA_MIGRATION_INCLUDED'), 'RESTRICTED', 310, true, '{}'::jsonb),
  ('API_WEBHOOK_INTEGRATIONS', 'Integraciones API y webhook', 'Endpoints, contratos y referencias seguras.', 'INTEGRATIONS', 'INTEGRATIONS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica a capacidades conectadas con terceros.', 'condition', 'API_INTEGRATION_ENABLED'), 'RESTRICTED', 320, true, '{}'::jsonb),
  ('WHATSAPP_META_BUSINESS', 'WhatsApp y Meta Business', 'Activos y configuracion de WhatsApp Business.', 'CHANNELS', 'CHANNELS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando WhatsApp es un canal contratado.', 'condition', 'WHATSAPP_ENABLED'), 'RESTRICTED', 330, true, '{}'::jsonb),
  ('EMAIL_AND_CALENDAR', 'Email y calendario', 'Cuentas y reglas de correo/calendario.', 'CHANNELS', 'INTEGRATIONS', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando se contratan correo o calendario.', 'condition', 'EMAIL_OR_CALENDAR_ENABLED'), 'RESTRICTED', 340, true, '{}'::jsonb),
  ('VOICE_CALLS_CONSENTS', 'Voz, llamadas y consentimientos', 'Politicas, guiones y consentimientos de voz.', 'CHANNELS', 'VOICE', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando se contratan voz o llamadas.', 'condition', 'VOICE_OR_CALLS_ENABLED'), 'RESTRICTED', 350, true, '{}'::jsonb),
  ('SECTOR_REGULATIONS', 'Regulacion sectorial', 'Obligaciones propias del sector.', 'LEGAL_COMPLIANCE', 'LEGAL', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica a sectores regulados.', 'condition', 'SECTOR_REGULATION_APPLIES'), 'RESTRICTED', 360, true, '{}'::jsonb),
  ('SENSITIVE_OR_MINOR_DATA', 'Datos sensibles o de menores', 'Tratamiento especial para datos sensibles o de menores.', 'LEGAL_COMPLIANCE', 'SECURITY', 'CONDITIONAL', jsonb_build_object('reason', 'Aplica cuando el tratamiento incluye categorias especiales.', 'condition', 'SPECIAL_CATEGORY_DATA_PRESENT'), 'RESTRICTED', 370, true, '{}'::jsonb)
on conflict (inventory_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  category_code = excluded.category_code,
  logical_section = excluded.logical_section,
  default_requirement_mode = excluded.default_requirement_mode,
  applicability_rule = excluded.applicability_rule,
  default_security_classification = excluded.default_security_classification,
  sort_order = excluded.sort_order,
  active = excluded.active,
  metadata = excluded.metadata,
  updated_at = now();

create table if not exists public.atlas_installation_manifests (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  package_id uuid not null,
  package_version integer not null,
  manifest_version text not null,
  source_file_id uuid not null,
  manifest_status text not null default 'RECEIVED',
  manifest_payload jsonb not null,
  manifest_sha256 text not null,
  created_by_user_id uuid not null,
  idempotency_key uuid not null,
  approved_by_user_id uuid,
  approved_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_manifests_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_installation_manifests_package_version_key
    unique (installation_id, package_id, package_version),
  constraint atlas_installation_manifests_hash_key
    unique (installation_id, manifest_sha256),
  constraint atlas_installation_manifests_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_manifests_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_manifests_source_file_fkey
    foreign key (source_file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_installation_manifests_created_by_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_manifests_approved_by_fkey
    foreign key (approved_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_manifests_package_version_check
    check (package_version >= 1),
  constraint atlas_installation_manifests_version_check
    check (manifest_version ~ '^B2_V[0-9]+$'),
  constraint atlas_installation_manifests_status_check
    check (
      manifest_status in (
        'RECEIVED',
        'VALIDATED',
        'APPROVED',
        'REJECTED',
        'SUPERSEDED'
      )
    ),
  constraint atlas_installation_manifests_payload_check
    check (public.atlas_manifest_payload_is_valid(manifest_payload)),
  constraint atlas_installation_manifests_payload_identity_check
    check (
      manifest_payload->>'installation_id' = installation_id::text
      and manifest_payload->>'package_id' = package_id::text
      and manifest_payload->>'package_version' = package_version::text
      and manifest_payload->>'manifest_version' = manifest_version
    ),
  constraint atlas_installation_manifests_sha256_check
    check (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_installation_manifests_approval_check
    check (
      (
        manifest_status = 'APPROVED'
        and approved_by_user_id is not null
        and approved_at is not null
      )
      or (
        manifest_status <> 'APPROVED'
        and approved_by_user_id is null
        and approved_at is null
      )
    ),
  constraint atlas_installation_manifests_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create table if not exists public.atlas_installation_manifest_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  manifest_id uuid not null,
  event_code text not null,
  from_manifest_status text,
  to_manifest_status text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  reason text,
  request_id uuid not null,
  package_version integer not null,
  manifest_sha256 text not null,
  evidence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_manifest_events_request_key
    unique (manifest_id, request_id),
  constraint atlas_manifest_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_manifest_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_manifest_events_manifest_fkey
    foreign key (manifest_id)
    references public.atlas_installation_manifests(id)
    on delete restrict,
  constraint atlas_manifest_events_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_manifest_events_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_manifest_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_manifest_events_from_status_check
    check (
      from_manifest_status is null
      or from_manifest_status in (
        'RECEIVED',
        'VALIDATED',
        'APPROVED',
        'REJECTED',
        'SUPERSEDED'
      )
    ),
  constraint atlas_manifest_events_to_status_check
    check (
      to_manifest_status in (
        'RECEIVED',
        'VALIDATED',
        'APPROVED',
        'REJECTED',
        'SUPERSEDED'
      )
    ),
  constraint atlas_manifest_events_package_version_check
    check (package_version >= 1),
  constraint atlas_manifest_events_sha256_check
    check (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_manifest_events_evidence_check
    check (jsonb_typeof(evidence) = 'object'),
  constraint atlas_manifest_events_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create table if not exists public.atlas_installation_inventory_requirements (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  inventory_code text not null,
  requirement_mode text not null,
  determination_reason text not null,
  determination_source text not null,
  fulfillment_status text not null default 'PENDING',
  current_file_id uuid,
  canonical_value_reference text,
  requirement_version integer not null default 1,
  determined_by_user_id uuid not null,
  approved_by_user_id uuid,
  approved_at timestamptz,
  idempotency_key uuid not null,
  rule_snapshot jsonb not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_inventory_requirements_installation_code_key
    unique (installation_id, inventory_code),
  constraint atlas_inventory_requirements_request_key
    unique (installation_id, inventory_code, idempotency_key),
  constraint atlas_inventory_requirements_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_inventory_requirements_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_inventory_requirements_definition_fkey
    foreign key (inventory_code)
    references public.atlas_installation_inventory_definitions(inventory_code)
    on delete restrict,
  constraint atlas_inventory_requirements_file_fkey
    foreign key (current_file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_inventory_requirements_determined_by_fkey
    foreign key (determined_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_inventory_requirements_approved_by_fkey
    foreign key (approved_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_inventory_requirements_mode_check
    check (
      requirement_mode in (
        'REQUIRED',
        'CONDITIONAL',
        'OPTIONAL',
        'NOT_APPLICABLE'
      )
    ),
  constraint atlas_inventory_requirements_reason_check
    check (length(btrim(determination_reason)) >= 5),
  constraint atlas_inventory_requirements_source_check
    check (
      determination_source in (
        'PLATFORM_DEFAULT',
        'DIAGNOSTIC',
        'CONTRACT',
        'CAPABILITY',
        'RISK_REVIEW',
        'MANUAL_OVERRIDE'
      )
    ),
  constraint atlas_inventory_requirements_fulfillment_check
    check (
      fulfillment_status in (
        'PENDING',
        'PROVIDED',
        'VALIDATED',
        'WAIVED',
        'NOT_APPLICABLE'
      )
    ),
  constraint atlas_inventory_requirements_mode_fulfillment_check
    check (
      (
        requirement_mode = 'NOT_APPLICABLE'
        and fulfillment_status = 'NOT_APPLICABLE'
      )
      or (
        requirement_mode <> 'NOT_APPLICABLE'
        and fulfillment_status <> 'NOT_APPLICABLE'
      )
    ),
  constraint atlas_inventory_requirements_required_not_waived_check
    check (
      requirement_mode <> 'REQUIRED'
      or fulfillment_status <> 'WAIVED'
    ),
  constraint atlas_inventory_requirements_version_check
    check (requirement_version >= 1),
  constraint atlas_inventory_requirements_approval_check
    check (
      (approved_by_user_id is null and approved_at is null)
      or (approved_by_user_id is not null and approved_at is not null)
    ),
  constraint atlas_inventory_requirements_rule_snapshot_check
    check (
      jsonb_typeof(rule_snapshot) = 'object'
      and rule_snapshot <> '{}'::jsonb
    ),
  constraint atlas_inventory_requirements_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create table if not exists public.atlas_installation_inventory_events (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  requirement_id uuid not null,
  inventory_code text not null,
  event_code text not null,
  from_requirement_mode text,
  to_requirement_mode text not null,
  from_fulfillment_status text,
  to_fulfillment_status text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  reason text not null,
  request_id uuid not null,
  requirement_version integer not null,
  evidence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_inventory_events_request_key
    unique (requirement_id, request_id),
  constraint atlas_inventory_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_inventory_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_inventory_events_requirement_fkey
    foreign key (requirement_id)
    references public.atlas_installation_inventory_requirements(id)
    on delete restrict,
  constraint atlas_inventory_events_definition_fkey
    foreign key (inventory_code)
    references public.atlas_installation_inventory_definitions(inventory_code)
    on delete restrict,
  constraint atlas_inventory_events_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_inventory_events_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_inventory_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_inventory_events_modes_check
    check (
      to_requirement_mode in (
        'REQUIRED',
        'CONDITIONAL',
        'OPTIONAL',
        'NOT_APPLICABLE'
      )
      and (
        from_requirement_mode is null
        or from_requirement_mode in (
          'REQUIRED',
          'CONDITIONAL',
          'OPTIONAL',
          'NOT_APPLICABLE'
        )
      )
    ),
  constraint atlas_inventory_events_fulfillment_check
    check (
      to_fulfillment_status in (
        'PENDING',
        'PROVIDED',
        'VALIDATED',
        'WAIVED',
        'NOT_APPLICABLE'
      )
      and (
        from_fulfillment_status is null
        or from_fulfillment_status in (
          'PENDING',
          'PROVIDED',
          'VALIDATED',
          'WAIVED',
          'NOT_APPLICABLE'
        )
      )
    ),
  constraint atlas_inventory_events_reason_check
    check (length(btrim(reason)) >= 5),
  constraint atlas_inventory_events_version_check
    check (requirement_version >= 1),
  constraint atlas_inventory_events_evidence_check
    check (jsonb_typeof(evidence) = 'object'),
  constraint atlas_inventory_events_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_atlas_manifests_installation_status
  on public.atlas_installation_manifests (
    installation_id,
    manifest_status,
    package_version desc
  );

create index if not exists idx_atlas_manifest_events_timeline
  on public.atlas_installation_manifest_events (
    installation_id,
    manifest_id,
    created_at desc
  );

create index if not exists idx_atlas_inventory_requirements_status
  on public.atlas_installation_inventory_requirements (
    installation_id,
    requirement_mode,
    fulfillment_status
  );

create index if not exists idx_atlas_inventory_events_timeline
  on public.atlas_installation_inventory_events (
    installation_id,
    requirement_id,
    created_at desc
  );

create or replace function public.atlas_block_manifest_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_MANIFEST_EVENTS_APPEND_ONLY';
end;
$$;

create or replace function public.atlas_block_inventory_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_INVENTORY_EVENTS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_manifest_event_mutation()
  from public, anon, authenticated;
revoke all on function public.atlas_block_inventory_event_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_manifest_event_mutation()
  to service_role;
grant execute on function public.atlas_block_inventory_event_mutation()
  to service_role;

drop trigger if exists trg_atlas_manifest_events_append_only
  on public.atlas_installation_manifest_events;
create trigger trg_atlas_manifest_events_append_only
before update or delete on public.atlas_installation_manifest_events
for each row execute function public.atlas_block_manifest_event_mutation();

drop trigger if exists trg_atlas_inventory_events_append_only
  on public.atlas_installation_inventory_events;
create trigger trg_atlas_inventory_events_append_only
before update or delete on public.atlas_installation_inventory_events
for each row execute function public.atlas_block_inventory_event_mutation();

drop trigger if exists trg_atlas_inventory_definitions_updated_at
  on public.atlas_installation_inventory_definitions;
create trigger trg_atlas_inventory_definitions_updated_at
before update on public.atlas_installation_inventory_definitions
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_installation_manifests_updated_at
  on public.atlas_installation_manifests;
create trigger trg_atlas_installation_manifests_updated_at
before update on public.atlas_installation_manifests
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_inventory_requirements_updated_at
  on public.atlas_installation_inventory_requirements;
create trigger trg_atlas_inventory_requirements_updated_at
before update on public.atlas_installation_inventory_requirements
for each row execute function public.atlas_set_updated_at();

alter table public.atlas_installation_inventory_definitions
  enable row level security;
alter table public.atlas_installation_manifests
  enable row level security;
alter table public.atlas_installation_manifest_events
  enable row level security;
alter table public.atlas_installation_inventory_requirements
  enable row level security;
alter table public.atlas_installation_inventory_events
  enable row level security;

revoke all on table public.atlas_installation_inventory_definitions
  from anon, authenticated;
revoke all on table public.atlas_installation_manifests
  from anon, authenticated;
revoke all on table public.atlas_installation_manifest_events
  from anon, authenticated;
revoke all on table public.atlas_installation_inventory_requirements
  from anon, authenticated;
revoke all on table public.atlas_installation_inventory_events
  from anon, authenticated;

grant select on table public.atlas_installation_inventory_definitions
  to authenticated;
grant select on table public.atlas_installation_manifests
  to authenticated;
grant select on table public.atlas_installation_manifest_events
  to authenticated;
grant select on table public.atlas_installation_inventory_requirements
  to authenticated;
grant select on table public.atlas_installation_inventory_events
  to authenticated;

grant all on table public.atlas_installation_inventory_definitions
  to service_role;
grant all on table public.atlas_installation_manifests
  to service_role;
grant all on table public.atlas_installation_manifest_events
  to service_role;
grant all on table public.atlas_installation_inventory_requirements
  to service_role;
grant all on table public.atlas_installation_inventory_events
  to service_role;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_inventory_definitions'
      and policyname = 'atlas_inventory_definitions_read'
  ) then
    execute $policy$
      create policy atlas_inventory_definitions_read
        on public.atlas_installation_inventory_definitions
        for select to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_manifests'
      and policyname = 'atlas_installation_manifests_read'
  ) then
    execute $policy$
      create policy atlas_installation_manifests_read
        on public.atlas_installation_manifests
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_manifest_events'
      and policyname = 'atlas_manifest_events_read'
  ) then
    execute $policy$
      create policy atlas_manifest_events_read
        on public.atlas_installation_manifest_events
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_inventory_requirements'
      and policyname = 'atlas_inventory_requirements_read'
  ) then
    execute $policy$
      create policy atlas_inventory_requirements_read
        on public.atlas_installation_inventory_requirements
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_inventory_events'
      and policyname = 'atlas_inventory_events_read'
  ) then
    execute $policy$
      create policy atlas_inventory_events_read
        on public.atlas_installation_inventory_events
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

comment on function public.atlas_jsonb_has_forbidden_secret_key(jsonb) is
  'B2: detecta recursivamente claves de secretos que no pertenecen al manifest.';

comment on function public.atlas_manifest_payload_is_valid(jsonb) is
  'B2: valida la forma minima, identidad, tipos y ausencia de secretos del manifest B2.';

comment on table public.atlas_installation_inventory_definitions is
  'B2: catalogo canonico de informacion obligatoria y condicionada.';

comment on table public.atlas_installation_manifests is
  'B2: manifests versionados asociados a un archivo fuente ACCEPTED.';

comment on table public.atlas_installation_manifest_events is
  'B2: trazabilidad append-only del ciclo de vida de manifests.';

comment on table public.atlas_installation_inventory_requirements is
  'B2: determinacion explicada de requisitos por expediente.';

comment on table public.atlas_installation_inventory_events is
  'B2: trazabilidad append-only de cambios del inventario condicionado.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2D1_MANIFEST_INVENTORY_CORE_INSTALLED',
  'next_block', 'B2.2D.2_MANIFEST_REGISTRATION_AND_INVENTORY_MATERIALIZATION_RPCS',
  'inventory_definitions', (
    select count(*)
    from public.atlas_installation_inventory_definitions
    where active = true
  ),
  'default_required', (
    select count(*)
    from public.atlas_installation_inventory_definitions
    where active = true
      and default_requirement_mode = 'REQUIRED'
  ),
  'default_conditional', (
    select count(*)
    from public.atlas_installation_inventory_definitions
    where active = true
      and default_requirement_mode = 'CONDITIONAL'
  ),
  'manifest_logical_section_enabled', true,
  'manifest_records', (
    select count(*)
    from public.atlas_installation_manifests
  ),
  'inventory_requirement_records', (
    select count(*)
    from public.atlas_installation_inventory_requirements
  ),
  'manifest_write_rpcs', 0,
  'inventory_write_rpcs', 0,
  'rls_tables', 5,
  'append_only_event_tables', 2,
  'manifest_secret_guard_enabled', true,
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
