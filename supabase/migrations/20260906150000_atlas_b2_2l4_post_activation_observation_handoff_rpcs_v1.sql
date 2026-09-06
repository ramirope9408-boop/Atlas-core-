-- ATLAS B2.2L.4
-- Observacion posactivacion y handoff operativo gobernado.
-- Corte: 2026-09-06
--
-- Deriva readiness desde el cierre real, exige ventana cumplida, soporte
-- vigente y ausencia de incidencias criticas antes de registrar el handoff.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_compute_installation_activation_closure_integrity(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_get_installation_activation_closure(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_execute_installation_activation(uuid,uuid,text,text,text,uuid,bigint,jsonb)'
     ) is null
     or to_regclass(
       'public.atlas_installation_activation_closures'
     ) is null
     or to_regclass(
       'public.atlas_installation_activation_events'
     ) is null then
    raise exception
      'B2.2L.4 requiere B2.2L.3 instalado y certificado';
  end if;

  if to_regprocedure(
       'public.atlas_compute_installation_post_activation_readiness(uuid)'
     ) is not null
     or to_regprocedure(
       'public.atlas_get_installation_post_activation_readiness(uuid)'
     ) is not null
     or to_regprocedure(
       'public.atlas_complete_installation_activation_handoff(uuid,text,text,text,uuid,bigint,jsonb)'
     ) is not null then
    raise exception
      'B2.2L.4 detecto RPC previas; reconciliar antes de instalar';
  end if;
end;
$$;

insert into public.atlas_internal_permissions(
  permission_code, description
)
values (
  'INSTALLATION_ACTIVATION_HANDOFF',
  'Consultar observacion posactivacion y cerrar el handoff operativo.'
)
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions(
  role_code, permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_ACTIVATION_HANDOFF'),
  (
    'ATLAS_IMPLEMENTATION_OPERATOR',
    'INSTALLATION_ACTIVATION_HANDOFF'
  ),
  ('ATLAS_SUPPORT_OPERATOR', 'INSTALLATION_ACTIVATION_HANDOFF')
on conflict (role_code, permission_code) do nothing;

create unique index
uq_atlas_activation_one_observation_completion
on public.atlas_installation_activation_events(installation_id)
where event_type = 'OBSERVATION_COMPLETED';

create or replace function
public.atlas_compute_installation_post_activation_readiness(
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
  v_completion_event
    public.atlas_installation_activation_events%rowtype;
  v_closure_integrity jsonb := '{}'::jsonb;
  v_criteria jsonb := '{}'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_payload jsonb;
  v_readiness_sha256 text;
  v_open_critical_incidents integer := 0;
  v_activation_failure_events integer := 0;
  v_observation_start_events integer := 0;
  v_support_owner_active boolean := false;
  v_closure_integrity_valid boolean := false;
  v_active_state_current boolean := false;
  v_observation_started boolean := false;
  v_observation_window_elapsed boolean := false;
  v_zero_critical_incidents boolean := false;
  v_no_activation_failures boolean := false;
  v_handoff_completed boolean := false;
  v_ready boolean := false;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'contract_version',
        'B2_POST_ACTIVATION_HANDOFF_READINESS_V1',
      'ready', false,
      'handoff_completed', false
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
      'contract_version',
        'B2_POST_ACTIVATION_HANDOFF_READINESS_V1',
      'installation_id', p_installation_id,
      'ready', false,
      'handoff_completed', false
    );
  end if;

  select closure.*
  into v_closure
  from public.atlas_installation_activation_closures as closure
  where closure.installation_id = v_installation.id
    and closure.empresa_id = v_installation.empresa_id;

  if v_closure.id is not null then
    v_closure_integrity :=
      public.atlas_compute_installation_activation_closure_integrity(
        v_installation.id
      );

    select authorization_record.*
    into v_authorization
    from public.atlas_installation_activation_authorizations
      as authorization_record
    where authorization_record.id =
        v_closure.activation_authorization_id
      and authorization_record.installation_id =
        v_closure.installation_id
      and authorization_record.empresa_id = v_closure.empresa_id;

    select exists (
      select 1
      from public.atlas_platform_memberships as membership
      join public.atlas_internal_roles as role_definition
        on role_definition.role_code = membership.role_code
       and role_definition.active
      where membership.user_id =
          v_authorization.support_owner_user_id
        and membership.status = 'ACTIVE'
        and membership.role_code in (
          'ATLAS_OWNER',
          'ATLAS_IMPLEMENTATION_OPERATOR',
          'ATLAS_SUPPORT_OPERATOR'
        )
    ) into v_support_owner_active;

    select count(*)::integer
    into v_open_critical_incidents
    from public.atlas_installation_exception_records
      as exception_record
    where exception_record.installation_id = v_installation.id
      and exception_record.severity = 'CRITICAL'
      and exception_record.exception_status not in (
        'REMEDIATED', 'SUPERSEDED'
      );

    select
      count(*) filter (
        where activation_event.event_type = 'ACTIVATION_FAILED'
      )::integer,
      count(*) filter (
        where activation_event.event_type = 'OBSERVATION_STARTED'
          and activation_event.activation_closure_id = v_closure.id
          and activation_event.evidence_sha256 =
            v_closure.closure_sha256
      )::integer
    into
      v_activation_failure_events,
      v_observation_start_events
    from public.atlas_installation_activation_events
      as activation_event
    where activation_event.installation_id = v_installation.id
      and activation_event.empresa_id = v_installation.empresa_id
      and activation_event.created_at >= v_closure.activated_at;

    select activation_event.*
    into v_completion_event
    from public.atlas_installation_activation_events
      as activation_event
    where activation_event.installation_id = v_installation.id
      and activation_event.empresa_id = v_installation.empresa_id
      and activation_event.activation_closure_id = v_closure.id
      and activation_event.event_type = 'OBSERVATION_COMPLETED'
    order by activation_event.created_at desc,
      activation_event.id desc
    limit 1;
  end if;

  v_closure_integrity_valid :=
    v_closure.id is not null
    and coalesce(
      (v_closure_integrity->>'integrity_verified')::boolean,
      false
    );
  v_active_state_current :=
    v_installation.current_state_code = 'ACTIVE'
    and v_closure.id is not null
    and v_installation.version >=
      v_closure.activated_installation_version;
  v_observation_started :=
    v_closure.id is not null
    and v_observation_start_events = 1;
  v_observation_window_elapsed :=
    v_closure.id is not null
    and clock_timestamp() >= v_closure.observation_window_ends_at;
  v_zero_critical_incidents :=
    v_closure.id is not null
    and v_open_critical_incidents = 0;
  v_no_activation_failures :=
    v_closure.id is not null
    and v_activation_failure_events = 0;
  v_handoff_completed :=
    v_completion_event.id is not null
    and v_completion_event.event_payload->>'closure_sha256' =
      v_closure.closure_sha256
    and v_completion_event.event_payload
          ->>'activation_closure_id' = v_closure.id::text
    and v_completion_event.event_payload
          ->>'support_owner_binding_sha256' =
      public.atlas_normalization_sha256(
        v_authorization.support_owner_user_id::text
      );

  v_criteria := jsonb_build_object(
    'ACTIVATION_CLOSURE_INTEGRITY',
      v_closure_integrity_valid,
    'ACTIVE_STATE_CURRENT', v_active_state_current,
    'OBSERVATION_STARTED', v_observation_started,
    'OBSERVATION_WINDOW_ELAPSED',
      v_observation_window_elapsed,
    'SUPPORT_OWNER_ACTIVE', v_support_owner_active,
    'ZERO_CRITICAL_INCIDENTS',
      v_zero_critical_incidents,
    'NO_ACTIVATION_FAILURES', v_no_activation_failures
  );

  v_ready :=
    v_closure_integrity_valid
    and v_active_state_current
    and v_observation_started
    and v_observation_window_elapsed
    and v_support_owner_active
    and v_zero_critical_incidents
    and v_no_activation_failures;

  select coalesce(jsonb_agg(blocker), '[]'::jsonb)
  into v_blockers
  from jsonb_array_elements(jsonb_build_array(
    case when v_closure.id is null
      then jsonb_build_object(
        'criterion', 'ACTIVATION_CLOSURE_INTEGRITY',
        'reason', 'ACTIVATION_CLOSURE_REQUIRED'
      ) end,
    case when v_closure.id is not null
          and not v_closure_integrity_valid
      then jsonb_build_object(
        'criterion', 'ACTIVATION_CLOSURE_INTEGRITY',
        'reason', 'ACTIVATION_CLOSURE_INTEGRITY_REQUIRED'
      ) end,
    case when not v_active_state_current
      then jsonb_build_object(
        'criterion', 'ACTIVE_STATE_CURRENT',
        'reason', 'ACTIVE_INSTALLATION_REQUIRED'
      ) end,
    case when v_closure.id is not null
          and not v_observation_started
      then jsonb_build_object(
        'criterion', 'OBSERVATION_STARTED',
        'reason', 'BOUND_OBSERVATION_START_REQUIRED'
      ) end,
    case when v_closure.id is not null
          and not v_observation_window_elapsed
      then jsonb_build_object(
        'criterion', 'OBSERVATION_WINDOW_ELAPSED',
        'reason', 'OBSERVATION_WINDOW_STILL_OPEN'
      ) end,
    case when v_closure.id is not null
          and not v_support_owner_active
      then jsonb_build_object(
        'criterion', 'SUPPORT_OWNER_ACTIVE',
        'reason', 'ACTIVE_SUPPORT_OWNER_REQUIRED'
      ) end,
    case when v_open_critical_incidents > 0
      then jsonb_build_object(
        'criterion', 'ZERO_CRITICAL_INCIDENTS',
        'reason', 'CRITICAL_INCIDENT_REMEDIATION_REQUIRED'
      ) end,
    case when v_activation_failure_events > 0
      then jsonb_build_object(
        'criterion', 'NO_ACTIVATION_FAILURES',
        'reason', 'ACTIVATION_FAILURE_REVIEW_REQUIRED'
      ) end
  )) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  v_payload := jsonb_build_object(
    'contract_version',
      'B2_POST_ACTIVATION_HANDOFF_READINESS_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'activation_closure_id', v_closure.id,
    'closure_sha256', v_closure.closure_sha256,
    'activation_authorization_id',
      v_closure.activation_authorization_id,
    'activated_at', v_closure.activated_at,
    'observation_window_ends_at',
      v_closure.observation_window_ends_at,
    'support_plan_code', v_authorization.support_plan_code,
    'support_owner_binding_sha256',
      case when v_authorization.support_owner_user_id is null
        then null
        else public.atlas_normalization_sha256(
          v_authorization.support_owner_user_id::text
        )
      end,
    'criteria', v_criteria,
    'open_critical_incidents', v_open_critical_incidents,
    'activation_failure_events',
      v_activation_failure_events,
    'handoff_completed', v_handoff_completed,
    'handoff_event_id', v_completion_event.id,
    'ready', v_ready
  );
  v_readiness_sha256 := public.atlas_normalization_sha256(
    v_payload::text
  );

  return v_payload || jsonb_build_object(
    'ok', true,
    'code', case
      when v_handoff_completed
        then 'POST_ACTIVATION_HANDOFF_COMPLETED'
      when v_ready then 'POST_ACTIVATION_HANDOFF_READY'
      when v_closure.id is null
        then 'POST_ACTIVATION_CLOSURE_REQUIRED'
      else 'POST_ACTIVATION_HANDOFF_NOT_READY'
    end,
    'readiness_sha256', v_readiness_sha256,
    'blockers', v_blockers,
    'raw_error_messages_exposed', false,
    'raw_payloads_exposed', false,
    'credential_values_exposed', false,
    'actor_identities_exposed', false,
    'evaluated_at', clock_timestamp(),
    'next_action', case
      when v_handoff_completed
        then 'POST_ACTIVATION_HANDOFF_CLOSED'
      when v_ready then 'COMPLETE_OPERATIONAL_HANDOFF'
      when v_closure.id is null then 'EXECUTE_ACTIVATION'
      when not v_observation_window_elapsed
        then 'CONTINUE_OBSERVATION'
      else 'RESOLVE_POST_ACTIVATION_BLOCKERS'
    end
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_post_activation_readiness(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_post_activation_readiness(uuid)
to service_role;

create or replace function
public.atlas_get_installation_post_activation_readiness(
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
     )
     and not public.atlas_platform_has_permission(
       'INSTALLATION_ACTIVATION_HANDOFF'
     ) then
    raise exception using
      errcode = '42501',
      message = 'POST_ACTIVATION_READ_FORBIDDEN';
  end if;

  return
    public.atlas_compute_installation_post_activation_readiness(
      p_installation_id
    );
end;
$$;

revoke all on function
public.atlas_get_installation_post_activation_readiness(uuid)
from public, anon;
grant execute on function
public.atlas_get_installation_post_activation_readiness(uuid)
to authenticated, service_role;

create or replace function
public.atlas_complete_installation_activation_handoff(
  p_installation_id uuid,
  p_handoff_code text,
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
  v_closure public.atlas_installation_activation_closures%rowtype;
  v_authorization
    public.atlas_installation_activation_authorizations%rowtype;
  v_existing
    public.atlas_installation_activation_events%rowtype;
  v_created
    public.atlas_installation_activation_events%rowtype;
  v_readiness jsonb;
  v_after jsonb;
  v_request_payload jsonb;
  v_request_sha256 text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_installation_id is null
     or p_handoff_code is null
     or btrim(p_handoff_code) !~ '^[A-Z][A-Z0-9_-]*$'
     or length(btrim(p_handoff_code)) not between 5 and 100
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
      message = 'ACTIVATION_HANDOFF_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version',
      'B2_POST_ACTIVATION_HANDOFF_REQUEST_V1',
    'installation_id', p_installation_id,
    'handoff_code', btrim(p_handoff_code),
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
    'INSTALLATION_ACTIVATION_HANDOFF'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACTIVATION_HANDOFF_FORBIDDEN';
  end if;

  v_actor_role_code :=
    public.atlas_activation_platform_role_for_permission(
      'INSTALLATION_ACTIVATION_HANDOFF'
    );

  if v_actor_role_code not in (
    'ATLAS_OWNER',
    'ATLAS_IMPLEMENTATION_OPERATOR',
    'ATLAS_SUPPORT_OPERATOR'
  ) then
    raise exception using
      errcode = '42501',
      message = 'ACTIVATION_HANDOFF_REQUIRES_PLATFORM_OPERATOR';
  end if;

  select activation_event.*
  into v_existing
  from public.atlas_installation_activation_events
    as activation_event
  where activation_event.installation_id = p_installation_id
    and activation_event.event_type = 'OBSERVATION_COMPLETED'
    and activation_event.request_id = p_request_id;

  if found then
    if v_existing.event_payload->>'request_sha256' <>
        v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'ACTIVATION_HANDOFF_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'activation_closure_id',
        v_existing.activation_closure_id,
      'handoff_event_id', v_existing.id,
      'installation_version',
        v_existing.installation_version,
      'request_sha256', v_request_sha256
    );
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

  if v_installation.version <>
      p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'ACTIVE' then
    raise exception using
      errcode = '22023',
      message = 'ACTIVATION_HANDOFF_REQUIRES_ACTIVE_STATE';
  end if;

  select closure.*
  into v_closure
  from public.atlas_installation_activation_closures as closure
  where closure.installation_id = v_installation.id
    and closure.empresa_id = v_installation.empresa_id;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'ACTIVATION_CLOSURE_REQUIRED';
  end if;

  select authorization_record.*
  into v_authorization
  from public.atlas_installation_activation_authorizations
    as authorization_record
  where authorization_record.id =
      v_closure.activation_authorization_id
    and authorization_record.installation_id =
      v_installation.id
    and authorization_record.empresa_id =
      v_installation.empresa_id;

  if not found then
    raise exception using
      errcode = 'XX001',
      message = 'ACTIVATION_AUTHORIZATION_BINDING_MISSING';
  end if;

  if v_actor_role_code <> 'ATLAS_OWNER'
     and v_authorization.support_owner_user_id <>
       v_actor_user_id then
    raise exception using
      errcode = '42501',
      message =
        'ACTIVATION_HANDOFF_REQUIRES_ASSIGNED_SUPPORT_OWNER';
  end if;

  if exists (
    select 1
    from public.atlas_installation_activation_events
      as activation_event
    where activation_event.installation_id = v_installation.id
      and activation_event.event_type = 'OBSERVATION_COMPLETED'
  ) then
    raise exception using
      errcode = '23505',
      message = 'ACTIVATION_HANDOFF_ALREADY_COMPLETED';
  end if;

  v_readiness :=
    public.atlas_compute_installation_post_activation_readiness(
      v_installation.id
    );

  if not coalesce((v_readiness->>'ready')::boolean, false)
     or coalesce(
       (v_readiness->>'handoff_completed')::boolean,
       false
     )
     or v_readiness->>'activation_closure_id' <>
       v_closure.id::text
     or v_readiness->>'closure_sha256' <>
       v_closure.closure_sha256
     or v_readiness->>'installation_version' <>
       v_installation.version::text then
    raise exception using
      errcode = '42501',
      message = 'POST_ACTIVATION_HANDOFF_READINESS_INCOMPLETE',
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
    v_closure.id,
    'OBSERVATION_COMPLETED',
    v_actor_user_id,
    v_actor_role_code,
    'ATLAS_POST_ACTIVATION_HANDOFF_RPC',
    p_request_id,
    v_installation.version,
    p_evidence_reference,
    p_evidence_sha256,
    jsonb_build_object(
      'contract_version',
        'B2_POST_ACTIVATION_HANDOFF_EVENT_V1',
      'activation_closure_id', v_closure.id,
      'activation_authorization_id', v_authorization.id,
      'closure_sha256', v_closure.closure_sha256,
      'handoff_code', btrim(p_handoff_code),
      'support_plan_code', v_authorization.support_plan_code,
      'support_owner_binding_sha256',
        public.atlas_normalization_sha256(
          v_authorization.support_owner_user_id::text
        ),
      'observation_window_ends_at',
        v_closure.observation_window_ends_at,
      'readiness_sha256',
        v_readiness->>'readiness_sha256',
      'request_sha256', v_request_sha256
    ),
    jsonb_build_object('request_metadata', p_metadata)
  )
  returning * into v_created;

  v_after :=
    public.atlas_compute_installation_post_activation_readiness(
      v_installation.id
    );

  if not coalesce(
       (v_after->>'handoff_completed')::boolean,
       false
     )
     or v_after->>'handoff_event_id' <> v_created.id::text then
    raise exception using
      errcode = 'XX001',
      message = 'ACTIVATION_HANDOFF_POSTCONDITION_FAILED';
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
    'INSTALLATION_POST_ACTIVATION_HANDOFF_COMPLETED',
    'B2_POST_ACTIVATION_HANDOFF',
    'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'handoff_code', btrim(p_handoff_code),
      'request_sha256', v_request_sha256
    ),
    jsonb_build_object(
      'installation_id', v_installation.id,
      'activation_closure_id', v_closure.id,
      'handoff_event_id', v_created.id,
      'closure_sha256', v_closure.closure_sha256
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_POST_ACTIVATION_HANDOFF_COMPLETED',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'activation_closure_id', v_closure.id,
    'handoff_event_id', v_created.id,
    'handoff_code', btrim(p_handoff_code),
    'closure_sha256', v_closure.closure_sha256,
    'request_sha256', v_request_sha256,
    'handoff_completed', true,
    'next_action', 'CLOSE_ACTIVATION_LAYER_AND_CERTIFY_CONTINUITY'
  );
end;
$$;

revoke all on function
public.atlas_complete_installation_activation_handoff(
  uuid, text, text, text, uuid, bigint, jsonb
)
from public, anon;
grant execute on function
public.atlas_complete_installation_activation_handoff(
  uuid, text, text, text, uuid, bigint, jsonb
)
to authenticated, service_role;

comment on function
public.atlas_get_installation_post_activation_readiness(uuid) is
  'B2: proyeccion segura de ventana, soporte, incidencias y readiness del handoff posactivacion.';

comment on function
public.atlas_complete_installation_activation_handoff(
  uuid, text, text, text, uuid, bigint, jsonb
) is
  'B2: completa una sola vez el handoff tras observacion verificable y sin incidencias criticas.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2L4_POST_ACTIVATION_OBSERVATION_HANDOFF_RPCS_INSTALLED',
  'next_block',
    'B2.2L.5_ACTIVATION_LAYER_CLOSURE_AND_END_TO_END_CONTINUITY',
  'readiness_rpcs', 2,
  'handoff_rpcs', 1,
  'post_activation_criteria', 7,
  'handoff_permission_roles', 3,
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
  'handoff_completion_records', (
    select count(*)
    from public.atlas_installation_activation_events
    where event_type = 'OBSERVATION_COMPLETED'
  ),
  'single_handoff_completion_enforced', true,
  'closure_integrity_revalidation_enabled', true,
  'observation_window_enforced', true,
  'support_owner_revalidation_enabled', true,
  'critical_incident_guard_enabled', true,
  'activation_failure_guard_enabled', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'active_state_changed_by_handoff', false,
  'direct_authenticated_write', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
