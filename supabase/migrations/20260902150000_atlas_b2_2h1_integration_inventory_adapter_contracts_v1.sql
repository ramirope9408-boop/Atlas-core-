-- ATLAS B2.2H.1
-- Inventario de integraciones y contratos de adaptadores.
-- Corte: 2026-09-02
--
-- Alcance deliberado:
-- - cataloga adaptadores reemplazables y sus capacidades;
-- - instala el inventario versionado de integraciones por instalacion;
-- - conserva eventos tecnicos append-only sin secretos;
-- - solo admite referencias opacas a gestores de credenciales;
-- - no conecta proveedores, no prueba canales y no mueve FingerFood.

begin;

do $$
begin
  if to_regclass('public.atlas_installations') is null
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
       'public.atlas_set_updated_at()'
     ) is null
     or to_regprocedure(
       'public.atlas_get_installation_certificate_readiness(uuid)'
     ) is null then
    raise exception
      'B2.2H.1 requiere B2.2G.4C instalado y certificado';
  end if;

  if to_regclass('public.atlas_installation_integrations') is not null
     or to_regclass(
       'public.atlas_integration_adapter_definitions'
     ) is not null
     or to_regclass(
       'public.atlas_installation_integration_events'
     ) is not null then
    raise exception
      'B2.2H.1 detecto estructuras de integracion previas; reconciliar antes de instalar';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_INTEGRATION_READ',
    'Consultar contratos, inventario y eventos internos de integraciones.'
  ),
  (
    'INSTALLATION_INTEGRATION_MANAGE',
    'Declarar y configurar integraciones mediante RPC gobernada.'
  ),
  (
    'INSTALLATION_INTEGRATION_VALIDATE',
    'Ejecutar y registrar validaciones tecnicas de integraciones.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_INTEGRATION_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_INTEGRATION_MANAGE'),
  ('ATLAS_OWNER', 'INSTALLATION_INTEGRATION_VALIDATE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_INTEGRATION_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_INTEGRATION_MANAGE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_INTEGRATION_VALIDATE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_INTEGRATION_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_INTEGRATION_VALIDATE')
on conflict (role_code, permission_code) do nothing;

