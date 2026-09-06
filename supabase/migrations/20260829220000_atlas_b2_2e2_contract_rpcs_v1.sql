-- ATLAS B2.2E.2
-- Registro, revision profesional y firma verificable de contratos.
-- Corte: 2026-08-29
--
-- Prerrequisito: B2.2E.1 instalado y certificado.
--
-- Invariantes:
-- - cada documento conserva identidad, version, hash y expediente;
-- - un archivo citado debe existir en Storage y estar ACCEPTED;
-- - la revision profesional es secuencial y exclusiva de Legal Reviewer;
-- - la firma exige OWNER activo, archivo firmado y evidencia verificable;
-- - versiones firmadas solo se sustituyen con referencia de cambio;
-- - toda operacion es idempotente, versionada y auditada.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_contracts') is null
     or to_regclass('public.atlas_installation_contract_events') is null
     or to_regclass('public.atlas_legal_document_definitions') is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception 'B2.2E.2 requiere B2.2E.1 instalado y certificado';
  end if;
end;
$$;

alter table public.atlas_installation_contracts
  add column if not exists state_version integer not null default 1,
  add column if not exists signed_source_file_id uuid,
  add column if not exists signed_content_sha256 text;

alter table public.atlas_installation_contract_events
  add column if not exists contract_state_version integer not null default 1;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.atlas_installation_contracts'::regclass
      and conname = 'atlas_contracts_signed_source_file_fkey'
  ) then
    alter table public.atlas_installation_contracts
      add constraint atlas_contracts_signed_source_file_fkey
      foreign key (signed_source_file_id)
      references public.atlas_installation_files(id)
      on delete restrict;
  end if;
end;
$$;

alter table public.atlas_installation_contracts
  drop constraint if exists atlas_installation_contracts_signed_check;

alter table public.atlas_installation_contracts
  add constraint atlas_installation_contracts_signed_check
  check (
    (
      lifecycle_status = 'SIGNED'
      and professional_review_status = 'APPROVED'
      and source_file_id is not null
      and signed_source_file_id is not null
      and signed_content_sha256 ~ '^[0-9a-f]{64}$'
      and signed_by_user_id is not null
      and signed_at is not null
      and nullif(btrim(signature_method), '') is not null
      and signature_evidence <> '{}'::jsonb
    )
    or (
      lifecycle_status = 'SUPERSEDED'
      and (
        (
          signed_source_file_id is null
          and signed_content_sha256 is null
          and signed_by_user_id is null
          and signed_at is null
          and signature_method is null
          and signature_evidence = '{}'::jsonb
        )
        or (
          professional_review_status = 'APPROVED'
          and source_file_id is not null
          and signed_source_file_id is not null
          and signed_content_sha256 ~ '^[0-9a-f]{64}$'
          and signed_by_user_id is not null
          and signed_at is not null
          and nullif(btrim(signature_method), '') is not null
          and signature_evidence <> '{}'::jsonb
        )
      )
    )
    or (
      lifecycle_status not in ('SIGNED', 'SUPERSEDED')
      and signed_source_file_id is null
      and signed_content_sha256 is null
      and signed_by_user_id is null
      and signed_at is null
      and signature_method is null
      and signature_evidence = '{}'::jsonb
    )
  );

alter table public.atlas_installation_contracts
  drop constraint if exists atlas_installation_contracts_state_version_check;
alter table public.atlas_installation_contracts
  add constraint atlas_installation_contracts_state_version_check
  check (state_version >= 1);

alter table public.atlas_installation_contract_events
  drop constraint if exists atlas_contract_events_state_version_check;
alter table public.atlas_installation_contract_events
  add constraint atlas_contract_events_state_version_check
  check (contract_state_version >= 1);

create index if not exists idx_atlas_contracts_signed_source
  on public.atlas_installation_contracts (
    installation_id,
    signed_source_file_id,
    signed_content_sha256
  )
  where signed_source_file_id is not null;

