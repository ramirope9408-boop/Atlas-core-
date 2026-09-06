-- ATLAS B2.2K.3 - Ciclo de vida y proyeccion segura del certificado.
-- Corte: 2026-09-04
--
-- La revocacion es append-only. La proyeccion oculta referencias internas,
-- actores, payloads y metadatos. No regenera ni renderiza certificados.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_issue_installation_certificate(uuid,uuid,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_certificate_verification(uuid)'
     ) is null
     or to_regclass(
       'public.atlas_installation_certificate_events'
     ) is null then
    raise exception 'B2.2K.3 requiere B2.2K.2 instalado y certificado';
  end if;

  if to_regprocedure(
       'public.atlas_revoke_installation_certificate(uuid,text,text,text,text,uuid,integer,jsonb)'
     ) is not null
     or to_regprocedure(
       'public.atlas_get_installation_certificate_safe_projection(uuid)'
     ) is not null
     or to_regprocedure(
       'public.atlas_list_installation_certificate_history(uuid)'
     ) is not null then
    raise exception
      'B2.2K.3 detecto RPC previas; reconciliar antes de instalar';
  end if;
end;
$$;

create or replace function
public.atlas_compute_installation_certificate_lifecycle(
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
  v_verification jsonb;
  v_revocation public.atlas_installation_certificate_events%rowtype;
  v_superseding public.atlas_installation_certificates%rowtype;
  v_event_count integer := 0;
  v_lifecycle_status text;
begin
  if p_certificate_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'CERTIFICATE_ID_REQUIRED',
      'lifecycle_status', 'UNKNOWN'
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
      'lifecycle_status', 'UNKNOWN'
    );
  end if;

  select event_record.*
  into v_revocation
  from public.atlas_installation_certificate_events as event_record
  where event_record.certificate_id = v_certificate.id
    and event_record.event_type = 'REVOKED'
  order by event_record.created_at desc, event_record.id desc
  limit 1;

  select certificate.*
  into v_superseding
  from public.atlas_installation_certificates as certificate
  where certificate.supersedes_certificate_id = v_certificate.id
  order by
    certificate.certificate_version desc,
    certificate.issued_at desc,
    certificate.id desc
  limit 1;

  select count(*)::integer
  into v_event_count
  from public.atlas_installation_certificate_events as event_record
  where event_record.certificate_id = v_certificate.id;

  v_verification :=
    public.atlas_compute_installation_certificate_verification(
      v_certificate.id
    );

  v_lifecycle_status := case
    when v_revocation.id is not null then 'REVOKED'
    when v_superseding.id is not null then 'SUPERSEDED'
    when coalesce((v_verification->>'verified')::boolean, false)
      then 'VERIFIED'
    else 'ISSUED_UNVERIFIED'
  end;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_LIFECYCLE_COMPUTED',
    'certificate_id', v_certificate.id,
    'installation_id', v_certificate.installation_id,
    'certificate_version', v_certificate.certificate_version,
    'lifecycle_status', v_lifecycle_status,
    'cryptographically_verified', coalesce(
      (v_verification->>'verified')::boolean,
      false
    ),
    'event_count', v_event_count,
    'revoked', v_revocation.id is not null,
    'revoked_at', v_revocation.created_at,
    'superseded', v_superseding.id is not null,
    'superseding_certificate_id', v_superseding.id,
    'superseding_certificate_version',
      v_superseding.certificate_version,
    'effective',
      v_revocation.id is null
      and v_superseding.id is null
      and coalesce((v_verification->>'verified')::boolean, false),
    'raw_event_payloads_exposed', false,
    'actor_identity_exposed', false
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_certificate_lifecycle(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_certificate_lifecycle(uuid)
to service_role;

create or replace function
public.atlas_revoke_installation_certificate(
  p_certificate_id uuid,
  p_reason_code text,
  p_reason text,
  p_evidence_reference text,
  p_evidence_sha256 text,
  p_request_id uuid,
  p_expected_certificate_version integer,
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
  v_existing public.atlas_installation_certificate_events%rowtype;
  v_lifecycle jsonb;
  v_request_payload jsonb;
  v_request_sha256 text;
  v_event_payload jsonb;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_certificate_id is null
     or v_reason_code !~ '^[A-Z][A-Z0-9_]{4,99}$'
     or p_reason is null
     or length(btrim(p_reason)) not between 10 and 2000
     or not public.atlas_certificate_reference_is_safe(
       p_evidence_reference
     )
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_request_id is null
     or p_expected_certificate_version is null
     or p_expected_certificate_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CERTIFICATE_REVOCATION_REQUIRED_FIELDS_INVALID';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_CERTIFICATE_REVOKE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_CERTIFICATE_REVOKE_FORBIDDEN';
  end if;

  v_actor_role_code :=
    public.atlas_certificate_platform_role_for_permission(
      'INSTALLATION_CERTIFICATE_REVOKE'
    );

  if v_actor_role_code <> 'ATLAS_OWNER' then
    raise exception using
      errcode = '42501',
      message = 'CERTIFICATE_REVOCATION_REQUIRES_ATLAS_OWNER';
  end if;

  v_request_payload := jsonb_build_object(
    'contract_version', 'B2_CERTIFICATE_REVOCATION_REQUEST_V1',
    'certificate_id', p_certificate_id,
    'reason_code', v_reason_code,
    'reason', btrim(p_reason),
    'evidence_reference', p_evidence_reference,
    'evidence_sha256', p_evidence_sha256,
    'expected_certificate_version', p_expected_certificate_version,
    'request_metadata', p_metadata
  );
  v_request_sha256 := public.atlas_normalization_sha256(
    v_request_payload::text
  );

  select event_record.*
  into v_existing
  from public.atlas_installation_certificate_events as event_record
  where event_record.certificate_id = p_certificate_id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.event_type <> 'REVOKED'
       or v_existing.event_payload->>'request_sha256' <>
          v_request_sha256 then
      raise exception using
        errcode = '22023',
        message =
          'CERTIFICATE_REVOCATION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'certificate_id', v_existing.certificate_id,
      'revocation_event_id', v_existing.id,
      'lifecycle_status', 'REVOKED',
      'revoked_at', v_existing.created_at,
      'active_transition_enabled', false
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

  if v_certificate.certificate_version <>
       p_expected_certificate_version then
    raise exception using
      errcode = '40001', message = 'CERTIFICATE_VERSION_CONFLICT';
  end if;

  v_lifecycle :=
    public.atlas_compute_installation_certificate_lifecycle(
      v_certificate.id
    );

  if coalesce((v_lifecycle->>'revoked')::boolean, false) then
    raise exception using
      errcode = '23505', message = 'CERTIFICATE_ALREADY_REVOKED';
  end if;

  if coalesce((v_lifecycle->>'superseded')::boolean, false) then
    raise exception using
      errcode = '22023',
      message = 'SUPERSEDED_CERTIFICATE_CANNOT_BE_REVOKED';
  end if;

  if not coalesce(
    (v_lifecycle->>'cryptographically_verified')::boolean,
    false
  ) then
    raise exception using
      errcode = '42501',
      message = 'UNVERIFIED_CERTIFICATE_CANNOT_BE_REVOKED';
  end if;

  v_event_payload := jsonb_build_object(
    'contract_version', 'B2_CERTIFICATE_EVENT_V1',
    'certificate_id', v_certificate.id,
    'certificate_code', v_certificate.certificate_code,
    'certificate_version', v_certificate.certificate_version,
    'certificate_sha256', v_certificate.certificate_sha256,
    'event_type', 'REVOKED',
    'reason_code', v_reason_code,
    'reason', btrim(p_reason),
    'request_sha256', v_request_sha256
  );

  insert into public.atlas_installation_certificate_events (
    certificate_id, installation_id, empresa_id, event_type,
    actor_user_id, actor_role_code, request_id,
    evidence_reference, evidence_sha256, event_payload
  ) values (
    v_certificate.id,
    v_certificate.installation_id,
    v_certificate.empresa_id,
    'REVOKED',
    v_actor_user_id,
    v_actor_role_code,
    p_request_id,
    p_evidence_reference,
    p_evidence_sha256,
    v_event_payload
  )
  returning * into v_existing;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_REVOKED',
    'certificate_id', v_certificate.id,
    'certificate_code', v_certificate.certificate_code,
    'certificate_version', v_certificate.certificate_version,
    'certificate_sha256', v_certificate.certificate_sha256,
    'revocation_event_id', v_existing.id,
    'lifecycle_status', 'REVOKED',
    'revoked_at', v_existing.created_at,
    'historical_record_preserved', true,
    'regeneration_automatic', false,
    'g04_auto_approval_enabled', false,
    'active_transition_enabled', false,
    'next_action', 'ASSESS_CONTROLLED_REGENERATION'
  );
end;
$$;

create or replace function
public.atlas_get_installation_certificate_safe_projection(
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
  v_lifecycle jsonb;
  v_verification jsonb;
  v_source_summary jsonb := '[]'::jsonb;
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

  v_lifecycle :=
    public.atlas_compute_installation_certificate_lifecycle(
      v_certificate.id
    );
  v_verification :=
    public.atlas_compute_installation_certificate_verification(
      v_certificate.id
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'domain', source.source_domain,
        'source_code', source.source_code,
        'source_version', source.source_version,
        'source_sha256', source.source_sha256,
        'verified', true,
        'verified_at', source.verified_at
      )
      order by source.source_domain, source.source_code
    ),
    '[]'::jsonb
  )
  into v_source_summary
  from public.atlas_installation_certificate_sources as source
  where source.certificate_id = v_certificate.id
    and source.required;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_SAFE_PROJECTION',
    'projection_contract_version',
      'B2_INSTALLATION_CERTIFICATE_SAFE_PROJECTION_V1',
    'certificate_id', v_certificate.id,
    'certificate_code', v_certificate.certificate_code,
    'certificate_version', v_certificate.certificate_version,
    'certificate_contract_version',
      v_certificate.certificate_contract_code,
    'installation_id', v_certificate.installation_id,
    'empresa_id', v_certificate.empresa_id,
    'company_legal_name',
      v_certificate.certificate_payload->>'company_legal_name',
    'company_trade_name',
      v_certificate.certificate_payload->>'company_trade_name',
    'engine_version', v_certificate.engine_version,
    'certified_state_code', v_certificate.certified_state_code,
    'issued_at', v_certificate.issued_at,
    'lifecycle_status', v_lifecycle->>'lifecycle_status',
    'effective', coalesce(
      (v_lifecycle->>'effective')::boolean,
      false
    ),
    'cryptographically_verified', coalesce(
      (v_verification->>'verified')::boolean,
      false
    ),
    'certificate_sha256', v_certificate.certificate_sha256,
    'evidence_root_sha256', v_certificate.evidence_root_sha256,
    'source_domains', v_source_summary,
    'module_summary', jsonb_build_object(
      'manifest_version',
        v_certificate.certificate_payload
          ->'manifest'->>'manifest_version',
      'provisioning_plan_version',
        v_certificate.certificate_payload
          ->'provisioning'->>'plan_version',
      'integration_contract_version',
        v_certificate.certificate_payload
          ->'integrations'->>'readiness_contract_version',
      'acceptance_version',
        v_certificate.certificate_payload
          ->'acceptance'->>'acceptance_version'
    ),
    'revoked_at', v_lifecycle->'revoked_at',
    'superseding_certificate_id',
      v_lifecycle->'superseding_certificate_id',
    'credential_values_exposed', false,
    'raw_payloads_exposed', false,
    'evidence_references_exposed', false,
    'actor_identities_exposed', false,
    'internal_metadata_exposed', false
  );
