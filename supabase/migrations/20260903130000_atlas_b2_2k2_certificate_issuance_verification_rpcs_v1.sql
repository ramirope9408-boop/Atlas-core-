-- ATLAS B2.2K.2 - Emision y verificacion del Certificado de Instalacion.
-- Corte: 2026-09-03
--
-- Emite exclusivamente desde evidencia canonica revalidada del backend.
-- No renderiza documentos, no aprueba G04 y no habilita ACTIVE.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_certificates') is null
     or to_regprocedure(
       'public.atlas_compute_installation_g04_readiness(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_get_installation_provisioning_verification_evidence(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_integration_readiness(uuid)'
     ) is null then
    raise exception 'B2.2K.2 requiere B2.2K.1 y la cadena G04 instalados';
  end if;

  if to_regprocedure(
       'public.atlas_issue_installation_certificate(uuid,uuid,bigint,jsonb)'
     ) is not null
     or to_regprocedure(
       'public.atlas_verify_installation_certificate(uuid)'
     ) is not null then
    raise exception
      'B2.2K.2 detecto RPC previas; reconciliar antes de instalar';
  end if;
end;
$$;

create or replace function
public.atlas_certificate_platform_role_for_permission(
  p_permission_code text
)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select membership.role_code
  from public.atlas_platform_memberships as membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = membership.role_code
   and role_definition.active
  join public.atlas_internal_role_permissions as role_permission
    on role_permission.role_code = membership.role_code
   and role_permission.permission_code = p_permission_code
  where membership.user_id = auth.uid()
    and membership.status = 'ACTIVE'
  order by role_definition.priority asc, membership.created_at asc
  limit 1
$$;

revoke all on function
public.atlas_certificate_platform_role_for_permission(text)
from public, anon, authenticated;
grant execute on function
public.atlas_certificate_platform_role_for_permission(text)
to service_role;