create or replace function public.atlas_register_installation_contract(
  p_installation_id uuid,
  p_document_code text,
  p_document_version integer,
  p_applicability_status text,
  p_source_file_id uuid,
  p_document_payload jsonb,
  p_content_sha256 text,
  p_effective_from timestamptz,
  p_effective_until timestamptz,
  p_request_id uuid,
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
  v_document_code text := upper(nullif(btrim(p_document_code), ''));
  v_applicability text := upper(nullif(btrim(p_applicability_status), ''));
  v_sha256 text := lower(nullif(btrim(p_content_sha256), ''));
  v_installation public.atlas_installations%rowtype;
  v_definition public.atlas_legal_document_definitions%rowtype;
  v_source_file public.atlas_installation_files%rowtype;
  v_existing public.atlas_installation_contracts%rowtype;
  v_previous public.atlas_installation_contracts%rowtype;
  v_created public.atlas_installation_contracts%rowtype;
  v_latest_version integer := 0;
  v_initial_lifecycle text;
  v_previous_lifecycle text;
  v_previous_review text;
  v_sha256_computed_at timestamptz;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_LEGAL_MANAGE') then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_LEGAL_MANAGE_FORBIDDEN';
  end if;

  if p_installation_id is null
     or v_document_code is null
     or p_document_version is null
     or p_document_version < 1
     or v_applicability is null
     or p_document_payload is null
     or jsonb_typeof(p_document_payload) <> 'object'
     or p_document_payload = '{}'::jsonb
     or v_sha256 is null
     or v_sha256 !~ '^[0-9a-f]{64}$'
     or p_request_id is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or nullif(btrim(p_metadata->>'sha256_computed_by'), '') is null
     or nullif(btrim(p_metadata->>'sha256_computed_at'), '') is null then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_REGISTRATION_REQUIRED_FIELDS_MISSING';
  end if;

  begin
    v_sha256_computed_at :=
      (p_metadata->>'sha256_computed_at')::timestamptz;
  exception
    when others then
      raise exception using
        errcode = '22023',
        message = 'CONTRACT_SHA256_COMPUTED_AT_INVALID';
  end;

  if v_sha256_computed_at > now() + interval '5 minutes' then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_SHA256_COMPUTED_AT_IN_FUTURE';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_document_payload)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_REGISTRATION_CONTAINS_SECRET';
  end if;

  if p_document_payload->>'document_code' <> v_document_code
     or p_document_payload->>'document_version' <>
       p_document_version::text then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_PAYLOAD_IDENTITY_MISMATCH';
  end if;

  if p_effective_until is not null
     and p_effective_from is not null
     and p_effective_until <= p_effective_from then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_VALIDITY_RANGE_INVALID';
  end if;

  select i.*
  into v_installation
  from public.atlas_installations as i
  where i.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_NOT_FOUND';
  end if;

  select contract.*
  into v_existing
  from public.atlas_installation_contracts as contract
  where contract.installation_id = v_installation.id
    and contract.idempotency_key = p_request_id
  limit 1;

  if found then
    if v_existing.document_code <> v_document_code
       or v_existing.document_version <> p_document_version
       or v_existing.applicability_status <> v_applicability
       or v_existing.source_file_id is distinct from p_source_file_id
       or v_existing.document_payload <> p_document_payload
       or v_existing.content_sha256 <> v_sha256
       or v_existing.effective_from is distinct from p_effective_from
       or v_existing.effective_until is distinct from p_effective_until
       or v_existing.metadata <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'CONTRACT_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'contract_id', v_existing.id,
      'document_code', v_existing.document_code,
      'document_version', v_existing.document_version,
      'state_version', v_existing.state_version,
      'applicability_status', v_existing.applicability_status,
      'lifecycle_status', v_existing.lifecycle_status,
      'professional_review_status', v_existing.professional_review_status
    );
  end if;

  if v_installation.current_state_code not in (
    'SECURITY_VALIDATION',
    'LEGAL_REVIEW'
  ) then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_READY_FOR_CONTRACT_REGISTRATION';
  end if;

  select definition.*
  into v_definition
  from public.atlas_legal_document_definitions as definition
  where definition.document_code = v_document_code
    and definition.active = true;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'LEGAL_DOCUMENT_DEFINITION_NOT_FOUND';
  end if;

  if (
    v_definition.default_applicability = 'REQUIRED'
    and v_applicability <> 'REQUIRED'
  ) or (
    v_definition.default_applicability = 'CONDITIONAL'
    and v_applicability not in ('REQUIRED', 'NOT_APPLICABLE')
  ) or (
    v_definition.default_applicability = 'POST_ACTIVATION'
    and v_applicability not in ('POST_ACTIVATION', 'NOT_APPLICABLE')
  ) then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_APPLICABILITY_CONFLICT';
  end if;

  if p_source_file_id is not null then
    select file_record.*
    into v_source_file
    from public.atlas_installation_files as file_record
    where file_record.id = p_source_file_id
      and file_record.installation_id = v_installation.id
      and file_record.empresa_id = v_installation.empresa_id;

    if not found then
      raise exception using
        errcode = 'P0002',
        message = 'CONTRACT_SOURCE_FILE_NOT_FOUND';
    end if;

    if v_source_file.logical_section <> 'LEGAL'
       or v_source_file.validation_status <> 'ACCEPTED'
       or v_source_file.sha256 <> v_sha256 then
      raise exception using
        errcode = '22023',
        message = 'CONTRACT_SOURCE_FILE_INVALID';
    end if;

    if not exists (
      select 1
      from storage.objects as object_record
      where object_record.bucket_id = v_source_file.storage_bucket
        and object_record.name = v_source_file.storage_object_path
        and object_record.archived_at is null
        and object_record.is_delete_marker = false
    ) then
      raise exception using
        errcode = 'P0002',
        message = 'CONTRACT_SOURCE_STORAGE_OBJECT_NOT_FOUND';
    end if;

    if exists (
      select 1
      from public.atlas_installation_files as newer
      where newer.installation_id = v_source_file.installation_id
        and newer.logical_section = v_source_file.logical_section
        and newer.canonical_file_name = v_source_file.canonical_file_name
        and (
          newer.file_version > v_source_file.file_version
          or (
            newer.file_version = v_source_file.file_version
            and newer.created_at > v_source_file.created_at
          )
        )
    ) then
      raise exception using
        errcode = '22023',
        message = 'CONTRACT_SOURCE_FILE_NOT_CURRENT_VERSION';
    end if;
  end if;

  if v_applicability <> 'NOT_APPLICABLE'
     and p_source_file_id is null then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_SOURCE_FILE_REQUIRED';
  end if;

  select contract.*
  into v_previous
  from public.atlas_installation_contracts as contract
  where contract.installation_id = v_installation.id
    and contract.document_code = v_document_code
  order by contract.document_version desc, contract.created_at desc
  limit 1
  for update;

  if found then
    v_latest_version := v_previous.document_version;

    if v_previous.lifecycle_status = 'SIGNED'
       and nullif(
         btrim(p_metadata->>'change_authorization_reference'),
         ''
       ) is null then
      raise exception using
        errcode = '42501',
        message = 'SIGNED_CONTRACT_CHANGE_AUTHORIZATION_REQUIRED';
    end if;
  end if;

  if p_document_version <> v_latest_version + 1 then
    raise exception using
      errcode = '40001',
      message = 'CONTRACT_DOCUMENT_VERSION_CONFLICT';
  end if;

  select pm.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as pm
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = pm.role_code
   and role_definition.active = true
  where pm.user_id = v_actor_user_id
    and pm.status = 'ACTIVE'
  order by role_definition.priority asc, pm.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PLATFORM_ACTOR_ROLE_NOT_FOUND';
  end if;

  if v_previous.id is not null then
    v_previous_lifecycle := v_previous.lifecycle_status;
    v_previous_review := v_previous.professional_review_status;

    update public.atlas_installation_contracts
    set
      lifecycle_status = 'SUPERSEDED',
      state_version = state_version + 1
    where id = v_previous.id
    returning * into v_previous;

    insert into public.atlas_installation_contract_events (
      installation_id,
      empresa_id,
      contract_id,
      document_code,
      event_code,
      from_lifecycle_status,
      to_lifecycle_status,
      from_review_status,
      to_review_status,
      actor_user_id,
      actor_role_code,
      reason,
      request_id,
      document_version,
      content_sha256,
      evidence,
      metadata,
      contract_state_version
    )
    values (
      v_previous.installation_id,
      v_previous.empresa_id,
      v_previous.id,
      v_previous.document_code,
      'CONTRACT_VERSION_SUPERSEDED',
      v_previous_lifecycle,
      'SUPERSEDED',
      v_previous_review,
      v_previous.professional_review_status,
      v_actor_user_id,
      v_actor_role_code,
      'Nueva version contractual registrada.',
      p_request_id,
      v_previous.document_version,
      v_previous.content_sha256,
      jsonb_build_object(
        'superseded_by_document_version', p_document_version
      ),
      '{}'::jsonb,
      v_previous.state_version
    );
  end if;

  v_initial_lifecycle := case
    when v_applicability = 'NOT_APPLICABLE' then 'PENDING'
    else 'DRAFT'
  end;

  insert into public.atlas_installation_contracts (
    installation_id,
    empresa_id,
    document_code,
    document_version,
    applicability_status,
    lifecycle_status,
    professional_review_status,
    source_file_id,
    document_payload,
    content_sha256,
    effective_from,
    effective_until,
    supersedes_contract_id,
    created_by_user_id,
    idempotency_key,
    metadata,
    state_version
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_document_code,
    p_document_version,
    v_applicability,
    v_initial_lifecycle,
    'PENDING',
    p_source_file_id,
    p_document_payload,
    v_sha256,
    p_effective_from,
    p_effective_until,
    v_previous.id,
    v_actor_user_id,
    p_request_id,
    p_metadata,
    1
  )
  returning * into v_created;

  insert into public.atlas_installation_contract_events (
    installation_id,
    empresa_id,
    contract_id,
    document_code,
    event_code,
    from_lifecycle_status,
    to_lifecycle_status,
    from_review_status,
    to_review_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    document_version,
    content_sha256,
    evidence,
    metadata,
    contract_state_version
  )
  values (
    v_created.installation_id,
    v_created.empresa_id,
    v_created.id,
    v_created.document_code,
    'CONTRACT_VERSION_REGISTERED',
    null,
    v_created.lifecycle_status,
    null,
    v_created.professional_review_status,
    v_actor_user_id,
    v_actor_role_code,
    'Version contractual registrada en el expediente.',
    p_request_id,
    v_created.document_version,
    v_created.content_sha256,
    jsonb_build_object(
      'source_file_id', v_created.source_file_id,
      'applicability_status', v_created.applicability_status,
      'professional_review_required',
        v_definition.professional_review_required
    ),
    '{}'::jsonb,
    v_created.state_version
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_created.empresa_id, v_actor_user_id, null, null,
    'INSTALLATION_CONTRACT_REGISTERED',
    'B2_LEGAL_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'document_code', v_document_code,
      'document_version', p_document_version,
      'content_sha256', v_sha256
    ),
    jsonb_build_object(
      'contract_id', v_created.id,
      'lifecycle_status', v_created.lifecycle_status,
      'professional_review_status', v_created.professional_review_status
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CONTRACT_REGISTERED',
    'installation_id', v_created.installation_id,
    'contract_id', v_created.id,
    'document_code', v_created.document_code,
    'document_version', v_created.document_version,
    'state_version', v_created.state_version,
    'applicability_status', v_created.applicability_status,
    'lifecycle_status', v_created.lifecycle_status,
    'professional_review_status', v_created.professional_review_status,
    'content_sha256', v_created.content_sha256
  );
