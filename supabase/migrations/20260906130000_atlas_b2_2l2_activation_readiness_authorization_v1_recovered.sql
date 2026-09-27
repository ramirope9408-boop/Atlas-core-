-- ATLAS B2.2L.2 RECOVERED CONTRACT
-- Recovered 2026-09-27 from certified production definitions because the
-- historical B2.2L.2 migration is absent from the repository.
-- Restores activation readiness and authorization authority required by L3.

begin;

CREATE OR REPLACE FUNCTION public.atlas_compute_installation_activation_readiness(p_installation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_installation public.atlas_installations%rowtype;
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_certificate public.atlas_installation_certificates%rowtype;
  v_history_certificate public.atlas_installation_certificates%rowtype;
  v_g04_gate public.atlas_installation_gates%rowtype;
  v_authorization
    public.atlas_installation_activation_authorizations%rowtype;
  v_g04 jsonb := '{}'::jsonb;
  v_certificate_integrity jsonb := '{}'::jsonb;
  v_certificate_lifecycle jsonb := '{}'::jsonb;
  v_history_projection jsonb := '[]'::jsonb;
  v_history_root_sha256 text;
  v_criteria jsonb := '{}'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_payload jsonb;
  v_readiness_sha256 text;
  v_certificate_count integer := 0;
  v_initial_certificate_count integer := 0;
  v_max_certificate_version integer := 0;
  v_expected_certificate_version integer := 1;
  v_effective_certificate_count integer := 0;
  v_previous_certificate_id uuid;
  v_previous_evidence_root_sha256 text;
  v_history_chain_complete boolean := true;
  v_all_history_verified boolean := true;
  v_effective_certificate_latest boolean := true;
  v_gate_count integer := 0;
  v_approved_gate_count integer := 0;
  v_pre_g04_approved_count integer := 0;
  v_open_critical_defects integer := 0;
  v_support_owner_valid boolean := false;
  v_g04_precertificate_ready boolean := false;
  v_g04_ready_current boolean := false;
  v_certificate_valid boolean := false;
  v_zero_critical_defects boolean := false;
  v_all_gates_approved boolean := false;
  v_client_acceptance_current boolean := false;
  v_technical_security_current boolean := false;
  v_commercial_condition_current boolean := false;
  v_support_plan_assigned boolean := false;
  v_authorization_current boolean := false;
  v_preauthorization_ready boolean := false;
  v_ready boolean := false;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'contract_version', 'B2_INSTALLATION_ACTIVATION_READINESS_V1',
      'preauthorization_ready', false,
      'ready', false
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
      'contract_version', 'B2_INSTALLATION_ACTIVATION_READINESS_V1',
      'installation_id', p_installation_id,
      'preauthorization_ready', false,
      'ready', false
    );
  end if;

  v_g04 := public.atlas_compute_installation_g04_readiness(
    v_installation.id
  );
  v_g04_precertificate_ready := coalesce(
    (v_g04->>'precertificate_ready')::boolean,
    false
  );
  v_g04_ready_current := coalesce(
    (v_g04->>'ready')::boolean,
    false
  );
  v_client_acceptance_current := coalesce(
    (v_g04->>'client_acceptance_valid')::boolean,
    false
  );

  if nullif(v_g04->>'acceptance_package_id', '') is not null then
    select package.*
    into v_package
    from public.atlas_installation_acceptance_packages as package
    where package.id = (v_g04->>'acceptance_package_id')::uuid
      and package.installation_id = v_installation.id
      and package.empresa_id = v_installation.empresa_id
      and package.package_status = 'ACCEPTED';
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where certificate.supersedes_certificate_id is null
    )::integer,
    coalesce(max(certificate.certificate_version), 0)::integer
  into
    v_certificate_count,
    v_initial_certificate_count,
    v_max_certificate_version
  from public.atlas_installation_certificates as certificate
  where certificate.installation_id = v_installation.id
    and certificate.empresa_id = v_installation.empresa_id;

  for v_history_certificate in
    select certificate.*
    from public.atlas_installation_certificates as certificate
    where certificate.installation_id = v_installation.id
      and certificate.empresa_id = v_installation.empresa_id
    order by certificate.certificate_version, certificate.id
  loop
    v_certificate_integrity :=
      public.atlas_compute_installation_certificate_historical_integrity(
        v_history_certificate.id
      );
    v_certificate_lifecycle :=
      public.atlas_compute_installation_certificate_lifecycle(
        v_history_certificate.id
      );

    if not coalesce(
      (
        v_certificate_integrity
          ->>'historical_integrity_verified'
      )::boolean,
      false
    ) then
      v_all_history_verified := false;
    end if;

    if v_history_certificate.certificate_version <>
        v_expected_certificate_version
       or (
         v_expected_certificate_version = 1
         and v_history_certificate.supersedes_certificate_id is not null
       )
       or (
         v_expected_certificate_version > 1
         and v_history_certificate.supersedes_certificate_id
           is distinct from v_previous_certificate_id
       )
       or (
         v_expected_certificate_version > 1
         and v_history_certificate.evidence_root_sha256
           is distinct from v_previous_evidence_root_sha256
       ) then
      v_history_chain_complete := false;
    end if;

    if coalesce(
      (v_certificate_lifecycle->>'effective')::boolean,
      false
    ) then
      v_effective_certificate_count :=
        v_effective_certificate_count + 1;
      v_certificate := v_history_certificate;

      if v_history_certificate.certificate_version <>
          v_max_certificate_version then
        v_effective_certificate_latest := false;
      end if;
    end if;

    v_history_projection := v_history_projection ||
      jsonb_build_array(jsonb_build_object(
        'certificate_id', v_history_certificate.id,
        'certificate_version',
          v_history_certificate.certificate_version,
        'certificate_sha256',
          v_history_certificate.certificate_sha256,
        'evidence_root_sha256',
          v_history_certificate.evidence_root_sha256,
        'supersedes_certificate_id',
          v_history_certificate.supersedes_certificate_id,
        'historical_integrity_verified', coalesce(
          (
            v_certificate_integrity
              ->>'historical_integrity_verified'
          )::boolean,
          false
        ),
        'lifecycle_status',
          v_certificate_lifecycle->>'lifecycle_status',
        'effective', coalesce(
          (v_certificate_lifecycle->>'effective')::boolean,
          false
        )
      ));

    v_previous_certificate_id := v_history_certificate.id;
    v_previous_evidence_root_sha256 :=
      v_history_certificate.evidence_root_sha256;
    v_expected_certificate_version :=
      v_expected_certificate_version + 1;
  end loop;

  if v_certificate_count > 0 then
    v_history_chain_complete :=
      v_history_chain_complete
      and v_initial_certificate_count = 1
      and v_max_certificate_version = v_certificate_count;
  else
    v_all_history_verified := false;
    v_history_chain_complete := false;
  end if;

  v_history_chain_complete :=
    v_history_chain_complete
    and v_effective_certificate_count = 1
    and v_effective_certificate_latest;

  v_history_root_sha256 := public.atlas_normalization_sha256(
    v_history_projection::text
  );

  v_certificate_valid :=
    v_certificate.id is not null
    and v_package.id is not null
    and v_certificate.acceptance_package_id = v_package.id
    and v_certificate.issuance_status = 'ISSUED'
    and v_certificate.certified_state_code = 'FINAL_APPROVAL'
    and v_certificate.certificate_sha256 =
      public.atlas_normalization_sha256(
        v_certificate.certificate_payload::text
      )
    and v_all_history_verified
    and v_history_chain_complete;

  select
    count(*)::integer,
    count(*) filter (
      where gate_record.status = 'APPROVED'
    )::integer,
    count(*) filter (
      where gate_record.gate_code in ('G01', 'G02', 'G03')
        and gate_record.status = 'APPROVED'
    )::integer
  into
    v_gate_count,
    v_approved_gate_count,
    v_pre_g04_approved_count
  from public.atlas_installation_gates as gate_record
  where gate_record.installation_id = v_installation.id;

  select gate_record.*
  into v_g04_gate
  from public.atlas_installation_gates as gate_record
  where gate_record.installation_id = v_installation.id
    and gate_record.gate_code = 'G04';

  if v_package.id is not null then
    select count(*)::integer
    into v_open_critical_defects
    from public.atlas_installation_exception_records as exception_record
    where exception_record.installation_id = v_installation.id
      and exception_record.acceptance_package_id = v_package.id
      and exception_record.severity = 'CRITICAL'
      and exception_record.exception_status not in (
        'REMEDIATED', 'SUPERSEDED'
      );
  end if;

  v_zero_critical_defects :=
    v_package.id is not null
    and v_open_critical_defects = 0;
  v_all_gates_approved :=
    v_gate_count = 4
    and v_approved_gate_count = 4;
  v_technical_security_current :=
    v_pre_g04_approved_count = 3
    and coalesce(
      (v_g04->>'platform_acceptance_valid')::boolean,
      false
    );

  select authorization_record.*
  into v_authorization
  from public.atlas_installation_activation_authorizations
    as authorization_record
  where authorization_record.installation_id = v_installation.id
  order by
    authorization_record.authorization_version desc,
    authorization_record.created_at desc,
    authorization_record.id desc
  limit 1;

  if v_authorization.id is not null then
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
    ) into v_support_owner_valid;

    v_authorization_current :=
      v_authorization.decision = 'AUTHORIZED'
      and v_authorization.expected_installation_version =
        v_installation.version
      and v_package.id is not null
      and v_certificate.id is not null
      and v_g04_gate.id is not null
      and v_authorization.acceptance_package_id = v_package.id
      and v_authorization.certificate_id = v_certificate.id
      and v_authorization.g04_gate_id = v_g04_gate.id
      and v_authorization.source_certificate_sha256 =
        v_certificate.certificate_sha256
      and v_authorization.source_history_root_sha256 =
        v_history_root_sha256
      and v_support_owner_valid
      and exists (
        select 1
        from public.atlas_installation_acceptance_requirements
          as requirement
        where requirement.acceptance_package_id = v_package.id
          and requirement.requirement_code =
            'ACTIVE_STATE_AUTHORIZED'
          and requirement.requirement_status = 'SATISFIED'
          and requirement.evidence_reference =
            'gate://atlas/' || v_installation.id::text ||
            '/G04/authorization/' || v_authorization.id::text
          and requirement.evidence_sha256 =
            v_authorization.request_sha256
          and requirement.verification_payload
              ->>'activation_authorization_id' =
            v_authorization.id::text
          and requirement.verification_payload->>'request_sha256' =
            v_authorization.request_sha256
      );
  end if;

  v_commercial_condition_current :=
    v_authorization_current
    and v_authorization.commercial_condition_code ~
      '^[A-Z][A-Z0-9_]*$';
  v_support_plan_assigned :=
    v_authorization_current
    and v_authorization.support_plan_code ~
      '^[A-Z][A-Z0-9_-]*$'
    and v_support_owner_valid
    and v_authorization.observation_window_hours between 24 and 720;

  v_preauthorization_ready :=
    v_installation.current_state_code = 'FINAL_APPROVAL'
    and v_package.id is not null
    and v_g04_precertificate_ready
    and v_certificate_valid
    and v_zero_critical_defects
    and v_pre_g04_approved_count = 3
    and v_client_acceptance_current
    and v_technical_security_current
    and not exists (
      select 1
      from public.atlas_installation_activation_closures as closure
      where closure.installation_id = v_installation.id
    );

  v_criteria := jsonb_build_object(
    'G04_READY_CURRENT', v_g04_ready_current,
    'EFFECTIVE_CERTIFICATE_VERIFIED', v_certificate_valid,
    'ZERO_CRITICAL_DEFECTS', v_zero_critical_defects,
    'ALL_GATES_APPROVED', v_all_gates_approved,
    'CLIENT_ACCEPTANCE_CURRENT', v_client_acceptance_current,
    'TECHNICAL_SECURITY_APPROVAL_CURRENT',
      v_technical_security_current,
    'COMMERCIAL_CONDITION_CURRENT',
      v_commercial_condition_current,
    'SUPPORT_PLAN_ASSIGNED', v_support_plan_assigned
  );

  v_ready :=
    v_installation.current_state_code = 'FINAL_APPROVAL'
    and v_authorization_current
    and v_g04_ready_current
    and v_certificate_valid
    and v_zero_critical_defects
    and v_all_gates_approved
    and v_client_acceptance_current
    and v_technical_security_current
    and v_commercial_condition_current
    and v_support_plan_assigned
    and not exists (
      select 1
      from public.atlas_installation_activation_closures as closure
      where closure.installation_id = v_installation.id
    );

  select coalesce(jsonb_agg(blocker), '[]'::jsonb)
  into v_blockers
  from jsonb_array_elements(jsonb_build_array(
    case when v_installation.current_state_code <> 'FINAL_APPROVAL'
      then jsonb_build_object(
        'criterion', 'FINAL_APPROVAL_STATE',
        'reason', 'INSTALLATION_FINAL_APPROVAL_REQUIRED'
      ) end,
    case when not v_g04_precertificate_ready
      then jsonb_build_object(
        'criterion', 'G04_PRECERTIFICATE_READY',
        'reason', 'CURRENT_PRECERTIFICATE_EVIDENCE_REQUIRED'
      ) end,
    case when not v_certificate_valid
      then jsonb_build_object(
        'criterion', 'EFFECTIVE_CERTIFICATE_VERIFIED',
        'reason', 'CURRENT_VERIFIED_CERTIFICATE_REQUIRED'
      ) end,
    case when not v_zero_critical_defects
      then jsonb_build_object(
        'criterion', 'ZERO_CRITICAL_DEFECTS',
        'reason', 'CRITICAL_DEFECT_REMEDIATION_REQUIRED'
      ) end,
    case when v_pre_g04_approved_count <> 3
      then jsonb_build_object(
        'criterion', 'PRE_G04_GATES_APPROVED',
        'reason', 'G01_G02_G03_APPROVAL_REQUIRED'
      ) end,
    case when not v_client_acceptance_current
      then jsonb_build_object(
        'criterion', 'CLIENT_ACCEPTANCE_CURRENT',
        'reason', 'CURRENT_CLIENT_ACCEPTANCE_REQUIRED'
      ) end,
    case when not v_technical_security_current
      then jsonb_build_object(
        'criterion', 'TECHNICAL_SECURITY_APPROVAL_CURRENT',
        'reason', 'CURRENT_PLATFORM_TECHNICAL_APPROVAL_REQUIRED'
      ) end,
    case when v_authorization.id is null
      then jsonb_build_object(
        'criterion', 'ACTIVE_STATE_AUTHORIZED',
        'reason', 'ATLAS_OWNER_AUTHORIZATION_REQUIRED'
      ) end,
    case when v_authorization.id is not null
          and not v_authorization_current
      then jsonb_build_object(
        'criterion', 'ACTIVE_STATE_AUTHORIZED',
        'reason', 'CURRENT_BOUND_AUTHORIZATION_REQUIRED'
      ) end,
    case when not v_all_gates_approved
      then jsonb_build_object(
        'criterion', 'ALL_GATES_APPROVED',
        'reason', 'G04_APPROVAL_REQUIRED'
      ) end,
    case when v_authorization_current
          and not v_commercial_condition_current
      then jsonb_build_object(
        'criterion', 'COMMERCIAL_CONDITION_CURRENT',
        'reason', 'CURRENT_COMMERCIAL_ATTESTATION_REQUIRED'
      ) end,
    case when v_authorization_current
          and not v_support_plan_assigned
      then jsonb_build_object(
        'criterion', 'SUPPORT_PLAN_ASSIGNED',
        'reason', 'CURRENT_SUPPORT_PLAN_REQUIRED'
      ) end
  )) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  v_payload := jsonb_build_object(
    'contract_version',
      'B2_INSTALLATION_ACTIVATION_READINESS_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_version', v_installation.version,
    'installation_state', v_installation.current_state_code,
    'acceptance_package_id', v_package.id,
    'acceptance_package_sha256', v_package.package_sha256,
    'g04_gate_id', v_g04_gate.id,
    'g04_gate_version', v_g04_gate.gate_version,
    'g04_readiness_sha256', v_g04->>'readiness_sha256',
    'certificate_id', v_certificate.id,
    'certificate_version', v_certificate.certificate_version,
    'certificate_sha256', v_certificate.certificate_sha256,
    'certificate_history_root_sha256', v_history_root_sha256,
    'authorization_id', v_authorization.id,
    'authorization_version', v_authorization.authorization_version,
    'authorization_request_sha256', v_authorization.request_sha256,
    'criteria', v_criteria,
    'preauthorization_ready', v_preauthorization_ready,
    'ready', v_ready
  );
  v_readiness_sha256 := public.atlas_normalization_sha256(
    v_payload::text
  );

  return v_payload || jsonb_build_object(
    'ok', true,
    'code', case
      when v_ready then 'INSTALLATION_ACTIVATION_READY'
      when v_preauthorization_ready and not v_authorization_current
        then 'INSTALLATION_ACTIVATION_AUTHORIZATION_REQUIRED'
      else 'INSTALLATION_ACTIVATION_NOT_READY'
    end,
    'authorization_current', v_authorization_current,
    'effective_certificate_count',
      v_effective_certificate_count,
    'certificate_history_chain_complete',
      v_history_chain_complete,
    'certificate_history_verified', v_all_history_verified,
    'gate_count', v_gate_count,
    'approved_gate_count', v_approved_gate_count,
    'open_critical_defects', v_open_critical_defects,
    'readiness_sha256', v_readiness_sha256,
    'blockers', v_blockers,
    'active_transition_enabled', false,
    'closure_enabled', false,
    'raw_payloads_exposed', false,
    'credential_values_exposed', false,
    'evaluated_at', now(),
    'next_action', case
      when v_ready then 'EXECUTE_AUTHORIZED_ACTIVATION'
      when v_preauthorization_ready and not v_authorization_current
        then 'RECORD_ATLAS_OWNER_AUTHORIZATION'
      when v_authorization_current and not v_g04_ready_current
        then 'REVALIDATE_G04'
      when v_authorization_current and not v_all_gates_approved
        then 'DECIDE_G04'
      else 'COMPLETE_ACTIVATION_REQUIREMENTS'
    end
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.atlas_get_installation_activation_readiness(p_installation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  return public.atlas_compute_installation_activation_readiness(
    p_installation_id
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.atlas_authorize_installation_activation(p_installation_id uuid, p_decision text, p_commercial_condition_code text, p_support_plan_code text, p_support_owner_user_id uuid, p_observation_window_hours integer, p_reason text, p_evidence_reference text, p_evidence_sha256 text, p_request_id uuid, p_expected_installation_version bigint, p_metadata jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_installation public.atlas_installations%rowtype;
  v_existing
    public.atlas_installation_activation_authorizations%rowtype;
  v_created
    public.atlas_installation_activation_authorizations%rowtype;
  v_readiness_before jsonb;
  v_readiness_after jsonb;
  v_g04_after jsonb;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_authorization_id uuid := gen_random_uuid();
  v_authorization_version integer;
  v_support_owner_valid boolean := false;
  v_now timestamptz := clock_timestamp();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_installation_id is null
     or p_decision is null
     or p_decision not in ('AUTHORIZED', 'REJECTED')
     or p_commercial_condition_code is null
     or btrim(p_commercial_condition_code) !~
       '^[A-Z][A-Z0-9_]*$'
     or length(btrim(p_commercial_condition_code)) not between 5 and 100
     or p_support_plan_code is null
     or btrim(p_support_plan_code) !~ '^[A-Z][A-Z0-9_-]*$'
     or length(btrim(p_support_plan_code)) not between 5 and 100
     or p_support_owner_user_id is null
     or p_observation_window_hours is null
     or p_observation_window_hours not between 24 and 720
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
      message = 'ACTIVATION_AUTHORIZATION_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version',
      'B2_INSTALLATION_ACTIVATION_AUTHORIZATION_REQUEST_V1',
    'installation_id', p_installation_id,
    'decision', p_decision,
    'commercial_condition_code',
      btrim(p_commercial_condition_code),
    'support_plan_code', btrim(p_support_plan_code),
    'support_owner_user_id', p_support_owner_user_id,
    'observation_window_hours', p_observation_window_hours,
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

  select authorization_record.*
  into v_existing
  from public.atlas_installation_activation_authorizations
    as authorization_record
  where authorization_record.installation_id = p_installation_id
    and authorization_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'ACTIVATION_AUTHORIZATION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'activation_authorization_id', v_existing.id,
      'authorization_version', v_existing.authorization_version,
      'decision', v_existing.decision,
      'request_sha256', v_existing.request_sha256,
      'active_transition_enabled', false
    );
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_ACTIVATION_AUTHORIZE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ACTIVATION_AUTHORIZE_FORBIDDEN';
  end if;

  v_actor_role_code :=
    public.atlas_activation_platform_role_for_permission(
      'INSTALLATION_ACTIVATION_AUTHORIZE'
    );

  if v_actor_role_code <> 'ATLAS_OWNER' then
    raise exception using
      errcode = '42501',
      message = 'ACTIVATION_AUTHORIZATION_REQUIRES_ATLAS_OWNER';
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

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'FINAL_APPROVAL' then
    raise exception using
      errcode = '22023',
      message =
        'ACTIVATION_AUTHORIZATION_REQUIRES_FINAL_APPROVAL_STATE';
  end if;

  if exists (
    select 1
    from public.atlas_installation_activation_closures as closure
    where closure.installation_id = v_installation.id
  ) then
    raise exception using
      errcode = '23505',
      message = 'INSTALLATION_ACTIVATION_ALREADY_CLOSED';
  end if;

  if exists (
    select 1
    from public.atlas_installation_activation_authorizations
      as authorization_record
    where authorization_record.installation_id = v_installation.id
      and authorization_record.decision = 'AUTHORIZED'
  ) then
    raise exception using
      errcode = '23505',
      message = 'INSTALLATION_ACTIVATION_ALREADY_AUTHORIZED';
  end if;

  select exists (
    select 1
    from public.atlas_platform_memberships as membership
    join public.atlas_internal_roles as role_definition
      on role_definition.role_code = membership.role_code
     and role_definition.active
    where membership.user_id = p_support_owner_user_id
      and membership.status = 'ACTIVE'
      and membership.role_code in (
        'ATLAS_OWNER',
        'ATLAS_IMPLEMENTATION_OPERATOR',
        'ATLAS_SUPPORT_OPERATOR'
      )
  ) into v_support_owner_valid;

  if not v_support_owner_valid then
    raise exception using
      errcode = '42501',
      message = 'ACTIVE_PLATFORM_SUPPORT_OWNER_REQUIRED';
  end if;

  v_readiness_before :=
    public.atlas_compute_installation_activation_readiness(
      v_installation.id
    );

  if not coalesce(
    (v_readiness_before->>'preauthorization_ready')::boolean,
    false
  )
     or v_readiness_before->>'installation_version' <>
        v_installation.version::text
     or v_readiness_before->>'acceptance_package_id' is null
     or v_readiness_before->>'certificate_id' is null
     or v_readiness_before->>'g04_gate_id' is null then
    raise exception using
      errcode = '42501',
      message = 'ACTIVATION_PREAUTHORIZATION_INCOMPLETE',
      detail = coalesce(
        v_readiness_before->'blockers',
        '[]'::jsonb
      )::text;
  end if;

  select coalesce(max(authorization_record.authorization_version), 0) + 1
  into v_authorization_version
  from public.atlas_installation_activation_authorizations
    as authorization_record
  where authorization_record.installation_id = v_installation.id;

  insert into public.atlas_installation_activation_authorizations (
    id, installation_id, empresa_id, acceptance_package_id,
    certificate_id, g04_gate_id, authorization_version,
    decision, expected_installation_version,
    source_g04_readiness_sha256, source_certificate_sha256,
    source_history_root_sha256, commercial_condition_code,
    support_plan_code, support_owner_user_id,
    observation_window_hours, reason, evidence_reference,
    evidence_sha256, request_id, request_sha256,
    authorized_by_user_id, authorized_by_role_code,
    metadata, created_at
  ) values (
    v_authorization_id,
    v_installation.id,
    v_installation.empresa_id,
    (v_readiness_before->>'acceptance_package_id')::uuid,
    (v_readiness_before->>'certificate_id')::uuid,
    (v_readiness_before->>'g04_gate_id')::uuid,
    v_authorization_version,
    p_decision,
    v_installation.version,
    v_readiness_before->>'g04_readiness_sha256',
    v_readiness_before->>'certificate_sha256',
    v_readiness_before->>'certificate_history_root_sha256',
    btrim(p_commercial_condition_code),
    btrim(p_support_plan_code),
    p_support_owner_user_id,
    p_observation_window_hours,
    btrim(p_reason),
    p_evidence_reference,
    p_evidence_sha256,
    p_request_id,
    v_request_sha256,
    v_actor_user_id,
    v_actor_role_code,
    jsonb_build_object(
      'contract_version',
        'B2_INSTALLATION_ACTIVATION_AUTHORIZATION_V1',
      'preauthorization_readiness_sha256',
        v_readiness_before->>'readiness_sha256',
      'request_metadata', p_metadata
    ),
    v_now
  )
  returning * into v_created;

  if p_decision = 'AUTHORIZED' then
    update public.atlas_installation_acceptance_requirements
    set
      requirement_status = 'SATISFIED',
      evidence_kind = 'ACTIVATION_AUTHORIZATION',
      evidence_reference =
        'gate://atlas/' || v_installation.id::text ||
        '/G04/authorization/' || v_created.id::text,
      evidence_sha256 = v_created.request_sha256,
      verification_payload = jsonb_build_object(
        'contract_version',
          'B2_ACCEPTANCE_REQUIREMENT_EVIDENCE_V1',
        'requirement_code', 'ACTIVE_STATE_AUTHORIZED',
        'activation_authorization_id', v_created.id,
        'authorization_version',
          v_created.authorization_version,
        'decision', v_created.decision,
        'certificate_id', v_created.certificate_id,
        'certificate_sha256',
          v_created.source_certificate_sha256,
        'history_root_sha256',
          v_created.source_history_root_sha256,
        'commercial_condition_code',
          v_created.commercial_condition_code,
        'support_plan_code', v_created.support_plan_code,
        'support_owner_user_id',
          v_created.support_owner_user_id,
        'observation_window_hours',
          v_created.observation_window_hours,
        'request_sha256', v_created.request_sha256
      ),
      verified_by_user_id = v_actor_user_id,
      verified_at = v_now,
      blocking_reason_code = null,
      updated_at = v_now
    where acceptance_package_id = v_created.acceptance_package_id
      and requirement_code = 'ACTIVE_STATE_AUTHORIZED'
      and requirement_status <> 'SATISFIED';

    if not found then
      raise exception using
        errcode = '42501',
        message = 'G04_ACTIVATION_AUTHORIZATION_REQUIREMENT_UPDATE_FAILED';
    end if;
  end if;

  insert into public.atlas_installation_activation_events (
    installation_id, empresa_id, activation_authorization_id,
    activation_closure_id, event_type, actor_user_id,
    actor_role_code, executor_code, request_id,
    installation_version, evidence_reference, evidence_sha256,
    event_payload, metadata, created_at
  ) values (
    v_installation.id,
    v_installation.empresa_id,
    v_created.id,
    null,
    case
      when p_decision = 'AUTHORIZED'
        then 'AUTHORIZATION_RECORDED'
      else 'AUTHORIZATION_REJECTED'
    end,
    v_actor_user_id,
    v_actor_role_code,
    'ATLAS_ACTIVATION_AUTHORITY_RPC',
    p_request_id,
    v_installation.version,
    p_evidence_reference,
    p_evidence_sha256,
    jsonb_build_object(
      'contract_version',
        'B2_INSTALLATION_ACTIVATION_EVENT_V1',
      'activation_authorization_id', v_created.id,
      'authorization_version', v_created.authorization_version,
      'decision', v_created.decision,
      'acceptance_package_id', v_created.acceptance_package_id,
      'certificate_id', v_created.certificate_id,
      'g04_gate_id', v_created.g04_gate_id,
      'request_sha256', v_created.request_sha256,
      'source_g04_readiness_sha256',
        v_created.source_g04_readiness_sha256,
      'source_certificate_sha256',
        v_created.source_certificate_sha256,
      'source_history_root_sha256',
        v_created.source_history_root_sha256
    ),
    jsonb_build_object('request_metadata', p_metadata),
    v_now
  );

  v_g04_after := public.atlas_compute_installation_g04_readiness(
    v_installation.id
  );

  if p_decision = 'AUTHORIZED'
     and not coalesce((v_g04_after->>'ready')::boolean, false) then
    raise exception using
      errcode = 'XX001',
      message = 'G04_NOT_READY_AFTER_ACTIVATION_AUTHORIZATION',
      detail = coalesce(v_g04_after->'blockers', '[]'::jsonb)::text;
  end if;

  v_readiness_after :=
    public.atlas_compute_installation_activation_readiness(
      v_installation.id
    );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when p_decision = 'AUTHORIZED'
        then 'INSTALLATION_ACTIVATION_AUTHORIZED'
      else 'INSTALLATION_ACTIVATION_REJECTED'
    end,
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'activation_authorization_id', v_created.id,
    'authorization_version', v_created.authorization_version,
    'decision', v_created.decision,
    'request_sha256', v_created.request_sha256,
    'g04_ready', coalesce(
      (v_g04_after->>'ready')::boolean,
      false
    ),
    'activation_ready', coalesce(
      (v_readiness_after->>'ready')::boolean,
      false
    ),
    'active_transition_enabled', false,
    'closure_enabled', false,
    'next_action', case
      when p_decision = 'REJECTED'
        then 'RESOLVE_REJECTION_AND_REAUTHORIZE'
      when coalesce(
        (v_readiness_after->>'approved_gate_count')::integer,
        0
      ) < 4 then 'DECIDE_G04'
      else 'EXECUTE_AUTHORIZED_ACTIVATION'
    end
  );
end;
$function$
;

revoke all on function public.atlas_compute_installation_activation_readiness(uuid) from public, anon;
grant execute on function public.atlas_compute_installation_activation_readiness(uuid) to authenticated, service_role;

revoke all on function public.atlas_get_installation_activation_readiness(uuid) from public, anon;
grant execute on function public.atlas_get_installation_activation_readiness(uuid) to authenticated, service_role;

revoke all on function public.atlas_authorize_installation_activation(uuid,text,text,text,uuid,integer,text,text,text,uuid,bigint,jsonb) from public, anon;
grant execute on function public.atlas_authorize_installation_activation(uuid,text,text,text,uuid,integer,text,text,text,uuid,bigint,jsonb) to authenticated, service_role;

commit;