create or replace function
public.atlas_integration_reference_is_safe(
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
      '^(vault|n8n-credential|platform-secret|external-secret)://[A-Za-z0-9][A-Za-z0-9._:/-]+$'
    and lower(p_reference) !~
      '(token|secret|password|credential|api[_-]?key|authorization|bearer)[/:_-][^/]+$'
$$;

revoke all on function
public.atlas_integration_reference_is_safe(text)
from public, anon, authenticated;
grant execute on function
public.atlas_integration_reference_is_safe(text)
to service_role;

create table public.atlas_integration_adapter_definitions (
  adapter_code text primary key,
  display_name text not null,
  description text not null,
  integration_group text not null,
  provider_family text not null,
  adapter_contract_version text not null,
  execution_boundary text not null,
  capabilities text[] not null,
  authentication_modes text[] not null,
  ownership_modes text[] not null,
  credential_reference_required boolean not null default true,
  healthcheck_required boolean not null default true,
  end_to_end_test_required boolean not null default true,
  compensation_strategy text not null,
  configuration_contract jsonb not null,
  verification_contract jsonb not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_integration_adapters_code_check
    check (adapter_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_integration_adapters_name_check
    check (length(btrim(display_name)) between 3 and 120),
  constraint atlas_integration_adapters_description_check
    check (length(btrim(description)) >= 20),
  constraint atlas_integration_adapters_group_check
    check (
      integration_group in (
        'DATABASE', 'STORAGE', 'CHANNEL', 'ORCHESTRATION',
        'COMMUNICATION', 'AI', 'VOICE', 'BILLING'
      )
    ),
  constraint atlas_integration_adapters_provider_check
    check (provider_family ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_integration_adapters_version_check
    check (adapter_contract_version ~ '^B2_[A-Z0-9_]+_V[0-9]+$'),
  constraint atlas_integration_adapters_boundary_check
    check (
      execution_boundary in (
        'DATABASE_ADAPTER_PORT', 'STORAGE_ADAPTER_PORT',
        'CHANNEL_ADAPTER_PORT', 'ORCHESTRATOR_ADAPTER_PORT',
        'COMMUNICATION_ADAPTER_PORT', 'AI_ADAPTER_PORT',
        'VOICE_ADAPTER_PORT', 'BILLING_ADAPTER_PORT'
      )
    ),
  constraint atlas_integration_adapters_capabilities_check
    check (
      cardinality(capabilities) >= 1
      and coalesce(array_to_string(capabilities, ','), '')
        ~ '^[A-Z][A-Z0-9_]*(,[A-Z][A-Z0-9_]*)*$'
    ),
  constraint atlas_integration_adapters_auth_check
    check (
      cardinality(authentication_modes) >= 1
      and authentication_modes <@ array[
        'API_TOKEN', 'OAUTH2', 'SERVICE_ACCOUNT',
        'CONNECTION_REFERENCE', 'SIGNED_WEBHOOK', 'NONE'
      ]::text[]
      and (
        credential_reference_required
        or 'NONE' = any(authentication_modes)
      )
    ),
  constraint atlas_integration_adapters_ownership_check
    check (
      cardinality(ownership_modes) >= 1
      and ownership_modes <@ array[
        'CLIENT_OWNED', 'ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'
      ]::text[]
    ),
  constraint atlas_integration_adapters_compensation_check
    check (
      compensation_strategy in (
        'DISCONNECT_AND_REVOKE', 'RESTORE_PREVIOUS_REFERENCE',
        'DISABLE_AND_REVIEW', 'MANUAL_REVIEW_REQUIRED'
      )
    ),
  constraint atlas_integration_adapters_contract_check
    check (
      jsonb_typeof(configuration_contract) = 'object'
      and configuration_contract <> '{}'::jsonb
      and jsonb_typeof(verification_contract) = 'object'
      and verification_contract <> '{}'::jsonb
      and not public.atlas_jsonb_has_forbidden_secret_key(
        configuration_contract
      )
      and not public.atlas_jsonb_has_forbidden_secret_key(
        verification_contract
      )
    ),
  constraint atlas_integration_adapters_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_integration_adapter_definitions (
  adapter_code, display_name, description, integration_group,
  provider_family, adapter_contract_version, execution_boundary,
  capabilities, authentication_modes, ownership_modes,
  credential_reference_required, healthcheck_required,
  end_to_end_test_required, compensation_strategy,
  configuration_contract, verification_contract, active, metadata
)
values
  (
    'SUPABASE_POSTGRES', 'Supabase PostgreSQL',
    'Adaptador de datos transaccionales, RPC, RLS y eventos del tenant.',
    'DATABASE', 'SUPABASE', 'B2_SUPABASE_POSTGRES_V1',
    'DATABASE_ADAPTER_PORT',
    array['DATABASE', 'RPC', 'RLS', 'REALTIME'],
    array['CONNECTION_REFERENCE', 'SERVICE_ACCOUNT'],
    array['ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'],
    true, true, true, 'MANUAL_REVIEW_REQUIRED',
    jsonb_build_object(
      'requires', jsonb_build_array(
        'project_reference', 'region', 'schema_contract'
      )
    ),
    jsonb_build_object(
      'asserts', jsonb_build_array(
        'CONNECTION_AVAILABLE', 'RLS_ENABLED', 'RPC_CONTRACT_VALID'
      )
    ), true, '{}'::jsonb
  ),
  (
    'SUPABASE_STORAGE', 'Supabase Storage',
    'Adaptador de almacenamiento privado, rutas aisladas y URLs firmadas.',
    'STORAGE', 'SUPABASE', 'B2_SUPABASE_STORAGE_V1',
    'STORAGE_ADAPTER_PORT',
    array['PRIVATE_STORAGE', 'PUBLIC_STORAGE', 'SIGNED_URLS'],
    array['CONNECTION_REFERENCE', 'SERVICE_ACCOUNT'],
    array['ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'],
    true, true, true, 'MANUAL_REVIEW_REQUIRED',
    jsonb_build_object(
      'requires', jsonb_build_array(
        'project_reference', 'bucket_reference', 'tenant_path_contract'
      )
    ),
    jsonb_build_object(
      'asserts', jsonb_build_array(
        'PRIVATE_BUCKET', 'TENANT_PATH_ISOLATED', 'DELETE_POLICY_GOVERNED'
      )
    ), true, '{}'::jsonb
  ),
  (
    'META_WHATSAPP_CLOUD', 'Meta WhatsApp Cloud',
    'Adaptador reemplazable para mensajeria, webhooks y medios de WhatsApp.',
    'CHANNEL', 'META', 'B2_META_WHATSAPP_CLOUD_V1',
    'CHANNEL_ADAPTER_PORT',
    array[
      'INBOUND_MESSAGE', 'OUTBOUND_MESSAGE',
      'MEDIA_DOWNLOAD', 'WEBHOOK'
    ],
    array['API_TOKEN', 'SIGNED_WEBHOOK'],
    array['CLIENT_OWNED', 'SHARED_RESPONSIBILITY'],
    true, true, true, 'DISCONNECT_AND_REVOKE',
    jsonb_build_object(
      'requires', jsonb_build_array(
        'business_account_reference', 'phone_number_reference',
        'webhook_reference'
      )
    ),
    jsonb_build_object(
      'asserts', jsonb_build_array(
        'WEBHOOK_VERIFIED', 'INBOUND_MESSAGE_OK',
        'OUTBOUND_MESSAGE_OK', 'MEDIA_ACCESS_OK'
      )
    ), true, '{}'::jsonb
  ),
  (
    'N8N_ORCHESTRATOR', 'n8n Orchestrator',
    'Adaptador sustituible para ejecucion, reintentos y auditoria de flujos.',
    'ORCHESTRATION', 'N8N', 'B2_N8N_ORCHESTRATOR_V1',
    'ORCHESTRATOR_ADAPTER_PORT',
    array['WORKFLOW_EXECUTION', 'WEBHOOK', 'RETRY', 'AUDIT'],
    array['API_TOKEN', 'CONNECTION_REFERENCE'],
    array['ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'],
    true, true, true, 'DISABLE_AND_REVIEW',
    jsonb_build_object(
      'requires', jsonb_build_array(
        'workspace_reference', 'workflow_references', 'execution_policy'
      )
    ),
    jsonb_build_object(
      'asserts', jsonb_build_array(
        'WORKFLOWS_ACTIVE', 'RETRY_POLICY_VALID', 'EXECUTION_AUDIT_AVAILABLE'
      )
    ), true, '{}'::jsonb
  ),
  (
    'SMTP_EMAIL', 'Correo SMTP',
    'Adaptador sustituible para entrega transaccional de correo electronico.',
    'COMMUNICATION', 'GENERIC_SMTP', 'B2_SMTP_EMAIL_V1',
    'COMMUNICATION_ADAPTER_PORT',
    array['OUTBOUND_EMAIL', 'DELIVERY_STATUS'],
    array['CONNECTION_REFERENCE', 'OAUTH2'],
    array[
      'CLIENT_OWNED', 'ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'
    ],
    true, true, true, 'DISCONNECT_AND_REVOKE',
    jsonb_build_object(
      'requires', jsonb_build_array(
        'sender_reference', 'transport_reference', 'delivery_policy'
      )
    ),
    jsonb_build_object(
      'asserts', jsonb_build_array(
        'SENDER_AUTHORIZED', 'OUTBOUND_DELIVERY_OK'
      )
    ), true, '{}'::jsonb
  ),
  (
    'OPENAI_AI', 'OpenAI AI',
    'Adaptador sustituible para razonamiento, embeddings y transcripcion.',
    'AI', 'OPENAI', 'B2_OPENAI_AI_V1', 'AI_ADAPTER_PORT',
    array['CHAT_COMPLETION', 'EMBEDDINGS', 'TRANSCRIPTION'],
    array['API_TOKEN', 'CONNECTION_REFERENCE'],
    array['ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'],
    true, true, true, 'DISABLE_AND_REVIEW',
    jsonb_build_object(
      'requires', jsonb_build_array(
        'provider_account_reference', 'model_policy', 'usage_policy'
      )
    ),
    jsonb_build_object(
      'asserts', jsonb_build_array(
        'MODEL_AVAILABLE', 'POLICY_APPLIED', 'CONTROLLED_REQUEST_OK'
      )
    ), true, '{}'::jsonb
  ),
  (
    'GENERIC_VOICE', 'Proveedor de voz',
    'Contrato futuro para voz, sintesis, transcripcion y llamadas certificadas.',
    'VOICE', 'GENERIC_VOICE', 'B2_GENERIC_VOICE_V1',
    'VOICE_ADAPTER_PORT',
    array['TEXT_TO_SPEECH', 'SPEECH_TO_TEXT', 'VOICE_CALL'],
    array['API_TOKEN', 'CONNECTION_REFERENCE'],
    array[
      'CLIENT_OWNED', 'ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'
    ],
    true, true, true, 'DISCONNECT_AND_REVOKE',
    jsonb_build_object(
      'requires', jsonb_build_array(
        'provider_account_reference', 'voice_profile_reference'
      )
    ),
    jsonb_build_object(
      'asserts', jsonb_build_array(
        'VOICE_PROFILE_AUTHORIZED', 'CONTROLLED_AUDIO_TEST_OK'
      )
    ), false, jsonb_build_object('activation', 'WHEN_CONTRACTED_AND_CERTIFIED')
  ),
  (
    'ATLAS_PAY', 'Atlas Pay',
    'Contrato futuro para pagos y facturacion cuando Atlas Pay este listo.',
    'BILLING', 'ATLAS_PAY', 'B2_ATLAS_PAY_V1',
    'BILLING_ADAPTER_PORT',
    array['PAYMENT_STATUS', 'BILLING_EVENT'],
    array['API_TOKEN', 'SIGNED_WEBHOOK'],
    array['ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'],
    true, true, true, 'DISCONNECT_AND_REVOKE',
    jsonb_build_object(
      'requires', jsonb_build_array(
        'merchant_reference', 'billing_policy_reference'
      )
    ),
    jsonb_build_object(
      'asserts', jsonb_build_array(
        'MERCHANT_AUTHORIZED', 'SIGNED_EVENT_VALID'
      )
    ), false, jsonb_build_object('activation', 'WHEN_ATLAS_PAY_READY')
  );

do $$
begin
  if (
    select count(*)
    from public.atlas_integration_adapter_definitions
  ) <> 8 then
    raise exception 'B2.2H.1 requiere 8 adaptadores canonicos';
  end if;

  if (
    select count(*)
    from public.atlas_integration_adapter_definitions
    where active
  ) <> 6 then
    raise exception 'B2.2H.1 requiere 6 adaptadores activos iniciales';
  end if;

  if exists (
    select 1
    from public.atlas_integration_adapter_definitions
    where execution_boundary !~ '_ADAPTER_PORT$'
  ) then
    raise exception 'B2.2H.1 todos los proveedores requieren frontera de adaptador';
  end if;
end;
$$;

create table public.atlas_installation_integrations (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  adapter_code text not null,
  integration_code text not null,
  display_name text not null,
  environment text not null,
  ownership_type text not null,
  lifecycle_status text not null default 'DECLARED',
  state_version bigint not null default 1,
  required_capabilities text[] not null,
  credential_authority text,
  credential_reference text,
  credential_reference_sha256 text,
  external_identity_sha256 text,
  non_secret_configuration jsonb not null default '{}'::jsonb,
  configuration_sha256 text,
  last_health_status text not null default 'UNKNOWN',
  last_health_checked_at timestamptz,
  declared_by_user_id uuid not null,
  idempotency_key uuid not null,
  configured_at timestamptz,
  validation_started_at timestamptz,
  validated_at timestamptz,
  disabled_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_integrations_code_key
    unique (installation_id, integration_code),
  constraint atlas_installation_integrations_request_key
    unique (installation_id, idempotency_key),
  constraint atlas_installation_integrations_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_integrations_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_integrations_adapter_fkey
    foreign key (adapter_code)
    references public.atlas_integration_adapter_definitions(adapter_code)
    on delete restrict,
  constraint atlas_installation_integrations_actor_fkey
    foreign key (declared_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_integrations_code_check
    check (
      integration_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(integration_code) between 3 and 100
    ),
  constraint atlas_installation_integrations_name_check
    check (length(btrim(display_name)) between 3 and 160),
  constraint atlas_installation_integrations_environment_check
    check (environment in ('PRODUCTION', 'SANDBOX', 'TEST')),
  constraint atlas_installation_integrations_ownership_check
    check (
      ownership_type in (
        'CLIENT_OWNED', 'ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'
      )
    ),
  constraint atlas_installation_integrations_status_check
    check (
      lifecycle_status in (
        'DECLARED', 'CONFIGURATION_PENDING', 'CONFIGURED',
        'VALIDATION_PENDING', 'VALIDATED', 'FAILED',
        'DISABLED', 'REVOKED'
      )
    ),
  constraint atlas_installation_integrations_version_check
    check (state_version >= 1),
  constraint atlas_installation_integrations_capabilities_check
    check (
      cardinality(required_capabilities) >= 1
      and coalesce(array_to_string(required_capabilities, ','), '')
        ~ '^[A-Z][A-Z0-9_]*(,[A-Z][A-Z0-9_]*)*$'
    ),
  constraint atlas_installation_integrations_credential_pair_check
    check (
      (
        credential_authority is null
        and credential_reference is null
        and credential_reference_sha256 is null
      )
      or (
        credential_authority in (
          'SUPABASE_VAULT', 'N8N_CREDENTIAL_STORE',
          'PLATFORM_SECRET_MANAGER', 'EXTERNAL_VAULT'
        )
        and credential_reference is not null
        and public.atlas_integration_reference_is_safe(
          credential_reference
        )
        and credential_reference_sha256 ~ '^[0-9a-f]{64}$'
      )
    ),
  constraint atlas_installation_integrations_hash_check
    check (
      (
        external_identity_sha256 is null
        or external_identity_sha256 ~ '^[0-9a-f]{64}$'
      )
      and (
        configuration_sha256 is null
        or configuration_sha256 ~ '^[0-9a-f]{64}$'
      )
    ),
  constraint atlas_installation_integrations_configuration_check
    check (
      jsonb_typeof(non_secret_configuration) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(
        non_secret_configuration
      )
      and jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    ),
  constraint atlas_installation_integrations_health_check
    check (
      last_health_status in (
        'UNKNOWN', 'HEALTHY', 'DEGRADED',
        'UNHEALTHY', 'NOT_APPLICABLE'
      )
      and (
        last_health_status = 'UNKNOWN'
        or last_health_checked_at is not null
      )
    ),
  constraint atlas_installation_integrations_timeline_check
    check (
      (configured_at is null or configured_at >= created_at)
      and (
        validation_started_at is null
        or (
          configured_at is not null
          and validation_started_at >= configured_at
        )
      )
      and (
        validated_at is null
        or (
          validation_started_at is not null
          and validated_at >= validation_started_at
        )
      )
      and (disabled_at is null or disabled_at >= created_at)
    ),
  constraint atlas_installation_integrations_lifecycle_check
    check (
      (
        lifecycle_status not in (
          'CONFIGURED', 'VALIDATION_PENDING', 'VALIDATED'
        )
        or (
          configured_at is not null
          and configuration_sha256 is not null
          and non_secret_configuration <> '{}'::jsonb
        )
      )
      and (
        lifecycle_status <> 'VALIDATION_PENDING'
        or validation_started_at is not null
      )
      and (
        lifecycle_status <> 'VALIDATED'
        or (
          validated_at is not null
          and last_health_status = 'HEALTHY'
        )
      )
      and (
        lifecycle_status not in ('DISABLED', 'REVOKED')
        or disabled_at is not null
      )
    )
);

create index idx_atlas_installation_integrations_status
  on public.atlas_installation_integrations (
    installation_id,
    lifecycle_status,
    adapter_code
  );

create index idx_atlas_installation_integrations_health
  on public.atlas_installation_integrations (
    installation_id,
    last_health_status,
    updated_at desc
  );

create table public.atlas_installation_integration_events (
  id uuid primary key default gen_random_uuid(),
  integration_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  adapter_code text not null,
  event_code text not null,
  from_status text,
  to_status text not null,
  integration_state_version bigint not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  executor_code text not null,
  request_id uuid not null,
  reason text not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  error_code text,
  redacted_error_summary text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_integration_events_request_key
    unique (integration_id, request_id),
  constraint atlas_integration_events_version_key
    unique (integration_id, integration_state_version),
  constraint atlas_integration_events_integration_fkey
    foreign key (integration_id)
    references public.atlas_installation_integrations(id)
    on delete restrict,
  constraint atlas_integration_events_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_integration_events_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_integration_events_adapter_fkey
    foreign key (adapter_code)
    references public.atlas_integration_adapter_definitions(adapter_code)
    on delete restrict,
  constraint atlas_integration_events_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_integration_events_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_integration_events_code_check
    check (event_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_integration_events_status_check
    check (
      to_status in (
        'DECLARED', 'CONFIGURATION_PENDING', 'CONFIGURED',
        'VALIDATION_PENDING', 'VALIDATED', 'FAILED',
        'DISABLED', 'REVOKED'
      )
      and (
        from_status is null
        or from_status in (
          'DECLARED', 'CONFIGURATION_PENDING', 'CONFIGURED',
          'VALIDATION_PENDING', 'VALIDATED', 'FAILED',
          'DISABLED', 'REVOKED'
        )
      )
    ),
  constraint atlas_integration_events_version_check
    check (integration_state_version >= 1),
  constraint atlas_integration_events_executor_check
    check (
      executor_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(executor_code) between 3 and 100
    ),
  constraint atlas_integration_events_reason_check
    check (length(btrim(reason)) between 10 and 1000),
  constraint atlas_integration_events_evidence_check
    check (
      length(btrim(evidence_reference)) between 5 and 500
      and evidence_reference !~ '[[:space:]?#=]'
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_integration_events_error_check
    check (
      (
        error_code is null
        and redacted_error_summary is null
      )
      or (
        nullif(btrim(error_code), '') is not null
        and length(btrim(redacted_error_summary)) between 5 and 500
      )
    ),
  constraint atlas_integration_events_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_integration_events_timeline
  on public.atlas_installation_integration_events (
    installation_id,
    created_at desc,
    id desc
  );

create or replace function
public.atlas_enforce_installation_integration_contract()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_installation_empresa_id uuid;
  v_adapter public.atlas_integration_adapter_definitions%rowtype;
begin
  select installation.empresa_id
  into v_installation_empresa_id
  from public.atlas_installations as installation
  where installation.id = new.installation_id;

  if v_installation_empresa_id is null
     or v_installation_empresa_id <> new.empresa_id then
    raise exception using
      errcode = '23514',
      message = 'INTEGRATION_INSTALLATION_EMPRESA_MISMATCH';
  end if;

  select adapter.*
  into v_adapter
  from public.atlas_integration_adapter_definitions as adapter
  where adapter.adapter_code = new.adapter_code;

  if v_adapter.adapter_code is null then
    raise exception using
      errcode = '23503',
      message = 'INTEGRATION_ADAPTER_NOT_FOUND';
  end if;

  if not v_adapter.active then
    raise exception using
      errcode = '55000',
      message = 'INTEGRATION_ADAPTER_NOT_ACTIVE';
  end if;

  if not new.required_capabilities <@ v_adapter.capabilities then
    raise exception using
      errcode = '23514',
      message = 'INTEGRATION_CAPABILITY_NOT_SUPPORTED';
  end if;

  if not new.ownership_type = any(v_adapter.ownership_modes) then
    raise exception using
      errcode = '23514',
      message = 'INTEGRATION_OWNERSHIP_NOT_SUPPORTED';
  end if;

  if new.lifecycle_status in (
       'CONFIGURED', 'VALIDATION_PENDING', 'VALIDATED'
     )
     and v_adapter.credential_reference_required
     and new.credential_reference is null then
    raise exception using
      errcode = '23514',
      message = 'INTEGRATION_CREDENTIAL_REFERENCE_REQUIRED';
  end if;

  if tg_op = 'UPDATE' then
    if new.installation_id <> old.installation_id
       or new.empresa_id <> old.empresa_id
       or new.adapter_code <> old.adapter_code
       or new.integration_code <> old.integration_code
       or new.environment <> old.environment
       or new.declared_by_user_id <> old.declared_by_user_id
       or new.idempotency_key <> old.idempotency_key
       or new.created_at <> old.created_at then
      raise exception using
        errcode = '42501',
        message = 'INSTALLATION_INTEGRATION_IDENTITY_IMMUTABLE';
    end if;

    if new.state_version <> old.state_version + 1 then
      raise exception using
        errcode = '40001',
        message = 'INSTALLATION_INTEGRATION_VERSION_CONFLICT';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_installation_integration_contract()
from public, anon, authenticated;
grant execute on function
public.atlas_enforce_installation_integration_contract()
to service_role;

create or replace function
public.atlas_block_integration_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INTEGRATION_EVENTS_APPEND_ONLY';
end;
$$;

revoke all on function
public.atlas_block_integration_event_mutation()
from public, anon, authenticated;
grant execute on function
public.atlas_block_integration_event_mutation()
to service_role;

create trigger trg_atlas_integration_adapters_updated_at
before update on public.atlas_integration_adapter_definitions
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_installation_integrations_contract
before insert or update on public.atlas_installation_integrations
for each row execute function
public.atlas_enforce_installation_integration_contract();

create trigger trg_atlas_installation_integrations_updated_at
before update on public.atlas_installation_integrations
for each row execute function public.atlas_set_updated_at();

create trigger trg_atlas_integration_events_append_only
before update or delete
on public.atlas_installation_integration_events
for each row execute function
public.atlas_block_integration_event_mutation();

alter table public.atlas_integration_adapter_definitions
  enable row level security;
alter table public.atlas_installation_integrations
  enable row level security;
alter table public.atlas_installation_integration_events
  enable row level security;

revoke all on table public.atlas_integration_adapter_definitions
from anon, authenticated;
revoke all on table public.atlas_installation_integrations
from anon, authenticated;
revoke all on table public.atlas_installation_integration_events
from anon, authenticated;

grant select on table public.atlas_integration_adapter_definitions
to authenticated;
grant select on table public.atlas_installation_integrations
to authenticated;
grant select on table public.atlas_installation_integration_events
to authenticated;

grant all on table public.atlas_integration_adapter_definitions
to service_role;
grant all on table public.atlas_installation_integrations
to service_role;
grant all on table public.atlas_installation_integration_events
to service_role;

create policy atlas_integration_adapters_platform_read
on public.atlas_integration_adapter_definitions
for select
to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_READ'
  )
);

create policy atlas_installation_integrations_platform_read
on public.atlas_installation_integrations
for select
to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_READ'
  )
);

create policy atlas_integration_events_platform_read
on public.atlas_installation_integration_events
for select
to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_READ'
  )
);

comment on table public.atlas_integration_adapter_definitions is
  'B2: contratos internos y reemplazables para proveedores e integraciones.';
comment on table public.atlas_installation_integrations is
  'B2: inventario versionado y no secreto de integraciones por instalacion.';
comment on table public.atlas_installation_integration_events is
  'B2: trazabilidad append-only de configuracion y validacion de integraciones.';
comment on function public.atlas_integration_reference_is_safe(text) is
  'B2: valida referencias opacas; nunca valida ni almacena el secreto real.';
comment on function
public.atlas_enforce_installation_integration_contract() is
  'B2: protege tenant, capacidad, propiedad e identidad del inventario.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2H1_INTEGRATION_INVENTORY_ADAPTER_CONTRACTS_INSTALLED',
  'next_block',
    'B2.2H.2_INTEGRATION_REGISTRATION_AND_CREDENTIAL_REFERENCE_RPCS',
  'adapter_definitions', (
    select count(*)
    from public.atlas_integration_adapter_definitions
  ),
  'active_adapters', (
    select count(*)
    from public.atlas_integration_adapter_definitions
    where active
  ),
  'integration_records', (
    select count(*)
    from public.atlas_installation_integrations
  ),
  'integration_event_records', (
    select count(*)
    from public.atlas_installation_integration_events
  ),
  'integration_write_rpcs', 0,
  'credential_values_stored', false,
  'provider_adapter_boundaries', true,
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
