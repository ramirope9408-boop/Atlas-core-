-- ATLAS B2.2K.4B.1
-- Autoridad de regeneracion y preparacion del render manifest.
-- Corte: 2026-09-04
--
-- Habilita solicitud/decision y manifiesto seguro. No ejecuta la
-- regeneracion, no produce archivos y no habilita ACTIVE.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_certificate_regeneration_requests'
     ) is null
     or to_regclass(
       'public.atlas_installation_certificate_render_manifests'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_certificate_lifecycle(uuid)'
     ) is null then
    raise exception 'B2.2K.4B.1 requiere B2.2K.4A certificado';
  end if;

  if to_regprocedure(
       'public.atlas_request_installation_certificate_regeneration(uuid,text,text,text,text,uuid,integer,jsonb)'
     ) is not null
     or to_regprocedure(
       'public.atlas_decide_installation_certificate_regeneration(uuid,text,text,text,text,uuid,integer,jsonb)'
     ) is not null
     or to_regprocedure(
       'public.atlas_prepare_installation_certificate_render_manifest(uuid,text,text,text,text,uuid,jsonb)'
     ) is not null then
    raise exception
      'B2.2K.4B.1 detecto RPC previas; reconciliar antes de instalar';
  end if;
end;
$$;

create or replace function
public.atlas_request_installation_certificate_regeneration(
  p_predecessor_certificate_id uuid,
  p_reason_code text,
  p_reason text,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_request_id uuid,
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
  v_reason_code text := upper(nullif(btrim(p_reason_code), ''));
  v_certificate public.atlas_installation_certificates%rowtype;
  v_existing
    public.atlas_installation_certificate_regeneration_requests%rowtype;
  v_created
    public.atlas_installation_certificate_regeneration_requests%rowtype;
  v_lifecycle jsonb;
  v_request_payload jsonb;
  v_request_sha256 text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_predecessor_certificate_id is null
     or v_reason_code !~ '^[A-Z][A-Z0-9_]{4,99}$'
     or p_reason is null
     or length(btrim(p_reason)) not between 10 and 2000
     or not public.atlas_certificate_reference_is_safe(
       p_evidence_reference
     )
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_request_id is null
     or p_expected_predecessor_version is null
     or p_expected_predecessor_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CERTIFICATE_REGENERATION_REQUEST_FIELDS_INVALID';
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
      message = 'CERTIFICATE_REGENERATION_REQUIRES_ATLAS_OWNER';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_CERTIFICATE_REGENERATION_REQUEST_V1',
    'predecessor_certificate_id', p_predecessor_certificate_id,
    'reason_code', v_reason_code,
    'reason', btrim(p_reason),
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', p_evidence_sha256,
    'expected_predecessor_version',
      p_expected_predecessor_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select request_record.*
  into v_existing
  from public.atlas_installation_certificate_regeneration_requests
    as request_record
  join public.atlas_installation_certificates as certificate
    on certificate.id = request_record.predecessor_certificate_id
  where request_record.predecessor_certificate_id =
      p_predecessor_certificate_id
    and request_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.request_sha256 <> v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'CERTIFICATE_REGENERATION_REQUEST_IDEMPOTENCY_COLLISION';
    end if;
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'regeneration_request_id', v_existing.id,
      'predecessor_certificate_id',
        v_existing.predecessor_certificate_id,
      'requested_certificate_version',
        v_existing.requested_certificate_version,
      'next_action', 'DECIDE_CERTIFICATE_REGENERATION'
    );
  end if;

  select certificate.*
  into v_certificate
  from public.atlas_installation_certificates as certificate
  where certificate.id = p_predecessor_certificate_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end if;

  if v_certificate.certificate_version <>
       p_expected_predecessor_version then
    raise exception using
      errcode = '40001', message = 'CERTIFICATE_VERSION_CONFLICT';
  end if;

  v_lifecycle :=
    public.atlas_compute_installation_certificate_lifecycle(
      v_certificate.id
    );

  if not coalesce((v_lifecycle->>'revoked')::boolean, false) then
    raise exception using
      errcode = '42501',
      message = 'CERTIFICATE_REGENERATION_REQUIRES_REVOCATION';
  end if;

  if coalesce((v_lifecycle->>'superseded')::boolean, false)
     or exists (
       select 1
       from public.atlas_installation_certificates as successor
       where successor.supersedes_certificate_id = v_certificate.id
     ) then
    raise exception using
      errcode = '23505',
      message = 'CERTIFICATE_ALREADY_SUPERSEDED';
  end if;

  insert into
  public.atlas_installation_certificate_regeneration_requests (
    predecessor_certificate_id, installation_id, empresa_id,
    requested_certificate_version, reason_code, reason,
    evidence_reference, evidence_sha256, request_id,
    request_sha256, expected_predecessor_version,
    requested_by_user_id, requested_by_role_code, metadata
  ) values (
    v_certificate.id,
    v_certificate.installation_id,
    v_certificate.empresa_id,
    v_certificate.certificate_version + 1,
    v_reason_code,
    btrim(p_reason),
    p_evidence_reference,
    p_evidence_sha256,
    p_request_id,
    v_request_sha256,
    v_certificate.certificate_version,
    v_actor_user_id,
    v_actor_role_code,
    jsonb_build_object(
      'request_contract', v_request_payload,
      'request_metadata', p_metadata
    )
  ) returning * into v_created;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_REGENERATION_REQUESTED',
    'regeneration_request_id', v_created.id,
    'installation_id', v_created.installation_id,
    'predecessor_certificate_id',
      v_created.predecessor_certificate_id,
    'requested_certificate_version',
      v_created.requested_certificate_version,
    'request_sha256', v_created.request_sha256,
    'automatic_regeneration', false,
    'next_action', 'DECIDE_CERTIFICATE_REGENERATION'
  );
