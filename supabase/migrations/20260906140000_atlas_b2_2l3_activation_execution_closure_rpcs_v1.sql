-- ATLAS B2.2L.3
-- Ejecucion gobernada de activacion y cierre tecnico inmutable.
-- Corte: 2026-09-06
--
-- Revalida L2 dentro de la misma transaccion, exige autorizacion vigente,
-- reutiliza ACTIVATE_TENANT y registra cierre/eventos con hashes enlazados.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_compute_installation_activation_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_get_installation_activation_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_authorize_installation_activation(uuid,text,text,text,uuid,integer,text,text,text,uuid,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_transition_installation(uuid,text,text,uuid,bigint)'
     ) is null
     or to_regclass(
       'public.atlas_installation_activation_closures'
     ) is null
     or to_regclass(
       'public.atlas_installation_activation_events'
     ) is null then
    raise exception
      'B2.2L.3 requiere B2.2L.2 instalado y certificado';
  end if;

  if to_regprocedure(
       'public.atlas_enforce_activation_execution_context()'
     ) is not null
     or to_regprocedure(
       'public.atlas_compute_installation_activation_closure_integrity(uuid)'
     ) is not null
     or to_regprocedure(
       'public.atlas_get_installation_activation_closure(uuid)'
     ) is not null
     or to_regprocedure(
       'public.atlas_execute_installation_activation(uuid,uuid,text,text,text,uuid,bigint,jsonb)'
     ) is not null then
    raise exception
      'B2.2L.3 detecto RPC previas; reconciliar antes de instalar';
  end if;
end;
$$;

create or replace function
public.atlas_enforce_activation_execution_context()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_request_id uuid;
  v_authorization_id uuid;
begin
  if old.current_state_code <> 'ACTIVE'
     and new.current_state_code = 'ACTIVE'
     and old.current_state_code not in (
       'FINAL_APPROVAL', 'OBSERVED'
     ) then
    raise exception using
      errcode = '42501',
      message = 'ACTIVE_TRANSITION_SOURCE_INVALID';
  end if;

  if old.current_state_code = 'FINAL_APPROVAL'
     and new.current_state_code = 'ACTIVE' then
    begin
      v_request_id := nullif(
        current_setting(
          'atlas.activation.execution_request_id', true
        ),
        ''
      )::uuid;
      v_authorization_id := nullif(
        current_setting(
          'atlas.activation.execution_authorization_id', true
        ),
        ''
      )::uuid;
    exception
      when others then
        raise exception using
          errcode = '42501',
          message = 'ACTIVATION_EXECUTION_CONTEXT_INVALID';
    end;

    if v_request_id is null
       or v_authorization_id is null
       or auth.uid() is null
       or not exists (
         select 1
         from public.atlas_installation_activation_authorizations
           as authorization_record
         where authorization_record.id = v_authorization_id
           and authorization_record.installation_id = old.id
           and authorization_record.empresa_id = old.empresa_id
           and authorization_record.decision = 'AUTHORIZED'
           and authorization_record.expected_installation_version =
             old.version
       )
       or not exists (
         select 1
         from public.atlas_installation_activation_events
           as activation_event
         where activation_event.installation_id = old.id
           and activation_event.empresa_id = old.empresa_id
           and activation_event.activation_authorization_id =
             v_authorization_id
           and activation_event.activation_closure_id is null
           and activation_event.event_type = 'ACTIVATION_STARTED'
           and activation_event.actor_user_id = auth.uid()
           and activation_event.request_id = v_request_id
           and activation_event.installation_version = old.version
       ) then
      raise exception using
        errcode = '42501',
        message =
          'ACTIVE_TRANSITION_REQUIRES_GOVERNED_ACTIVATION_EXECUTION';
    end if;

    if exists (
      select 1
      from public.atlas_installation_activation_closures as closure
      where closure.installation_id = old.id
    ) then
      raise exception using
        errcode = '23505',
        message = 'INSTALLATION_ACTIVATION_ALREADY_CLOSED';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_activation_execution_context()
from public, anon, authenticated;
grant execute on function
public.atlas_enforce_activation_execution_context()
to service_role;

drop trigger if exists trg_atlas_activation_execution_context
  on public.atlas_installations;