end;
$$;

create or replace function
public.atlas_list_installation_certificate_history(
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
  v_history jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_installation_id is null then
    raise exception using
      errcode = '22023', message = 'INSTALLATION_ID_REQUIRED';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  if not public.atlas_can_read_installation(v_installation.id)
     and not public.atlas_platform_has_permission(
       'INSTALLATION_CERTIFICATE_READ'
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_CERTIFICATE_READ_FORBIDDEN';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'certificate_id', certificate.id,
        'certificate_code', certificate.certificate_code,
        'certificate_version', certificate.certificate_version,
        'contract_version', certificate.certificate_contract_code,
        'issued_at', certificate.issued_at,
        'certificate_sha256', certificate.certificate_sha256,
        'evidence_root_sha256', certificate.evidence_root_sha256,
        'lifecycle_status',
          lifecycle.value->>'lifecycle_status',
        'effective', coalesce(
          (lifecycle.value->>'effective')::boolean,
          false
        ),
        'supersedes_certificate_id',
          certificate.supersedes_certificate_id
      )
      order by certificate.certificate_version desc,
        certificate.issued_at desc,
        certificate.id desc
    ),
    '[]'::jsonb
  )
  into v_history
  from public.atlas_installation_certificates as certificate
  cross join lateral (
    select public.atlas_compute_installation_certificate_lifecycle(
      certificate.id
    ) as value
  ) as lifecycle
  where certificate.installation_id = v_installation.id;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_HISTORY',
    'projection_contract_version',
      'B2_INSTALLATION_CERTIFICATE_HISTORY_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'certificate_count', jsonb_array_length(v_history),
    'certificates', v_history,
    'raw_payloads_exposed', false,
    'evidence_references_exposed', false,
    'actor_identities_exposed', false
  );