end;
$$;

revoke all on function public.atlas_register_installation_contract(
  uuid, text, integer, text, uuid, jsonb, text,
  timestamptz, timestamptz, uuid, jsonb
) from public, anon;
grant execute on function public.atlas_register_installation_contract(
  uuid, text, integer, text, uuid, jsonb, text,
  timestamptz, timestamptz, uuid, jsonb
) to authenticated, service_role;

create or replace function public.atlas_review_installation_contract(
  p_contract_id uuid,
  p_review_decision text,
  p_reason text,
  p_evidence jsonb,
  p_request_id uuid,
  p_expected_state_version integer,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_decision text := upper(nullif(btrim(p_review_decision), ''));
  v_reason text := nullif(btrim(p_reason), '');
  v_contract public.atlas_installation_contracts%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_source_file public.atlas_installation_files%rowtype;
  v_existing_event public.atlas_installation_contract_events%rowtype;
  v_actor_role_code text := 'ATLAS_LEGAL_REVIEWER';
  v_event_code text;
  v_to_lifecycle text;
  v_from_lifecycle text;
  v_from_review text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.atlas_platform_memberships as membership
    join public.atlas_internal_roles as role_definition
      on role_definition.role_code = membership.role_code
     and role_definition.active = true
    where membership.user_id = v_actor_user_id
      and membership.role_code = 'ATLAS_LEGAL_REVIEWER'
      and membership.status = 'ACTIVE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'ACTIVE_LEGAL_REVIEWER_REQUIRED';
  end if;

  if p_contract_id is null
     or v_decision not in ('IN_REVIEW', 'APPROVED', 'REQUIRES_CHANGES')
     or v_reason is null
     or length(v_reason) < 10
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb
     or nullif(btrim(p_evidence->>'professional_reference'), '') is null
     or nullif(btrim(p_evidence->>'review_scope'), '') is null
     or p_request_id is null
     or p_expected_state_version is null
     or p_expected_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_REVIEW_REQUIRED_FIELDS_MISSING';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_REVIEW_CONTAINS_SECRET';
  end if;

  select contract.*
  into v_contract
  from public.atlas_installation_contracts as contract
  where contract.id = p_contract_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_CONTRACT_NOT_FOUND';
  end if;

  v_event_code := case v_decision
    when 'IN_REVIEW' then 'CONTRACT_REVIEW_STARTED'
    when 'APPROVED' then 'CONTRACT_PROFESSIONALLY_APPROVED'
    else 'CONTRACT_CHANGES_REQUIRED'
  end;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_contract_events as event_record
  where event_record.contract_id = v_contract.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <> v_event_code
       or v_existing_event.reason <> v_reason
       or v_existing_event.evidence <> p_evidence
       or v_existing_event.metadata <> p_metadata
       or v_existing_event.contract_state_version <>
         p_expected_state_version + 1 then
      raise exception using
        errcode = '22023',
        message = 'CONTRACT_REVIEW_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'contract_id', v_existing_event.contract_id,
      'document_code', v_existing_event.document_code,
      'review_status', v_existing_event.to_review_status,
      'lifecycle_status', v_existing_event.to_lifecycle_status,
      'state_version', v_existing_event.contract_state_version
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_contract.installation_id;

  if v_installation.current_state_code <> 'LEGAL_REVIEW' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_LEGAL_REVIEW';
  end if;

  if v_contract.applicability_status = 'NOT_APPLICABLE'
     or v_contract.lifecycle_status in ('SIGNED', 'SUPERSEDED') then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_NOT_REVIEWABLE';
  end if;

  if exists (
    select 1
    from public.atlas_installation_contracts as newer
    where newer.installation_id = v_contract.installation_id
      and newer.document_code = v_contract.document_code
      and newer.document_version > v_contract.document_version
  ) then
    raise exception using
      errcode = '40001',
      message = 'CONTRACT_NOT_LATEST_VERSION';
  end if;

  if v_contract.state_version <> p_expected_state_version then
    raise exception using
      errcode = '40001',
      message = 'CONTRACT_STATE_VERSION_CONFLICT';
  end if;

  if v_decision = 'IN_REVIEW' then
    if v_contract.lifecycle_status not in ('DRAFT', 'REJECTED')
       or v_contract.professional_review_status not in (
         'PENDING', 'REQUIRES_CHANGES'
       ) then
      raise exception using
        errcode = '22023',
        message = 'CONTRACT_REVIEW_START_TRANSITION_INVALID';
    end if;
    v_to_lifecycle := 'UNDER_REVIEW';
  else
    if v_contract.lifecycle_status <> 'UNDER_REVIEW'
       or v_contract.professional_review_status <> 'IN_REVIEW' then
      raise exception using
        errcode = '22023',
        message = 'CONTRACT_REVIEW_DECISION_TRANSITION_INVALID';
    end if;

    if v_decision = 'APPROVED' then
      if v_contract.source_file_id is null then
        raise exception using
          errcode = '42501',
          message = 'CONTRACT_APPROVAL_SOURCE_FILE_REQUIRED';
      end if;

      select file_record.*
      into v_source_file
      from public.atlas_installation_files as file_record
      where file_record.id = v_contract.source_file_id
        and file_record.installation_id = v_contract.installation_id
        and file_record.empresa_id = v_contract.empresa_id;

      if not found
         or v_source_file.logical_section <> 'LEGAL'
         or v_source_file.validation_status <> 'ACCEPTED'
         or v_source_file.sha256 <> v_contract.content_sha256 then
        raise exception using
          errcode = '42501',
          message = 'CONTRACT_APPROVAL_SOURCE_FILE_INVALID';
      end if;

      if not exists (
        select 1
        from storage.objects as object_record
        where object_record.bucket_id = v_source_file.storage_bucket
          and object_record.name = v_source_file.storage_object_path
          and object_record.archived_at is null
          and object_record.is_delete_marker = false
      ) then
        raise exception using
          errcode = 'P0002',
          message = 'CONTRACT_APPROVAL_STORAGE_OBJECT_NOT_FOUND';
      end if;

      if exists (
        select 1
        from public.atlas_installation_files as newer
        where newer.installation_id = v_source_file.installation_id
          and newer.logical_section = v_source_file.logical_section
          and newer.canonical_file_name = v_source_file.canonical_file_name
          and (
            newer.file_version > v_source_file.file_version
            or (
              newer.file_version = v_source_file.file_version
              and newer.created_at > v_source_file.created_at
            )
          )
      ) then
        raise exception using
          errcode = '22023',
          message = 'CONTRACT_APPROVAL_SOURCE_FILE_NOT_CURRENT';
      end if;

      v_to_lifecycle := 'READY_FOR_SIGNATURE';
    else
      v_to_lifecycle := 'REJECTED';
    end if;
  end if;

  v_from_lifecycle := v_contract.lifecycle_status;
  v_from_review := v_contract.professional_review_status;

  update public.atlas_installation_contracts
  set
    lifecycle_status = v_to_lifecycle,
    professional_review_status = v_decision,
    reviewed_by_user_id = v_actor_user_id,
    reviewed_at = now(),
    state_version = state_version + 1,
    metadata = metadata || p_metadata || jsonb_build_object(
      'latest_review_request_id', p_request_id
    )
  where id = v_contract.id
  returning * into v_contract;

  insert into public.atlas_installation_contract_events (
    installation_id, empresa_id, contract_id, document_code,
    event_code, from_lifecycle_status, to_lifecycle_status,
    from_review_status, to_review_status,
    actor_user_id, actor_role_code, reason, request_id,
    document_version, content_sha256, evidence, metadata,
    contract_state_version
  )
  values (
    v_contract.installation_id, v_contract.empresa_id,
    v_contract.id, v_contract.document_code,
    v_event_code,
    v_from_lifecycle,
    v_contract.lifecycle_status,
    v_from_review,
    v_contract.professional_review_status,
    v_actor_user_id, v_actor_role_code, v_reason, p_request_id,
    v_contract.document_version, v_contract.content_sha256,
    p_evidence, p_metadata, v_contract.state_version
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_contract.empresa_id, v_actor_user_id, null, null,
    'INSTALLATION_CONTRACT_REVIEWED',
    'B2_LEGAL_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'contract_id', v_contract.id,
      'review_decision', v_decision
    ),
    jsonb_build_object(
      'lifecycle_status', v_contract.lifecycle_status,
      'professional_review_status',
        v_contract.professional_review_status,
      'state_version', v_contract.state_version
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_decision = 'IN_REVIEW' then 'CONTRACT_REVIEW_STARTED'
      when v_decision = 'APPROVED' then 'CONTRACT_PROFESSIONALLY_APPROVED'
      else 'CONTRACT_CHANGES_REQUIRED'
    end,
    'contract_id', v_contract.id,
    'document_code', v_contract.document_code,
    'document_version', v_contract.document_version,
    'state_version', v_contract.state_version,
    'lifecycle_status', v_contract.lifecycle_status,
    'professional_review_status', v_contract.professional_review_status
  );
end;
$$;

revoke all on function public.atlas_review_installation_contract(
  uuid, text, text, jsonb, uuid, integer, jsonb
) from public, anon;
grant execute on function public.atlas_review_installation_contract(
  uuid, text, text, jsonb, uuid, integer, jsonb
) to authenticated, service_role;

create or replace function public.atlas_sign_installation_contract(
  p_contract_id uuid,
  p_signer_user_id uuid,
  p_signed_source_file_id uuid,
  p_signed_content_sha256 text,
  p_signature_method text,
  p_signed_at timestamptz,
  p_reason text,
  p_signature_evidence jsonb,
  p_request_id uuid,
  p_expected_state_version integer,
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
  v_method text := upper(nullif(btrim(p_signature_method), ''));
  v_reason text := nullif(btrim(p_reason), '');
  v_signed_sha256 text := lower(
    nullif(btrim(p_signed_content_sha256), '')
  );
  v_contract public.atlas_installation_contracts%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_signed_file public.atlas_installation_files%rowtype;
  v_existing_event public.atlas_installation_contract_events%rowtype;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_LEGAL_MANAGE') then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_LEGAL_MANAGE_FORBIDDEN';
  end if;

  if p_contract_id is null
     or p_signer_user_id is null
     or p_signed_source_file_id is null
     or v_signed_sha256 is null
     or v_signed_sha256 !~ '^[0-9a-f]{64}$'
     or v_method not in (
       'ELECTRONIC_ACCEPTANCE',
       'DIGITAL_SIGNATURE',
       'WET_SIGNATURE_VERIFIED',
       'PROVIDER_SIGNATURE'
     )
     or p_signed_at is null
     or p_signed_at > now() + interval '5 minutes'
     or v_reason is null
     or length(v_reason) < 10
     or p_signature_evidence is null
     or jsonb_typeof(p_signature_evidence) <> 'object'
     or p_signature_evidence = '{}'::jsonb
     or nullif(
       btrim(p_signature_evidence->>'acceptance_reference'),
       ''
     ) is null
     or nullif(
       btrim(p_signature_evidence->>'consent_text_version'),
       ''
     ) is null
     or p_request_id is null
     or p_expected_state_version is null
     or p_expected_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_SIGNATURE_REQUIRED_FIELDS_MISSING';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_signature_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_SIGNATURE_CONTAINS_SECRET';
  end if;

  if p_signature_evidence ?| array[
    'signer_user_id',
    'signed_source_file_id',
    'signed_content_sha256',
    'signature_method',
    'signed_at'
  ] then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_SIGNATURE_EVIDENCE_RESERVED_KEY';
  end if;

  select contract.*
  into v_contract
  from public.atlas_installation_contracts as contract
  where contract.id = p_contract_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_CONTRACT_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_installation_contract_events as event_record
  where event_record.contract_id = v_contract.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <> 'CONTRACT_SIGNED'
       or v_existing_event.reason <> v_reason
       or (
         v_existing_event.evidence
           - 'signer_user_id'
           - 'signed_source_file_id'
           - 'signed_content_sha256'
           - 'signature_method'
           - 'signed_at'
       ) <> p_signature_evidence
       or v_existing_event.metadata <> p_metadata
       or v_existing_event.contract_state_version <>
         p_expected_state_version + 1
       or v_contract.signed_by_user_id is distinct from p_signer_user_id
       or v_contract.signed_source_file_id is distinct from
         p_signed_source_file_id
       or v_contract.signed_content_sha256 is distinct from
         v_signed_sha256
       or v_contract.signature_method is distinct from v_method
       or v_contract.signed_at is distinct from p_signed_at then
      raise exception using
        errcode = '22023',
        message = 'CONTRACT_SIGNATURE_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'contract_id', v_existing_event.contract_id,
      'document_code', v_existing_event.document_code,
      'lifecycle_status', v_existing_event.to_lifecycle_status,
      'state_version', v_existing_event.contract_state_version
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_contract.installation_id;

  if v_installation.current_state_code <> 'LEGAL_REVIEW' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_LEGAL_REVIEW';
  end if;

  if v_contract.lifecycle_status <> 'READY_FOR_SIGNATURE'
     or v_contract.professional_review_status <> 'APPROVED' then
    raise exception using
      errcode = '42501',
      message = 'CONTRACT_NOT_READY_FOR_SIGNATURE';
  end if;

  if p_signed_at < v_contract.created_at then
    raise exception using
      errcode = '22023',
      message = 'CONTRACT_SIGNATURE_PRECEDES_DOCUMENT';
  end if;

  if v_contract.state_version <> p_expected_state_version then
    raise exception using
      errcode = '40001',
      message = 'CONTRACT_STATE_VERSION_CONFLICT';
  end if;

  if exists (
    select 1
    from public.atlas_installation_contracts as newer
    where newer.installation_id = v_contract.installation_id
      and newer.document_code = v_contract.document_code
      and newer.document_version > v_contract.document_version
  ) then
    raise exception using
      errcode = '40001',
      message = 'CONTRACT_NOT_LATEST_VERSION';
  end if;

  if not exists (
    select 1
    from public.atlas_internal_memberships as membership
    where membership.empresa_id = v_contract.empresa_id
      and membership.user_id = p_signer_user_id
      and membership.role_code = 'OWNER'
      and membership.status = 'ACTIVE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'ACTIVE_EMPRESA_OWNER_SIGNER_REQUIRED';
  end if;

  select file_record.*
  into v_signed_file
  from public.atlas_installation_files as file_record
  where file_record.id = p_signed_source_file_id
    and file_record.installation_id = v_contract.installation_id
    and file_record.empresa_id = v_contract.empresa_id;

  if not found
     or v_signed_file.logical_section <> 'LEGAL'
     or v_signed_file.validation_status <> 'ACCEPTED'
     or v_signed_file.sha256 <> v_signed_sha256 then
    raise exception using
      errcode = '22023',
      message = 'SIGNED_CONTRACT_SOURCE_FILE_INVALID';
  end if;

  if not exists (
    select 1
    from storage.objects as object_record
    where object_record.bucket_id = v_signed_file.storage_bucket
      and object_record.name = v_signed_file.storage_object_path
      and object_record.archived_at is null
      and object_record.is_delete_marker = false
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'SIGNED_CONTRACT_STORAGE_OBJECT_NOT_FOUND';
  end if;

  if exists (
    select 1
    from public.atlas_installation_files as newer
    where newer.installation_id = v_signed_file.installation_id
      and newer.logical_section = v_signed_file.logical_section
      and newer.canonical_file_name = v_signed_file.canonical_file_name
      and (
        newer.file_version > v_signed_file.file_version
        or (
          newer.file_version = v_signed_file.file_version
          and newer.created_at > v_signed_file.created_at
        )
      )
  ) then
    raise exception using
      errcode = '22023',
      message = 'SIGNED_CONTRACT_SOURCE_FILE_NOT_CURRENT';
  end if;

  select pm.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as pm
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = pm.role_code
   and role_definition.active = true
  where pm.user_id = v_actor_user_id
    and pm.status = 'ACTIVE'
  order by role_definition.priority asc, pm.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PLATFORM_ACTOR_ROLE_NOT_FOUND';
  end if;

  update public.atlas_installation_contracts
  set
    lifecycle_status = 'SIGNED',
    signed_source_file_id = v_signed_file.id,
    signed_content_sha256 = v_signed_sha256,
    signed_by_user_id = p_signer_user_id,
    signed_at = p_signed_at,
    signature_method = v_method,
    signature_evidence = p_signature_evidence,
    state_version = state_version + 1,
    metadata = metadata || p_metadata || jsonb_build_object(
      'signature_registered_by_user_id', v_actor_user_id,
      'signature_request_id', p_request_id
    )
  where id = v_contract.id
  returning * into v_contract;

  insert into public.atlas_installation_contract_events (
    installation_id, empresa_id, contract_id, document_code,
    event_code, from_lifecycle_status, to_lifecycle_status,
    from_review_status, to_review_status,
    actor_user_id, actor_role_code, reason, request_id,
    document_version, content_sha256, evidence, metadata,
    contract_state_version
  )
  values (
    v_contract.installation_id, v_contract.empresa_id,
    v_contract.id, v_contract.document_code,
    'CONTRACT_SIGNED',
    'READY_FOR_SIGNATURE', 'SIGNED',
    'APPROVED', 'APPROVED',
    v_actor_user_id, v_actor_role_code, v_reason, p_request_id,
    v_contract.document_version, v_contract.content_sha256,
    p_signature_evidence || jsonb_build_object(
      'signer_user_id', p_signer_user_id,
      'signed_source_file_id', v_signed_file.id,
      'signed_content_sha256', v_signed_sha256,
      'signature_method', v_method,
      'signed_at', p_signed_at
    ),
    p_metadata,
    v_contract.state_version
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_contract.empresa_id, v_actor_user_id, null, null,
    'INSTALLATION_CONTRACT_SIGNED',
    'B2_LEGAL_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'contract_id', v_contract.id,
      'signer_user_id', p_signer_user_id,
      'signature_method', v_method
    ),
    jsonb_build_object(
      'lifecycle_status', v_contract.lifecycle_status,
      'state_version', v_contract.state_version,
      'signed_content_sha256', v_contract.signed_content_sha256
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_CONTRACT_SIGNED',
    'contract_id', v_contract.id,
    'document_code', v_contract.document_code,
    'document_version', v_contract.document_version,
    'state_version', v_contract.state_version,
    'lifecycle_status', v_contract.lifecycle_status,
    'professional_review_status', v_contract.professional_review_status,
    'signer_user_id', v_contract.signed_by_user_id,
    'signed_at', v_contract.signed_at,
    'signed_content_sha256', v_contract.signed_content_sha256
  );
end;
$$;

revoke all on function public.atlas_sign_installation_contract(
  uuid, uuid, uuid, text, text, timestamptz,
  text, jsonb, uuid, integer, jsonb
) from public, anon;
grant execute on function public.atlas_sign_installation_contract(
  uuid, uuid, uuid, text, text, timestamptz,
  text, jsonb, uuid, integer, jsonb
) to authenticated, service_role;

comment on function public.atlas_register_installation_contract(
  uuid, text, integer, text, uuid, jsonb, text,
  timestamptz, timestamptz, uuid, jsonb
) is
  'B2: registra una version contractual con identidad, hash, archivo ACCEPTED e idempotencia.';

comment on function public.atlas_review_installation_contract(
  uuid, text, text, jsonb, uuid, integer, jsonb
) is
  'B2: registra revision profesional secuencial y exclusiva de Atlas Legal Reviewer.';

comment on function public.atlas_sign_installation_contract(
  uuid, uuid, uuid, text, text, timestamptz,
  text, jsonb, uuid, integer, jsonb
) is
  'B2: registra firma verificable por OWNER contra archivo firmado ACCEPTED.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2E2_CONTRACT_RPCS_INSTALLED',
  'next_action', 'CERTIFY_CONTRACT_RPC_GUARDS',
  'contract_rpcs', (
    select count(*)
    from pg_proc as procedure_definition
    join pg_namespace as namespace_definition
      on namespace_definition.oid = procedure_definition.pronamespace
    where namespace_definition.nspname = 'public'
      and procedure_definition.proname in (
        'atlas_register_installation_contract',
        'atlas_review_installation_contract',
        'atlas_sign_installation_contract'
      )
  ),
  'contract_records', (
    select count(*) from public.atlas_installation_contracts
  ),
  'contract_event_records', (
    select count(*) from public.atlas_installation_contract_events
  ),
  'professional_review_role', 'ATLAS_LEGAL_REVIEWER',
  'signer_role', 'OWNER',
  'signed_file_required', true,
  'optimistic_concurrency_enabled', true,
  'direct_authenticated_write', false,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  )
) as result;
