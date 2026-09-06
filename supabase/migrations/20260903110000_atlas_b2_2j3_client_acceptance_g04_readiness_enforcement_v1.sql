-- ATLAS B2.2J.3
-- Aceptacion verificable del cliente y enforcement objetivo de G04.
-- Corte: 2026-09-03
--
-- Principios:
-- - la aceptacion del paquete es distinta de la aprobacion del gate G04;
-- - CLIENT exige el OWNER canonico de la empresa;
-- - PLATFORM exige autoridad Atlas con INSTALLATION_ACCEPTANCE_REVIEW;
-- - la aceptacion es dual, append-only, idempotente y ligada al hash del paquete;
-- - precertificate_ready cubre los seis criterios previos al certificado;
-- - G04 ready exige ademas certificado y autorizacion de activacion;
-- - G04 se revalida al decidir y antes de entrar a ACTIVE;
-- - este bloque no crea datos ficticios, no emite certificados, no decide G04
--   y no activa instalaciones.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_acceptance_packages'
     ) is null
     or to_regclass(
       'public.atlas_installation_acceptance_requirements'
     ) is null
     or to_regclass(
       'public.atlas_installation_acceptance_decisions'
     ) is null
     or to_regclass(
       'public.atlas_installation_acceptance_events'
     ) is null
     or to_regprocedure(
       'public.atlas_submit_installation_acceptance_package(uuid,text,text,jsonb,uuid,bigint,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_g03_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_decide_installation_gate(uuid,text,text,text,text,jsonb,uuid,bigint)'
     ) is null
     or to_regprocedure(
       'public.atlas_acceptance_current_user_is_client_owner(uuid)'
     ) is null then
    raise exception
      'B2.2J.3 requiere B2.2J.2 y enforcement G03 instalados y certificados';
  end if;

  if exists (
    select 1
    from public.atlas_installation_acceptance_decisions
  ) then
    raise exception
      'B2.2J.3 requiere ledger de decisiones de aceptacion vacio para instalar concurrencia';
  end if;

  if (
    select count(*)
    from public.atlas_installation_acceptance_requirement_definitions
    where active
  ) <> 8 then
    raise exception 'B2.2J.3 requiere ocho requisitos G04 canonicos';
  end if;
end;
$$;

alter table public.atlas_installation_acceptance_decisions
  add column decision_contract_version text
    not null default 'B2_ACCEPTANCE_DECISION_V1';
alter table public.atlas_installation_acceptance_decisions
  add column request_sha256 text;
alter table public.atlas_installation_acceptance_decisions
  add column expected_installation_version bigint;
alter table public.atlas_installation_acceptance_decisions
  add column expected_package_state_version bigint;
alter table public.atlas_installation_acceptance_decisions
  add column metadata jsonb not null default '{}'::jsonb;

alter table public.atlas_installation_acceptance_decisions
  alter column request_sha256 set not null;
alter table public.atlas_installation_acceptance_decisions
  alter column expected_installation_version set not null;
alter table public.atlas_installation_acceptance_decisions
  alter column expected_package_state_version set not null;

alter table public.atlas_installation_acceptance_decisions
  add constraint atlas_acceptance_decisions_contract_check
  check (
    decision_contract_version = 'B2_ACCEPTANCE_DECISION_V1'
    and expected_installation_version >= 1
    and expected_package_state_version >= 1
  );
alter table public.atlas_installation_acceptance_decisions
  add constraint atlas_acceptance_decisions_request_sha256_check
  check (request_sha256 ~ '^[0-9a-f]{64}$');
alter table public.atlas_installation_acceptance_decisions
  add constraint atlas_acceptance_decisions_metadata_check
  check (
    jsonb_typeof(metadata) = 'object'
    and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
  );

