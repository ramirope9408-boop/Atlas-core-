-- ATLAS B2.2K.4C
-- Integridad historica y cierre de la capa de certificados.
-- Corte: 2026-09-04
--
-- Separa dos conceptos que no deben confundirse:
--   1. integridad historica: hashes, fuentes y eventos siguen siendo autenticos;
--   2. efectividad actual: el certificado no fue revocado/sustituido y conserva
--      el binding vigente con el requisito G04.
-- No emite, revoca, regenera ni renderiza certificados.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_compute_installation_certificate_verification(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_installation_certificate_lifecycle(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_execute_installation_certificate_regeneration(uuid,uuid,bigint,integer,jsonb)'
     ) is null
     or to_regclass(
       'public.atlas_installation_certificate_sources'
     ) is null
     or to_regclass(
       'public.atlas_installation_certificate_events'
     ) is null then
    raise exception
      'B2.2K.4C requiere B2.2K.4B.2 instalado y certificado';
  end if;

  if to_regprocedure(
       'public.atlas_compute_installation_certificate_historical_integrity(uuid)'
     ) is not null
     or to_regprocedure(
       'public.atlas_verify_installation_certificate_history_integrity(uuid)'
     ) is not null then
    raise exception
      'B2.2K.4C detecto funciones previas; reconciliar antes de instalar';
  end if;
end;
$$;

create or replace function
public.atlas_compute_installation_certificate_historical_integrity(
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
  v_predecessor public.atlas_installation_certificates%rowtype;
  v_successor public.atlas_installation_certificates%rowtype;
  v_source_projection jsonb := '[]'::jsonb;
  v_recomputed_root text;
  v_source_count integer := 0;
  v_domain_count integer := 0;
  v_required_domains_complete boolean := false;
  v_payload_hash_valid boolean := false;
  v_issuance_event_valid boolean := false;
  v_predecessor_binding_valid boolean := false;
  v_successor_binding_valid boolean := false;
  v_integrity_verified boolean := false;
  v_blockers jsonb := '[]'::jsonb;
begin
  if p_certificate_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'CERTIFICATE_ID_REQUIRED',
      'historical_integrity_verified', false
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
      'historical_integrity_verified', false
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
  ) into v_issuance_event_valid;

  if v_certificate.certificate_version = 1 then
    v_predecessor_binding_valid :=
      v_certificate.supersedes_certificate_id is null;
  else
    select predecessor.*
    into v_predecessor
    from public.atlas_installation_certificates as predecessor
    where predecessor.id = v_certificate.supersedes_certificate_id;

    v_predecessor_binding_valid :=
      v_predecessor.id is not null
      and v_predecessor.installation_id = v_certificate.installation_id
      and v_predecessor.empresa_id = v_certificate.empresa_id
      and v_predecessor.acceptance_package_id =
        v_certificate.acceptance_package_id
      and v_predecessor.certificate_version =
        v_certificate.certificate_version - 1
      and v_predecessor.evidence_root_sha256 =
        v_certificate.evidence_root_sha256
      and coalesce(
        (
          v_certificate.certificate_payload
            ->'regeneration'->>'same_certified_snapshot'
        )::boolean,
        false
      )
      and exists (
        select 1
        from public.atlas_installation_certificate_events as event_record
        where event_record.certificate_id = v_predecessor.id
          and event_record.event_type = 'REVOKED'
      )
      and exists (
        select 1
        from public.atlas_installation_certificate_events as event_record
        where event_record.certificate_id = v_predecessor.id
          and event_record.event_type = 'SUPERSEDED'
          and event_record.evidence_sha256 =
            v_certificate.certificate_sha256
          and event_record.event_payload->>'superseding_certificate_id' =
            v_certificate.id::text
      );
  end if;

  select successor.*
  into v_successor
  from public.atlas_installation_certificates as successor
  where successor.supersedes_certificate_id = v_certificate.id
  order by successor.certificate_version desc, successor.id desc
  limit 1;

  if v_successor.id is null then
    v_successor_binding_valid := true;
  else
    v_successor_binding_valid :=
      v_successor.installation_id = v_certificate.installation_id
      and v_successor.empresa_id = v_certificate.empresa_id
      and v_successor.acceptance_package_id =
        v_certificate.acceptance_package_id
      and v_successor.certificate_version =
        v_certificate.certificate_version + 1
      and v_successor.evidence_root_sha256 =
        v_certificate.evidence_root_sha256
      and exists (
        select 1
        from public.atlas_installation_certificate_events as event_record
        where event_record.certificate_id = v_certificate.id
          and event_record.event_type = 'SUPERSEDED'
          and event_record.evidence_sha256 =
            v_successor.certificate_sha256
          and event_record.event_payload->>'superseding_certificate_id' =
            v_successor.id::text
      );
  end if;

  v_integrity_verified :=
    v_required_domains_complete
    and v_payload_hash_valid
    and v_recomputed_root = v_certificate.evidence_root_sha256
    and v_issuance_event_valid
    and v_predecessor_binding_valid
    and v_successor_binding_valid;

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
    case when not v_issuance_event_valid
      then jsonb_build_object(
        'criterion', 'ISSUANCE_EVENT_BOUND',
        'reason', 'BOUND_ISSUANCE_EVENT_REQUIRED'
      ) end,
    case when not v_predecessor_binding_valid
      then jsonb_build_object(
        'criterion', 'PREDECESSOR_CHAIN_VALID',
        'reason', 'IMMEDIATE_REVOKED_PREDECESSOR_BINDING_REQUIRED'
      ) end,
    case when not v_successor_binding_valid
      then jsonb_build_object(
        'criterion', 'SUCCESSOR_CHAIN_VALID',
        'reason', 'IMMEDIATE_SUCCESSOR_EVENT_BINDING_REQUIRED'
      ) end
  )) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_integrity_verified
        then 'INSTALLATION_CERTIFICATE_HISTORICAL_INTEGRITY_VERIFIED'
      else 'INSTALLATION_CERTIFICATE_HISTORICAL_INTEGRITY_FAILED'
    end,
    'integrity_contract_version',
      'B2_INSTALLATION_CERTIFICATE_HISTORICAL_INTEGRITY_V1',
    'certificate_id', v_certificate.id,
    'installation_id', v_certificate.installation_id,
    'empresa_id', v_certificate.empresa_id,
    'certificate_version', v_certificate.certificate_version,
    'certificate_sha256', v_certificate.certificate_sha256,
    'stored_evidence_root_sha256',
      v_certificate.evidence_root_sha256,
    'recomputed_evidence_root_sha256', v_recomputed_root,
    'source_count', v_source_count,
    'source_domain_count', v_domain_count,
    'required_domains_complete', v_required_domains_complete,
    'payload_hash_valid', v_payload_hash_valid,
    'issuance_event_valid', v_issuance_event_valid,
    'predecessor_binding_valid', v_predecessor_binding_valid,
    'successor_binding_valid', v_successor_binding_valid,
    'historical_integrity_verified', v_integrity_verified,
    'current_g04_binding_required', false,
    'blockers', v_blockers,
    'credential_values_exposed', false,
    'raw_payloads_exposed', false
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_certificate_historical_integrity(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_certificate_historical_integrity(uuid)
to service_role;

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
  v_current_verification jsonb;
  v_historical_integrity jsonb;
  v_revocation public.atlas_installation_certificate_events%rowtype;
  v_superseding public.atlas_installation_certificates%rowtype;
  v_event_count integer := 0;
  v_historical_integrity_verified boolean := false;
  v_current_requirement_binding_valid boolean := false;
  v_effective boolean := false;
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
  order by certificate.certificate_version desc, certificate.id desc
  limit 1;

  select count(*)::integer
  into v_event_count
  from public.atlas_installation_certificate_events as event_record
  where event_record.certificate_id = v_certificate.id;

  v_historical_integrity :=
    public.atlas_compute_installation_certificate_historical_integrity(
      v_certificate.id
    );
  v_current_verification :=
    public.atlas_compute_installation_certificate_verification(
      v_certificate.id
    );

  v_historical_integrity_verified := coalesce(
    (v_historical_integrity->>'historical_integrity_verified')::boolean,
    false
  );
  v_current_requirement_binding_valid := coalesce(
    (v_current_verification->>'requirement_binding_valid')::boolean,
    false
  );
  v_effective :=
    v_historical_integrity_verified
    and v_current_requirement_binding_valid
    and v_revocation.id is null
    and v_superseding.id is null;

  v_lifecycle_status := case
    when v_superseding.id is not null then 'SUPERSEDED'
    when v_revocation.id is not null then 'REVOKED'
    when v_effective then 'VERIFIED'
    else 'ISSUED_UNVERIFIED'
  end;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CERTIFICATE_LIFECYCLE_COMPUTED',
    'lifecycle_contract_version',
      'B2_INSTALLATION_CERTIFICATE_LIFECYCLE_V2',
    'certificate_id', v_certificate.id,
    'installation_id', v_certificate.installation_id,
    'certificate_version', v_certificate.certificate_version,
    'lifecycle_status', v_lifecycle_status,
    'cryptographically_verified',
      v_historical_integrity_verified,
    'historical_integrity_verified',
      v_historical_integrity_verified,
    'current_requirement_binding_valid',
      v_current_requirement_binding_valid,
    'event_count', v_event_count,
    'revoked', v_revocation.id is not null,
    'revoked_at', v_revocation.created_at,
    'superseded', v_superseding.id is not null,
    'superseding_certificate_id', v_superseding.id,
    'superseding_certificate_version',
      v_superseding.certificate_version,
    'effective', v_effective,
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
      (v_lifecycle->>'historical_integrity_verified')::boolean,
      false
    ),
    'historical_integrity_verified', coalesce(
      (v_lifecycle->>'historical_integrity_verified')::boolean,
      false
    ),
    'current_requirement_binding_valid', coalesce(
      (v_lifecycle->>'current_requirement_binding_valid')::boolean,
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
        'historical_integrity_verified', coalesce(
          (
            lifecycle.value
              ->>'historical_integrity_verified'
          )::boolean,
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
    'historical_integrity_projected', true,
    'raw_payloads_exposed', false,
    'evidence_references_exposed', false,
    'actor_identities_exposed', false
  );
end;
$$;

create or replace function
public.atlas_verify_installation_certificate_history_integrity(
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
  v_certificate public.atlas_installation_certificates%rowtype;
  v_integrity jsonb;
  v_lifecycle jsonb;
  v_certificate_count integer := 0;
  v_historically_verified_count integer := 0;
  v_effective_count integer := 0;
  v_initial_count integer := 0;
  v_max_version integer := 0;
  v_expected_version integer := 1;
  v_previous_id uuid;
  v_previous_root text;
  v_chain_complete boolean := true;
  v_all_historically_verified boolean := true;
  v_effective_certificate_is_latest boolean := true;
  v_history_projection jsonb := '[]'::jsonb;
  v_history_root_sha256 text;
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

  select
    count(*)::integer,
    count(*) filter (
      where certificate.supersedes_certificate_id is null
    )::integer,
    coalesce(max(certificate.certificate_version), 0)::integer
  into v_certificate_count, v_initial_count, v_max_version
  from public.atlas_installation_certificates as certificate
  where certificate.installation_id = v_installation.id;

  for v_certificate in
    select certificate.*
    from public.atlas_installation_certificates as certificate
    where certificate.installation_id = v_installation.id
    order by certificate.certificate_version, certificate.id
  loop
    v_integrity :=
      public.atlas_compute_installation_certificate_historical_integrity(
        v_certificate.id
      );
    v_lifecycle :=
      public.atlas_compute_installation_certificate_lifecycle(
        v_certificate.id
      );

    if coalesce(
      (v_integrity->>'historical_integrity_verified')::boolean,
      false
    ) then
      v_historically_verified_count :=
        v_historically_verified_count + 1;
    else
      v_all_historically_verified := false;
    end if;

    if coalesce((v_lifecycle->>'effective')::boolean, false) then
      v_effective_count := v_effective_count + 1;
      if v_certificate.certificate_version <> v_max_version then
        v_effective_certificate_is_latest := false;
      end if;
    end if;

    if v_certificate.certificate_version <> v_expected_version
       or (
         v_expected_version = 1
         and v_certificate.supersedes_certificate_id is not null
       )
       or (
         v_expected_version > 1
         and v_certificate.supersedes_certificate_id is distinct from
           v_previous_id
       )
       or (
         v_expected_version > 1
         and v_certificate.evidence_root_sha256 is distinct from
           v_previous_root
       ) then
      v_chain_complete := false;
    end if;

    v_history_projection := v_history_projection ||
      jsonb_build_array(jsonb_build_object(
        'certificate_id', v_certificate.id,
        'certificate_version', v_certificate.certificate_version,
        'certificate_sha256', v_certificate.certificate_sha256,
        'evidence_root_sha256', v_certificate.evidence_root_sha256,
        'supersedes_certificate_id',
          v_certificate.supersedes_certificate_id,
        'historical_integrity_verified', coalesce(
          (
            v_integrity
              ->>'historical_integrity_verified'
          )::boolean,
          false
        ),
        'lifecycle_status', v_lifecycle->>'lifecycle_status',
        'effective', coalesce(
          (v_lifecycle->>'effective')::boolean,
          false
        )
      ));

    v_previous_id := v_certificate.id;
    v_previous_root := v_certificate.evidence_root_sha256;
    v_expected_version := v_expected_version + 1;
  end loop;

  if v_certificate_count > 0 then
    v_chain_complete :=
      v_chain_complete
      and v_initial_count = 1
      and v_max_version = v_certificate_count;
  else
    v_all_historically_verified := true;
    v_chain_complete := true;
  end if;

  v_chain_complete :=
    v_chain_complete
    and v_effective_count <= 1
    and v_effective_certificate_is_latest;

  v_history_root_sha256 := public.atlas_normalization_sha256(
    v_history_projection::text
  );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_certificate_count = 0
        then 'INSTALLATION_CERTIFICATE_HISTORY_EMPTY'
      when v_chain_complete and v_all_historically_verified
        then 'INSTALLATION_CERTIFICATE_HISTORY_INTEGRITY_VERIFIED'
      else 'INSTALLATION_CERTIFICATE_HISTORY_INTEGRITY_FAILED'
    end,
    'integrity_contract_version',
      'B2_INSTALLATION_CERTIFICATE_HISTORY_INTEGRITY_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'certificate_count', v_certificate_count,
    'historically_verified_count',
      v_historically_verified_count,
    'effective_certificate_count', v_effective_count,
    'chain_complete', v_chain_complete,
    'all_historically_verified',
      v_all_historically_verified,
    'effective_certificate_is_latest',
      v_effective_certificate_is_latest,
    'history_root_sha256', v_history_root_sha256,
    'certificates', v_history_projection,
    'empty_history_valid', v_certificate_count = 0,
    'current_g04_binding_changes_historical_integrity', false,
    'credential_values_exposed', false,
    'raw_payloads_exposed', false,
    'evidence_references_exposed', false,
    'actor_identities_exposed', false
  );
end;
$$;

revoke all on function
public.atlas_get_installation_certificate_safe_projection(uuid)
from public, anon;
revoke all on function
public.atlas_list_installation_certificate_history(uuid)
from public, anon;
revoke all on function
public.atlas_verify_installation_certificate_history_integrity(uuid)
from public, anon;

grant execute on function
public.atlas_get_installation_certificate_safe_projection(uuid)
to authenticated, service_role;
grant execute on function
public.atlas_list_installation_certificate_history(uuid)
to authenticated, service_role;
grant execute on function
public.atlas_verify_installation_certificate_history_integrity(uuid)
to authenticated, service_role;

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2K4C_HISTORICAL_INTEGRITY_CERTIFICATE_LAYER_CLOSED',
  'next_block', 'B2.2L.1_ACTIVATION_AND_INSTALLATION_CLOSURE_CORE',
  'historical_integrity_helpers', 1,
  'history_integrity_rpcs', 1,
  'safe_projection_rpcs', 2,
  'lifecycle_contract_version',
    'B2_INSTALLATION_CERTIFICATE_LIFECYCLE_V2',
  'historical_integrity_contract_version',
    'B2_INSTALLATION_CERTIFICATE_HISTORICAL_INTEGRITY_V1',
  'historical_integrity_independent_from_current_g04', true,
  'superseded_predecessor_integrity_preserved', true,
  'single_effective_certificate_enforced', true,
  'effective_certificate_must_be_latest', true,
  'certificate_layer_closed', true,
  'certificate_issuance_enabled', true,
  'controlled_regeneration_enabled', true,
  'document_generation_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'current_installation_state', installation.current_state_code,
  'current_installation_version', installation.version,
  'certificate_records', (
    select count(*) from public.atlas_installation_certificates
  )
) as result
from public.atlas_installations as installation
order by installation.created_at asc, installation.id asc
limit 1;