end;
$$;

create or replace function
public.atlas_decide_installation_certificate_regeneration(
  p_regeneration_request_id uuid,
  p_decision text,
  p_reason text,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_decision_request_id uuid,
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
  v_decision text := upper(nullif(btrim(p_decision), ''));
  v_request
    public.atlas_installation_certificate_regeneration_requests%rowtype;
  v_existing
    public.atlas_installation_certificate_regeneration_decisions%rowtype;
  v_created
    public.atlas_installation_certificate_regeneration_decisions%rowtype;
  v_certificate public.atlas_installation_certificates%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_lifecycle jsonb;
  v_g04 jsonb;
  v_decision_payload jsonb;
  v_decision_sha256 text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_regeneration_request_id is null
     or v_decision not in ('APPROVED', 'REJECTED')
     or p_reason is null
     or length(btrim(p_reason)) not between 10 and 2000
     or not public.atlas_certificate_reference_is_safe(
       p_evidence_reference
     )
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_decision_request_id is null
     or p_expected_predecessor_version is null
     or p_expected_predecessor_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CERTIFICATE_REGENERATION_DECISION_FIELDS_INVALID';
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
      message = 'CERTIFICATE_REGENERATION_DECISION_REQUIRES_ATLAS_OWNER';
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

  v_decision_payload := jsonb_build_object(
    'contract_version', 'B2_CERTIFICATE_REGENERATION_DECISION_V1',
    'regeneration_request_id', v_request.id,
    'predecessor_certificate_id',
      v_request.predecessor_certificate_id,
    'request_sha256', v_request.request_sha256,
    'decision', v_decision,
    'reason', btrim(p_reason),
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', p_evidence_sha256,
    'expected_predecessor_version',
      p_expected_predecessor_version,
    'decision_metadata', p_metadata
  );
  v_decision_sha256 := public.atlas_normalization_sha256(
    v_decision_payload::text
  );

  select decision_record.*
  into v_existing
  from public.atlas_installation_certificate_regeneration_decisions
    as decision_record
  where decision_record.installation_id = v_request.installation_id
    and decision_record.decision_request_id = p_decision_request_id
  limit 1;

  if found then
    if v_existing.decision_sha256 <> v_decision_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'CERTIFICATE_REGENERATION_DECISION_IDEMPOTENCY_COLLISION';
    end if;
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'regeneration_decision_id', v_existing.id,
      'regeneration_request_id',
        v_existing.regeneration_request_id,
      'decision', v_existing.decision,
      'next_action', case
        when v_existing.decision = 'APPROVED'
          then 'EXECUTE_CERTIFICATE_REGENERATION'
        else 'CLOSE_REGENERATION_REQUEST'
      end
    );
  end if;

  if exists (
    select 1
    from public.atlas_installation_certificate_regeneration_decisions
      as decision_record
    where decision_record.regeneration_request_id = v_request.id
  ) then
    raise exception using
      errcode = '23505',
      message = 'CERTIFICATE_REGENERATION_ALREADY_DECIDED';
  end if;

  select certificate.*
  into v_certificate
  from public.atlas_installation_certificates as certificate
  where certificate.id = v_request.predecessor_certificate_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end if;

  if v_certificate.certificate_version <>
       p_expected_predecessor_version
     or v_request.expected_predecessor_version <>
       p_expected_predecessor_version then
    raise exception using
      errcode = '40001', message = 'CERTIFICATE_VERSION_CONFLICT';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_certificate.installation_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  v_lifecycle :=
    public.atlas_compute_installation_certificate_lifecycle(
      v_certificate.id
    );

  if v_decision = 'APPROVED' then
    if v_installation.current_state_code <> 'FINAL_APPROVAL' then
      raise exception using
        errcode = '22023',
        message = 'CERTIFICATE_REGENERATION_REQUIRES_FINAL_APPROVAL_STATE';
    end if;

    if not coalesce((v_lifecycle->>'revoked')::boolean, false)
       or coalesce((v_lifecycle->>'superseded')::boolean, false) then
      raise exception using
        errcode = '42501',
        message = 'CERTIFICATE_REGENERATION_LIFECYCLE_INVALID';
    end if;

    v_g04 := public.atlas_compute_installation_g04_readiness(
      v_installation.id
    );
    if not coalesce(
      (v_g04->>'precertificate_ready')::boolean,
      false
    ) then
      raise exception using
        errcode = '42501',
        message = 'CERTIFICATE_REGENERATION_EVIDENCE_NOT_READY';
    end if;
  end if;

  insert into
  public.atlas_installation_certificate_regeneration_decisions (
    regeneration_request_id, predecessor_certificate_id,
    installation_id, empresa_id, decision, reason,
    evidence_reference, evidence_sha256, decision_request_id,
    decision_sha256, expected_predecessor_version,
    decided_by_user_id, decided_by_role_code, metadata
  ) values (
    v_request.id,
    v_certificate.id,
    v_certificate.installation_id,
    v_certificate.empresa_id,
    v_decision,
    btrim(p_reason),
    p_evidence_reference,
    p_evidence_sha256,
    p_decision_request_id,
    v_decision_sha256,
    p_expected_predecessor_version,
    v_actor_user_id,
    v_actor_role_code,
    jsonb_build_object(
      'decision_contract', v_decision_payload,
      'decision_metadata', p_metadata
    )
  ) returning * into v_created;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_REGENERATION_DECIDED',
    'regeneration_request_id', v_request.id,
    'regeneration_decision_id', v_created.id,
    'predecessor_certificate_id', v_certificate.id,
    'requested_certificate_version',
      v_request.requested_certificate_version,
    'decision', v_created.decision,
    'decision_sha256', v_created.decision_sha256,
    'automatic_execution', false,
    'next_action', case
      when v_created.decision = 'APPROVED'
        then 'EXECUTE_CERTIFICATE_REGENERATION'
      else 'CLOSE_REGENERATION_REQUEST'
    end
  );