create or replace function
public.atlas_compute_installation_certificate_verification(
  p_certificate_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_certificate public.atlas_installation_certificates%rowtype;
  v_contract public.atlas_installation_certificate_contracts%rowtype;
  v_source_projection jsonb := '[]'::jsonb;
  v_recomputed_root text;
  v_source_count integer := 0;
  v_domain_count integer := 0;
  v_required_domains_complete boolean := false;
  v_payload_hash_valid boolean := false;
  v_event_binding_valid boolean := false;
  v_requirement_binding_valid boolean := false;
  v_verified boolean := false;
  v_blockers jsonb := '[]'::jsonb;
begin
  if p_certificate_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'CERTIFICATE_ID_REQUIRED',
      'verified', false
    );
  end if;

  select certificate.*
  into v_certificate
  from public.atlas_installation_certificates as certificate
  where certificate.id = p_certificate_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_CERTIFICATE_NOT_FOUND',
      'certificate_id', p_certificate_id,
      'verified', false
    );
  end if;

  select contract.*
  into v_contract
  from public.atlas_installation_certificate_contracts as contract
  where contract.contract_code = v_certificate.certificate_contract_code
    and contract.active;

  select
    count(*)::integer,
    count(distinct source.source_domain)::integer,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'source_domain', source.source_domain,
          'source_code', source.source_code,
          'source_record_id', source.source_record_id,
          'source_version', source.source_version,
          'source_sha256', source.source_sha256,
          'evidence_reference', source.evidence_reference,
          'verification_payload', source.verification_payload
        )
        order by source.source_domain, source.source_code
      ),
      '[]'::jsonb
    )
  into v_source_count, v_domain_count, v_source_projection
  from public.atlas_installation_certificate_sources as source
  where source.certificate_id = v_certificate.id
    and source.installation_id = v_certificate.installation_id
    and source.empresa_id = v_certificate.empresa_id
    and source.required;

  v_recomputed_root := public.atlas_normalization_sha256(
    v_source_projection::text
  );

  v_required_domains_complete :=
    v_contract.contract_code is not null
    and v_source_count = 7
    and v_domain_count = 7
    and not exists (
      select required_domain
      from unnest(v_contract.required_source_domains)
        as required_domain
      except
      select source.source_domain
      from public.atlas_installation_certificate_sources as source
      where source.certificate_id = v_certificate.id
        and source.required
    )
    and not exists (
      select source.source_domain
      from public.atlas_installation_certificate_sources as source
      where source.certificate_id = v_certificate.id
        and source.required
      except
      select required_domain
      from unnest(v_contract.required_source_domains)
        as required_domain
    );

  v_payload_hash_valid :=
    v_certificate.certificate_contract_code =
      'B2_INSTALLATION_CERTIFICATE_V1'
    and v_certificate.issuance_status = 'ISSUED'
    and v_certificate.certified_state_code = 'FINAL_APPROVAL'
    and v_certificate.certificate_sha256 =
      public.atlas_normalization_sha256(
        v_certificate.certificate_payload::text
      )
    and v_certificate.certificate_payload->>'evidence_root_sha256' =
      v_certificate.evidence_root_sha256
    and not public.atlas_jsonb_has_forbidden_secret_key(
      v_certificate.certificate_payload
    );

  select exists (
    select 1
    from public.atlas_installation_certificate_events as event_record
    where event_record.certificate_id = v_certificate.id
      and event_record.installation_id = v_certificate.installation_id
      and event_record.empresa_id = v_certificate.empresa_id
      and event_record.event_type = 'ISSUED'
      and event_record.evidence_sha256 =
        v_certificate.certificate_sha256
      and event_record.event_payload->>'certificate_sha256' =
        v_certificate.certificate_sha256
      and event_record.event_payload->>'evidence_root_sha256' =
        v_certificate.evidence_root_sha256
  ) into v_event_binding_valid;

  select exists (
    select 1
    from public.atlas_installation_acceptance_requirements as requirement
    where requirement.acceptance_package_id =
        v_certificate.acceptance_package_id
      and requirement.installation_id = v_certificate.installation_id
      and requirement.empresa_id = v_certificate.empresa_id
      and requirement.requirement_code =
        'INSTALLATION_CERTIFICATE_ISSUED'
      and requirement.requirement_status = 'SATISFIED'
      and requirement.evidence_kind = 'CERTIFICATE'
      and requirement.evidence_sha256 =
        v_certificate.certificate_sha256
      and requirement.verification_payload->>'certificate_id' =
        v_certificate.id::text
  ) into v_requirement_binding_valid;

  v_verified :=
    v_required_domains_complete
    and v_payload_hash_valid
    and v_recomputed_root = v_certificate.evidence_root_sha256
    and v_event_binding_valid
    and v_requirement_binding_valid;

  select coalesce(jsonb_agg(blocker), '[]'::jsonb)
  into v_blockers
  from jsonb_array_elements(jsonb_build_array(
    case when not v_required_domains_complete
      then jsonb_build_object(
        'criterion', 'REQUIRED_SOURCE_DOMAINS_COMPLETE',
        'reason', 'EXACT_SEVEN_CANONICAL_DOMAINS_REQUIRED'
      ) end,
    case when not v_payload_hash_valid
      then jsonb_build_object(
        'criterion', 'CERTIFICATE_PAYLOAD_HASH_VALID',
        'reason', 'CANONICAL_CERTIFICATE_PAYLOAD_REQUIRED'
      ) end,
    case when v_recomputed_root is distinct from
        v_certificate.evidence_root_sha256
      then jsonb_build_object(
        'criterion', 'EVIDENCE_ROOT_VALID',
        'reason', 'SOURCE_PROJECTION_HASH_MISMATCH'
      ) end,
    case when not v_event_binding_valid
      then jsonb_build_object(
        'criterion', 'ISSUANCE_EVENT_BOUND',
        'reason', 'BOUND_ISSUANCE_EVENT_REQUIRED'
      ) end,
    case when not v_requirement_binding_valid
      then jsonb_build_object(
        'criterion', 'G04_CERTIFICATE_REQUIREMENT_BOUND',
        'reason', 'SATISFIED_G04_CERTIFICATE_REQUIREMENT_REQUIRED'
      ) end
  )) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_verified then 'INSTALLATION_CERTIFICATE_VERIFIED'
      else 'INSTALLATION_CERTIFICATE_VERIFICATION_FAILED'
    end,
    'contract_version', v_certificate.certificate_contract_code,
    'certificate_id', v_certificate.id,
    'certificate_code', v_certificate.certificate_code,
    'certificate_version', v_certificate.certificate_version,
    'installation_id', v_certificate.installation_id,
    'empresa_id', v_certificate.empresa_id,
    'issuance_status', v_certificate.issuance_status,
    'certificate_sha256', v_certificate.certificate_sha256,
    'stored_evidence_root_sha256',
      v_certificate.evidence_root_sha256,
    'recomputed_evidence_root_sha256', v_recomputed_root,
    'required_source_count', 7,
    'source_count', v_source_count,
    'source_domain_count', v_domain_count,
    'required_domains_complete', v_required_domains_complete,
    'payload_hash_valid', v_payload_hash_valid,
    'event_binding_valid', v_event_binding_valid,
    'requirement_binding_valid', v_requirement_binding_valid,
    'verified', v_verified,
    'blockers', v_blockers,
    'credential_values_exposed', false,
    'raw_payloads_exposed', false
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_certificate_verification(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_certificate_verification(uuid)
to service_role;

create or replace function
public.atlas_issue_installation_certificate(
  p_installation_id uuid,
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
  v_package public.atlas_installation_acceptance_packages%rowtype;
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_existing public.atlas_installation_certificates%rowtype;
  v_certificate_id uuid := gen_random_uuid();
  v_certificate_version integer := 1;
  v_certificate_code text;
  v_issued_at timestamptz := clock_timestamp();
  v_g04 jsonb;
  v_g03 jsonb;
  v_integration jsonb;
  v_provisioning jsonb;
  v_gate_projection jsonb;
  v_gate_sha256 text;
  v_audit_projection jsonb;
  v_audit_sha256 text;
  v_source_projection jsonb;
  v_evidence_root_sha256 text;
  v_certificate_payload jsonb;
  v_certificate_sha256 text;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_verification jsonb;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CERTIFICATE_ISSUANCE_REQUIRED_FIELDS_INVALID';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_CERTIFICATE_ISSUANCE_REQUEST_V1',
    'installation_id', p_installation_id,
    'expected_installation_version',
      p_expected_installation_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select certificate.*
  into v_existing
  from public.atlas_installation_certificates as certificate
  where certificate.installation_id = p_installation_id
    and certificate.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'CERTIFICATE_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    v_verification :=
      public.atlas_compute_installation_certificate_verification(
        v_existing.id
      );

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'certificate_id', v_existing.id,
      'certificate_code', v_existing.certificate_code,
      'certificate_version', v_existing.certificate_version,
      'certificate_sha256', v_existing.certificate_sha256,
      'verified', coalesce(
        (v_verification->>'verified')::boolean,
        false
      ),
      'active_enabled', false
    );
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_CERTIFICATE_ISSUE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_CERTIFICATE_ISSUE_FORBIDDEN';
  end if;

  v_actor_role_code :=
    public.atlas_certificate_platform_role_for_permission(
      'INSTALLATION_CERTIFICATE_ISSUE'
    );

  if v_actor_role_code <> 'ATLAS_OWNER' then
    raise exception using
      errcode = '42501',
      message = 'CERTIFICATE_ISSUANCE_REQUIRES_ATLAS_OWNER';
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
      message = 'CERTIFICATE_ISSUANCE_REQUIRES_FINAL_APPROVAL_STATE';
  end if;

  if exists (
    select 1
    from public.atlas_installation_certificates as certificate
    where certificate.installation_id = v_installation.id
  ) then
    raise exception using
      errcode = '23505',
      message = 'INSTALLATION_CERTIFICATE_ALREADY_ISSUED';
  end if;

  v_g04 := public.atlas_compute_installation_g04_readiness(
    v_installation.id
  );

  if not coalesce((v_g04->>'precertificate_ready')::boolean, false)
     or v_g04->>'installation_version' <>
        v_installation.version::text then
    raise exception using
      errcode = '42501',
      message = 'CERTIFICATE_PRECONDITIONS_INCOMPLETE',
      detail = coalesce(v_g04->'blockers', '[]'::jsonb)::text;
  end if;

  select package.*
  into v_package
  from public.atlas_installation_acceptance_packages as package
  where package.id = (v_g04->>'acceptance_package_id')::uuid
    and package.installation_id = v_installation.id
    and package.empresa_id = v_installation.empresa_id
    and package.package_status = 'ACCEPTED';

  if not found then
    raise exception using
      errcode = '42501',
      message = 'CURRENT_ACCEPTED_PACKAGE_REQUIRED';
  end if;

  v_g03 := public.atlas_compute_installation_g03_readiness(
    v_installation.id
  );
  v_integration :=
    public.atlas_compute_installation_integration_readiness(
      v_installation.id
    );

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.installation_id = v_installation.id
    and plan.empresa_id = v_installation.empresa_id
    and plan.plan_status = 'COMPLETED'
  order by plan.plan_version desc, plan.created_at desc, plan.id desc
  limit 1;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'COMPLETED_PROVISIONING_PLAN_REQUIRED';
  end if;

  v_provisioning :=
    public.atlas_get_installation_provisioning_verification_evidence(
      v_plan.id
    );

  if not coalesce((v_g03->>'ready')::boolean, false)
     or not coalesce((v_integration->>'ready')::boolean, false)
     or not coalesce(
       (v_provisioning->>'provisioning_evidence_ready')::boolean,
       false
     )
     or v_g03->>'readiness_sha256' !~ '^[0-9a-f]{64}$'
     or v_integration->>'evidence_root_sha256' !~ '^[0-9a-f]{64}$'
     or v_provisioning->>'evidence_root_sha256' !~
       '^[0-9a-f]{64}$' then
    raise exception using
      errcode = '42501',
      message = 'CANONICAL_CERTIFICATE_EVIDENCE_INCOMPLETE';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'gate_id', gate_record.id,
        'gate_code', gate_record.gate_code,
        'gate_version', gate_record.gate_version,
        'status', gate_record.status,
        'platform_approved', gate_record.platform_approved,
        'client_approved', gate_record.client_approved,
        'approval_records', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'approval_id', approval.id,
              'authority_type', approval.authority_type,
              'decision', approval.decision,
              'gate_version', approval.gate_version,
              'actor_role_code', approval.actor_role_code
            )
            order by approval.authority_type, approval.id
          )
          from public.atlas_installation_approvals as approval
          where approval.gate_id = gate_record.id
        ), '[]'::jsonb)
      )
      order by gate_record.gate_code
    ),
    '[]'::jsonb
  )
  into v_gate_projection
  from public.atlas_installation_gates as gate_record
  where gate_record.installation_id = v_installation.id;

  if jsonb_array_length(v_gate_projection) <> 4 then
    raise exception using
      errcode = '42501',
      message = 'CANONICAL_GATE_SET_INCOMPLETE';
  end if;
  v_gate_sha256 := public.atlas_normalization_sha256(
    v_gate_projection::text
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'event_id', state_event.id,
        'event_code', state_event.event_code,
        'from_state_code', state_event.from_state_code,
        'to_state_code', state_event.to_state_code,
        'installation_version', state_event.installation_version,
        'actor_role_code', state_event.actor_role_code,
        'created_at', state_event.created_at
      )
      order by state_event.installation_version, state_event.id
    ),
    '[]'::jsonb
  )
  into v_audit_projection
  from public.atlas_installation_state_events as state_event
  where state_event.installation_id = v_installation.id;

  if jsonb_array_length(v_audit_projection) = 0 then
    raise exception using
      errcode = '42501', message = 'INSTALLATION_AUDIT_TRAIL_REQUIRED';
  end if;
  v_audit_sha256 := public.atlas_normalization_sha256(
    v_audit_projection::text
  );

  v_source_projection := jsonb_build_array(
    jsonb_build_object(
      'source_domain', 'ACCEPTANCE',
      'source_code', 'G04_PRECERTIFICATE_READINESS',
      'source_record_id', v_package.id,
      'source_version', v_package.acceptance_version::text,
      'source_sha256', v_g04->>'readiness_sha256',
      'evidence_reference',
        'acceptance://atlas/' || v_package.id::text,
      'verification_payload', jsonb_build_object(
        'contract_version', 'B2_CERTIFICATE_SOURCE_V1',
        'precertificate_ready', true,
        'package_sha256', v_package.package_sha256,
        'decision_evidence_root_sha256',
          v_g04->>'decision_evidence_root_sha256'
      )
    ),
    jsonb_build_object(
      'source_domain', 'AUDIT',
      'source_code', 'INSTALLATION_STATE_AUDIT_TRAIL',
      'source_record_id', null,
      'source_version', v_installation.version::text,
      'source_sha256', v_audit_sha256,
      'evidence_reference',
        'audit://atlas/' || v_installation.id::text || '/states',
      'verification_payload', jsonb_build_object(
        'contract_version', 'B2_CERTIFICATE_SOURCE_V1',
        'state_event_count', jsonb_array_length(v_audit_projection),
        'current_state_code', v_installation.current_state_code
      )
    ),
    jsonb_build_object(
      'source_domain', 'GATES',
      'source_code', 'INSTALLATION_GATE_SNAPSHOT',
      'source_record_id', v_package.source_g03_gate_id,
      'source_version', v_package.source_g03_gate_version::text,
      'source_sha256', v_gate_sha256,
      'evidence_reference',
        'gate://atlas/' || v_installation.id::text || '/snapshot',
      'verification_payload', jsonb_build_object(
        'contract_version', 'B2_CERTIFICATE_SOURCE_V1',
        'gate_count', jsonb_array_length(v_gate_projection),
        'g03_gate_id', v_package.source_g03_gate_id
      )
    ),
    jsonb_build_object(
      'source_domain', 'INTEGRATION',
      'source_code', 'INTEGRATION_READINESS',
      'source_record_id', (v_integration->>'manifest_id')::uuid,
      'source_version', 'B2_INTEGRATION_READINESS_V1',
      'source_sha256', v_integration->>'evidence_root_sha256',
      'evidence_reference',
        'integration://atlas/' || v_installation.id::text ||
        '/readiness',
      'verification_payload', jsonb_build_object(
        'contract_version', 'B2_CERTIFICATE_SOURCE_V1',
        'ready', true,
        'required_integrations',
          (v_integration->>'required_integrations')::integer,
        'validated_required_integrations',
          (v_integration->>'validated_required_integrations')::integer
      )
    ),
    jsonb_build_object(
      'source_domain', 'MANIFEST',
      'source_code', 'VALIDATED_INSTALLATION_MANIFEST',
      'source_record_id', v_package.source_manifest_id,
      'source_version', v_installation.manifest_version,
      'source_sha256', v_package.source_manifest_sha256,
      'evidence_reference',
        'manifest://atlas/' || v_package.source_manifest_id::text,
      'verification_payload', jsonb_build_object(
        'contract_version', 'B2_CERTIFICATE_SOURCE_V1',
        'manifest_id', v_package.source_manifest_id,
        'manifest_sha256', v_package.source_manifest_sha256
      )
    ),
    jsonb_build_object(
      'source_domain', 'PROVISIONING',
      'source_code', 'PROVISIONING_VERIFICATION_EVIDENCE',
      'source_record_id', v_plan.id,
      'source_version', v_plan.plan_version::text,
      'source_sha256', v_provisioning->>'evidence_root_sha256',
      'evidence_reference',
        'provisioning://atlas/' || v_plan.id::text || '/evidence',
      'verification_payload', jsonb_build_object(
        'contract_version', 'B2_CERTIFICATE_SOURCE_V1',
        'plan_id', v_plan.id,
        'plan_sha256', v_plan.plan_sha256,
        'required_steps', v_provisioning->'counts'->'required_steps',
        'required_complete_steps',
          v_provisioning->'counts'->'required_complete_steps'
      )
    ),
    jsonb_build_object(
      'source_domain', 'TESTING',
      'source_code', 'G03_TEST_READINESS',
      'source_record_id', v_package.source_test_run_id,
      'source_version', v_package.source_g03_gate_version::text,
      'source_sha256', v_g03->>'readiness_sha256',
      'evidence_reference',
        'test-evidence://atlas/' ||
        v_package.source_test_run_id::text,
      'verification_payload', jsonb_build_object(
        'contract_version', 'B2_CERTIFICATE_SOURCE_V1',
        'ready', true,
        'test_plan_id', v_package.source_test_plan_id,
        'test_run_id', v_package.source_test_run_id,
        'test_evidence_root_sha256',
          v_package.source_test_evidence_root_sha256
      )
    )
  );

  v_evidence_root_sha256 := public.atlas_normalization_sha256(
    v_source_projection::text
  );
  v_certificate_code :=
    'ATLAS-CERT-' || upper(v_installation.installation_code) || '-V1';

  v_certificate_payload := jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_CERTIFICATE_V1',
    'certificate_id', v_certificate_id,
    'certificate_code', v_certificate_code,
    'certificate_version', v_certificate_version,
    'installation_id', v_installation.id,
    'installation_code', v_installation.installation_code,
    'empresa_id', v_installation.empresa_id,
    'company_legal_name', v_installation.company_legal_name,
    'company_trade_name', v_installation.company_trade_name,
    'acceptance_package_id', v_package.id,
    'engine_version', 'B2_INSTALLATION_ENGINE_V1',
    'manifest', jsonb_build_object(
      'manifest_id', v_package.source_manifest_id,
      'manifest_version', v_installation.manifest_version,
      'manifest_sha256', v_package.source_manifest_sha256
    ),
    'provisioning', jsonb_build_object(
      'plan_id', v_plan.id,
      'plan_version', v_plan.plan_version,
      'plan_sha256', v_plan.plan_sha256,
      'evidence_root_sha256',
        v_provisioning->>'evidence_root_sha256'
    ),
    'integrations', jsonb_build_object(
      'readiness_contract_version',
        v_integration->>'contract_version',
      'evidence_root_sha256',
        v_integration->>'evidence_root_sha256'
    ),
    'tests', jsonb_build_object(
      'test_plan_id', v_package.source_test_plan_id,
      'test_run_id', v_package.source_test_run_id,
      'readiness_sha256', v_g03->>'readiness_sha256',
      'evidence_root_sha256',
        v_package.source_test_evidence_root_sha256
    ),
    'gates', jsonb_build_object(
      'gate_snapshot_sha256', v_gate_sha256,
      'gate_count', jsonb_array_length(v_gate_projection)
    ),
    'acceptance', jsonb_build_object(
      'acceptance_code', v_package.acceptance_code,
      'acceptance_version', v_package.acceptance_version,
      'package_sha256', v_package.package_sha256,
      'readiness_sha256', v_g04->>'readiness_sha256'
    ),
    'audit_references', jsonb_build_array(
      'audit://atlas/' || v_installation.id::text || '/states',
      'certificate://atlas/' || v_certificate_id::text || '/sources'
    ),
    'evidence_root_sha256', v_evidence_root_sha256,
    'certified_state_code', 'FINAL_APPROVAL',
    'issued_at', v_issued_at,
    'secret_values_included', false
  );
  v_certificate_sha256 := public.atlas_normalization_sha256(
    v_certificate_payload::text
  );

  insert into public.atlas_installation_certificates (
    id, installation_id, empresa_id, acceptance_package_id,
    certificate_code, certificate_version,
    certificate_contract_code, engine_version,
    certified_state_code, issuance_status, certificate_payload,
    certificate_sha256, evidence_root_sha256, request_id,
    request_sha256, issued_by_user_id, issued_by_role_code,
    issued_at, supersedes_certificate_id, metadata, created_at
  ) values (
    v_certificate_id, v_installation.id, v_installation.empresa_id,
    v_package.id, v_certificate_code, v_certificate_version,
    'B2_INSTALLATION_CERTIFICATE_V1',
    'B2_INSTALLATION_ENGINE_V1', 'FINAL_APPROVAL', 'ISSUED',
    v_certificate_payload, v_certificate_sha256,
    v_evidence_root_sha256, p_request_id, v_request_sha256,
    v_actor_user_id, v_actor_role_code, v_issued_at, null,
    jsonb_build_object(
      'request_contract', v_request_payload,
      'request_metadata', p_metadata,
      'rendering_status', 'NOT_RENDERED'
    ),
    v_issued_at
  );

  insert into public.atlas_installation_certificate_sources (
    certificate_id, installation_id, empresa_id,
    source_domain, source_code, source_record_id, source_version,
    source_sha256, evidence_reference, required,
    verification_payload, verified_by_user_id, verified_at,
    created_at
  )
  select
    v_certificate_id,
    v_installation.id,
    v_installation.empresa_id,
    source_item->>'source_domain',
    source_item->>'source_code',
    nullif(source_item->>'source_record_id', '')::uuid,
    source_item->>'source_version',
    source_item->>'source_sha256',
    source_item->>'evidence_reference',
    true,
    source_item->'verification_payload',
    v_actor_user_id,
    v_issued_at,
    v_issued_at
  from jsonb_array_elements(v_source_projection)
    as source_rows(source_item);

  update public.atlas_installation_acceptance_requirements
  set
    requirement_status = 'SATISFIED',
    evidence_kind = 'CERTIFICATE',
    evidence_reference =
      'certificate://atlas/' || v_certificate_id::text,
    evidence_sha256 = v_certificate_sha256,
    verification_payload = jsonb_build_object(
      'contract_version',
        'B2_ACCEPTANCE_REQUIREMENT_EVIDENCE_V1',
      'requirement_code', 'INSTALLATION_CERTIFICATE_ISSUED',
      'certificate_id', v_certificate_id,
      'certificate_code', v_certificate_code,
      'certificate_sha256', v_certificate_sha256,
      'evidence_root_sha256', v_evidence_root_sha256
    ),
    verified_by_user_id = v_actor_user_id,
    verified_at = v_issued_at,
    blocking_reason_code = null,
    updated_at = v_issued_at
  where acceptance_package_id = v_package.id
    and requirement_code = 'INSTALLATION_CERTIFICATE_ISSUED'
    and requirement_status <> 'SATISFIED';

  if not found then
    raise exception using
      errcode = '42501',
      message = 'G04_CERTIFICATE_REQUIREMENT_UPDATE_FAILED';
  end if;

  insert into public.atlas_installation_certificate_events (
    certificate_id, installation_id, empresa_id, event_type,
    actor_user_id, actor_role_code, request_id,
    evidence_reference, evidence_sha256, event_payload, created_at
  ) values (
    v_certificate_id, v_installation.id, v_installation.empresa_id,
    'ISSUED', v_actor_user_id, v_actor_role_code, p_request_id,
    'certificate://atlas/' || v_certificate_id::text || '/issued',
    v_certificate_sha256,
    jsonb_build_object(
      'contract_version', 'B2_CERTIFICATE_EVENT_V1',
      'certificate_id', v_certificate_id,
      'certificate_code', v_certificate_code,
      'certificate_version', v_certificate_version,
      'certificate_sha256', v_certificate_sha256,
      'evidence_root_sha256', v_evidence_root_sha256,
      'request_sha256', v_request_sha256
    ),
    v_issued_at
  );

  v_verification :=
    public.atlas_compute_installation_certificate_verification(
      v_certificate_id
    );

  if not coalesce((v_verification->>'verified')::boolean, false) then
    raise exception using
      errcode = 'XX001',
      message = 'ISSUED_CERTIFICATE_FAILED_SELF_VERIFICATION',
      detail = coalesce(
        v_verification->'blockers',
        '[]'::jsonb
      )::text;
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_ISSUED',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'certificate_id', v_certificate_id,
    'certificate_code', v_certificate_code,
    'certificate_version', v_certificate_version,
    'certificate_sha256', v_certificate_sha256,
    'evidence_root_sha256', v_evidence_root_sha256,
    'source_domains', 7,
    'verified', true,
    'g04_ready', false,
    'active_enabled', false,
    'next_action', 'AUTHORIZE_ACTIVE_STATE'
  );
