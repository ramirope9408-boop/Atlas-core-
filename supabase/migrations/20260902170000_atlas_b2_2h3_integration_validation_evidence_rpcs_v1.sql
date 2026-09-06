-- ATLAS B2.2H.3
-- Validacion en dos fases y evidencia verificable de integraciones.
-- Corte: 2026-09-02
--
-- Este bloque registra contratos y resultados; no llama proveedores.
-- Un ejecutor externo resuelve la referencia segura, ejecuta los checks y
-- devuelve evidencia resumida. Ningun secreto o payload crudo se conserva.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_integrations'
     ) is null
     or to_regclass(
       'public.atlas_installation_integration_events'
     ) is null
     or to_regprocedure(
       'public.atlas_register_installation_integration(uuid,text,text,text,text,text,text[],uuid,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_configure_installation_integration_reference(uuid,text,text,text,jsonb,uuid,bigint,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null then
    raise exception 'B2.2H.3 requiere B2.2H.2 instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_integration_evidence_reference_is_safe(
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
      '^(audit|storage|receipt|integration-test)://[A-Za-z0-9][A-Za-z0-9._:/-]+$'
$$;

revoke all on function
public.atlas_integration_evidence_reference_is_safe(text)
from public, anon, authenticated;
grant execute on function
public.atlas_integration_evidence_reference_is_safe(text)
to service_role;

create or replace function
public.atlas_integration_check_results_are_valid(
  p_adapter_code text,
  p_check_results jsonb,
  p_outcome text
)
returns boolean
language plpgsql
stable
strict
security definer
set search_path = public, pg_temp
as $$
declare
  v_required_checks jsonb;
  v_required_count integer;
begin
  if p_outcome not in ('PASSED', 'FAILED')
     or jsonb_typeof(p_check_results) <> 'array'
     or jsonb_array_length(p_check_results) = 0
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_check_results
     ) then
    return false;
  end if;

  select adapter.verification_contract->'asserts'
  into v_required_checks
  from public.atlas_integration_adapter_definitions as adapter
  where adapter.adapter_code = p_adapter_code
    and adapter.active;

  if not found
     or jsonb_typeof(v_required_checks) <> 'array'
     or jsonb_array_length(v_required_checks) = 0 then
    return false;
  end if;

  v_required_count := jsonb_array_length(v_required_checks);

  if jsonb_array_length(p_check_results) <> v_required_count then
    return false;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_check_results) as result(value)
    where jsonb_typeof(result.value) <> 'object'
       or not (result.value ?& array[
         'check_code', 'outcome', 'evidence_reference',
         'evidence_sha256', 'observed_at'
       ])
       or coalesce(result.value->>'check_code', '') !~
         '^[A-Z][A-Z0-9_]*$'
       or result.value->>'outcome' not in ('PASSED', 'FAILED')
       or not public.atlas_integration_evidence_reference_is_safe(
         result.value->>'evidence_reference'
       )
       or coalesce(result.value->>'evidence_sha256', '') !~
         '^[0-9a-f]{64}$'
       or result.value->>'observed_at' is null
  ) then
    return false;
  end if;

  perform (result.value->>'observed_at')::timestamptz
  from jsonb_array_elements(p_check_results) as result(value);

  if (
    select count(distinct result.value->>'check_code')
    from jsonb_array_elements(p_check_results) as result(value)
  ) <> v_required_count then
    return false;
  end if;

  if exists (
    select required.value #>> '{}'
    from jsonb_array_elements(v_required_checks) as required(value)
    except
    select result.value->>'check_code'
    from jsonb_array_elements(p_check_results) as result(value)
  )
  or exists (
    select result.value->>'check_code'
    from jsonb_array_elements(p_check_results) as result(value)
    except
    select required.value #>> '{}'
    from jsonb_array_elements(v_required_checks) as required(value)
  ) then
    return false;
  end if;

  if p_outcome = 'PASSED' and exists (
    select 1
    from jsonb_array_elements(p_check_results) as result(value)
    where result.value->>'outcome' <> 'PASSED'
  ) then
    return false;
  end if;

  if p_outcome = 'FAILED' and not exists (
    select 1
    from jsonb_array_elements(p_check_results) as result(value)
    where result.value->>'outcome' = 'FAILED'
  ) then
    return false;
  end if;

  return true;
