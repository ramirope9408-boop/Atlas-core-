-- ATLAS B2.2K.4B.2 - Ejecucion controlada de regeneracion.
-- Corte: 2026-09-04
--
-- Crea una nueva version del mismo snapshot certificado, solo cuando el
-- predecesor fue revocado y existe decision humana aprobada. Evidencia
-- nueva requiere un ciclo de certificacion nuevo, no esta RPC.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_decide_installation_certificate_regeneration(uuid,text,text,text,text,uuid,integer,jsonb)'
     ) is null
     or to_regclass(
       'public.atlas_installation_certificate_regeneration_decisions'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_certificate_verification(uuid)'
     ) is null then
    raise exception 'B2.2K.4B.2 requiere B2.2K.4B.1 certificado';
  end if;

  if to_regprocedure(
       'public.atlas_execute_installation_certificate_regeneration(uuid,uuid,bigint,integer,jsonb)'
     ) is not null then
    raise exception
      'B2.2K.4B.2 detecto RPC previa; reconciliar antes de instalar';
  end if;
end;
$$;

create unique index
uq_atlas_certificate_single_successor
on public.atlas_installation_certificates(supersedes_certificate_id)
where supersedes_certificate_id is not null;

create or replace function
public.atlas_execute_installation_certificate_regeneration(
  p_regeneration_request_id uuid,
  p_execution_request_id uuid,
  p_expected_installation_version bigint,
  p_expected_predecessor_version integer,
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
  v_request
    public.atlas_installation_certificate_regeneration_requests%rowtype;
  v_decision
    public.atlas_installation_certificate_regeneration_decisions%rowtype;
  v_predecessor public.atlas_installation_certificates%rowtype;
  v_existing public.atlas_installation_certificates%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_g04 jsonb;
  v_lifecycle jsonb;
  v_predecessor_verification jsonb;
  v_new_verification jsonb;
  v_certificate_id uuid := gen_random_uuid();
  v_certificate_code text;
  v_issued_at timestamptz := clock_timestamp();
  v_execution_payload jsonb;
  v_execution_sha256 text;
  v_certificate_payload jsonb;
  v_certificate_sha256 text;
  v_source_count integer;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_regeneration_request_id is null
     or p_execution_request_id is null
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_expected_predecessor_version is null
     or p_expected_predecessor_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CERTIFICATE_REGENERATION_EXECUTION_FIELDS_INVALID';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_CERTIFICATE_REGENERATE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_CERTIFICATE_REGENERATE_FORBIDDEN';
  end if;

  v_actor_role_code :=
    public.atlas_certificate_platform_role_for_permission(
      'INSTALLATION_CERTIFICATE_REGENERATE'
    );
  if v_actor_role_code <> 'ATLAS_OWNER' then
    raise exception using
      errcode = '42501',
      message = 'CERTIFICATE_REGENERATION_EXECUTION_REQUIRES_ATLAS_OWNER';
  end if;

  select request_record.*
  into v_request
  from public.atlas_installation_certificate_regeneration_requests
    as request_record
  where request_record.id = p_regeneration_request_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'CERTIFICATE_REGENERATION_REQUEST_NOT_FOUND';
  end if;

  select decision_record.*
  into v_decision
  from public.atlas_installation_certificate_regeneration_decisions
    as decision_record
  where decision_record.regeneration_request_id = v_request.id
    and decision_record.decision = 'APPROVED';

  if not found then
    raise exception using
      errcode = '42501',
      message = 'APPROVED_REGENERATION_DECISION_REQUIRED';
  end if;

  v_execution_payload := jsonb_build_object(
    'contract_version', 'B2_CERTIFICATE_REGENERATION_EXECUTION_V1',
    'regeneration_request_id', v_request.id,
    'request_sha256', v_request.request_sha256,
    'regeneration_decision_id', v_decision.id,
    'decision_sha256', v_decision.decision_sha256,
    'predecessor_certificate_id',
      v_request.predecessor_certificate_id,
    'requested_certificate_version',
      v_request.requested_certificate_version,
    'expected_installation_version',
      p_expected_installation_version,
    'expected_predecessor_version',
      p_expected_predecessor_version,
    'execution_metadata', p_metadata
  );
  v_execution_sha256 := public.atlas_normalization_sha256(
    v_execution_payload::text
  );

  select certificate.*
  into v_existing
  from public.atlas_installation_certificates as certificate
  where certificate.installation_id = v_request.installation_id
    and certificate.request_id = p_execution_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_execution_sha256
       or v_existing.supersedes_certificate_id <>
          v_request.predecessor_certificate_id then
      raise exception using
        errcode = '22023',
        message =
          'CERTIFICATE_REGENERATION_EXECUTION_IDEMPOTENCY_COLLISION';
    end if;

    v_new_verification :=
      public.atlas_compute_installation_certificate_verification(
        v_existing.id
      );
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'certificate_id', v_existing.id,
      'certificate_code', v_existing.certificate_code,
      'certificate_version', v_existing.certificate_version,
      'supersedes_certificate_id',
        v_existing.supersedes_certificate_id,
      'verified', coalesce(
        (v_new_verification->>'verified')::boolean,
        false
      ),
      'active_transition_enabled', false
    );
  end if;

  select certificate.*
  into v_predecessor
  from public.atlas_installation_certificates as certificate
  where certificate.id = v_request.predecessor_certificate_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end if;

  if v_predecessor.certificate_version <>
       p_expected_predecessor_version
     or v_request.expected_predecessor_version <>
       p_expected_predecessor_version
     or v_decision.expected_predecessor_version <>
       p_expected_predecessor_version
     or v_request.requested_certificate_version <>
       p_expected_predecessor_version + 1 then
    raise exception using
      errcode = '40001', message = 'CERTIFICATE_VERSION_CONFLICT';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_predecessor.installation_id
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
      message = 'CERTIFICATE_REGENERATION_REQUIRES_FINAL_APPROVAL_STATE';
  end if;

  v_lifecycle :=
    public.atlas_compute_installation_certificate_lifecycle(
      v_predecessor.id
    );
  if not coalesce((v_lifecycle->>'revoked')::boolean, false)
     or coalesce((v_lifecycle->>'superseded')::boolean, false) then
    raise exception using
      errcode = '42501',
      message = 'CERTIFICATE_REGENERATION_LIFECYCLE_INVALID';
  end if;

  if exists (
    select 1
    from public.atlas_installation_certificates as successor
    where successor.supersedes_certificate_id = v_predecessor.id
  ) then
    raise exception using
      errcode = '23505', message = 'CERTIFICATE_ALREADY_SUPERSEDED';
  end if;

  v_predecessor_verification :=
    public.atlas_compute_installation_certificate_verification(
      v_predecessor.id
    );
  if not coalesce(
    (v_predecessor_verification->>'verified')::boolean,
    false
  ) then
    raise exception using
      errcode = '42501',
      message = 'PREDECESSOR_CERTIFICATE_INTEGRITY_INVALID';
  end if;

  select count(*)::integer
  into v_source_count
  from public.atlas_installation_certificate_sources as source
  where source.certificate_id = v_predecessor.id
    and source.required;
  if v_source_count <> 7 then
    raise exception using
      errcode = '42501',
      message = 'PREDECESSOR_CERTIFICATE_SOURCE_SET_INVALID';
  end if;

  v_g04 := public.atlas_compute_installation_g04_readiness(
    v_installation.id
  );
  if not coalesce((v_g04->>'precertificate_ready')::boolean, false)
     or v_g04->>'acceptance_package_id' <>
        v_predecessor.acceptance_package_id::text
     or v_g04->>'package_sha256' <>
        v_predecessor.certificate_payload
          ->'acceptance'->>'package_sha256' then
    raise exception using
      errcode = '42501',
      message = 'REGENERATION_REQUIRES_UNCHANGED_CERTIFIED_SNAPSHOT';
  end if;

  v_certificate_code :=
    'ATLAS-CERT-' || upper(v_installation.installation_code) ||
    '-V' || v_request.requested_certificate_version::text;

  v_certificate_payload :=
    v_predecessor.certificate_payload
    || jsonb_build_object(
      'certificate_id', v_certificate_id,
      'certificate_code', v_certificate_code,
      'certificate_version', v_request.requested_certificate_version,
      'issued_at', v_issued_at,
      'supersedes_certificate_id', v_predecessor.id,
      'regeneration', jsonb_build_object(
        'contract_version',
          'B2_CERTIFICATE_CONTROLLED_REGENERATION_V1',
        'regeneration_request_id', v_request.id,
        'request_sha256', v_request.request_sha256,
        'regeneration_decision_id', v_decision.id,
        'decision_sha256', v_decision.decision_sha256,
        'execution_sha256', v_execution_sha256,
        'same_certified_snapshot', true
      )
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
    v_certificate_id,
    v_predecessor.installation_id,
    v_predecessor.empresa_id,
    v_predecessor.acceptance_package_id,
    v_certificate_code,
    v_request.requested_certificate_version,
    v_predecessor.certificate_contract_code,
    v_predecessor.engine_version,
    v_predecessor.certified_state_code,
    'ISSUED',
    v_certificate_payload,
    v_certificate_sha256,
    v_predecessor.evidence_root_sha256,
    p_execution_request_id,
    v_execution_sha256,
    v_actor_user_id,
    v_actor_role_code,
    v_issued_at,
    v_predecessor.id,
    jsonb_build_object(
      'execution_contract', v_execution_payload,
      'execution_metadata', p_metadata,
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
    source.installation_id,
    source.empresa_id,
    source.source_domain,
    source.source_code,
    source.source_record_id,
    source.source_version,
    source.source_sha256,
    source.evidence_reference,
    source.required,
    source.verification_payload,
    v_actor_user_id,
    v_issued_at,
    v_issued_at
  from public.atlas_installation_certificate_sources as source
  where source.certificate_id = v_predecessor.id;

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
      'evidence_root_sha256', v_predecessor.evidence_root_sha256,
      'regeneration_request_id', v_request.id,
      'supersedes_certificate_id', v_predecessor.id
    ),
    verified_by_user_id = v_actor_user_id,
    verified_at = v_issued_at,
    blocking_reason_code = null,
    updated_at = v_issued_at
  where acceptance_package_id = v_predecessor.acceptance_package_id
    and requirement_code = 'INSTALLATION_CERTIFICATE_ISSUED';

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
    v_certificate_id,
    v_predecessor.installation_id,
    v_predecessor.empresa_id,
    'ISSUED',
    v_actor_user_id,
    v_actor_role_code,
    p_execution_request_id,
    'certificate://atlas/' || v_certificate_id::text || '/issued',
    v_certificate_sha256,
    jsonb_build_object(
      'contract_version', 'B2_CERTIFICATE_EVENT_V1',
      'certificate_id', v_certificate_id,
      'certificate_code', v_certificate_code,
      'certificate_version', v_request.requested_certificate_version,
      'certificate_sha256', v_certificate_sha256,
      'evidence_root_sha256', v_predecessor.evidence_root_sha256,
      'request_sha256', v_execution_sha256,
      'regenerated', true,
      'supersedes_certificate_id', v_predecessor.id
    ),
    v_issued_at
  );

  insert into public.atlas_installation_certificate_events (
    certificate_id, installation_id, empresa_id, event_type,
    actor_user_id, actor_role_code, request_id,
    evidence_reference, evidence_sha256, event_payload, created_at
  ) values (
    v_predecessor.id,
    v_predecessor.installation_id,
    v_predecessor.empresa_id,
    'SUPERSEDED',
    v_actor_user_id,
    v_actor_role_code,
    p_execution_request_id,
    'certificate://atlas/' || v_predecessor.id::text ||
      '/superseded/' || v_certificate_id::text,
    v_certificate_sha256,
    jsonb_build_object(
      'contract_version', 'B2_CERTIFICATE_EVENT_V1',
      'certificate_id', v_predecessor.id,
      'certificate_version', v_predecessor.certificate_version,
      'event_type', 'SUPERSEDED',
      'superseding_certificate_id', v_certificate_id,
      'superseding_certificate_version',
        v_request.requested_certificate_version,
      'superseding_certificate_sha256', v_certificate_sha256,
      'regeneration_request_id', v_request.id,
      'decision_sha256', v_decision.decision_sha256,
      'execution_sha256', v_execution_sha256
    ),
    v_issued_at
  );

  v_new_verification :=
    public.atlas_compute_installation_certificate_verification(
      v_certificate_id
    );
  if not coalesce((v_new_verification->>'verified')::boolean, false) then
    raise exception using
      errcode = 'XX001',
      message = 'REGENERATED_CERTIFICATE_FAILED_SELF_VERIFICATION',
      detail = coalesce(
        v_new_verification->'blockers',
        '[]'::jsonb
      )::text;
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_REGENERATED',
    'regeneration_request_id', v_request.id,
    'regeneration_decision_id', v_decision.id,
    'predecessor_certificate_id', v_predecessor.id,
    'certificate_id', v_certificate_id,
    'certificate_code', v_certificate_code,
    'certificate_version', v_request.requested_certificate_version,
    'certificate_sha256', v_certificate_sha256,
    'evidence_root_sha256', v_predecessor.evidence_root_sha256,
    'source_domains', v_source_count,
    'same_certified_snapshot', true,
    'verified', true,
    'historical_predecessor_preserved', true,
    'document_generated', false,
    'g04_auto_approval_enabled', false,
    'active_transition_enabled', false,
    'next_action', 'PREPARE_CERTIFICATE_RENDER_MANIFEST'
  );
end;
$$;

revoke all on function
public.atlas_execute_installation_certificate_regeneration(
  uuid,uuid,bigint,integer,jsonb
)
from public, anon;
grant execute on function
public.atlas_execute_installation_certificate_regeneration(
  uuid,uuid,bigint,integer,jsonb
)
to authenticated, service_role;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K4B2_REGENERATION_EXECUTION_RPC_INSTALLED',
  'next_action', 'CERTIFY_K4B2_REGENERATION_EXECUTION_GUARDS',
  'regeneration_execution_rpcs', 1,
  'single_successor_index_enabled', true,
  'regeneration_requires_revocation', true,
  'regeneration_requires_approved_decision', true,
  'same_certified_snapshot_required', true,
  'predecessor_integrity_revalidation_enabled', true,
  'new_certificate_self_verification_enabled', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'historical_predecessor_preserved', true,
  'certificate_records', (
    select count(*) from public.atlas_installation_certificates
  ),
  'regeneration_requests', (
    select count(*)
    from public.atlas_installation_certificate_regeneration_requests
  ),
  'regeneration_decisions', (
    select count(*)
    from public.atlas_installation_certificate_regeneration_decisions
  ),
  'document_generation_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'direct_authenticated_write', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
