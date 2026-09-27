-- ATLAS B2.2H.2 RECOVERED CONTRACT
-- Recovered 2026-09-27 from the certified production function definitions.
-- Historical migration file was absent from the repository.
-- This migration restores the exact registration/configuration RPC contracts
-- required by B2.2H.3. No provider is called and no secret value is stored.

begin;

CREATE OR REPLACE FUNCTION public.atlas_register_installation_integration(p_installation_id uuid, p_adapter_code text, p_integration_code text, p_display_name text, p_environment text, p_ownership_type text, p_required_capabilities text[], p_request_id uuid, p_expected_installation_version bigint, p_metadata jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_installation public.atlas_installations%rowtype;
  v_adapter public.atlas_integration_adapter_definitions%rowtype;
  v_existing public.atlas_installation_integrations%rowtype;
  v_created public.atlas_installation_integrations%rowtype;
  v_event_evidence jsonb;
  v_event_reference text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_INTEGRATION_MANAGE_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_adapter_code is null
     or p_adapter_code !~ '^[A-Z][A-Z0-9_]*$'
     or p_integration_code is null
     or p_integration_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_integration_code) not between 3 and 100
     or p_display_name is null
     or length(btrim(p_display_name)) not between 3 and 160
     or p_display_name ~ '[[:cntrl:]]'
     or p_environment not in ('PRODUCTION', 'SANDBOX', 'TEST')
     or p_ownership_type not in (
       'CLIENT_OWNED', 'ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'
     )
     or p_required_capabilities is null
     or cardinality(p_required_capabilities) < 1
     or coalesce(array_to_string(p_required_capabilities, ','), '')
       !~ '^[A-Z][A-Z0-9_]*(,[A-Z][A-Z0-9_]*)*$'
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_REGISTRATION_REQUIRED_FIELDS_INVALID';
  end if;

  if exists (
    select 1
    from unnest(p_required_capabilities)
      as capability(capability_code)
    group by capability.capability_code
    having count(*) > 1
  ) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_REQUIRED_CAPABILITY_DUPLICATED';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  select integration.*
  into v_existing
  from public.atlas_installation_integrations as integration
  where integration.installation_id = v_installation.id
    and integration.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.adapter_code <> p_adapter_code
       or v_existing.integration_code <> p_integration_code
       or v_existing.display_name <> btrim(p_display_name)
       or v_existing.environment <> p_environment
       or v_existing.ownership_type <> p_ownership_type
       or v_existing.required_capabilities <>
         p_required_capabilities
       or v_existing.metadata->'registration_request_metadata'
         <> p_metadata
       or coalesce(
         (
           v_existing.metadata->'registration_contract'->>
             'expected_installation_version'
         )::bigint,
         0
       ) <> p_expected_installation_version then
      raise exception using
        errcode = '22023',
        message =
          'INTEGRATION_REGISTRATION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'integration_id', v_existing.id,
      'integration_code', v_existing.integration_code,
      'adapter_code', v_existing.adapter_code,
      'lifecycle_status', v_existing.lifecycle_status,
      'state_version', v_existing.state_version,
      'credential_reference_present',
        v_existing.credential_reference is not null,
      'next_action', case
        when v_existing.credential_reference is null
          then 'CONFIGURE_CREDENTIAL_REFERENCE'
        else 'RUN_INTEGRATION_VALIDATION'
      end
    );
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if not (
    v_installation.current_state_code = 'INTEGRATION_SETUP'
    or (
      v_installation.current_state_code = 'PAUSED'
      and v_installation.resume_state_code = 'INTEGRATION_SETUP'
    )
  ) then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_INTEGRATION_SETUP';
  end if;

  if exists (
    select 1
    from public.atlas_installation_integrations as integration
    where integration.installation_id = v_installation.id
      and integration.integration_code = p_integration_code
  ) then
    raise exception using
      errcode = '23505',
      message = 'INSTALLATION_INTEGRATION_CODE_ALREADY_EXISTS';
  end if;

  select adapter.*
  into v_adapter
  from public.atlas_integration_adapter_definitions as adapter
  where adapter.adapter_code = p_adapter_code;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INTEGRATION_ADAPTER_NOT_FOUND';
  end if;

  if not v_adapter.active then
    raise exception using
      errcode = '55000', message = 'INTEGRATION_ADAPTER_NOT_ACTIVE';
  end if;

  if not p_required_capabilities <@ v_adapter.capabilities then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_CAPABILITY_NOT_SUPPORTED';
  end if;

  if not p_ownership_type = any(v_adapter.ownership_modes) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_OWNERSHIP_NOT_SUPPORTED';
  end if;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active = true
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code =
     'INSTALLATION_INTEGRATION_MANAGE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'INTEGRATION_ACTOR_ROLE_NOT_FOUND';
  end if;

  insert into public.atlas_installation_integrations (
    installation_id,
    empresa_id,
    adapter_code,
    integration_code,
    display_name,
    environment,
    ownership_type,
    lifecycle_status,
    state_version,
    required_capabilities,
    declared_by_user_id,
    idempotency_key,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    p_adapter_code,
    p_integration_code,
    btrim(p_display_name),
    p_environment,
    p_ownership_type,
    'DECLARED',
    1,
    p_required_capabilities,
    v_actor_user_id,
    p_request_id,
    jsonb_build_object(
      'registration_request_metadata', p_metadata,
      'registration_contract', jsonb_build_object(
        'contract_version', 'B2_INTEGRATION_REGISTRATION_V1',
        'expected_installation_version',
          p_expected_installation_version
      )
    )
  )
  returning * into v_created;

  v_event_reference := format(
    'integration://%s/events/%s',
    v_created.id,
    v_created.state_version
  );

  v_event_evidence := jsonb_build_object(
    'contract_version', 'B2_INTEGRATION_REGISTRATION_V1',
    'integration_id', v_created.id,
    'integration_code', v_created.integration_code,
    'adapter_code', v_created.adapter_code,
    'required_capabilities', v_created.required_capabilities,
    'credential_value_stored', false
  );

  insert into public.atlas_installation_integration_events (
    integration_id,
    installation_id,
    empresa_id,
    adapter_code,
    event_code,
    from_status,
    to_status,
    integration_state_version,
    actor_user_id,
    actor_role_code,
    executor_code,
    request_id,
    reason,
    evidence_reference,
    evidence_sha256,
    metadata
  )
  values (
    v_created.id,
    v_created.installation_id,
    v_created.empresa_id,
    v_created.adapter_code,
    'INTEGRATION_DECLARED',
    null,
    v_created.lifecycle_status,
    v_created.state_version,
    v_actor_user_id,
    v_actor_role_code,
    'B2_INTEGRATION_ENGINE',
    p_request_id,
    'Integracion declarada mediante contrato gobernado de Atlas.',
    v_event_reference,
    public.atlas_normalization_sha256(v_event_evidence::text),
    jsonb_build_object(
      'contract_version', 'B2_INTEGRATION_EVENT_V1',
      'request_metadata', p_metadata,
      'evidence_projection', v_event_evidence
    )
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
    'INSTALLATION_INTEGRATION_DECLARED',
    'B2_INTEGRATION_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'installation_id', v_created.installation_id,
      'adapter_code', v_created.adapter_code,
      'integration_code', v_created.integration_code,
      'request_id', p_request_id,
      'expected_installation_version',
        p_expected_installation_version
    ),
    jsonb_build_object(
      'integration_id', v_created.id,
      'lifecycle_status', v_created.lifecycle_status,
      'state_version', v_created.state_version,
      'credential_value_stored', false
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INTEGRATION_REGISTERED',
    'installation_id', v_created.installation_id,
    'integration_id', v_created.id,
    'integration_code', v_created.integration_code,
    'adapter_code', v_created.adapter_code,
    'lifecycle_status', v_created.lifecycle_status,
    'state_version', v_created.state_version,
    'credential_reference_present', false,
    'credential_value_stored', false,
    'next_action', 'CONFIGURE_CREDENTIAL_REFERENCE'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.atlas_configure_installation_integration_reference(p_integration_id uuid, p_credential_authority text, p_credential_reference text, p_external_identity_sha256 text, p_non_secret_configuration jsonb, p_request_id uuid, p_expected_integration_state_version bigint, p_expected_installation_version bigint, p_metadata jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_installation public.atlas_installations%rowtype;
  v_adapter public.atlas_integration_adapter_definitions%rowtype;
  v_integration public.atlas_installation_integrations%rowtype;
  v_existing_event public.atlas_installation_integration_events%rowtype;
  v_updated public.atlas_installation_integrations%rowtype;
  v_operation_payload jsonb;
  v_operation_sha256 text;
  v_credential_reference_sha256 text;
  v_configuration_sha256 text;
  v_event_evidence jsonb;
  v_event_reference text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_INTEGRATION_MANAGE_FORBIDDEN';
  end if;

  if p_integration_id is null
     or p_request_id is null
     or p_expected_integration_state_version is null
     or p_expected_integration_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_credential_authority not in (
       'SUPABASE_VAULT', 'N8N_CREDENTIAL_STORE',
       'PLATFORM_SECRET_MANAGER', 'EXTERNAL_VAULT'
     )
     or p_credential_reference is null
     or not public.atlas_integration_reference_is_safe(
       p_credential_reference
     )
     or p_external_identity_sha256 is null
     or p_external_identity_sha256 !~ '^[0-9a-f]{64}$'
     or p_non_secret_configuration is null
     or jsonb_typeof(p_non_secret_configuration) <> 'object'
     or p_non_secret_configuration = '{}'::jsonb
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_non_secret_configuration
     )
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_CONFIGURATION_REQUIRED_FIELDS_INVALID';
  end if;

  if not (
    (p_credential_authority = 'SUPABASE_VAULT'
      and p_credential_reference like 'vault://%')
    or (p_credential_authority = 'N8N_CREDENTIAL_STORE'
      and p_credential_reference like 'n8n-credential://%')
    or (p_credential_authority = 'PLATFORM_SECRET_MANAGER'
      and p_credential_reference like 'platform-secret://%')
    or (p_credential_authority = 'EXTERNAL_VAULT'
      and p_credential_reference like 'external-secret://%')
  ) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_CREDENTIAL_AUTHORITY_REFERENCE_MISMATCH';
  end if;

  v_credential_reference_sha256 :=
    public.atlas_normalization_sha256(p_credential_reference);
  v_configuration_sha256 :=
    public.atlas_normalization_sha256(
      p_non_secret_configuration::text
    );

  v_operation_payload := jsonb_build_object(
    'contract_version', 'B2_INTEGRATION_CONFIGURATION_V1',
    'integration_id', p_integration_id,
    'credential_authority', p_credential_authority,
    'credential_reference_sha256',
      v_credential_reference_sha256,
    'external_identity_sha256', p_external_identity_sha256,
    'configuration_sha256', v_configuration_sha256,
    'expected_integration_state_version',
      p_expected_integration_state_version,
    'expected_installation_version',
      p_expected_installation_version,
    'request_metadata', p_metadata
  );
  v_operation_sha256 := public.atlas_normalization_sha256(
    v_operation_payload::text
  );

  select integration.*
  into v_integration
  from public.atlas_installation_integrations as integration
  where integration.id = p_integration_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_INTEGRATION_NOT_FOUND';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_integration.installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_integration_events as event_record
  where event_record.integration_id = v_integration.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <>
         'INTEGRATION_CONFIGURATION_REFERENCED'
       or v_existing_event.metadata->>'operation_sha256' <>
         v_operation_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'INTEGRATION_CONFIGURATION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing_event.installation_id,
      'integration_id', v_existing_event.integration_id,
      'integration_code', v_integration.integration_code,
      'adapter_code', v_existing_event.adapter_code,
      'lifecycle_status', v_existing_event.to_status,
      'state_version', v_existing_event.integration_state_version,
      'credential_reference_present', true,
      'credential_reference_sha256',
        v_existing_event.metadata->>'credential_reference_sha256',
      'configuration_sha256',
        v_existing_event.metadata->>'configuration_sha256',
      'credential_value_stored', false,
      'next_action', 'RUN_INTEGRATION_VALIDATION'
    );
  end if;

  if v_integration.state_version <>
       p_expected_integration_state_version then
    raise exception using
      errcode = '40001',
      message = 'INSTALLATION_INTEGRATION_VERSION_CONFLICT';
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_integration.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_INSTALLATION_EMPRESA_MISMATCH';
  end if;

  if not (
    v_installation.current_state_code = 'INTEGRATION_SETUP'
    or (
      v_installation.current_state_code = 'PAUSED'
      and v_installation.resume_state_code = 'INTEGRATION_SETUP'
    )
  ) then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_INTEGRATION_SETUP';
  end if;

  if v_integration.lifecycle_status not in (
    'DECLARED', 'CONFIGURATION_PENDING', 'CONFIGURED', 'FAILED'
  ) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_NOT_CONFIGURABLE';
  end if;

  select adapter.*
  into v_adapter
  from public.atlas_integration_adapter_definitions as adapter
  where adapter.adapter_code = v_integration.adapter_code;

  if not found or not v_adapter.active then
    raise exception using
      errcode = '55000', message = 'INTEGRATION_ADAPTER_NOT_ACTIVE';
  end if;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active = true
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code =
     'INSTALLATION_INTEGRATION_MANAGE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'INTEGRATION_ACTOR_ROLE_NOT_FOUND';
  end if;

  update public.atlas_installation_integrations
  set
    lifecycle_status = 'CONFIGURED',
    state_version = state_version + 1,
    credential_authority = p_credential_authority,
    credential_reference = p_credential_reference,
    credential_reference_sha256 =
      v_credential_reference_sha256,
    external_identity_sha256 = p_external_identity_sha256,
    non_secret_configuration = p_non_secret_configuration,
    configuration_sha256 = v_configuration_sha256,
    last_health_status = 'UNKNOWN',
    last_health_checked_at = null,
    configured_at = now(),
    validation_started_at = null,
    validated_at = null,
    disabled_at = null,
    metadata = metadata || jsonb_build_object(
      'configuration_request_metadata', p_metadata,
      'configuration_contract', jsonb_build_object(
        'contract_version', 'B2_INTEGRATION_CONFIGURATION_V1',
        'operation_sha256', v_operation_sha256,
        'expected_integration_state_version',
          p_expected_integration_state_version,
        'expected_installation_version',
          p_expected_installation_version
      )
    )
  where id = v_integration.id
  returning * into v_updated;

  v_event_reference := format(
    'integration://%s/events/%s',
    v_updated.id,
    v_updated.state_version
  );

  v_event_evidence := jsonb_build_object(
    'contract_version', 'B2_INTEGRATION_CONFIGURATION_V1',
    'integration_id', v_updated.id,
    'adapter_code', v_updated.adapter_code,
    'credential_authority', v_updated.credential_authority,
    'credential_reference_sha256',
      v_updated.credential_reference_sha256,
    'external_identity_sha256',
      v_updated.external_identity_sha256,
    'configuration_sha256', v_updated.configuration_sha256,
    'credential_value_stored', false
  );

  insert into public.atlas_installation_integration_events (
    integration_id,
    installation_id,
    empresa_id,
    adapter_code,
    event_code,
    from_status,
    to_status,
    integration_state_version,
    actor_user_id,
    actor_role_code,
    executor_code,
    request_id,
    reason,
    evidence_reference,
    evidence_sha256,
    metadata
  )
  values (
    v_updated.id,
    v_updated.installation_id,
    v_updated.empresa_id,
    v_updated.adapter_code,
    'INTEGRATION_CONFIGURATION_REFERENCED',
    v_integration.lifecycle_status,
    v_updated.lifecycle_status,
    v_updated.state_version,
    v_actor_user_id,
    v_actor_role_code,
    'B2_INTEGRATION_ENGINE',
    p_request_id,
    'Referencia segura y configuracion no secreta vinculadas.',
    v_event_reference,
    public.atlas_normalization_sha256(v_event_evidence::text),
    jsonb_build_object(
      'contract_version', 'B2_INTEGRATION_EVENT_V1',
      'operation_sha256', v_operation_sha256,
      'credential_reference_sha256',
        v_credential_reference_sha256,
      'configuration_sha256', v_configuration_sha256,
      'expected_integration_state_version',
        p_expected_integration_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'request_metadata', p_metadata
    )
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
    v_updated.empresa_id,
    v_actor_user_id,
    null,
    null,
    'INSTALLATION_INTEGRATION_REFERENCE_CONFIGURED',
    'B2_INTEGRATION_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'installation_id', v_updated.installation_id,
      'integration_id', v_updated.id,
      'request_id', p_request_id,
      'expected_integration_state_version',
        p_expected_integration_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'operation_sha256', v_operation_sha256
    ),
    jsonb_build_object(
      'integration_code', v_updated.integration_code,
      'adapter_code', v_updated.adapter_code,
      'lifecycle_status', v_updated.lifecycle_status,
      'state_version', v_updated.state_version,
      'credential_reference_sha256',
        v_updated.credential_reference_sha256,
      'configuration_sha256', v_updated.configuration_sha256,
      'credential_value_stored', false
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INTEGRATION_REFERENCE_CONFIGURED',
    'installation_id', v_updated.installation_id,
    'integration_id', v_updated.id,
    'integration_code', v_updated.integration_code,
    'adapter_code', v_updated.adapter_code,
    'lifecycle_status', v_updated.lifecycle_status,
    'state_version', v_updated.state_version,
    'credential_authority', v_updated.credential_authority,
    'credential_reference_present', true,
    'credential_reference_sha256',
      v_updated.credential_reference_sha256,
    'external_identity_sha256',
      v_updated.external_identity_sha256,
    'configuration_sha256', v_updated.configuration_sha256,
    'credential_value_stored', false,
    'next_action', 'RUN_INTEGRATION_VALIDATION'
  );
end;
$function$
;

revoke all on function public.atlas_register_installation_integration(uuid,text,text,text,text,text,text[],uuid,bigint,jsonb) from public, anon;
grant execute on function public.atlas_register_installation_integration(uuid,text,text,text,text,text,text[],uuid,bigint,jsonb) to authenticated, service_role;

revoke all on function public.atlas_configure_installation_integration_reference(uuid,text,text,text,jsonb,uuid,bigint,bigint,jsonb) from public, anon;
grant execute on function public.atlas_configure_installation_integration_reference(uuid,text,text,text,jsonb,uuid,bigint,bigint,jsonb) to authenticated, service_role;

commit;