exception
  when others then
    return false;
end;
$$;

revoke all on function
public.atlas_integration_check_results_are_valid(text,jsonb,text)
from public, anon, authenticated;
grant execute on function
public.atlas_integration_check_results_are_valid(text,jsonb,text)
to service_role;

create table public.atlas_installation_integration_validation_results (
  id uuid primary key default gen_random_uuid(),
  integration_id uuid not null,
  installation_id uuid not null,
  empresa_id uuid not null,
  adapter_code text not null,
  validation_attempt integer not null,
  evaluated_integration_state_version bigint not null,
  resulting_integration_state_version bigint not null,
  outcome text not null,
  health_status text not null,
  executor_code text not null,
  start_request_id uuid not null,
  request_id uuid not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  check_results jsonb not null,
  check_results_sha256 text not null,
  evidence_reference text not null,
  evidence_sha256 text not null,
  error_code text,
  redacted_error_summary text,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_integration_validation_attempt_key
    unique (integration_id, validation_attempt),
  constraint atlas_integration_validation_start_key
    unique (integration_id, start_request_id),
  constraint atlas_integration_validation_request_key
    unique (integration_id, request_id),
  constraint atlas_integration_validation_integration_fkey
    foreign key (integration_id)
    references public.atlas_installation_integrations(id)
    on delete restrict,
  constraint atlas_integration_validation_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_integration_validation_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_integration_validation_adapter_fkey
    foreign key (adapter_code)
    references public.atlas_integration_adapter_definitions(adapter_code)
    on delete restrict,
  constraint atlas_integration_validation_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_integration_validation_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_integration_validation_attempt_check
    check (validation_attempt between 1 and 20),
  constraint atlas_integration_validation_versions_check
    check (
      evaluated_integration_state_version >= 1
      and resulting_integration_state_version =
        evaluated_integration_state_version + 1
    ),
  constraint atlas_integration_validation_outcome_check
    check (
      (outcome = 'PASSED' and health_status = 'HEALTHY')
      or (outcome = 'FAILED' and health_status = 'UNHEALTHY')
    ),
  constraint atlas_integration_validation_executor_check
    check (
      executor_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(executor_code) between 3 and 100
    ),
  constraint atlas_integration_validation_results_check
    check (
      jsonb_typeof(check_results) = 'array'
      and jsonb_array_length(check_results) > 0
      and check_results_sha256 ~ '^[0-9a-f]{64}$'
      and not public.atlas_jsonb_has_forbidden_secret_key(
        check_results
      )
    ),
  constraint atlas_integration_validation_evidence_check
    check (
      public.atlas_integration_evidence_reference_is_safe(
        evidence_reference
      )
      and evidence_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_integration_validation_error_check
    check (
      (
        outcome = 'PASSED'
        and error_code is null
        and redacted_error_summary is null
      )
      or (
        outcome = 'FAILED'
        and nullif(btrim(error_code), '') is not null
        and length(btrim(redacted_error_summary)) between 5 and 500
      )
    ),
  constraint atlas_integration_validation_timeline_check
    check (completed_at >= started_at),
  constraint atlas_integration_validation_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_integration_validation_timeline
  on public.atlas_installation_integration_validation_results (
    installation_id,
    integration_id,
    validation_attempt desc,
    created_at desc
  );

create or replace function
public.atlas_enforce_integration_validation_result_contract()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_integration public.atlas_installation_integrations%rowtype;
begin
  select integration.*
  into v_integration
  from public.atlas_installation_integrations as integration
  where integration.id = new.integration_id;

  if not found
     or v_integration.installation_id <> new.installation_id
     or v_integration.empresa_id <> new.empresa_id
     or v_integration.adapter_code <> new.adapter_code then
    raise exception using
      errcode = '23514',
      message = 'INTEGRATION_VALIDATION_IDENTITY_MISMATCH';
  end if;

  if new.check_results_sha256 <>
       public.atlas_normalization_sha256(new.check_results::text) then
    raise exception using
      errcode = '23514',
      message = 'INTEGRATION_VALIDATION_CHECK_RESULTS_HASH_MISMATCH';
  end if;

  if not public.atlas_integration_check_results_are_valid(
    new.adapter_code,
    new.check_results,
    new.outcome
  ) then
    raise exception using
      errcode = '23514',
      message = 'INTEGRATION_VALIDATION_CHECK_RESULTS_INVALID';
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_integration_validation_result_contract()
from public, anon, authenticated;
grant execute on function
public.atlas_enforce_integration_validation_result_contract()
to service_role;

create or replace function
public.atlas_block_integration_validation_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INTEGRATION_VALIDATION_RESULTS_APPEND_ONLY';
end;
$$;

revoke all on function
public.atlas_block_integration_validation_mutation()
from public, anon, authenticated;
grant execute on function
public.atlas_block_integration_validation_mutation()
to service_role;

create trigger trg_atlas_integration_validation_contract
before insert
on public.atlas_installation_integration_validation_results
for each row execute function
public.atlas_enforce_integration_validation_result_contract();

create trigger trg_atlas_integration_validation_append_only
before update or delete
on public.atlas_installation_integration_validation_results
for each row execute function
public.atlas_block_integration_validation_mutation();

alter table public.atlas_installation_integration_validation_results
  enable row level security;

revoke all on table
public.atlas_installation_integration_validation_results
from anon, authenticated;

grant select on table
public.atlas_installation_integration_validation_results
to authenticated;

grant all on table
public.atlas_installation_integration_validation_results
to service_role;

create policy atlas_integration_validation_results_platform_read
on public.atlas_installation_integration_validation_results
for select
to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_READ'
  )
);