end;
$$;

create or replace function
public.atlas_prepare_installation_certificate_render_manifest(
  p_certificate_id uuid,
  p_template_code text,
  p_template_version text,
  p_output_format text,
  p_locale text,
  p_idempotency_key uuid,
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
  v_template_code text := upper(nullif(btrim(p_template_code), ''));
  v_template_version text := upper(nullif(btrim(p_template_version), ''));
  v_output_format text := upper(nullif(btrim(p_output_format), ''));
  v_locale text := nullif(btrim(p_locale), '');
  v_certificate public.atlas_installation_certificates%rowtype;
  v_existing
    public.atlas_installation_certificate_render_manifests%rowtype;
  v_previous
    public.atlas_installation_certificate_render_manifests%rowtype;
  v_created
    public.atlas_installation_certificate_render_manifests%rowtype;
  v_lifecycle jsonb;
  v_safe_projection jsonb;
  v_safe_projection_sha256 text;
  v_render_version integer;
  v_render_manifest jsonb;
  v_render_manifest_sha256 text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_certificate_id is null
     or v_template_code !~ '^[A-Z][A-Z0-9_]*$'
     or v_template_version !~ '^V[0-9]+$'
     or v_output_format not in ('PDF', 'PDF_A_3')
     or v_locale !~ '^[a-z]{2}-[A-Z]{2}$'
     or p_idempotency_key is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CERTIFICATE_RENDER_MANIFEST_FIELDS_INVALID';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_CERTIFICATE_RENDER_PREPARE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_CERTIFICATE_RENDER_PREPARE_FORBIDDEN';
  end if;

  v_actor_role_code :=
    public.atlas_certificate_platform_role_for_permission(
      'INSTALLATION_CERTIFICATE_RENDER_PREPARE'
    );
  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'CERTIFICATE_RENDER_PREPARE_ROLE_NOT_RESOLVED';
  end if;

  select manifest.*
  into v_existing
  from public.atlas_installation_certificate_render_manifests
    as manifest
  where manifest.certificate_id = p_certificate_id
    and manifest.idempotency_key = p_idempotency_key
  limit 1;

  if found then
    if v_existing.template_code <> v_template_code
       or v_existing.template_version <> v_template_version
       or v_existing.output_format <> v_output_format
       or v_existing.locale <> v_locale
       or v_existing.metadata->'request_metadata' is distinct from
          p_metadata then
      raise exception using
        errcode = '22023',
        message = 'CERTIFICATE_RENDER_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'render_manifest_id', v_existing.id,
      'certificate_id', v_existing.certificate_id,
      'render_version', v_existing.render_version,
      'render_manifest_sha256',
        v_existing.render_manifest_sha256,
      'render_status', v_existing.render_status,
      'next_action', 'RENDER_CERTIFICATE_DOCUMENT'
    );
  end if;

  select certificate.*
  into v_certificate
  from public.atlas_installation_certificates as certificate
  where certificate.id = p_certificate_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_CERTIFICATE_NOT_FOUND';
  end if;

  v_lifecycle :=
    public.atlas_compute_installation_certificate_lifecycle(
      v_certificate.id
    );
  if not coalesce((v_lifecycle->>'effective')::boolean, false)
     or not coalesce(
       (v_lifecycle->>'cryptographically_verified')::boolean,
       false
     ) then
    raise exception using
      errcode = '42501',
      message = 'ONLY_EFFECTIVE_VERIFIED_CERTIFICATE_CAN_BE_RENDERED';
  end if;

  v_safe_projection :=
    public.atlas_get_installation_certificate_safe_projection(
      v_certificate.id
    );
  if v_safe_projection->>'projection_contract_version' <>
       'B2_INSTALLATION_CERTIFICATE_SAFE_PROJECTION_V1'
     or coalesce(
       (v_safe_projection->>'raw_payloads_exposed')::boolean,
       true
     )
     or coalesce(
       (v_safe_projection->>'evidence_references_exposed')::boolean,
       true
     )
     or coalesce(
       (v_safe_projection->>'actor_identities_exposed')::boolean,
       true
     )
     or public.atlas_jsonb_has_forbidden_secret_key(
       v_safe_projection
     ) then
    raise exception using
      errcode = '42501',
      message = 'CERTIFICATE_SAFE_PROJECTION_INVALID';
  end if;

  select manifest.*
  into v_previous
  from public.atlas_installation_certificate_render_manifests
    as manifest
  where manifest.certificate_id = v_certificate.id
  order by manifest.render_version desc, manifest.created_at desc
  limit 1;

  v_render_version := coalesce(v_previous.render_version, 0) + 1;
  v_safe_projection_sha256 := public.atlas_normalization_sha256(
    v_safe_projection::text
  );
  v_render_manifest := jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_CERTIFICATE_RENDER_V1',
    'certificate_id', v_certificate.id,
    'certificate_code', v_certificate.certificate_code,
    'certificate_version', v_certificate.certificate_version,
    'render_version', v_render_version,
    'template_code', v_template_code,
    'template_version', v_template_version,
    'output_format', v_output_format,
    'locale', v_locale,
    'safe_projection_sha256', v_safe_projection_sha256,
    'certificate_sha256', v_certificate.certificate_sha256,
    'evidence_root_sha256', v_certificate.evidence_root_sha256,
    'sections', jsonb_build_array(
      'IDENTITY', 'SCOPE', 'VERIFICATION', 'INTEGRITY', 'STATUS'
    ),
    'renderer_authority_actions_allowed', false,
    'rendering_changes_certificate_state', false
  );
  v_render_manifest_sha256 := public.atlas_normalization_sha256(
    v_render_manifest::text
  );

  insert into public.atlas_installation_certificate_render_manifests (
    certificate_id, installation_id, empresa_id, render_version,
    render_contract_code, template_code, template_version,
    output_format, locale, render_status, safe_projection,
    safe_projection_sha256, render_manifest,
    render_manifest_sha256, idempotency_key,
    prepared_by_user_id, prepared_by_role_code,
    supersedes_render_manifest_id, metadata
  ) values (
    v_certificate.id,
    v_certificate.installation_id,
    v_certificate.empresa_id,
    v_render_version,
    'B2_INSTALLATION_CERTIFICATE_RENDER_V1',
    v_template_code,
    v_template_version,
    v_output_format,
    v_locale,
    'READY_FOR_RENDER',
    v_safe_projection,
    v_safe_projection_sha256,
    v_render_manifest,
    v_render_manifest_sha256,
    p_idempotency_key,
    v_actor_user_id,
    v_actor_role_code,
    v_previous.id,
    jsonb_build_object('request_metadata', p_metadata)
  ) returning * into v_created;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_RENDER_MANIFEST_PREPARED',
    'render_manifest_id', v_created.id,
    'certificate_id', v_created.certificate_id,
    'certificate_code', v_certificate.certificate_code,
    'render_version', v_created.render_version,
    'render_contract_version', v_created.render_contract_code,
    'template_code', v_created.template_code,
    'template_version', v_created.template_version,
    'output_format', v_created.output_format,
    'locale', v_created.locale,
    'safe_projection_sha256', v_created.safe_projection_sha256,
    'render_manifest_sha256', v_created.render_manifest_sha256,
    'render_status', v_created.render_status,
    'document_generated', false,
    'active_transition_enabled', false,
    'next_action', 'RENDER_CERTIFICATE_DOCUMENT'
  );