create or replace function
public.atlas_compute_installation_g04_readiness(
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
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_g03_readiness jsonb;
  v_g03_current boolean := false;
  v_package_hash_valid boolean := false;
  v_package_binding_valid boolean := false;
  v_required_count integer := 0;
  v_satisfied_count integer := 0;
  v_precertificate_satisfied_count integer := 0;
  v_client_decision public.atlas_installation_acceptance_decisions%rowtype;
  v_platform_decision public.atlas_installation_acceptance_decisions%rowtype;
  v_client_acceptance_valid boolean := false;
  v_platform_acceptance_valid boolean := false;
  v_decision_evidence_root_sha256 text;
  v_criteria jsonb := '{}'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_preacceptance_ready boolean := false;
  v_precertificate_ready boolean := false;
  v_ready boolean := false;
  v_readiness_payload jsonb;
  v_readiness_sha256 text;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'contract_version', 'B2_ACCEPTANCE_READINESS_G04_V1',
      'precertificate_ready', false,
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
      'contract_version', 'B2_ACCEPTANCE_READINESS_G04_V1',
      'installation_id', p_installation_id,
      'precertificate_ready', false,
      'ready', false
    );
  end if;

  select package.*
  into v_package
  from public.atlas_installation_acceptance_packages as package
  where package.installation_id = v_installation.id
    and package.empresa_id = v_installation.empresa_id
    and package.package_status <> 'SUPERSEDED'
  order by
    package.acceptance_version desc,
    package.created_at desc,
    package.id desc
  limit 1;

  if v_package.id is not null then
    v_g03_readiness :=
      public.atlas_compute_installation_g03_readiness(
        v_installation.id
      );

    v_g03_current :=
      coalesce((v_g03_readiness->>'ready')::boolean, false)
      and v_g03_readiness->>'test_plan_id' =
        v_package.source_test_plan_id::text
      and v_g03_readiness->>'test_run_id' =
        v_package.source_test_run_id::text
      and v_g03_readiness->>'source_manifest_id' =
        v_package.source_manifest_id::text
      and v_g03_readiness->>'plan_sha256' =
        v_package.source_test_plan_sha256
      and v_g03_readiness->>'evidence_root_sha256' =
        v_package.source_test_evidence_root_sha256
      and v_g03_readiness->>'source_manifest_sha256' =
        v_package.source_manifest_sha256
      and v_g03_readiness->>'readiness_sha256' =
        v_package.source_g03_readiness_sha256;

    v_package_hash_valid :=
      v_package.acceptance_contract_version =
        'B2_INSTALLATION_ACCEPTANCE_V1'
      and v_package.package_sha256 =
        public.atlas_normalization_sha256(
          v_package.package_payload::text
        )
      and not public.atlas_jsonb_has_forbidden_secret_key(
        v_package.package_payload
      );

    v_package_binding_valid :=
      v_package.expected_installation_version =
        v_installation.version
      and v_package.package_status in (
        'DELIVERED', 'UNDER_CLIENT_REVIEW', 'ACCEPTED'
      )
      and v_package.delivered_at is not null
      and public.atlas_acceptance_evidence_reference_is_safe(
        v_package.delivery_evidence_reference
      )
      and v_package.delivery_evidence_sha256 ~
        '^[0-9a-f]{64}$';

    select
      count(*)::integer,
      count(*) filter (
        where requirement.requirement_status = 'SATISFIED'
      )::integer,
      count(*) filter (
        where requirement.requirement_code in (
          'FUNCTIONAL_CASES_APPROVED',
          'SECURITY_TESTS_APPROVED',
          'ZERO_CRITICAL_DEFECTS',
          'EXCEPTIONS_ACCEPTED',
          'TRAINING_COMPLETED',
          'ACCEPTANCE_RECORDED'
        )
          and requirement.requirement_status = 'SATISFIED'
      )::integer,
      coalesce(
        jsonb_object_agg(
          requirement.requirement_code,
          requirement.requirement_status = 'SATISFIED'
          order by definition.sort_order
        ),
        '{}'::jsonb
      )
    into
      v_required_count,
      v_satisfied_count,
      v_precertificate_satisfied_count,
      v_criteria
    from public.atlas_installation_acceptance_requirements
      as requirement
    join public.atlas_installation_acceptance_requirement_definitions
      as definition
      on definition.requirement_code = requirement.requirement_code
     and definition.active
    where requirement.acceptance_package_id = v_package.id;

    select decision_record.*
    into v_client_decision
    from public.atlas_installation_acceptance_decisions
      as decision_record
    where decision_record.acceptance_package_id = v_package.id
      and decision_record.acceptance_version =
        v_package.acceptance_version
      and decision_record.authority_type = 'CLIENT'
    order by decision_record.created_at desc, decision_record.id desc
    limit 1;

    select decision_record.*
    into v_platform_decision
    from public.atlas_installation_acceptance_decisions
      as decision_record
    where decision_record.acceptance_package_id = v_package.id
      and decision_record.acceptance_version =
        v_package.acceptance_version
      and decision_record.authority_type = 'PLATFORM'
    order by decision_record.created_at desc, decision_record.id desc
    limit 1;

    v_client_acceptance_valid :=
      v_client_decision.id is not null
      and v_client_decision.decision = 'ACCEPTED'
      and v_client_decision.package_sha256 = v_package.package_sha256
      and v_client_decision.expected_installation_version =
        v_installation.version
      and v_client_decision.decision_contract_version =
        'B2_ACCEPTANCE_DECISION_V1'
      and v_client_decision.request_sha256 ~ '^[0-9a-f]{64}$';

    v_platform_acceptance_valid :=
      v_platform_decision.id is not null
      and v_platform_decision.decision = 'ACCEPTED'
      and v_platform_decision.package_sha256 = v_package.package_sha256
      and v_platform_decision.expected_installation_version =
        v_installation.version
      and v_platform_decision.decision_contract_version =
        'B2_ACCEPTANCE_DECISION_V1'
      and v_platform_decision.request_sha256 ~ '^[0-9a-f]{64}$';

    v_decision_evidence_root_sha256 :=
      public.atlas_normalization_sha256(
        jsonb_build_object(
          'contract_version', 'B2_ACCEPTANCE_DECISION_ROOT_V1',
          'acceptance_package_id', v_package.id,
          'package_sha256', v_package.package_sha256,
          'client_decision_id', v_client_decision.id,
          'client_request_sha256', v_client_decision.request_sha256,
          'client_evidence_sha256', v_client_decision.evidence_sha256,
          'platform_decision_id', v_platform_decision.id,
          'platform_request_sha256', v_platform_decision.request_sha256,
          'platform_evidence_sha256', v_platform_decision.evidence_sha256
        )::text
      );
  end if;

  v_preacceptance_ready :=
    v_package.id is not null
    and v_installation.current_state_code = 'FINAL_APPROVAL'
    and v_g03_current
    and v_package_hash_valid
    and v_package_binding_valid
    and v_required_count = 8
    and coalesce((v_criteria->>'FUNCTIONAL_CASES_APPROVED')::boolean, false)
    and coalesce((v_criteria->>'SECURITY_TESTS_APPROVED')::boolean, false)
    and coalesce((v_criteria->>'ZERO_CRITICAL_DEFECTS')::boolean, false)
    and coalesce((v_criteria->>'EXCEPTIONS_ACCEPTED')::boolean, false)
    and coalesce((v_criteria->>'TRAINING_COMPLETED')::boolean, false);

  v_precertificate_ready :=
    v_preacceptance_ready
    and v_client_acceptance_valid
    and v_platform_acceptance_valid
    and v_package.package_status = 'ACCEPTED'
    and v_precertificate_satisfied_count = 6
    and coalesce((v_criteria->>'ACCEPTANCE_RECORDED')::boolean, false);

  v_ready :=
    v_precertificate_ready
    and v_satisfied_count = 8
    and coalesce(
      (v_criteria->>'INSTALLATION_CERTIFICATE_ISSUED')::boolean,
      false
    )
    and coalesce(
      (v_criteria->>'ACTIVE_STATE_AUTHORIZED')::boolean,
      false
    );

  select coalesce(jsonb_agg(blocker), '[]'::jsonb)
  into v_blockers
  from jsonb_array_elements(jsonb_build_array(
    case when v_package.id is null then jsonb_build_object(
      'criterion', 'ACCEPTANCE_PACKAGE_PRESENT',
      'reason', 'CURRENT_ACCEPTANCE_PACKAGE_REQUIRED'
    ) end,
    case when v_package.id is not null and not v_g03_current
      then jsonb_build_object(
        'criterion', 'G03_READINESS_CURRENT',
        'reason', 'CURRENT_G03_EVIDENCE_REQUIRED'
      ) end,
    case when v_package.id is not null and not v_package_hash_valid
      then jsonb_build_object(
        'criterion', 'ACCEPTANCE_PACKAGE_HASH_VALID',
        'reason', 'CANONICAL_PACKAGE_HASH_REQUIRED'
      ) end,
    case when v_package.id is not null and not v_package_binding_valid
      then jsonb_build_object(
        'criterion', 'ACCEPTANCE_PACKAGE_CURRENT',
        'reason', 'DELIVERED_CURRENT_VERSION_PACKAGE_REQUIRED'
      ) end,
    case when v_package.id is not null and v_required_count <> 8
      then jsonb_build_object(
        'criterion', 'G04_REQUIREMENT_SET_COMPLETE',
        'reason', 'EXACT_EIGHT_REQUIREMENTS_REQUIRED'
      ) end,
    case when v_package.id is not null and not v_preacceptance_ready
      then jsonb_build_object(
        'criterion', 'DELIVERY_BASIS_COMPLETE',
        'reason', 'TESTS_DEFECTS_EXCEPTIONS_AND_TRAINING_REQUIRED'
      ) end,
    case when v_package.id is not null and not v_client_acceptance_valid
      then jsonb_build_object(
        'criterion', 'CLIENT_ACCEPTANCE_RECORDED',
        'reason', 'CLIENT_OWNER_ACCEPTANCE_REQUIRED'
      ) end,
    case when v_package.id is not null and not v_platform_acceptance_valid
      then jsonb_build_object(
        'criterion', 'PLATFORM_ACCEPTANCE_RECORDED',
        'reason', 'ATLAS_FINAL_REVIEW_REQUIRED'
      ) end,
    case when v_package.id is not null and not coalesce(
      (v_criteria->>'INSTALLATION_CERTIFICATE_ISSUED')::boolean,
      false
    ) then jsonb_build_object(
      'criterion', 'INSTALLATION_CERTIFICATE_ISSUED',
      'reason', 'B2_K_CERTIFICATE_REQUIRED'
    ) end,
    case when v_package.id is not null and not coalesce(
      (v_criteria->>'ACTIVE_STATE_AUTHORIZED')::boolean,
      false
    ) then jsonb_build_object(
      'criterion', 'ACTIVE_STATE_AUTHORIZED',
      'reason', 'B2_L_ACTIVATION_AUTHORITY_REQUIRED'
    ) end
  )) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  v_readiness_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_READINESS_G04_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_version', v_installation.version,
    'acceptance_package_id', v_package.id,
    'acceptance_version', v_package.acceptance_version,
    'package_status', v_package.package_status,
    'package_state_version', v_package.state_version,
    'package_sha256', v_package.package_sha256,
    'g03_readiness_sha256', v_package.source_g03_readiness_sha256,
    'decision_evidence_root_sha256',
      v_decision_evidence_root_sha256,
    'required_requirements', v_required_count,
    'satisfied_requirements', v_satisfied_count,
    'precertificate_satisfied_requirements',
      v_precertificate_satisfied_count,
    'client_acceptance_valid', v_client_acceptance_valid,
    'platform_acceptance_valid', v_platform_acceptance_valid,
    'criteria', v_criteria,
    'precertificate_ready', v_precertificate_ready,
    'ready', v_ready
  );
  v_readiness_sha256 := public.atlas_normalization_sha256(
    v_readiness_payload::text
  );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_ready then 'G04_ACCEPTANCE_READINESS_COMPLETE'
      when v_precertificate_ready then
        'G04_PRECERTIFICATE_READINESS_COMPLETE'
      else 'G04_ACCEPTANCE_READINESS_INCOMPLETE'
    end,
    'contract_version', 'B2_ACCEPTANCE_READINESS_G04_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'acceptance_package_id', v_package.id,
    'acceptance_version', v_package.acceptance_version,
    'package_status', v_package.package_status,
    'package_state_version', v_package.state_version,
    'package_sha256', v_package.package_sha256,
    'g03_readiness_current', v_g03_current,
    'package_hash_valid', v_package_hash_valid,
    'package_binding_valid', v_package_binding_valid,
    'preacceptance_ready', v_preacceptance_ready,
    'client_acceptance_valid', v_client_acceptance_valid,
    'platform_acceptance_valid', v_platform_acceptance_valid,
    'decision_evidence_root_sha256',
      v_decision_evidence_root_sha256,
    'required_requirements', v_required_count,
    'satisfied_requirements', v_satisfied_count,
    'precertificate_satisfied_requirements',
      v_precertificate_satisfied_count,
    'criteria', v_criteria,
    'precertificate_ready', v_precertificate_ready,
    'ready', v_ready,
    'readiness_sha256', v_readiness_sha256,
    'blockers', v_blockers,
    'certificate_issuance_enabled', false,
    'active_transition_enabled', false,
    'credential_values_exposed', false,
    'evaluated_at', now(),
    'next_action', case
      when v_ready then 'DECIDE_G04'
      when v_precertificate_ready then 'ISSUE_INSTALLATION_CERTIFICATE'
      when not v_client_acceptance_valid then 'RECORD_CLIENT_ACCEPTANCE'
      when not v_platform_acceptance_valid then 'RECORD_PLATFORM_ACCEPTANCE'
      else 'COMPLETE_ACCEPTANCE_REQUIREMENTS'
    end
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_g04_readiness(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_g04_readiness(uuid)
to service_role;

create or replace function
public.atlas_get_installation_g04_readiness(
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
     and not public.atlas_can_read_installation(
       p_installation_id
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_G04_READ_FORBIDDEN';
  end if;

  return public.atlas_compute_installation_g04_readiness(
    p_installation_id
  );
end;
$$;

revoke all on function
public.atlas_get_installation_g04_readiness(uuid)
from public, anon;
grant execute on function
public.atlas_get_installation_g04_readiness(uuid)
to authenticated, service_role;

create or replace function
public.atlas_decide_installation_acceptance(
  p_acceptance_package_id uuid,
  p_authority_type text,
  p_decision text,
  p_reason text,
  p_decision_details jsonb,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_request_id uuid,
  p_expected_installation_version bigint,
  p_expected_package_state_version bigint,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_authority_type text := upper(nullif(btrim(p_authority_type), ''));
  v_decision text := upper(nullif(btrim(p_decision), ''));
  v_actor_role_code text;
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_installation_acceptance_decisions%rowtype;
  v_created public.atlas_installation_acceptance_decisions%rowtype;
  v_client_decision public.atlas_installation_acceptance_decisions%rowtype;
  v_readiness_before jsonb;
  v_readiness_after jsonb;
  v_request_payload jsonb;
  v_decision_evidence jsonb;
  v_event_payload jsonb;
  v_request_sha256 text;
  v_new_package_status text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_acceptance_package_id is null
     or v_authority_type not in ('CLIENT', 'PLATFORM')
     or v_decision not in (
       'ACCEPTED', 'REJECTED', 'CHANGES_REQUIRED'
     )
     or p_reason is null
     or length(btrim(p_reason)) not between 5 and 2000
     or p_decision_details is null
     or jsonb_typeof(p_decision_details) <> 'object'
     or p_decision_details = '{}'::jsonb
     or not public.atlas_acceptance_evidence_reference_is_safe(
       p_evidence_reference
     )
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_expected_package_state_version is null
     or p_expected_package_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_decision_details
     )
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'ACCEPTANCE_DECISION_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_DECISION_REQUEST_V1',
    'acceptance_package_id', p_acceptance_package_id,
    'authority_type', v_authority_type,
    'decision', v_decision,
    'reason', btrim(p_reason),
    'decision_details', p_decision_details,
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', p_evidence_sha256,
    'expected_installation_version',
      p_expected_installation_version,
    'expected_package_state_version',
      p_expected_package_state_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select package.*
  into v_package
  from public.atlas_installation_acceptance_packages as package
  where package.id = p_acceptance_package_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'ACCEPTANCE_PACKAGE_NOT_FOUND';
  end if;

  select decision_record.*
  into v_existing
  from public.atlas_installation_acceptance_decisions
    as decision_record
  where decision_record.acceptance_package_id = v_package.id
    and decision_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'ACCEPTANCE_DECISION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'acceptance_decision_id', v_existing.id,
      'acceptance_package_id', v_existing.acceptance_package_id,
      'authority_type', v_existing.authority_type,
      'decision', v_existing.decision,
      'package_status', v_package.package_status,
      'package_state_version', v_package.state_version,
      'next_action', case
        when v_package.package_status = 'ACCEPTED'
          then 'ISSUE_INSTALLATION_CERTIFICATE'
        else 'COMPLETE_DUAL_ACCEPTANCE'
      end
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_package.installation_id
  for update;

  if v_installation.version <>
       p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_package.state_version <>
       p_expected_package_state_version then
    raise exception using
      errcode = '40001',
      message = 'ACCEPTANCE_PACKAGE_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> 'FINAL_APPROVAL'
     or v_package.package_status not in (
       'DELIVERED', 'UNDER_CLIENT_REVIEW'
     ) then
    raise exception using
      errcode = '22023',
      message = 'ACCEPTANCE_DECISION_NOT_ALLOWED_IN_CURRENT_STATE';
  end if;

  if v_authority_type = 'CLIENT' then
    if v_installation.client_owner_user_id is null
       or v_installation.client_owner_user_id <> v_actor_user_id
       or not public.atlas_acceptance_current_user_is_client_owner(
         v_installation.empresa_id
       ) then
      raise exception using
        errcode = '42501',
        message = 'CLIENT_OWNER_NOT_AUTHORIZED_FOR_ACCEPTANCE';
    end if;

    v_actor_role_code := 'OWNER';
  else
    if not public.atlas_platform_has_permission(
      'INSTALLATION_ACCEPTANCE_REVIEW'
    ) then
      raise exception using
        errcode = '42501',
        message = 'INSTALLATION_ACCEPTANCE_REVIEW_FORBIDDEN';
    end if;

    v_actor_role_code :=
      public.atlas_acceptance_platform_role_for_permission(
        'INSTALLATION_ACCEPTANCE_REVIEW'
      );

    if v_actor_role_code <> 'ATLAS_OWNER' then
      raise exception using
        errcode = '42501',
        message = 'PLATFORM_ACCEPTANCE_REQUIRES_ATLAS_OWNER';
    end if;
  end if;

  if exists (
    select 1
    from public.atlas_installation_acceptance_decisions
      as decision_record
    where decision_record.acceptance_package_id = v_package.id
      and decision_record.acceptance_version =
        v_package.acceptance_version
      and decision_record.authority_type = v_authority_type
  ) then
    raise exception using
      errcode = '23505',
      message = 'ACCEPTANCE_AUTHORITY_ALREADY_DECIDED';
  end if;

  v_readiness_before :=
    public.atlas_compute_installation_g04_readiness(
      v_installation.id
    );

  if v_decision = 'ACCEPTED'
     and not coalesce(
       (v_readiness_before->>'preacceptance_ready')::boolean,
       false
     ) then
    raise exception using
      errcode = '42501',
      message = 'ACCEPTANCE_OBJECTIVE_BASIS_INCOMPLETE',
      detail = coalesce(
        v_readiness_before->'blockers',
        '[]'::jsonb
      )::text;
  end if;

  if v_authority_type = 'PLATFORM'
     and v_decision = 'ACCEPTED' then
    select decision_record.*
    into v_client_decision
    from public.atlas_installation_acceptance_decisions
      as decision_record
    where decision_record.acceptance_package_id = v_package.id
      and decision_record.acceptance_version =
        v_package.acceptance_version
      and decision_record.authority_type = 'CLIENT'
      and decision_record.decision = 'ACCEPTED'
      and decision_record.package_sha256 = v_package.package_sha256
    limit 1;

    if not found then
      raise exception using
        errcode = '42501',
        message = 'PLATFORM_ACCEPTANCE_REQUIRES_CLIENT_ACCEPTANCE';
    end if;
  end if;

  v_decision_evidence := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_DECISION_EVIDENCE_V1',
    'acceptance_package_id', v_package.id,
    'acceptance_version', v_package.acceptance_version,
    'package_sha256', v_package.package_sha256,
    'authority_type', v_authority_type,
    'decision', v_decision,
    'decision_details', p_decision_details,
    'preacceptance_readiness_sha256',
      v_readiness_before->>'readiness_sha256'
  );

  insert into public.atlas_installation_acceptance_decisions (
    acceptance_package_id,
    installation_id,
    empresa_id,
    authority_type,
    decision,
    actor_user_id,
    actor_role_code,
    reason,
    decision_evidence,
    evidence_reference,
    evidence_sha256,
    package_sha256,
    acceptance_version,
    request_id,
    decision_contract_version,
    request_sha256,
    expected_installation_version,
    expected_package_state_version,
    metadata
  )
  values (
    v_package.id,
    v_installation.id,
    v_installation.empresa_id,
    v_authority_type,
    v_decision,
    v_actor_user_id,
    v_actor_role_code,
    btrim(p_reason),
    v_decision_evidence,
    p_evidence_reference,
    p_evidence_sha256,
    v_package.package_sha256,
    v_package.acceptance_version,
    p_request_id,
    'B2_ACCEPTANCE_DECISION_V1',
    v_request_sha256,
    v_installation.version,
    v_package.state_version,
    jsonb_build_object(
      'request_contract', v_request_payload,
      'request_metadata', p_metadata
    )
  )
  returning * into v_created;

  if v_authority_type = 'CLIENT'
     and v_decision = 'ACCEPTED' then
    update public.atlas_installation_acceptance_requirements
    set
      requirement_status = 'SATISFIED',
      evidence_kind = 'SIGNED_ACCEPTANCE',
      evidence_reference = p_evidence_reference,
      evidence_sha256 = p_evidence_sha256,
      verification_payload = jsonb_build_object(
        'contract_version',
          'B2_ACCEPTANCE_REQUIREMENT_EVIDENCE_V1',
        'requirement_code', 'ACCEPTANCE_RECORDED',
        'acceptance_decision_id', v_created.id,
        'authority_type', v_created.authority_type,
        'decision', v_created.decision,
        'package_sha256', v_created.package_sha256,
        'request_sha256', v_created.request_sha256
      ),
      verified_by_user_id = v_actor_user_id,
      verified_at = clock_timestamp(),
      blocking_reason_code = null,
      updated_at = clock_timestamp()
    where acceptance_package_id = v_package.id
      and requirement_code = 'ACCEPTANCE_RECORDED';
  end if;

  if v_decision in ('REJECTED', 'CHANGES_REQUIRED') then
    v_new_package_status := v_decision;
  elsif v_authority_type = 'PLATFORM' then
    v_new_package_status := 'ACCEPTED';
  else
    v_new_package_status := 'UNDER_CLIENT_REVIEW';
  end if;

  update public.atlas_installation_acceptance_packages
  set
    package_status = v_new_package_status,
    state_version = state_version + 1,
    closed_at = case
      when v_new_package_status in (
        'ACCEPTED', 'REJECTED', 'CHANGES_REQUIRED'
      ) then clock_timestamp()
      else null
    end,
    metadata = metadata || jsonb_build_object(
      'last_acceptance_decision_id', v_created.id,
      'last_acceptance_authority', v_authority_type,
      'last_acceptance_decision', v_decision,
      'last_acceptance_request_sha256', v_request_sha256
    ),
    updated_at = clock_timestamp()
  where id = v_package.id
  returning * into v_package;

  v_readiness_after :=
    public.atlas_compute_installation_g04_readiness(
      v_installation.id
    );

  v_event_payload := jsonb_build_object(
    'contract_version', 'B2_ACCEPTANCE_EVENT_V1',
    'acceptance_decision_id', v_created.id,
    'acceptance_package_id', v_package.id,
    'package_sha256', v_package.package_sha256,
    'request_sha256', v_created.request_sha256,
    'authority_type', v_created.authority_type,
    'decision', v_created.decision,
    'package_status', v_package.package_status,
    'package_state_version', v_package.state_version,
    'precertificate_ready', coalesce(
      (v_readiness_after->>'precertificate_ready')::boolean,
      false
    ),
    'g04_ready', coalesce(
      (v_readiness_after->>'ready')::boolean,
      false
    )
  );

  insert into public.atlas_installation_acceptance_events (
    acceptance_package_id, installation_id, empresa_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, executor_code, reason_code,
    request_id, acceptance_version, evidence_reference,
    evidence_sha256, event_payload, metadata
  )
  values (
    v_package.id, v_installation.id, v_installation.empresa_id,
    'DECISION', v_created.id, 'ACCEPTANCE_AUTHORITY_DECIDED',
    case
      when v_authority_type = 'CLIENT' then 'DELIVERED'
      else 'UNDER_CLIENT_REVIEW'
    end,
    v_package.package_status,
    v_actor_user_id, v_actor_role_code,
    'B2_ACCEPTANCE_ENGINE',
    case
      when v_decision = 'ACCEPTED' then 'AUTHORITY_ACCEPTED'
      when v_decision = 'REJECTED' then 'AUTHORITY_REJECTED'
      else 'AUTHORITY_REQUESTED_CHANGES'
    end,
    p_request_id, v_package.acceptance_version,
    p_evidence_reference, p_evidence_sha256,
    v_event_payload,
    jsonb_build_object('request_metadata', p_metadata)
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_ACCEPTANCE_DECIDED',
    'installation_id', v_installation.id,
    'acceptance_package_id', v_package.id,
    'acceptance_decision_id', v_created.id,
    'authority_type', v_created.authority_type,
    'decision', v_created.decision,
    'package_status', v_package.package_status,
    'package_state_version', v_package.state_version,
    'precertificate_ready', coalesce(
      (v_readiness_after->>'precertificate_ready')::boolean,
      false
    ),
    'g04_ready', coalesce(
      (v_readiness_after->>'ready')::boolean,
      false
    ),
    'certificate_issued', false,
    'active_enabled', false,
    'next_action', case
      when v_package.package_status = 'ACCEPTED'
        then 'ISSUE_INSTALLATION_CERTIFICATE'
      when v_package.package_status = 'UNDER_CLIENT_REVIEW'
        then 'RECORD_PLATFORM_ACCEPTANCE'
      else 'CREATE_SUPERSEDING_ACCEPTANCE_PACKAGE'
    end
  );
end;
$$;

revoke all on function
public.atlas_decide_installation_acceptance(
  uuid, text, text, text, jsonb, text, text,
  uuid, bigint, bigint, jsonb
)
from public, anon;
grant execute on function
public.atlas_decide_installation_acceptance(
  uuid, text, text, text, jsonb, text, text,
  uuid, bigint, bigint, jsonb
)
to authenticated, service_role;

create or replace function
public.atlas_g04_approval_evidence_matches_readiness_v1(
  p_evidence jsonb,
  p_readiness jsonb
)
returns boolean
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select
    jsonb_typeof(p_evidence) = 'object'
    and jsonb_typeof(p_readiness) = 'object'
    and not public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
    and p_evidence->>'readiness_contract_version' =
      p_readiness->>'contract_version'
    and p_evidence->>'acceptance_package_id' =
      p_readiness->>'acceptance_package_id'
    and p_evidence->>'package_sha256' =
      p_readiness->>'package_sha256'
    and p_evidence->>'decision_evidence_root_sha256' =
      p_readiness->>'decision_evidence_root_sha256'
    and p_evidence->>'readiness_sha256' =
      p_readiness->>'readiness_sha256'
    and p_evidence->'criteria' = p_readiness->'criteria'
$$;

revoke all on function
public.atlas_g04_approval_evidence_matches_readiness_v1(
  jsonb, jsonb
)
from public, anon, authenticated;
grant execute on function
public.atlas_g04_approval_evidence_matches_readiness_v1(
  jsonb, jsonb
)
to service_role;

create or replace function
public.atlas_enforce_g04_approval_readiness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_installation public.atlas_installations%rowtype;
  v_readiness jsonb;
begin
  if new.gate_code = 'G04'
     and new.decision = 'APPROVED' then
    select installation.*
    into v_installation
    from public.atlas_installations as installation
    where installation.id = new.installation_id;

    if new.authority_type = 'PLATFORM'
       and new.actor_role_code <> 'ATLAS_OWNER' then
      raise exception using
        errcode = '42501',
        message = 'G04_PLATFORM_APPROVAL_REQUIRES_ATLAS_OWNER';
    end if;

    if new.authority_type = 'CLIENT'
       and (
         new.actor_role_code <> 'OWNER'
         or v_installation.client_owner_user_id is null
         or v_installation.client_owner_user_id <> new.actor_user_id
         or not exists (
           select 1
           from public.atlas_internal_memberships as membership
           where membership.empresa_id = v_installation.empresa_id
             and membership.user_id = new.actor_user_id
             and membership.role_code = 'OWNER'
             and membership.status = 'ACTIVE'
         )
       ) then
      raise exception using
        errcode = '42501',
        message = 'G04_CLIENT_APPROVAL_REQUIRES_CLIENT_OWNER';
    end if;

    v_readiness :=
      public.atlas_compute_installation_g04_readiness(
        new.installation_id
      );

    if not coalesce((v_readiness->>'ready')::boolean, false) then
      raise exception using
        errcode = '42501',
        message = 'G04_ACCEPTANCE_READINESS_INCOMPLETE',
        detail = coalesce(
          v_readiness->'blockers',
          '[]'::jsonb
        )::text;
    end if;

    if not public.atlas_g04_approval_evidence_matches_readiness_v1(
      new.evidence,
      v_readiness
    ) then
      raise exception using
        errcode = '22023',
        message = 'G04_ACCEPTANCE_EVIDENCE_BINDING_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_g04_approval_readiness()
from public, anon, authenticated;
grant execute on function
public.atlas_enforce_g04_approval_readiness()
to service_role;

drop trigger if exists trg_atlas_g04_approval_readiness
  on public.atlas_installation_approvals;
create trigger trg_atlas_g04_approval_readiness
before insert on public.atlas_installation_approvals
for each row execute function
public.atlas_enforce_g04_approval_readiness();

create or replace function
public.atlas_enforce_g04_active_transition_readiness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
  v_gate public.atlas_installation_gates%rowtype;
  v_platform_approval public.atlas_installation_approvals%rowtype;
  v_client_approval public.atlas_installation_approvals%rowtype;
begin
  if old.current_state_code in ('FINAL_APPROVAL', 'OBSERVED')
     and new.current_state_code = 'ACTIVE' then
    v_readiness :=
      public.atlas_compute_installation_g04_readiness(old.id);

    if not coalesce((v_readiness->>'ready')::boolean, false) then
      raise exception using
        errcode = '42501',
        message = 'G04_READINESS_STALE_OR_INCOMPLETE',
        detail = coalesce(
          v_readiness->'blockers',
          '[]'::jsonb
        )::text;
    end if;

    select gate_record.*
    into v_gate
    from public.atlas_installation_gates as gate_record
    where gate_record.installation_id = old.id
      and gate_record.gate_code = 'G04'
      and gate_record.status = 'APPROVED'
      and gate_record.platform_approved
      and gate_record.client_approved;

    if not found then
      raise exception using
        errcode = '42501',
        message = 'G04_DUAL_GATE_APPROVAL_REQUIRED';
    end if;

    select approval.*
    into v_platform_approval
    from public.atlas_installation_approvals as approval
    where approval.gate_id = v_gate.id
      and approval.gate_code = 'G04'
      and approval.authority_type = 'PLATFORM'
      and approval.decision = 'APPROVED'
      and approval.actor_role_code = 'ATLAS_OWNER'
    order by approval.created_at desc, approval.id desc
    limit 1;

    select approval.*
    into v_client_approval
    from public.atlas_installation_approvals as approval
    where approval.gate_id = v_gate.id
      and approval.gate_code = 'G04'
      and approval.authority_type = 'CLIENT'
      and approval.decision = 'APPROVED'
      and approval.actor_role_code = 'OWNER'
    order by approval.created_at desc, approval.id desc
    limit 1;

    if v_platform_approval.id is null
       or v_client_approval.id is null then
      raise exception using
        errcode = '42501',
        message = 'G04_BOUND_DUAL_APPROVALS_REQUIRED';
    end if;

    if not public.atlas_g04_approval_evidence_matches_readiness_v1(
      v_platform_approval.evidence,
      v_readiness
    )
       or not public.atlas_g04_approval_evidence_matches_readiness_v1(
         v_client_approval.evidence,
         v_readiness
       ) then
      raise exception using
        errcode = '22023',
        message = 'G04_APPROVAL_EVIDENCE_STALE';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_g04_active_transition_readiness()
from public, anon, authenticated;
grant execute on function
public.atlas_enforce_g04_active_transition_readiness()
to service_role;

drop trigger if exists trg_atlas_installations_g04_active_readiness
  on public.atlas_installations;
create trigger trg_atlas_installations_g04_active_readiness
before update of current_state_code on public.atlas_installations
for each row execute function
public.atlas_enforce_g04_active_transition_readiness();

comment on function
public.atlas_compute_installation_g04_readiness(uuid) is
  'B2: deriva pre-certificacion y readiness G04 desde entrega, aceptacion dual, certificado y autorizacion vigentes.';
comment on function
public.atlas_get_installation_g04_readiness(uuid) is
  'B2: frontera autorizada de lectura del alistamiento objetivo G04.';
comment on function
public.atlas_decide_installation_acceptance(
  uuid, text, text, text, jsonb, text, text,
  uuid, bigint, bigint, jsonb
) is
  'B2: registra aceptacion CLIENT o PLATFORM con autoridad, evidencia, hashes, version e idempotencia.';
comment on function
public.atlas_g04_approval_evidence_matches_readiness_v1(
  jsonb, jsonb
) is
  'B2: valida el vinculo inmutable entre evidencia de gate y readiness G04.';
comment on function
public.atlas_enforce_g04_approval_readiness() is
  'B2: impide aprobar G04 sin los ocho requisitos objetivos y evidencia vigente.';
comment on function
public.atlas_enforce_g04_active_transition_readiness() is
  'B2: revalida G04 y sus autoridades antes de permitir ACTIVE.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2J3_CLIENT_ACCEPTANCE_G04_READINESS_ENFORCEMENT_INSTALLED',
  'next_action', 'CERTIFY_J3_ACCEPTANCE_AND_G04_GUARDS',
  'acceptance_decision_rpcs', 1,
  'readiness_rpcs', 2,
  'readiness_helpers', 1,
  'enforcement_triggers', 2,
  'current_g04_ready', coalesce((
    public.atlas_compute_installation_g04_readiness(
      installation.id
    )->>'ready'
  )::boolean, false),
  'current_precertificate_ready', coalesce((
    public.atlas_compute_installation_g04_readiness(
      installation.id
    )->>'precertificate_ready'
  )::boolean, false),
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version,
  'client_owner_authority_enforced', true,
  'platform_owner_authority_enforced', true,
  'dual_acceptance_enabled', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'g03_revalidation_enabled', true,
  'g04_objective_enforcement_enabled', true,
  'g04_auto_approval_enabled', false,
  'certificate_issuance_enabled', false,
  'active_auto_transition_enabled', false,
  'direct_authenticated_write', false,
  'credential_values_stored', false
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