create or replace function
public.atlas_begin_installation_integration_validation(
  p_integration_id uuid,
  p_executor_code text,
  p_request_id uuid,
  p_expected_integration_state_version bigint,
  p_expected_installation_version bigint,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_integration public.atlas_installation_integrations%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_adapter public.atlas_integration_adapter_definitions%rowtype;
  v_existing_event public.atlas_installation_integration_events%rowtype;
  v_updated public.atlas_installation_integrations%rowtype;
  v_attempt integer;
  v_started_at timestamptz;
  v_evidence jsonb;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_VALIDATE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_INTEGRATION_VALIDATE_FORBIDDEN';
  end if;

  if p_integration_id is null
     or p_request_id is null
     or p_executor_code is null
     or p_executor_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_executor_code) not between 3 and 100
     or p_expected_integration_state_version is null
     or p_expected_integration_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_VALIDATION_BEGIN_REQUIRED_FIELDS_INVALID';
  end if;

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
    if v_existing_event.event_code <> 'INTEGRATION_VALIDATION_STARTED'
       or v_existing_event.metadata->>'executor_code' <>
         p_executor_code
       or coalesce(
         (
           v_existing_event.metadata->>
             'expected_integration_state_version'
         )::bigint,
         0
       ) <> p_expected_integration_state_version
       or coalesce(
         (
           v_existing_event.metadata->>
             'expected_installation_version'
         )::bigint,
         0
       ) <> p_expected_installation_version
       or v_existing_event.metadata->'request_metadata' <>
         p_metadata then
      raise exception using
        errcode = '22023',
        message =
          'INTEGRATION_VALIDATION_BEGIN_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
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
      'validation_attempt',
        (v_existing_event.metadata->>'validation_attempt')::integer,
      'validation_started_at',
        v_existing_event.metadata->>'validation_started_at',
      'validation_contract', jsonb_build_object(
        'contract_version', 'B2_INTEGRATION_VALIDATION_V1',
        'required_checks',
          v_existing_event.metadata->'required_checks',
        'executor_code', p_executor_code
      )
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

  if v_integration.lifecycle_status not in ('CONFIGURED', 'FAILED') then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_NOT_READY_FOR_VALIDATION';
  end if;

  if v_integration.credential_reference is null
     or not public.atlas_integration_reference_is_safe(
       v_integration.credential_reference
     )
     or v_integration.credential_reference_sha256 <>
       public.atlas_normalization_sha256(
         v_integration.credential_reference
       )
     or v_integration.non_secret_configuration = '{}'::jsonb
     or v_integration.configuration_sha256 <>
       public.atlas_normalization_sha256(
         v_integration.non_secret_configuration::text
       ) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_CONFIGURATION_INTEGRITY_INVALID';
  end if;

  select adapter.*
  into v_adapter
  from public.atlas_integration_adapter_definitions as adapter
  where adapter.adapter_code = v_integration.adapter_code
    and adapter.active;

  if not found then
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
     'INSTALLATION_INTEGRATION_VALIDATE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'INTEGRATION_VALIDATION_ACTOR_ROLE_NOT_FOUND';
  end if;

  select coalesce(max(result.validation_attempt), 0) + 1
  into v_attempt
  from public.atlas_installation_integration_validation_results
    as result
  where result.integration_id = v_integration.id;

  if v_attempt > 20 then
    raise exception using
      errcode = '54000',
      message = 'INTEGRATION_VALIDATION_ATTEMPT_LIMIT_REACHED';
  end if;

  v_started_at := clock_timestamp();

  update public.atlas_installation_integrations
  set
    lifecycle_status = 'VALIDATION_PENDING',
    state_version = state_version + 1,
    validation_started_at = v_started_at,
    validated_at = null,
    last_health_status = 'UNKNOWN',
    last_health_checked_at = null,
    metadata = metadata || jsonb_build_object(
      'validation_contract', jsonb_build_object(
        'contract_version', 'B2_INTEGRATION_VALIDATION_V1',
        'validation_attempt', v_attempt,
        'executor_code', p_executor_code,
        'start_request_id', p_request_id
      ),
      'validation_request_metadata', p_metadata
    )
  where id = v_integration.id
  returning * into v_updated;

  v_evidence := jsonb_build_object(
    'contract_version', 'B2_INTEGRATION_VALIDATION_V1',
    'integration_id', v_updated.id,
    'adapter_code', v_updated.adapter_code,
    'validation_attempt', v_attempt,
    'executor_code', p_executor_code,
    'configuration_sha256', v_updated.configuration_sha256,
    'credential_reference_sha256',
      v_updated.credential_reference_sha256,
    'required_checks', v_adapter.verification_contract->'asserts'
  );

  insert into public.atlas_installation_integration_events (
    integration_id, installation_id, empresa_id, adapter_code,
    event_code, from_status, to_status, integration_state_version,
    actor_user_id, actor_role_code, executor_code, request_id,
    reason, evidence_reference, evidence_sha256, metadata
  )
  values (
    v_updated.id, v_updated.installation_id, v_updated.empresa_id,
    v_updated.adapter_code, 'INTEGRATION_VALIDATION_STARTED',
    v_integration.lifecycle_status, v_updated.lifecycle_status,
    v_updated.state_version, v_actor_user_id, v_actor_role_code,
    p_executor_code, p_request_id,
    'Validacion tecnica iniciada con contrato y configuracion vinculados.',
    format(
      'integration-test://%s/attempts/%s/start',
      v_updated.id,
      v_attempt
    ),
    public.atlas_normalization_sha256(v_evidence::text),
    jsonb_build_object(
      'contract_version', 'B2_INTEGRATION_EVENT_V1',
      'validation_attempt', v_attempt,
      'validation_started_at', v_started_at,
      'executor_code', p_executor_code,
      'expected_integration_state_version',
        p_expected_integration_state_version,
      'expected_installation_version',
        p_expected_installation_version,
      'required_checks', v_adapter.verification_contract->'asserts',
      'configuration_sha256', v_updated.configuration_sha256,
      'credential_reference_sha256',
        v_updated.credential_reference_sha256,
      'request_metadata', p_metadata
    )
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_updated.empresa_id, v_actor_user_id, null, null,
    'INSTALLATION_INTEGRATION_VALIDATION_STARTED',
    'B2_INTEGRATION_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'installation_id', v_updated.installation_id,
      'integration_id', v_updated.id,
      'request_id', p_request_id,
      'executor_code', p_executor_code,
      'expected_integration_state_version',
        p_expected_integration_state_version,
      'expected_installation_version',
        p_expected_installation_version
    ),
    jsonb_build_object(
      'lifecycle_status', v_updated.lifecycle_status,
      'state_version', v_updated.state_version,
      'validation_attempt', v_attempt,
      'required_check_count', jsonb_array_length(
        v_adapter.verification_contract->'asserts'
      ),
      'credential_value_stored', false
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INTEGRATION_VALIDATION_STARTED',
    'installation_id', v_updated.installation_id,
    'integration_id', v_updated.id,
    'integration_code', v_updated.integration_code,
    'adapter_code', v_updated.adapter_code,
    'lifecycle_status', v_updated.lifecycle_status,
    'state_version', v_updated.state_version,
    'validation_attempt', v_attempt,
    'validation_started_at', v_started_at,
    'validation_contract', jsonb_build_object(
      'contract_version', 'B2_INTEGRATION_VALIDATION_V1',
      'adapter_contract_version',
        v_adapter.adapter_contract_version,
      'execution_boundary', v_adapter.execution_boundary,
      'executor_code', p_executor_code,
      'credential_authority', v_updated.credential_authority,
      'credential_reference', v_updated.credential_reference,
      'credential_reference_sha256',
        v_updated.credential_reference_sha256,
      'external_identity_sha256',
        v_updated.external_identity_sha256,
      'non_secret_configuration',
        v_updated.non_secret_configuration,
      'configuration_sha256', v_updated.configuration_sha256,
      'required_checks', v_adapter.verification_contract->'asserts'
    ),
    'credential_value_stored', false,
    'next_action', 'EXECUTE_AND_COMPLETE_INTEGRATION_VALIDATION'
  );