end;
$$;

create or replace function
public.atlas_verify_installation_certificate(
  p_certificate_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_certificate public.atlas_installation_certificates%rowtype;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_certificate_id is null then
    raise exception using
      errcode = '22023', message = 'CERTIFICATE_ID_REQUIRED';
  end if;

  select certificate.*
  into v_certificate
  from public.atlas_installation_certificates as certificate
  where certificate.id = p_certificate_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end if;

  if not public.atlas_can_read_installation(
    v_certificate.installation_id
  )
     and not public.atlas_platform_has_permission(
       'INSTALLATION_CERTIFICATE_READ'
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_CERTIFICATE_READ_FORBIDDEN';
  end if;

  return public.atlas_compute_installation_certificate_verification(
    v_certificate.id
  );
end;
$$;

revoke all on function
public.atlas_issue_installation_certificate(uuid,uuid,bigint,jsonb)
from public, anon;
revoke all on function
public.atlas_verify_installation_certificate(uuid)
from public, anon;

grant execute on function
public.atlas_issue_installation_certificate(uuid,uuid,bigint,jsonb)
to authenticated, service_role;
grant execute on function
public.atlas_verify_installation_certificate(uuid)
to authenticated, service_role;

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2K2_CERTIFICATE_ISSUANCE_VERIFICATION_RPCS_INSTALLED',
  'next_action', 'CERTIFY_K2_RPC_GUARDS',
  'certificate_rpcs', 2,
  'certificate_records', (
    select count(*) from public.atlas_installation_certificates
  ),
  'certificate_source_records', (
    select count(*)
    from public.atlas_installation_certificate_sources
  ),
  'certificate_event_records', (
    select count(*)
    from public.atlas_installation_certificate_events
  ),
  'issuance_authority', 'ATLAS_OWNER',
  'required_source_domains', 7,
  'backend_derived_evidence_only', true,
  'self_verification_enabled', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'precertificate_revalidation_enabled', true,
  'certificate_issuance_enabled', true,
  'certificate_rendering_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'direct_authenticated_write', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