end;
$$;

revoke all on function
public.atlas_request_installation_certificate_regeneration(
  uuid,text,text,text,text,uuid,integer,jsonb
)
from public, anon;
revoke all on function
public.atlas_decide_installation_certificate_regeneration(
  uuid,text,text,text,text,uuid,integer,jsonb
)
from public, anon;
revoke all on function
public.atlas_prepare_installation_certificate_render_manifest(
  uuid,text,text,text,text,uuid,jsonb
)
from public, anon;

grant execute on function
public.atlas_request_installation_certificate_regeneration(
  uuid,text,text,text,text,uuid,integer,jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_decide_installation_certificate_regeneration(
  uuid,text,text,text,text,uuid,integer,jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_prepare_installation_certificate_render_manifest(
  uuid,text,text,text,text,uuid,jsonb
)
to authenticated, service_role;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K4B1_REGENERATION_AUTHORITY_RENDER_RPCS_INSTALLED',
  'next_block', 'B2.2K.4B.2_REGENERATION_EXECUTION_RPC',
  'regeneration_authority_rpcs', 2,
  'render_manifest_rpcs', 1,
  'regeneration_requests', (
    select count(*)
    from public.atlas_installation_certificate_regeneration_requests
  ),
  'regeneration_decisions', (
    select count(*)
    from public.atlas_installation_certificate_regeneration_decisions
  ),
  'render_manifests', (
    select count(*)
    from public.atlas_installation_certificate_render_manifests
  ),
  'regeneration_requires_revocation', true,
  'regeneration_requires_human_decision', true,
  'regeneration_execution_enabled', false,
  'render_manifest_preparation_enabled', true,
  'document_generation_enabled', false,
  'safe_projection_required', true,
  'request_idempotency_enabled', true,
  'optimistic_concurrency_enabled', true,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'direct_authenticated_write', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