end;
$$;

revoke all on function
public.atlas_begin_installation_integration_validation(
  uuid, text, uuid, bigint, bigint, jsonb
)
from public, anon, authenticated;
grant execute on function
public.atlas_begin_installation_integration_validation(
  uuid, text, uuid, bigint, bigint, jsonb
)
to authenticated, service_role;

create or replace function
public.atlas_complete_installation_integration_validation(
  p_integration_id uuid,
  p_start_request_id uuid,
  p_request_id uuid,
  p_executor_code text,
  p_expected_integration_state_version bigint,
  p_expected_installation_version bigint,
  p_outcome text,
  p_check_results jsonb,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_started_at timestamptz,
  p_completed_at timestamptz,
  p_error_code text,
  p_redacted_error_summary text,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_integration public.atlas_installation_integrations%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_start_event public.atlas_installation_integration_events%rowtype;
  v_existing_result
    public.atlas_installation_integration_validation_results%rowtype;
  v_updated public.atlas_installation_integrations%rowtype;
  v_created
    public.atlas_installation_integration_validation_results%rowtype;
  v_attempt integer;
  v_operation_payload jsonb;
  v_operation_sha256 text;
  v_check_results_sha256 text;
  v_result_evidence jsonb;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_VALIDATE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_INTEGRATION_VALIDATE_FORBIDDEN';
  end if;

  if p_integration_id is null
     or p_start_request_id is null
     or p_request_id is null
     or p_start_request_id = p_request_id
     or p_executor_code is null
     or p_executor_code !~ '^[A-Z][A-Z0-9_]*$'
     or length(p_executor_code) not between 3 and 100
     or p_expected_integration_state_version is null
     or p_expected_integration_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_outcome not in ('PASSED', 'FAILED')
     or p_check_results is null
     or jsonb_typeof(p_check_results) <> 'array'
     or public.atlas_jsonb_has_forbidden_secret_key(p_check_results)
     or p_evidence_reference is null
     or not public.atlas_integration_evidence_reference_is_safe(
       p_evidence_reference
     )
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_started_at is null
     or p_completed_at is null
     or p_completed_at < p_started_at
     or p_completed_at > clock_timestamp() + interval '5 minutes'
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata)
     or (
       p_outcome = 'PASSED'
       and (
         p_error_code is not null
         or p_redacted_error_summary is not null
       )
     )
     or (
       p_outcome = 'FAILED'
       and (
         nullif(btrim(p_error_code), '') is null
         or length(btrim(p_redacted_error_summary))
           not between 5 and 500
       )
     ) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_VALIDATION_COMPLETE_REQUIRED_FIELDS_INVALID';
  end if;

  v_check_results_sha256 := public.atlas_normalization_sha256(
    p_check_results::text
  );

  v_operation_payload := jsonb_build_object(
    'contract_version', 'B2_INTEGRATION_VALIDATION_V1',
    'integration_id', p_integration_id,
    'start_request_id', p_start_request_id,
    'executor_code', p_executor_code,
    'expected_integration_state_version',
      p_expected_integration_state_version,
    'expected_installation_version',
      p_expected_installation_version,
    'outcome', p_outcome,
    'check_results_sha256', v_check_results_sha256,
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', p_evidence_sha256,
    'started_at', p_started_at,
    'completed_at', p_completed_at,
    'error_code', p_error_code,
    'redacted_error_summary', p_redacted_error_summary,
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

  select result.*
  into v_existing_result
  from public.atlas_installation_integration_validation_results as result
  where result.integration_id = v_integration.id
    and result.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_result.metadata->>'operation_sha256' <>
         v_operation_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'INTEGRATION_VALIDATION_COMPLETE_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing_result.installation_id,
      'integration_id', v_existing_result.integration_id,
      'integration_code', v_integration.integration_code,
      'adapter_code', v_existing_result.adapter_code,
      'validation_attempt', v_existing_result.validation_attempt,
      'outcome', v_existing_result.outcome,
      'health_status', v_existing_result.health_status,
      'lifecycle_status', case
        when v_existing_result.outcome = 'PASSED'
          then 'VALIDATED'
        else 'FAILED'
      end,
      'state_version',
        v_existing_result.resulting_integration_state_version,
      'check_results_sha256',
        v_existing_result.check_results_sha256,
      'evidence_reference',
        v_existing_result.evidence_reference,
      'evidence_sha256', v_existing_result.evidence_sha256,
      'credential_value_stored', false
    );
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

  if v_integration.lifecycle_status <> 'VALIDATION_PENDING'
     or v_integration.validation_started_at is null then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_VALIDATION_NOT_PENDING';
  end if;

  select event_record.*
  into v_start_event
  from public.atlas_installation_integration_events as event_record
  where event_record.integration_id = v_integration.id
    and event_record.request_id = p_start_request_id
    and event_record.event_code = 'INTEGRATION_VALIDATION_STARTED'
  limit 1;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INTEGRATION_VALIDATION_START_EVENT_NOT_FOUND';
  end if;

  v_attempt := (
    v_start_event.metadata->>'validation_attempt'
  )::integer;

  if v_start_event.integration_state_version <>
       v_integration.state_version
     or v_start_event.metadata->>'executor_code' <>
       p_executor_code
     or (
       v_start_event.metadata->>'validation_started_at'
     )::timestamptz <> p_started_at
     or v_start_event.metadata->>'configuration_sha256' <>
       v_integration.configuration_sha256
     or v_start_event.metadata->>'credential_reference_sha256' <>
       v_integration.credential_reference_sha256 then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_VALIDATION_START_BINDING_MISMATCH';
  end if;

  if not public.atlas_integration_check_results_are_valid(
    v_integration.adapter_code,
    p_check_results,
    p_outcome
  ) then
    raise exception using
      errcode = '22023',
      message = 'INTEGRATION_VALIDATION_CHECK_RESULTS_INVALID';
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
     'INSTALLATION_INTEGRATION_VALIDATE'
  where membership.user_id = v_actor_user_id
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'INTEGRATION_VALIDATION_ACTOR_ROLE_NOT_FOUND';
  end if;

  update public.atlas_installation_integrations
  set
    lifecycle_status = case
      when p_outcome = 'PASSED' then 'VALIDATED'
      else 'FAILED'
    end,
    state_version = state_version + 1,
    last_health_status = case
      when p_outcome = 'PASSED' then 'HEALTHY'
      else 'UNHEALTHY'
    end,
    last_health_checked_at = p_completed_at,
    validated_at = case
      when p_outcome = 'PASSED' then p_completed_at
      else null
    end,
    metadata = metadata || jsonb_build_object(
      'last_validation', jsonb_build_object(
        'contract_version', 'B2_INTEGRATION_VALIDATION_V1',
        'validation_attempt', v_attempt,
        'outcome', p_outcome,
        'check_results_sha256', v_check_results_sha256,
        'evidence_sha256', p_evidence_sha256
      )
    )
  where id = v_integration.id
  returning * into v_updated;

  insert into public.atlas_installation_integration_validation_results (
    integration_id, installation_id, empresa_id, adapter_code,
    validation_attempt, evaluated_integration_state_version,
    resulting_integration_state_version, outcome, health_status,
    executor_code, start_request_id, request_id,
    actor_user_id, actor_role_code,
    check_results, check_results_sha256,
    evidence_reference, evidence_sha256,
    error_code, redacted_error_summary,
    started_at, completed_at, metadata
  )
  values (
    v_updated.id, v_updated.installation_id, v_updated.empresa_id,
    v_updated.adapter_code, v_attempt,
    p_expected_integration_state_version,
    v_updated.state_version, p_outcome,
    v_updated.last_health_status, p_executor_code,
    p_start_request_id, p_request_id,
    v_actor_user_id, v_actor_role_code,
    p_check_results, v_check_results_sha256,
    p_evidence_reference, p_evidence_sha256,
    p_error_code, p_redacted_error_summary,
    p_started_at, p_completed_at,
    jsonb_build_object(
      'contract_version', 'B2_INTEGRATION_VALIDATION_RESULT_V1',
      'operation_sha256', v_operation_sha256,
      'request_metadata', p_metadata
    )
  )
  returning * into v_created;

  v_result_evidence := jsonb_build_object(
    'contract_version', 'B2_INTEGRATION_VALIDATION_RESULT_V1',
    'validation_result_id', v_created.id,
    'validation_attempt', v_created.validation_attempt,
    'outcome', v_created.outcome,
    'health_status', v_created.health_status,
    'check_results_sha256', v_created.check_results_sha256,
    'evidence_reference', v_created.evidence_reference,
    'evidence_sha256', v_created.evidence_sha256,
    'configuration_sha256', v_updated.configuration_sha256,
    'credential_reference_sha256',
      v_updated.credential_reference_sha256
  );

  insert into public.atlas_installation_integration_events (
    integration_id, installation_id, empresa_id, adapter_code,
    event_code, from_status, to_status, integration_state_version,
    actor_user_id, actor_role_code, executor_code, request_id,
    reason, evidence_reference, evidence_sha256,
    error_code, redacted_error_summary, metadata
  )
  values (
    v_updated.id, v_updated.installation_id, v_updated.empresa_id,
    v_updated.adapter_code,
    case
      when p_outcome = 'PASSED' then 'INTEGRATION_VALIDATED'
      else 'INTEGRATION_VALIDATION_FAILED'
    end,
    v_integration.lifecycle_status, v_updated.lifecycle_status,
    v_updated.state_version, v_actor_user_id, v_actor_role_code,
    p_executor_code, p_request_id,
    case
      when p_outcome = 'PASSED'
        then 'Integracion validada mediante checks y evidencia verificable.'
      else 'Validacion de integracion fallida con evidencia preservada.'
    end,
    p_evidence_reference,
    public.atlas_normalization_sha256(v_result_evidence::text),
    p_error_code, p_redacted_error_summary,
    jsonb_build_object(
      'contract_version', 'B2_INTEGRATION_EVENT_V1',
      'validation_result_id', v_created.id,
      'validation_attempt', v_created.validation_attempt,
      'check_results_sha256', v_created.check_results_sha256,
      'external_evidence_sha256', v_created.evidence_sha256,
      'operation_sha256', v_operation_sha256,
      'request_metadata', p_metadata
    )
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_code, error_message
  )
  values (
    v_updated.empresa_id, v_actor_user_id, null, null,
    case
      when p_outcome = 'PASSED'
        then 'INSTALLATION_INTEGRATION_VALIDATED'
      else 'INSTALLATION_INTEGRATION_VALIDATION_FAILED'
    end,
    'B2_INTEGRATION_ENGINE',
    case when p_outcome = 'PASSED' then 'COMPLETED' else 'FAILED' end,
    jsonb_build_object(
      'installation_id', v_updated.installation_id,
      'integration_id', v_updated.id,
      'start_request_id', p_start_request_id,
      'request_id', p_request_id,
      'executor_code', p_executor_code,
      'expected_integration_state_version',
        p_expected_integration_state_version,
      'expected_installation_version',
        p_expected_installation_version
    ),
    jsonb_build_object(
      'validation_result_id', v_created.id,
      'validation_attempt', v_created.validation_attempt,
      'outcome', v_created.outcome,
      'health_status', v_created.health_status,
      'lifecycle_status', v_updated.lifecycle_status,
      'state_version', v_updated.state_version,
      'check_results_sha256', v_created.check_results_sha256,
      'evidence_reference', v_created.evidence_reference,
      'evidence_sha256', v_created.evidence_sha256,
      'credential_value_stored', false
    ),
    p_error_code,
    p_redacted_error_summary
  );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when p_outcome = 'PASSED' then 'INTEGRATION_VALIDATED'
      else 'INTEGRATION_VALIDATION_FAILED'
    end,
    'installation_id', v_updated.installation_id,
    'integration_id', v_updated.id,
    'integration_code', v_updated.integration_code,
    'adapter_code', v_updated.adapter_code,
    'validation_result_id', v_created.id,
    'validation_attempt', v_created.validation_attempt,
    'outcome', v_created.outcome,
    'health_status', v_created.health_status,
    'lifecycle_status', v_updated.lifecycle_status,
    'state_version', v_updated.state_version,
    'check_results_sha256', v_created.check_results_sha256,
    'evidence_reference', v_created.evidence_reference,
    'evidence_sha256', v_created.evidence_sha256,
    'credential_value_stored', false,
    'next_action', case
      when p_outcome = 'PASSED'
        then 'EVALUATE_INTEGRATION_READINESS'
      else 'REMEDIATE_OR_RECONFIGURE_INTEGRATION'
    end
  );