create trigger trg_atlas_activation_execution_context
before update of current_state_code on public.atlas_installations
for each row execute function
public.atlas_enforce_activation_execution_context();

create or replace function
public.atlas_compute_installation_activation_closure_integrity(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_installation public.atlas_installations%rowtype;
  v_closure public.atlas_installation_activation_closures%rowtype;
  v_authorization
    public.atlas_installation_activation_authorizations%rowtype;
  v_certificate public.atlas_installation_certificates%rowtype;
  v_state_event public.atlas_installation_state_events%rowtype;
  v_certificate_integrity jsonb := '{}'::jsonb;
  v_started_count integer := 0;
  v_activated_count integer := 0;
  v_closure_event_count integer := 0;
  v_observation_count integer := 0;
  v_hash_valid boolean := false;
  v_source_binding_valid boolean := false;
  v_state_binding_valid boolean := false;
  v_event_set_complete boolean := false;
  v_historical_certificate_valid boolean := false;
  v_integrity_verified boolean := false;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'integrity_verified', false,
      'contract_version',
        'B2_INSTALLATION_ACTIVATION_CLOSURE_INTEGRITY_V1'
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_NOT_FOUND',
      'installation_id', p_installation_id,
      'integrity_verified', false,
      'contract_version',
        'B2_INSTALLATION_ACTIVATION_CLOSURE_INTEGRITY_V1'
    );
  end if;

  select closure.*
  into v_closure
  from public.atlas_installation_activation_closures as closure
  where closure.installation_id = v_installation.id
    and closure.empresa_id = v_installation.empresa_id;

  if not found then
    return jsonb_build_object(
      'ok', true,
      'code', 'INSTALLATION_ACTIVATION_CLOSURE_NOT_FOUND',
      'installation_id', v_installation.id,
      'empresa_id', v_installation.empresa_id,
      'installation_state', v_installation.current_state_code,
      'installation_version', v_installation.version,
      'closure_present', false,
      'integrity_verified', false,
      'contract_version',
        'B2_INSTALLATION_ACTIVATION_CLOSURE_INTEGRITY_V1',
      'raw_payloads_exposed', false,
      'evidence_references_exposed', false,
      'actor_identities_exposed', false
    );
  end if;

  select authorization_record.*
  into v_authorization
  from public.atlas_installation_activation_authorizations
    as authorization_record
  where authorization_record.id =
      v_closure.activation_authorization_id
    and authorization_record.installation_id =
      v_closure.installation_id
    and authorization_record.empresa_id = v_closure.empresa_id;

  select certificate.*
  into v_certificate
  from public.atlas_installation_certificates as certificate
  where certificate.id = v_closure.certificate_id
    and certificate.installation_id = v_closure.installation_id
    and certificate.empresa_id = v_closure.empresa_id;

  select state_event.*
  into v_state_event
  from public.atlas_installation_state_events as state_event
  where state_event.id = v_closure.activation_state_event_id
    and state_event.installation_id = v_closure.installation_id;

  if v_certificate.id is not null then
    v_certificate_integrity :=
      public.atlas_compute_installation_certificate_historical_integrity(
        v_certificate.id
      );
  end if;

  select
    count(*) filter (
      where activation_event.event_type = 'ACTIVATION_STARTED'
        and activation_event.activation_closure_id is null
    )::integer,
    count(*) filter (
      where activation_event.event_type = 'ACTIVATED'
        and activation_event.activation_closure_id = v_closure.id
    )::integer,
    count(*) filter (
      where activation_event.event_type = 'CLOSURE_RECORDED'
        and activation_event.activation_closure_id = v_closure.id
    )::integer,
    count(*) filter (
      where activation_event.event_type = 'OBSERVATION_STARTED'
        and activation_event.activation_closure_id = v_closure.id
    )::integer
  into
    v_started_count,
    v_activated_count,
    v_closure_event_count,
    v_observation_count
  from public.atlas_installation_activation_events
    as activation_event
  where activation_event.installation_id = v_closure.installation_id
    and activation_event.empresa_id = v_closure.empresa_id
    and activation_event.activation_authorization_id =
      v_closure.activation_authorization_id
    and activation_event.request_id = v_closure.request_id;

  v_hash_valid :=
    v_closure.closure_sha256 =
      public.atlas_normalization_sha256(
        v_closure.closure_payload::text
      )
    and v_closure.closure_payload->>'closure_id' =
      v_closure.id::text
    and v_closure.closure_payload->>'installation_id' =
      v_closure.installation_id::text
    and v_closure.closure_payload->>'activation_authorization_id' =
      v_closure.activation_authorization_id::text
    and v_closure.closure_payload->>'certificate_id' =
      v_closure.certificate_id::text
    and v_closure.closure_payload->>'activation_state_event_id' =
      v_closure.activation_state_event_id::text
    and v_closure.closure_payload->>'final_state_code' = 'ACTIVE';

  v_historical_certificate_valid :=
    v_certificate.id is not null
    and v_certificate.issuance_status = 'ISSUED'
    and v_certificate.certificate_sha256 =
      public.atlas_normalization_sha256(
        v_certificate.certificate_payload::text
      )
    and coalesce(
      (
        v_certificate_integrity
          ->>'historical_integrity_verified'
      )::boolean,
      false
    );

  v_source_binding_valid :=
    v_authorization.id is not null
    and v_authorization.decision = 'AUTHORIZED'
    and v_authorization.authorized_by_role_code = 'ATLAS_OWNER'
    and v_authorization.acceptance_package_id =
      v_closure.acceptance_package_id
    and v_authorization.certificate_id = v_closure.certificate_id
    and v_authorization.g04_gate_id = v_closure.g04_gate_id
    and v_authorization.expected_installation_version + 1 =
      v_closure.activated_installation_version
    and v_authorization.request_sha256 =
      v_closure.source_authorization_sha256
    and v_authorization.source_certificate_sha256 =
      v_closure.source_certificate_sha256
    and v_authorization.source_history_root_sha256 =
      v_closure.source_history_root_sha256
    and v_certificate.id is not null
    and v_certificate.certificate_sha256 =
      v_closure.source_certificate_sha256;

  v_state_binding_valid :=
    v_state_event.id is not null
    and v_state_event.event_code = 'ACTIVATE_TENANT'
    and v_state_event.from_state_code = 'FINAL_APPROVAL'
    and v_state_event.to_state_code = 'ACTIVE'
    and v_state_event.request_id = v_closure.request_id
    and v_state_event.installation_version =
      v_closure.activated_installation_version
    and v_installation.current_state_code in ('ACTIVE', 'OBSERVED')
    and v_installation.version >=
      v_closure.activated_installation_version
    and v_installation.activated_at = v_closure.activated_at;

  v_event_set_complete :=
    v_started_count = 1
    and v_activated_count = 1
    and v_closure_event_count = 1
    and v_observation_count = 1;

  v_integrity_verified :=
    v_hash_valid
    and v_source_binding_valid
    and v_state_binding_valid
    and v_event_set_complete
    and v_historical_certificate_valid
    and v_closure.final_state_code = 'ACTIVE'
    and v_closure.closure_contract_version =
      'B2_INSTALLATION_ACTIVATION_CLOSURE_V1'
    and v_closure.observation_window_ends_at >
      v_closure.activated_at;

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_integrity_verified
        then 'INSTALLATION_ACTIVATION_CLOSURE_VERIFIED'
      else 'INSTALLATION_ACTIVATION_CLOSURE_INTEGRITY_FAILED'
    end,
    'contract_version',
      'B2_INSTALLATION_ACTIVATION_CLOSURE_INTEGRITY_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'closure_present', true,
    'closure_id', v_closure.id,
    'closure_version', v_closure.closure_version,
    'closure_contract_version',
      v_closure.closure_contract_version,
    'closure_sha256', v_closure.closure_sha256,
    'activation_authorization_id',
      v_closure.activation_authorization_id,
    'certificate_id', v_closure.certificate_id,
    'activation_state_event_id',
      v_closure.activation_state_event_id,
    'activated_installation_version',
      v_closure.activated_installation_version,
    'activated_at', v_closure.activated_at,
    'observation_window_ends_at',
      v_closure.observation_window_ends_at,
    'hash_valid', v_hash_valid,
    'source_binding_valid', v_source_binding_valid,
    'state_binding_valid', v_state_binding_valid,
    'event_set_complete', v_event_set_complete,
    'historical_certificate_valid',
      v_historical_certificate_valid,
    'integrity_verified', v_integrity_verified,
    'raw_payloads_exposed', false,
    'evidence_references_exposed', false,
    'actor_identities_exposed', false
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_activation_closure_integrity(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_activation_closure_integrity(uuid)
to service_role;

create or replace function
public.atlas_get_installation_activation_closure(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_can_read_installation(p_installation_id)
     and not public.atlas_platform_has_permission(
       'INSTALLATION_ACTIVATION_READ'
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACTIVATION_READ_FORBIDDEN';
  end if;

  return
    public.atlas_compute_installation_activation_closure_integrity(
      p_installation_id
    );
end;
$$;

revoke all on function
public.atlas_get_installation_activation_closure(uuid)
from public, anon;
grant execute on function
public.atlas_get_installation_activation_closure(uuid)
to authenticated, service_role;

create or replace function
public.atlas_execute_installation_activation(
  p_installation_id uuid,
  p_activation_authorization_id uuid,
  p_reason text,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_request_id uuid,
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
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_installation_activation_closures%rowtype;
  v_authorization
    public.atlas_installation_activation_authorizations%rowtype;
  v_created public.atlas_installation_activation_closures%rowtype;
  v_state_event public.atlas_installation_state_events%rowtype;
  v_readiness jsonb;
  v_transition jsonb;
  v_integrity jsonb;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_closure_payload jsonb;
  v_closure_sha256 text;
  v_closure_id uuid := gen_random_uuid();
  v_activated_at timestamptz;
  v_observation_window_ends_at timestamptz;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_installation_id is null
     or p_activation_authorization_id is null
     or p_reason is null
     or length(btrim(p_reason)) not between 10 and 2000
     or p_evidence_reference is null
     or not public.atlas_activation_evidence_reference_is_safe(
       p_evidence_reference
     )
     or p_evidence_sha256 is null
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'ACTIVATION_EXECUTION_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version',
      'B2_INSTALLATION_ACTIVATION_EXECUTION_REQUEST_V1',
    'installation_id', p_installation_id,
    'activation_authorization_id',
      p_activation_authorization_id,
    'reason', btrim(p_reason),
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', p_evidence_sha256,
    'expected_installation_version',
      p_expected_installation_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  if not public.atlas_platform_has_permission(
    'INSTALLATION_ACTIVATION_EXECUTE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACTIVATION_EXECUTE_FORBIDDEN';
  end if;

  v_actor_role_code :=
    public.atlas_activation_platform_role_for_permission(
      'INSTALLATION_ACTIVATION_EXECUTE'
    );

  if v_actor_role_code not in (
    'ATLAS_OWNER', 'ATLAS_IMPLEMENTATION_OPERATOR'
  ) then
    raise exception using
      errcode = '42501',
      message = 'ACTIVATION_EXECUTION_REQUIRES_PLATFORM_OPERATOR';
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

  select closure.*
  into v_existing
  from public.atlas_installation_activation_closures as closure
  where closure.installation_id = v_installation.id;

  if found then
    if v_existing.request_id = p_request_id
       and v_existing.activation_authorization_id =
         p_activation_authorization_id
       and v_existing.metadata->>'execution_request_sha256' =
         v_request_sha256 then
      return jsonb_build_object(
        'ok', true,
        'code', 'ALREADY_COMPLETED',
        'installation_id', v_existing.installation_id,
        'empresa_id', v_existing.empresa_id,
        'installation_state', v_existing.final_state_code,
        'installation_version',
          v_existing.activated_installation_version,
        'activation_closure_id', v_existing.id,
        'activation_authorization_id',
          v_existing.activation_authorization_id,
        'closure_sha256', v_existing.closure_sha256,
        'observation_window_ends_at',
          v_existing.observation_window_ends_at
      );
    end if;

    raise exception using
      errcode = '23505',
      message = 'INSTALLATION_ACTIVATION_ALREADY_CLOSED';
  end if;

  if v_installation.version <>
      p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'FINAL_APPROVAL' then
    raise exception using
      errcode = '22023',
      message = 'ACTIVATION_EXECUTION_REQUIRES_FINAL_APPROVAL_STATE';
  end if;

  select authorization_record.*
  into v_authorization
  from public.atlas_installation_activation_authorizations
    as authorization_record
  where authorization_record.id = p_activation_authorization_id
    and authorization_record.installation_id = v_installation.id
    and authorization_record.empresa_id = v_installation.empresa_id
    and authorization_record.decision = 'AUTHORIZED';

  if not found then
    raise exception using
      errcode = '42501',
      message = 'CURRENT_ACTIVATION_AUTHORIZATION_REQUIRED';
  end if;

  if v_authorization.expected_installation_version <>
      v_installation.version then
    raise exception using
      errcode = '40001',
      message = 'ACTIVATION_AUTHORIZATION_VERSION_STALE';
  end if;

  v_readiness :=
    public.atlas_compute_installation_activation_readiness(
      v_installation.id
    );

  if not coalesce((v_readiness->>'ready')::boolean, false)
     or v_readiness->>'installation_state' <> 'FINAL_APPROVAL'
     or v_readiness->>'installation_version' <>
       v_installation.version::text
     or v_readiness->>'authorization_id' <>
       v_authorization.id::text
     or v_readiness->>'authorization_request_sha256' <>
       v_authorization.request_sha256
     or v_readiness->>'certificate_id' <>
       v_authorization.certificate_id::text
     or v_readiness->>'certificate_sha256' <>
       v_authorization.source_certificate_sha256
     or v_readiness->>'certificate_history_root_sha256' <>
       v_authorization.source_history_root_sha256 then
    raise exception using
      errcode = '42501',
      message = 'ACTIVATION_READINESS_STALE_OR_INCOMPLETE',
      detail = coalesce(v_readiness->'blockers', '[]'::jsonb)::text;
  end if;

  insert into public.atlas_installation_activation_events (
    installation_id, empresa_id, activation_authorization_id,
    activation_closure_id, event_type, actor_user_id,
    actor_role_code, executor_code, request_id,
    installation_version, evidence_reference, evidence_sha256,
    event_payload, metadata
  ) values (
    v_installation.id,
    v_installation.empresa_id,
    v_authorization.id,
    null,
    'ACTIVATION_STARTED',
    v_actor_user_id,
    v_actor_role_code,
    'ATLAS_ACTIVATION_EXECUTION_RPC',
    p_request_id,
    v_installation.version,
    p_evidence_reference,
    p_evidence_sha256,
    jsonb_build_object(
      'contract_version',
        'B2_INSTALLATION_ACTIVATION_EVENT_V1',
      'activation_authorization_id', v_authorization.id,
      'authorization_request_sha256',
        v_authorization.request_sha256,
      'activation_readiness_sha256',
        v_readiness->>'readiness_sha256',
      'execution_request_sha256', v_request_sha256,
      'expected_installation_version',
        v_installation.version
    ),
    jsonb_build_object('request_metadata', p_metadata)
  );

  perform set_config(
    'atlas.activation.execution_request_id',
    p_request_id::text,
    true
  );
  perform set_config(
    'atlas.activation.execution_authorization_id',
    v_authorization.id::text,
    true
  );

  v_transition := public.atlas_transition_installation(
    v_installation.id,
    'ACTIVE',
    btrim(p_reason),
    p_request_id,
    v_installation.version
  );

  perform set_config(
    'atlas.activation.execution_request_id', '', true
  );
  perform set_config(
    'atlas.activation.execution_authorization_id', '', true
  );

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id;

  if v_installation.current_state_code <> 'ACTIVE'
     or v_installation.version <>
       p_expected_installation_version + 1
     or v_transition->>'state' <> 'ACTIVE'
     or v_transition->>'version' <>
       v_installation.version::text then
    raise exception using
      errcode = 'XX001',
      message = 'ACTIVATION_TRANSITION_RESULT_INVALID';
  end if;

  select state_event.*
  into v_state_event
  from public.atlas_installation_state_events as state_event
  where state_event.installation_id = v_installation.id
    and state_event.request_id = p_request_id
    and state_event.event_code = 'ACTIVATE_TENANT'
    and state_event.from_state_code = 'FINAL_APPROVAL'
    and state_event.to_state_code = 'ACTIVE'
    and state_event.installation_version = v_installation.version;

  if not found then
    raise exception using
      errcode = 'XX001',
      message = 'ACTIVATION_STATE_EVENT_BINDING_MISSING';
  end if;

  v_activated_at := v_installation.activated_at;
  if v_activated_at is null then
    raise exception using
      errcode = 'XX001',
      message = 'ACTIVATED_AT_NOT_RECORDED';
  end if;

  v_observation_window_ends_at :=
    v_activated_at + make_interval(
      hours => v_authorization.observation_window_hours
    );

  v_closure_payload := jsonb_build_object(
    'contract_version',
      'B2_INSTALLATION_ACTIVATION_CLOSURE_V1',
    'closure_id', v_closure_id,
    'closure_version', 1,
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'activation_authorization_id', v_authorization.id,
    'authorization_version',
      v_authorization.authorization_version,
    'authorization_request_sha256',
      v_authorization.request_sha256,
    'acceptance_package_id',
      v_authorization.acceptance_package_id,
    'certificate_id', v_authorization.certificate_id,
    'certificate_sha256',
      v_authorization.source_certificate_sha256,
    'certificate_history_root_sha256',
      v_authorization.source_history_root_sha256,
    'g04_gate_id', v_authorization.g04_gate_id,
    'activation_state_event_id', v_state_event.id,
    'activation_readiness_sha256',
      v_readiness->>'readiness_sha256',
    'execution_request_sha256', v_request_sha256,
    'activation_evidence_sha256', p_evidence_sha256,
    'activated_installation_version',
      v_installation.version,
    'final_state_code', 'ACTIVE',
    'activated_at', v_activated_at,
    'observation_window_ends_at',
      v_observation_window_ends_at,
    'support_plan_code', v_authorization.support_plan_code,
    'support_owner_user_id',
      v_authorization.support_owner_user_id,
    'commercial_condition_code',
      v_authorization.commercial_condition_code
  );
  v_closure_sha256 := public.atlas_normalization_sha256(
    v_closure_payload::text
  );

  insert into public.atlas_installation_activation_closures (
    id, installation_id, empresa_id,
    activation_authorization_id, acceptance_package_id,
    certificate_id, g04_gate_id, activation_state_event_id,
    closure_version, activated_installation_version,
    final_state_code, closure_contract_version,
    source_authorization_sha256, source_certificate_sha256,
    source_history_root_sha256, closure_payload,
    closure_sha256, activated_at,
    observation_window_ends_at, closed_by_user_id,
    closed_by_role_code, request_id, metadata, created_at
  ) values (
    v_closure_id,
    v_installation.id,
    v_installation.empresa_id,
    v_authorization.id,
    v_authorization.acceptance_package_id,
    v_authorization.certificate_id,
    v_authorization.g04_gate_id,
    v_state_event.id,
    1,
    v_installation.version,
    'ACTIVE',
    'B2_INSTALLATION_ACTIVATION_CLOSURE_V1',
    v_authorization.request_sha256,
    v_authorization.source_certificate_sha256,
    v_authorization.source_history_root_sha256,
    v_closure_payload,
    v_closure_sha256,
    v_activated_at,
    v_observation_window_ends_at,
    v_actor_user_id,
    v_actor_role_code,
    p_request_id,
    jsonb_build_object(
      'execution_request_sha256', v_request_sha256,
      'activation_readiness_sha256',
        v_readiness->>'readiness_sha256',
      'request_metadata', p_metadata
    ),
    v_activated_at
  )
  returning * into v_created;

  insert into public.atlas_installation_activation_events (
    installation_id, empresa_id, activation_authorization_id,
    activation_closure_id, event_type, actor_user_id,
    actor_role_code, executor_code, request_id,
    installation_version, evidence_reference, evidence_sha256,
    event_payload, metadata, created_at
  )
  select
    v_installation.id,
    v_installation.empresa_id,
    v_authorization.id,
    v_created.id,
    event_row.event_type,
    v_actor_user_id,
    v_actor_role_code,
    'ATLAS_ACTIVATION_EXECUTION_RPC',
    p_request_id,
    v_installation.version,
    'activation://atlas/' || v_installation.id::text ||
      '/closure/' || v_created.id::text,
    v_created.closure_sha256,
    jsonb_build_object(
      'contract_version',
        'B2_INSTALLATION_ACTIVATION_EVENT_V1',
      'event_type', event_row.event_type,
      'activation_closure_id', v_created.id,
      'activation_authorization_id', v_authorization.id,
      'activation_state_event_id', v_state_event.id,
      'closure_sha256', v_created.closure_sha256,
      'activated_installation_version',
        v_installation.version,
      'observation_window_ends_at',
        v_observation_window_ends_at
    ),
    jsonb_build_object(
      'execution_request_sha256', v_request_sha256
    ),
    v_activated_at
  from (
    values
      ('ACTIVATED'::text),
      ('CLOSURE_RECORDED'::text),
      ('OBSERVATION_STARTED'::text)
  ) as event_row(event_type);

  v_integrity :=
    public.atlas_compute_installation_activation_closure_integrity(
      v_installation.id
    );

  if not coalesce(
    (v_integrity->>'integrity_verified')::boolean,
    false
  ) then
    raise exception using
      errcode = 'XX001',
      message = 'ACTIVATION_CLOSURE_POSTCONDITION_FAILED',
      detail = v_integrity::text;
  end if;

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  ) values (
    v_installation.empresa_id,
    v_actor_user_id,
    null,
    null,
    'INSTALLATION_ACTIVATED_AND_CLOSED',
    'B2_INSTALLATION_ACTIVATION_EXECUTION',
    'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'activation_authorization_id', v_authorization.id,
      'execution_request_sha256', v_request_sha256
    ),
    jsonb_build_object(
      'installation_id', v_installation.id,
      'installation_state', v_installation.current_state_code,
      'installation_version', v_installation.version,
      'activation_closure_id', v_created.id,
      'closure_sha256', v_created.closure_sha256
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_ACTIVATED_AND_CLOSED',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'activation_authorization_id', v_authorization.id,
    'activation_closure_id', v_created.id,
    'activation_state_event_id', v_state_event.id,
    'closure_sha256', v_created.closure_sha256,
    'activated_at', v_created.activated_at,
    'observation_window_ends_at',
      v_created.observation_window_ends_at,
    'closure_integrity_verified', true,
    'next_action', 'MONITOR_POST_ACTIVATION_OBSERVATION'
  );
end;
$$;

revoke all on function
public.atlas_execute_installation_activation(
  uuid, uuid, text, text, text, uuid, bigint, jsonb
)
from public, anon;
grant execute on function
public.atlas_execute_installation_activation(
  uuid, uuid, text, text, text, uuid, bigint, jsonb
)
to authenticated, service_role;

comment on function
public.atlas_get_installation_activation_closure(uuid) is
  'B2: proyeccion segura y verificable del cierre tecnico de activacion.';

comment on function
public.atlas_execute_installation_activation(
  uuid, uuid, text, text, text, uuid, bigint, jsonb
) is
  'B2: revalida autorizacion/readiness, ejecuta ACTIVATE_TENANT y crea cierre inmutable en una sola transaccion.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2L3_ACTIVATION_EXECUTION_CLOSURE_RPCS_INSTALLED',
  'next_block',
    'B2.2L.4_POST_ACTIVATION_OBSERVATION_AND_HANDOFF_RPCS',
  'execution_rpcs', 1,
  'closure_read_rpcs', 1,
  'closure_integrity_helpers', 1,
  'active_transition_context_guards', 1,
  'activation_authorizations', (
    select count(*)
    from public.atlas_installation_activation_authorizations
  ),
  'activation_closures', (
    select count(*)
    from public.atlas_installation_activation_closures
  ),
  'activation_events', (
    select count(*)
    from public.atlas_installation_activation_events
  ),
  'active_transition_enabled', true,
  'closure_enabled', true,
  'atomic_transition_and_closure', true,
  'readiness_revalidation_enabled', true,
  'authorization_revalidation_enabled', true,
  'canonical_transition_reused', true,
  'closure_self_verification_enabled', true,
  'observation_window_started_on_activation', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'direct_authenticated_write', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