end;
$$;

revoke all on function
public.atlas_revoke_installation_certificate(
  uuid,text,text,text,text,uuid,integer,jsonb
)
from public, anon;
revoke all on function
public.atlas_get_installation_certificate_safe_projection(uuid)
from public, anon;
revoke all on function
public.atlas_list_installation_certificate_history(uuid)
from public, anon;

grant execute on function
public.atlas_revoke_installation_certificate(
  uuid,text,text,text,text,uuid,integer,jsonb
)
to authenticated, service_role;
grant execute on function
public.atlas_get_installation_certificate_safe_projection(uuid)
to authenticated, service_role;
grant execute on function
public.atlas_list_installation_certificate_history(uuid)
to authenticated, service_role;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K3_CERTIFICATE_LIFECYCLE_SAFE_PROJECTION_INSTALLED',
  'next_action', 'CERTIFY_K3_LIFECYCLE_AND_PROJECTION_GUARDS',
  'lifecycle_rpcs', 1,
  'safe_projection_rpcs', 2,
  'lifecycle_helpers', 1,
  'revocation_authority', 'ATLAS_OWNER',
  'revocation_append_only', true,
  'historical_records_preserved', true,
  'safe_projection_contract_version',
    'B2_INSTALLATION_CERTIFICATE_SAFE_PROJECTION_V1',
  'raw_payloads_exposed', false,
  'evidence_references_exposed', false,
  'actor_identities_exposed', false,
  'controlled_regeneration_enabled', false,
  'certificate_rendering_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'certificate_records', (
    select count(*) from public.atlas_installation_certificates
  ),
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