end;
$$;

revoke all on function
public.atlas_complete_installation_integration_validation(
  uuid, uuid, uuid, text, bigint, bigint, text, jsonb,
  text, text, timestamptz, timestamptz, text, text, jsonb
)
from public, anon, authenticated;
grant execute on function
public.atlas_complete_installation_integration_validation(
  uuid, uuid, uuid, text, bigint, bigint, text, jsonb,
  text, text, timestamptz, timestamptz, text, text, jsonb
)
to authenticated, service_role;

comment on table
public.atlas_installation_integration_validation_results is
  'B2: resultados append-only con checks completos y evidencia por intento.';
comment on function
public.atlas_integration_check_results_are_valid(text,jsonb,text) is
  'B2: exige cobertura exacta y resultado coherente del contrato del adaptador.';
comment on function
public.atlas_begin_installation_integration_validation(
  uuid, text, uuid, bigint, bigint, jsonb
) is
  'B2: inicia validacion y entrega contrato seguro al ejecutor autorizado.';
comment on function
public.atlas_complete_installation_integration_validation(
  uuid, uuid, uuid, text, bigint, bigint, text, jsonb,
  text, text, timestamptz, timestamptz, text, text, jsonb
) is
  'B2: decide VALIDATED o FAILED solo con checks y evidencia completos.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2H3_INTEGRATION_VALIDATION_EVIDENCE_RPCS_INSTALLED',
  'next_action', 'CERTIFY_H3_VALIDATION_AND_EVIDENCE_GUARDS',
  'validation_rpcs', 2,
  'validation_result_tables', 1,
  'validation_results', (
    select count(*)
    from public.atlas_installation_integration_validation_results
  ),
  'integration_records', (
    select count(*)
    from public.atlas_installation_integrations
  ),
  'integration_event_records', (
    select count(*)
    from public.atlas_installation_integration_events
  ),
  'two_phase_validation_enabled', true,
  'required_check_coverage_enforced', true,
  'objective_success_enforced', true,
  'append_only_results_enabled', true,
  'evidence_hash_lineage_enabled', true,
  'configuration_revalidation_enabled', true,
  'credential_reference_revalidation_enabled', true,
  'raw_provider_payloads_stored', false,
  'credential_values_stored', false,
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
