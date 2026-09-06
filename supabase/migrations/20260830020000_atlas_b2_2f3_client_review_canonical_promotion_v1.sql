-- ATLAS B2.2F.3
-- Revision humana del cliente, correccion y promocion canonica de datos.
-- Corte: 2026-08-30
--
-- Principios:
-- - la IA y el operador pueden proponer, pero no aprobar por el cliente;
-- - cada decision del cliente es append-only, versionada e idempotente;
-- - solo el client_owner_user_id con membresia OWNER activa puede decidir;
-- - una correccion vuelve por la maquina de estados y conserva trazabilidad;
-- - la version canonica se congela como JSONB inmutable con SHA-256 interno;
-- - G02 se calcula desde hechos y se revalida al aprobar y transicionar;
-- - esta migracion no crea lotes, decisiones ni versiones ficticias.

begin;

do $$
begin
  if to_regclass('public.atlas_normalization_batches') is null
     or to_regclass('public.atlas_normalized_records') is null
     or to_regclass('public.atlas_normalization_issues') is null
     or to_regclass('public.atlas_normalization_events') is null
     or to_regclass('public.atlas_installation_gates') is null
     or to_regclass('public.atlas_installation_approvals') is null
     or to_regclass('public.atlas_installation_inventory_definitions') is null
     or to_regclass('public.atlas_installation_inventory_requirements') is null
     or to_regclass('public.atlas_installation_files') is null
     or to_regclass('public.atlas_installation_manifests') is null
     or to_regclass('public.atlas_internal_memberships') is null
     or to_regprocedure(
       'public.atlas_platform_has_permission(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_internal_has_permission(uuid,text)'
     ) is null
     or to_regprocedure(
       'public.atlas_can_read_installation(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_analyze_normalization_batch(uuid,uuid,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_transition_installation(uuid,text,text,uuid,bigint)'
     ) is null then
    raise exception 'B2.2F.3 requiere B2.2A-F.2 instalado y certificado';
  end if;
end;
$$;

create or replace function public.atlas_return_normalization_for_correction(
  p_normalization_batch_id uuid,
  p_reason text,
  p_request_id uuid,
  p_expected_batch_state_version bigint,
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
  v_batch public.atlas_normalization_batches%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing_event public.atlas_normalization_events%rowtype;
  v_transition_result jsonb;
  v_correction_count bigint;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_NORMALIZATION_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_NORMALIZATION_MANAGE_FORBIDDEN';
  end if;

  if p_normalization_batch_id is null
     or length(coalesce(btrim(p_reason), '')) < 10
     or p_request_id is null
     or p_expected_batch_state_version is null
     or p_expected_installation_version is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_CORRECTION_REQUIRED_FIELDS_MISSING';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_CORRECTION_METADATA_CONTAINS_SECRET';
  end if;

  select batch.*
  into v_batch
  from public.atlas_normalization_batches as batch
  where batch.id = p_normalization_batch_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'NORMALIZATION_BATCH_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_normalization_events as event_record
  where event_record.normalization_batch_id = v_batch.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <> 'NORMALIZATION_RETURNED_FOR_CORRECTION'
       or v_existing_event.reason <> btrim(p_reason)
       or v_existing_event.metadata->'request_metadata' <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'NORMALIZATION_CORRECTION_IDEMPOTENCY_COLLISION';
    end if;

    select installation.*
    into v_installation
    from public.atlas_installations as installation
    where installation.id = v_batch.installation_id;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'normalization_batch_id', v_batch.id,
      'batch_status', v_batch.batch_status,
      'batch_state_version', v_batch.state_version,
      'installation_state', v_installation.current_state_code,
      'installation_version', v_installation.version
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_batch.installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_installation.current_state_code <> 'CLIENT_REVIEW'
     or v_batch.batch_status <> 'IN_CLIENT_REVIEW' then
    raise exception using
      errcode = '22023', message = 'NORMALIZATION_NOT_IN_CLIENT_REVIEW';
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001', message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_batch.state_version <> p_expected_batch_state_version then
    raise exception using
      errcode = '40001', message = 'NORMALIZATION_BATCH_VERSION_CONFLICT';
  end if;

  select count(*)
  into v_correction_count
  from public.atlas_normalized_records as normalized_record
  where normalized_record.normalization_batch_id = v_batch.id
    and normalized_record.normalization_status = 'CLIENT_REJECTED'
    and exists (
      select 1
      from public.atlas_normalization_review_decisions as decision_record
      where decision_record.normalized_record_id = normalized_record.id
        and decision_record.decision = 'CORRECTION_REQUIRED'
        and decision_record.decision_version = (
          select max(latest_decision.decision_version)
          from public.atlas_normalization_review_decisions as latest_decision
          where latest_decision.normalized_record_id = normalized_record.id
        )
    );

  if v_correction_count = 0 then
    raise exception using
      errcode = '22023', message = 'CLIENT_CORRECTION_DECISION_REQUIRED';
  end if;

  select platform_membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as platform_membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = platform_membership.role_code
   and role_definition.active = true
  where platform_membership.user_id = v_actor_user_id
    and platform_membership.status = 'ACTIVE'
  order by role_definition.priority, platform_membership.created_at
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501', message = 'PLATFORM_ACTOR_ROLE_NOT_FOUND';
  end if;

  update public.atlas_normalization_batches
  set
    batch_status = 'NORMALIZING',
    state_version = state_version + 1,
    completed_at = null,
    metadata = metadata || jsonb_build_object(
      'correction_return_request_id', p_request_id,
      'correction_returned_at', now()
    ),
    updated_at = now()
  where id = v_batch.id
  returning * into v_batch;

  v_transition_result := public.atlas_transition_installation(
    v_installation.id,
    'DATA_NORMALIZATION',
    btrim(p_reason),
    p_request_id,
    p_expected_installation_version
  );

  insert into public.atlas_normalization_events (
    installation_id, empresa_id, normalization_batch_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, reason, request_id,
    evidence, metadata
  )
  values (
    v_batch.installation_id, v_batch.empresa_id, v_batch.id,
    'BATCH', v_batch.id, 'NORMALIZATION_RETURNED_FOR_CORRECTION',
    'IN_CLIENT_REVIEW', 'NORMALIZING',
    v_actor_user_id, v_actor_role_code, btrim(p_reason), p_request_id,
    jsonb_build_object(
      'correction_record_count', v_correction_count,
      'transition_result', v_transition_result
    ),
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_batch.empresa_id, v_actor_user_id, null, null,
    'NORMALIZATION_RETURNED_FOR_CORRECTION',
    'B2_NORMALIZATION_REVIEW_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'normalization_batch_id', v_batch.id,
      'expected_batch_state_version', p_expected_batch_state_version,
      'expected_installation_version', p_expected_installation_version
    ),
    jsonb_build_object(
      'batch_status', v_batch.batch_status,
      'batch_state_version', v_batch.state_version,
      'installation_state', v_transition_result->>'state',
      'installation_version', v_transition_result->>'version'
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'NORMALIZATION_RETURNED_FOR_CORRECTION',
    'normalization_batch_id', v_batch.id,
    'batch_status', v_batch.batch_status,
    'batch_state_version', v_batch.state_version,
    'installation_state', v_transition_result->>'state',
    'installation_version', (v_transition_result->>'version')::bigint,
    'correction_record_count', v_correction_count
  );
end;
$$;

revoke all on function public.atlas_return_normalization_for_correction(
  uuid, text, uuid, bigint, bigint, jsonb
) from public, anon;
grant execute on function public.atlas_return_normalization_for_correction(
  uuid, text, uuid, bigint, bigint, jsonb
) to authenticated, service_role;

create or replace function public.atlas_decide_normalized_record(
  p_normalization_batch_id uuid,
  p_normalized_record_id uuid,
  p_decision text,
  p_reason text,
  p_evidence jsonb,
  p_request_id uuid,
  p_expected_batch_state_version bigint,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_decision text := upper(nullif(btrim(p_decision), ''));
  v_batch public.atlas_normalization_batches%rowtype;
  v_record public.atlas_normalized_records%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing record;
  v_decision_id uuid := gen_random_uuid();
  v_decision_version integer;
  v_new_record_status text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_normalization_batch_id is null
     or p_normalized_record_id is null
     or v_decision is null
     or p_request_id is null
     or p_expected_batch_state_version is null
     or p_expected_batch_state_version < 1
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZED_RECORD_DECISION_REQUIRED_FIELDS_MISSING';
  end if;

  if v_decision not in ('APPROVED', 'CORRECTION_REQUIRED') then
    raise exception using
      errcode = '22023', message = 'NORMALIZED_RECORD_DECISION_INVALID';
  end if;

  if nullif(btrim(p_evidence->>'evidence_reference'), '') is null then
    raise exception using
      errcode = '22023', message = 'CLIENT_REVIEW_EVIDENCE_REQUIRED';
  end if;

  if v_decision = 'CORRECTION_REQUIRED'
     and length(coalesce(btrim(p_reason), '')) < 10 then
    raise exception using
      errcode = '22023', message = 'CLIENT_CORRECTION_REASON_REQUIRED';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023', message = 'CLIENT_REVIEW_PAYLOAD_CONTAINS_SECRET';
  end if;

  select batch.*
  into v_batch
  from public.atlas_normalization_batches as batch
  where batch.id = p_normalization_batch_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'NORMALIZATION_BATCH_NOT_FOUND';
  end if;

  select decision_record.*
  into v_existing
  from public.atlas_normalization_review_decisions as decision_record
  where decision_record.normalization_batch_id = v_batch.id
    and decision_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.normalized_record_id <> p_normalized_record_id
       or v_existing.decision <> v_decision
       or coalesce(v_existing.reason, '') <> coalesce(nullif(btrim(p_reason), ''), '')
       or v_existing.evidence <> p_evidence
       or v_existing.metadata->'request_metadata' <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'NORMALIZED_RECORD_DECISION_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'review_decision_id', v_existing.id,
      'normalization_batch_id', v_existing.normalization_batch_id,
      'normalized_record_id', v_existing.normalized_record_id,
      'decision', v_existing.decision,
      'decision_version', v_existing.decision_version,
      'batch_state_version', v_existing.resulting_batch_state_version
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_batch.installation_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_installation.current_state_code <> 'CLIENT_REVIEW'
     or v_batch.batch_status <> 'IN_CLIENT_REVIEW' then
    raise exception using
      errcode = '22023', message = 'NORMALIZATION_NOT_IN_CLIENT_REVIEW';
  end if;

  if v_batch.state_version <> p_expected_batch_state_version then
    raise exception using
      errcode = '40001', message = 'NORMALIZATION_BATCH_VERSION_CONFLICT';
  end if;

  if v_installation.client_owner_user_id <> v_actor_user_id
     or not exists (
       select 1
       from public.atlas_internal_memberships as membership
       where membership.empresa_id = v_installation.empresa_id
         and membership.user_id = v_actor_user_id
         and membership.role_code = 'OWNER'
         and membership.status = 'ACTIVE'
     )
     or not public.atlas_internal_has_permission(
       v_installation.empresa_id,
       'INSTALLATION_NORMALIZATION_CLIENT_REVIEW'
     ) then
    raise exception using
      errcode = '42501', message = 'CLIENT_OWNER_REVIEW_FORBIDDEN';
  end if;

  select record.*
  into v_record
  from public.atlas_normalized_records as record
  where record.id = p_normalized_record_id
    and record.normalization_batch_id = v_batch.id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'NORMALIZED_RECORD_NOT_FOUND';
  end if;

  if v_record.normalization_status <> 'NORMALIZED' then
    raise exception using
      errcode = '22023', message = 'NORMALIZED_RECORD_NOT_DECIDABLE';
  end if;

  if exists (
    select 1
    from public.atlas_normalization_issues as issue
    join public.atlas_normalization_issue_definitions as definition
      on definition.issue_code = issue.issue_code
     and definition.active = true
    where issue.normalization_batch_id = v_batch.id
      and issue.normalized_record_id = v_record.id
      and issue.issue_status = 'OPEN'
      and definition.blocks_client_review = true
  ) then
    raise exception using
      errcode = '22023', message = 'NORMALIZED_RECORD_HAS_BLOCKING_ISSUES';
  end if;

  select coalesce(max(decision_record.decision_version), 0) + 1
  into v_decision_version
  from public.atlas_normalization_review_decisions as decision_record
  where decision_record.normalized_record_id = v_record.id;

  v_new_record_status := case
    when v_decision = 'APPROVED' then 'CLIENT_APPROVED'
    else 'CLIENT_REJECTED'
  end;

  update public.atlas_normalized_records
  set
    normalization_status = v_new_record_status,
    metadata = metadata || jsonb_build_object(
      'latest_client_review_request_id', p_request_id,
      'latest_client_review_decision', v_decision
    ),
    updated_at = now()
  where id = v_record.id;

  update public.atlas_normalization_batches
  set
    state_version = state_version + 1,
    metadata = metadata || jsonb_build_object(
      'latest_client_review_request_id', p_request_id
    ),
    updated_at = now()
  where id = v_batch.id
  returning * into v_batch;

  insert into public.atlas_normalization_review_decisions (
    id, installation_id, empresa_id, normalization_batch_id,
    normalized_record_id, inventory_requirement_id, inventory_code,
    decision, decision_version, reviewed_record_version,
    resulting_batch_state_version, reason, evidence,
    reviewer_user_id, reviewer_role_code, request_id, metadata
  )
  values (
    v_decision_id, v_record.installation_id, v_record.empresa_id,
    v_batch.id, v_record.id, v_record.inventory_requirement_id,
    v_record.inventory_code, v_decision, v_decision_version,
    v_record.record_version, v_batch.state_version,
    nullif(btrim(p_reason), ''), p_evidence,
    v_actor_user_id, 'OWNER', p_request_id,
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_normalization_events (
    installation_id, empresa_id, normalization_batch_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, reason, request_id,
    evidence, metadata
  )
  values (
    v_record.installation_id, v_record.empresa_id, v_batch.id,
    'RECORD', v_record.id, 'NORMALIZED_RECORD_CLIENT_DECIDED',
    'NORMALIZED', v_new_record_status,
    v_actor_user_id, 'OWNER',
    coalesce(nullif(btrim(p_reason), ''),
      'Registro normalizado aprobado por el OWNER del cliente.'),
    p_request_id,
    p_evidence || jsonb_build_object(
      'review_decision_id', v_decision_id,
      'decision', v_decision
    ),
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_batch.empresa_id, v_actor_user_id, null, null,
    'NORMALIZED_RECORD_CLIENT_DECIDED',
    'B2_NORMALIZATION_REVIEW_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'normalized_record_id', v_record.id,
      'decision', v_decision,
      'expected_batch_state_version', p_expected_batch_state_version
    ),
    jsonb_build_object(
      'review_decision_id', v_decision_id,
      'record_status', v_new_record_status,
      'batch_state_version', v_batch.state_version
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'NORMALIZED_RECORD_CLIENT_DECIDED',
    'review_decision_id', v_decision_id,
    'normalization_batch_id', v_batch.id,
    'normalized_record_id', v_record.id,
    'decision', v_decision,
    'record_status', v_new_record_status,
    'decision_version', v_decision_version,
    'batch_state_version', v_batch.state_version
  );
end;
$$;

revoke all on function public.atlas_decide_normalized_record(
  uuid, uuid, text, text, jsonb, uuid, bigint, jsonb
) from public, anon;
grant execute on function public.atlas_decide_normalized_record(
  uuid, uuid, text, text, jsonb, uuid, bigint, jsonb
) to authenticated, service_role;

create or replace function
public.atlas_submit_normalization_for_client_review(
  p_normalization_batch_id uuid,
  p_request_id uuid,
  p_expected_batch_state_version bigint,
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
  v_batch public.atlas_normalization_batches%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing_event public.atlas_normalization_events%rowtype;
  v_transition_result jsonb;
  v_record_count bigint;
  v_uncovered_count bigint;
  v_blocking_count bigint;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_NORMALIZATION_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_NORMALIZATION_MANAGE_FORBIDDEN';
  end if;

  if p_normalization_batch_id is null
     or p_request_id is null
     or p_expected_batch_state_version is null
     or p_expected_batch_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_SUBMISSION_REQUIRED_FIELDS_MISSING';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_SUBMISSION_METADATA_CONTAINS_SECRET';
  end if;

  select batch.*
  into v_batch
  from public.atlas_normalization_batches as batch
  where batch.id = p_normalization_batch_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'NORMALIZATION_BATCH_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_normalization_events as event_record
  where event_record.normalization_batch_id = v_batch.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <>
         'NORMALIZATION_SUBMITTED_FOR_CLIENT_REVIEW'
       or v_existing_event.metadata->'request_metadata' <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'NORMALIZATION_SUBMISSION_IDEMPOTENCY_COLLISION';
    end if;

    select installation.*
    into v_installation
    from public.atlas_installations as installation
    where installation.id = v_batch.installation_id;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'normalization_batch_id', v_batch.id,
      'batch_status', v_batch.batch_status,
      'batch_state_version', v_batch.state_version,
      'installation_state', v_installation.current_state_code,
      'installation_version', v_installation.version
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_batch.installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_installation.current_state_code <> 'DATA_NORMALIZATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_DATA_NORMALIZATION';
  end if;

  if v_installation.version <> p_expected_installation_version then
    raise exception using
      errcode = '40001',
      message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_batch.batch_status <> 'READY_FOR_REVIEW' then
    raise exception using
      errcode = '55000',
      message = 'NORMALIZATION_BATCH_NOT_READY_FOR_CLIENT_REVIEW';
  end if;

  if v_batch.state_version <> p_expected_batch_state_version then
    raise exception using
      errcode = '40001',
      message = 'NORMALIZATION_BATCH_VERSION_CONFLICT';
  end if;

  select count(*)
  into v_blocking_count
  from public.atlas_normalization_issues as issue
  join public.atlas_normalization_issue_definitions as definition
    on definition.issue_code = issue.issue_code
   and definition.active = true
  where issue.normalization_batch_id = v_batch.id
    and issue.issue_status = 'OPEN'
    and definition.blocks_client_review = true;

  if v_blocking_count > 0 then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_BLOCKING_ISSUES_PRESENT';
  end if;

  select count(*)
  into v_record_count
  from public.atlas_normalized_records as record
  where record.normalization_batch_id = v_batch.id
    and record.normalization_status <> 'SUPERSEDED';

  if v_record_count = 0 then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_CLIENT_REVIEW_REQUIRES_RECORDS';
  end if;

  if exists (
    select 1
    from public.atlas_normalized_records as record
    where record.normalization_batch_id = v_batch.id
      and record.normalization_status not in (
        'NORMALIZED', 'CLIENT_APPROVED', 'SUPERSEDED'
      )
  ) then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_RECORDS_NOT_REVIEWABLE';
  end if;

  select count(*)
  into v_uncovered_count
  from public.atlas_installation_inventory_requirements as requirement
  where requirement.installation_id = v_batch.installation_id
    and requirement.source_manifest_id = v_batch.source_manifest_id
    and requirement.requirement_mode <> 'NOT_APPLICABLE'
    and not exists (
      select 1
      from public.atlas_normalized_records as record
      where record.normalization_batch_id = v_batch.id
        and record.inventory_requirement_id = requirement.id
        and record.normalization_status in (
          'NORMALIZED', 'CLIENT_APPROVED'
        )
    );

  if v_uncovered_count > 0 then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZATION_APPLICABLE_REQUIREMENTS_UNCOVERED';
  end if;

  select platform_membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as platform_membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = platform_membership.role_code
   and role_definition.active = true
  where platform_membership.user_id = v_actor_user_id
    and platform_membership.status = 'ACTIVE'
  order by role_definition.priority asc, platform_membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'PLATFORM_ACTOR_ROLE_NOT_FOUND';
  end if;

  update public.atlas_normalization_batches
  set
    batch_status = 'IN_CLIENT_REVIEW',
    state_version = state_version + 1,
    metadata = metadata || jsonb_build_object(
      'client_review_submission_request_id', p_request_id,
      'client_review_submitted_at', now()
    ),
    updated_at = now()
  where id = v_batch.id
  returning * into v_batch;

  v_transition_result := public.atlas_transition_installation(
    v_installation.id,
    'CLIENT_REVIEW',
    'Lote normalizado listo para revision humana del cliente.',
    p_request_id,
    p_expected_installation_version
  );

  insert into public.atlas_normalization_events (
    installation_id, empresa_id, normalization_batch_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, reason, request_id,
    evidence, metadata
  )
  values (
    v_batch.installation_id, v_batch.empresa_id, v_batch.id,
    'BATCH', v_batch.id, 'NORMALIZATION_SUBMITTED_FOR_CLIENT_REVIEW',
    'READY_FOR_REVIEW', 'IN_CLIENT_REVIEW',
    v_actor_user_id, v_actor_role_code,
    'Lote normalizado sometido a revision humana del cliente.',
    p_request_id,
    jsonb_build_object(
      'record_count', v_record_count,
      'blocking_issue_count', v_blocking_count,
      'uncovered_requirement_count', v_uncovered_count,
      'transition_result', v_transition_result
    ),
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_batch.empresa_id, v_actor_user_id, null, null,
    'NORMALIZATION_SUBMITTED_FOR_CLIENT_REVIEW',
    'B2_NORMALIZATION_REVIEW_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'normalization_batch_id', v_batch.id,
      'expected_batch_state_version',
        p_expected_batch_state_version,
      'expected_installation_version',
        p_expected_installation_version
    ),
    jsonb_build_object(
      'batch_status', v_batch.batch_status,
      'batch_state_version', v_batch.state_version,
      'installation_state', v_transition_result->>'state',
      'installation_version', v_transition_result->>'version'
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'NORMALIZATION_SUBMITTED_FOR_CLIENT_REVIEW',
    'normalization_batch_id', v_batch.id,
    'batch_status', v_batch.batch_status,
    'batch_state_version', v_batch.state_version,
    'installation_state', v_transition_result->>'state',
    'installation_version',
      (v_transition_result->>'version')::bigint,
    'record_count', v_record_count
  );
end;
$$;

revoke all on function
public.atlas_submit_normalization_for_client_review(
  uuid, uuid, bigint, bigint, jsonb
) from public, anon;
grant execute on function
public.atlas_submit_normalization_for_client_review(
  uuid, uuid, bigint, bigint, jsonb
) to authenticated, service_role;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_NORMALIZATION_CLIENT_REVIEW',
    'Revisar y aprobar propuestas normalizadas como OWNER del cliente.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('OWNER', 'INSTALLATION_NORMALIZATION_CLIENT_REVIEW')
on conflict (role_code, permission_code) do nothing;

create table if not exists
public.atlas_normalization_review_decisions (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  normalization_batch_id uuid not null,
  normalized_record_id uuid not null,
  inventory_requirement_id uuid not null,
  inventory_code text not null,
  decision text not null,
  decision_version integer not null,
  reviewed_record_version integer not null,
  resulting_batch_state_version bigint not null,
  reason text,
  evidence jsonb not null,
  reviewer_user_id uuid not null,
  reviewer_role_code text not null,
  request_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_norm_review_decisions_request_key
    unique (normalization_batch_id, request_id),
  constraint atlas_norm_review_decisions_version_key
    unique (normalized_record_id, decision_version),
  constraint atlas_norm_review_decisions_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_norm_review_decisions_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_norm_review_decisions_batch_fkey
    foreign key (normalization_batch_id)
    references public.atlas_normalization_batches(id)
    on delete restrict,
  constraint atlas_norm_review_decisions_record_fkey
    foreign key (normalized_record_id)
    references public.atlas_normalized_records(id)
    on delete restrict,
  constraint atlas_norm_review_decisions_requirement_fkey
    foreign key (inventory_requirement_id)
    references public.atlas_installation_inventory_requirements(id)
    on delete restrict,
  constraint atlas_norm_review_decisions_inventory_fkey
    foreign key (inventory_code)
    references public.atlas_installation_inventory_definitions(inventory_code)
    on delete restrict,
  constraint atlas_norm_review_decisions_reviewer_fkey
    foreign key (reviewer_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_norm_review_decisions_role_fkey
    foreign key (reviewer_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_norm_review_decisions_decision_check
    check (decision in ('APPROVED', 'CORRECTION_REQUIRED')),
  constraint atlas_norm_review_decisions_versions_check
    check (
      decision_version >= 1
      and reviewed_record_version >= 1
      and resulting_batch_state_version >= 2
    ),
  constraint atlas_norm_review_decisions_reason_check
    check (
      decision <> 'CORRECTION_REQUIRED'
      or length(btrim(reason)) >= 10
    ),
  constraint atlas_norm_review_decisions_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
      and nullif(btrim(evidence->>'evidence_reference'), '') is not null
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
    ),
  constraint atlas_norm_review_decisions_owner_check
    check (reviewer_role_code = 'OWNER'),
  constraint atlas_norm_review_decisions_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index if not exists idx_atlas_norm_review_latest_record
  on public.atlas_normalization_review_decisions (
    normalized_record_id,
    decision_version desc
  );

create index if not exists idx_atlas_norm_review_batch_decision
  on public.atlas_normalization_review_decisions (
    normalization_batch_id,
    decision,
    created_at desc
  );

create table if not exists public.atlas_canonical_data_versions (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  normalization_batch_id uuid not null,
  source_manifest_id uuid not null,
  canonical_version integer not null,
  schema_version text not null,
  version_status text not null default 'APPROVED',
  canonical_payload jsonb not null,
  canonical_sha256 text not null,
  approved_by_user_id uuid not null,
  approved_by_role_code text not null,
  approval_reason text not null,
  approval_evidence jsonb not null,
  request_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  approved_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint atlas_canonical_data_versions_request_key
    unique (installation_id, request_id),
  constraint atlas_canonical_data_versions_number_key
    unique (installation_id, canonical_version),
  constraint atlas_canonical_data_versions_batch_key
    unique (normalization_batch_id),
  constraint atlas_canonical_data_versions_hash_key
    unique (installation_id, canonical_sha256),
  constraint atlas_canonical_data_versions_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_canonical_data_versions_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_canonical_data_versions_batch_fkey
    foreign key (normalization_batch_id)
    references public.atlas_normalization_batches(id)
    on delete restrict,
  constraint atlas_canonical_data_versions_manifest_fkey
    foreign key (source_manifest_id)
    references public.atlas_installation_manifests(id)
    on delete restrict,
  constraint atlas_canonical_data_versions_approver_fkey
    foreign key (approved_by_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_canonical_data_versions_role_fkey
    foreign key (approved_by_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_canonical_data_versions_number_check
    check (canonical_version >= 1),
  constraint atlas_canonical_data_versions_schema_check
    check (schema_version ~ '^B2_NORM_V[0-9]+$'),
  constraint atlas_canonical_data_versions_status_check
    check (version_status = 'APPROVED'),
  constraint atlas_canonical_data_versions_payload_check
    check (
      jsonb_typeof(canonical_payload) = 'object'
      and canonical_payload ?& array[
        'schema_version',
        'installation_id',
        'empresa_id',
        'normalization_batch_id',
        'source_manifest_id',
        'records'
      ]
      and jsonb_typeof(canonical_payload->'records') = 'array'
      and jsonb_array_length(canonical_payload->'records') > 0
      and not public.atlas_jsonb_has_forbidden_secret_key(
        canonical_payload
      )
    ),
  constraint atlas_canonical_data_versions_hash_check
    check (canonical_sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_canonical_data_versions_owner_check
    check (approved_by_role_code = 'OWNER'),
  constraint atlas_canonical_data_versions_reason_check
    check (length(btrim(approval_reason)) >= 10),
  constraint atlas_canonical_data_versions_evidence_check
    check (
      jsonb_typeof(approval_evidence) = 'object'
      and approval_evidence <> '{}'::jsonb
      and nullif(
        btrim(approval_evidence->>'evidence_reference'),
        ''
      ) is not null
      and not public.atlas_jsonb_has_forbidden_secret_key(
        approval_evidence
      )
    ),
  constraint atlas_canonical_data_versions_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index if not exists idx_atlas_canonical_data_current
  on public.atlas_canonical_data_versions (
    installation_id,
    canonical_version desc
  );

create or replace function public.atlas_block_f3_immutable_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_F3_RECORDS_APPEND_ONLY:' || tg_table_name;
end;
$$;

revoke all on function public.atlas_block_f3_immutable_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_f3_immutable_mutation()
  to service_role;

drop trigger if exists trg_atlas_norm_review_decisions_append_only
  on public.atlas_normalization_review_decisions;
create trigger trg_atlas_norm_review_decisions_append_only
before update or delete
on public.atlas_normalization_review_decisions
for each row execute function public.atlas_block_f3_immutable_mutation();

drop trigger if exists trg_atlas_canonical_data_versions_append_only
  on public.atlas_canonical_data_versions;
create trigger trg_atlas_canonical_data_versions_append_only
before update or delete
on public.atlas_canonical_data_versions
for each row execute function public.atlas_block_f3_immutable_mutation();

alter table public.atlas_normalization_review_decisions
  enable row level security;
alter table public.atlas_canonical_data_versions
  enable row level security;

revoke all on table public.atlas_normalization_review_decisions
  from anon, authenticated;
revoke all on table public.atlas_canonical_data_versions
  from anon, authenticated;
grant select on table public.atlas_normalization_review_decisions
  to authenticated;
grant select on table public.atlas_canonical_data_versions
  to authenticated;
grant all on table public.atlas_normalization_review_decisions
  to service_role;
grant all on table public.atlas_canonical_data_versions
  to service_role;

create or replace function public.atlas_supersede_normalized_record(
  p_normalization_batch_id uuid,
  p_rejected_record_id uuid,
  p_replacement_record_id uuid,
  p_reason text,
  p_request_id uuid,
  p_expected_batch_state_version bigint,
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
  v_batch public.atlas_normalization_batches%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_rejected public.atlas_normalized_records%rowtype;
  v_replacement public.atlas_normalized_records%rowtype;
  v_existing_event public.atlas_normalization_events%rowtype;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_NORMALIZATION_MANAGE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_NORMALIZATION_MANAGE_FORBIDDEN';
  end if;

  if p_normalization_batch_id is null
     or p_rejected_record_id is null
     or p_replacement_record_id is null
     or p_rejected_record_id = p_replacement_record_id
     or length(coalesce(btrim(p_reason), '')) < 10
     or p_request_id is null
     or p_expected_batch_state_version is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZED_RECORD_SUPERSESSION_REQUIRED_FIELDS_MISSING';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZED_RECORD_SUPERSESSION_METADATA_CONTAINS_SECRET';
  end if;

  select batch.*
  into v_batch
  from public.atlas_normalization_batches as batch
  where batch.id = p_normalization_batch_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'NORMALIZATION_BATCH_NOT_FOUND';
  end if;

  select event_record.*
  into v_existing_event
  from public.atlas_normalization_events as event_record
  where event_record.normalization_batch_id = v_batch.id
    and event_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing_event.event_code <> 'NORMALIZED_RECORD_SUPERSEDED'
       or v_existing_event.entity_id <> p_rejected_record_id
       or v_existing_event.reason <> btrim(p_reason)
       or v_existing_event.evidence->>'replacement_record_id'
            <> p_replacement_record_id::text
       or v_existing_event.metadata->'request_metadata' <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'NORMALIZED_RECORD_SUPERSESSION_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'normalization_batch_id', v_batch.id,
      'rejected_record_id', p_rejected_record_id,
      'replacement_record_id', p_replacement_record_id,
      'batch_state_version', v_batch.state_version
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_batch.installation_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_installation.current_state_code <> 'DATA_NORMALIZATION'
     or v_batch.batch_status <> 'NORMALIZING' then
    raise exception using
      errcode = '22023', message = 'NORMALIZATION_NOT_IN_CORRECTION';
  end if;

  if v_batch.state_version <> p_expected_batch_state_version then
    raise exception using
      errcode = '40001', message = 'NORMALIZATION_BATCH_VERSION_CONFLICT';
  end if;

  select record.*
  into v_rejected
  from public.atlas_normalized_records as record
  where record.id = p_rejected_record_id
    and record.normalization_batch_id = v_batch.id
  for update;

  if not found or v_rejected.normalization_status <> 'CLIENT_REJECTED' then
    raise exception using
      errcode = '22023', message = 'REJECTED_NORMALIZED_RECORD_REQUIRED';
  end if;

  select record.*
  into v_replacement
  from public.atlas_normalized_records as record
  where record.id = p_replacement_record_id
    and record.normalization_batch_id = v_batch.id
  for update;

  if not found or v_replacement.normalization_status <> 'NORMALIZED' then
    raise exception using
      errcode = '22023', message = 'NORMALIZED_REPLACEMENT_RECORD_REQUIRED';
  end if;

  if v_replacement.inventory_requirement_id <>
       v_rejected.inventory_requirement_id
     or v_replacement.inventory_code <> v_rejected.inventory_code
     or v_replacement.record_key <> v_rejected.record_key
     or v_replacement.record_version <= v_rejected.record_version
     or v_replacement.supersedes_record_id is not null then
    raise exception using
      errcode = '22023',
      message = 'NORMALIZED_REPLACEMENT_LINEAGE_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.atlas_normalization_review_decisions as decision_record
    where decision_record.normalized_record_id = v_rejected.id
      and decision_record.decision = 'CORRECTION_REQUIRED'
      and decision_record.decision_version = (
        select max(latest_decision.decision_version)
        from public.atlas_normalization_review_decisions as latest_decision
        where latest_decision.normalized_record_id = v_rejected.id
      )
  ) then
    raise exception using
      errcode = '22023', message = 'CLIENT_CORRECTION_DECISION_REQUIRED';
  end if;

  select platform_membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as platform_membership
  join public.atlas_internal_roles as role_definition
    on role_definition.role_code = platform_membership.role_code
   and role_definition.active = true
  where platform_membership.user_id = v_actor_user_id
    and platform_membership.status = 'ACTIVE'
  order by role_definition.priority, platform_membership.created_at
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501', message = 'PLATFORM_ACTOR_ROLE_NOT_FOUND';
  end if;

  update public.atlas_normalized_records
  set
    normalization_status = 'SUPERSEDED',
    metadata = metadata || jsonb_build_object(
      'superseded_by_record_id', v_replacement.id,
      'supersession_request_id', p_request_id
    ),
    updated_at = now()
  where id = v_rejected.id;

  update public.atlas_normalized_records
  set
    supersedes_record_id = v_rejected.id,
    metadata = metadata || jsonb_build_object(
      'supersession_request_id', p_request_id
    ),
    updated_at = now()
  where id = v_replacement.id;

  update public.atlas_normalization_batches
  set
    state_version = state_version + 1,
    metadata = metadata || jsonb_build_object(
      'latest_supersession_request_id', p_request_id
    ),
    updated_at = now()
  where id = v_batch.id
  returning * into v_batch;

  insert into public.atlas_normalization_events (
    installation_id, empresa_id, normalization_batch_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, reason, request_id,
    evidence, metadata
  )
  values (
    v_batch.installation_id, v_batch.empresa_id, v_batch.id,
    'RECORD', v_rejected.id, 'NORMALIZED_RECORD_SUPERSEDED',
    'CLIENT_REJECTED', 'SUPERSEDED',
    v_actor_user_id, v_actor_role_code, btrim(p_reason), p_request_id,
    jsonb_build_object(
      'replacement_record_id', v_replacement.id,
      'rejected_record_version', v_rejected.record_version,
      'replacement_record_version', v_replacement.record_version
    ),
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_batch.empresa_id, v_actor_user_id, null, null,
    'NORMALIZED_RECORD_SUPERSEDED',
    'B2_NORMALIZATION_REVIEW_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'rejected_record_id', v_rejected.id,
      'replacement_record_id', v_replacement.id,
      'expected_batch_state_version', p_expected_batch_state_version
    ),
    jsonb_build_object(
      'batch_state_version', v_batch.state_version,
      'replacement_status', v_replacement.normalization_status
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'NORMALIZED_RECORD_SUPERSEDED',
    'normalization_batch_id', v_batch.id,
    'rejected_record_id', v_rejected.id,
    'replacement_record_id', v_replacement.id,
    'batch_state_version', v_batch.state_version
  );
end;
$$;

revoke all on function public.atlas_supersede_normalized_record(
  uuid, uuid, uuid, text, uuid, bigint, jsonb
) from public, anon;
grant execute on function public.atlas_supersede_normalized_record(
  uuid, uuid, uuid, text, uuid, bigint, jsonb
) to authenticated, service_role;

create or replace function public.atlas_promote_normalization_batch(
  p_normalization_batch_id uuid,
  p_approval_reason text,
  p_approval_evidence jsonb,
  p_request_id uuid,
  p_expected_batch_state_version bigint,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_batch public.atlas_normalization_batches%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_canonical_data_versions%rowtype;
  v_canonical_id uuid := gen_random_uuid();
  v_canonical_version integer;
  v_canonical_payload jsonb;
  v_canonical_sha256 text;
  v_active_record_count bigint;
  v_unapproved_record_count bigint;
  v_uncovered_requirement_count bigint;
  v_blocking_issue_count bigint;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_normalization_batch_id is null
     or length(coalesce(btrim(p_approval_reason), '')) < 10
     or p_approval_evidence is null
     or jsonb_typeof(p_approval_evidence) <> 'object'
     or nullif(
       btrim(p_approval_evidence->>'evidence_reference'), ''
     ) is null
     or p_request_id is null
     or p_expected_batch_state_version is null
     or p_expected_batch_state_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'CANONICAL_PROMOTION_REQUIRED_FIELDS_MISSING';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_approval_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'CANONICAL_PROMOTION_PAYLOAD_CONTAINS_SECRET';
  end if;

  select batch.*
  into v_batch
  from public.atlas_normalization_batches as batch
  where batch.id = p_normalization_batch_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'NORMALIZATION_BATCH_NOT_FOUND';
  end if;

  select canonical_version.*
  into v_existing
  from public.atlas_canonical_data_versions as canonical_version
  where canonical_version.installation_id = v_batch.installation_id
    and canonical_version.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.normalization_batch_id <> v_batch.id
       or v_existing.approval_reason <> btrim(p_approval_reason)
       or v_existing.approval_evidence <> p_approval_evidence
       or v_existing.metadata->'request_metadata' <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'CANONICAL_PROMOTION_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'canonical_data_version_id', v_existing.id,
      'canonical_version', v_existing.canonical_version,
      'canonical_sha256', v_existing.canonical_sha256,
      'normalization_batch_id', v_existing.normalization_batch_id,
      'batch_status', v_batch.batch_status,
      'batch_state_version', v_batch.state_version
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_batch.installation_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_installation.current_state_code <> 'CLIENT_REVIEW'
     or v_batch.batch_status <> 'IN_CLIENT_REVIEW' then
    raise exception using
      errcode = '22023', message = 'NORMALIZATION_NOT_IN_CLIENT_REVIEW';
  end if;

  if v_batch.state_version <> p_expected_batch_state_version then
    raise exception using
      errcode = '40001', message = 'NORMALIZATION_BATCH_VERSION_CONFLICT';
  end if;

  if v_installation.client_owner_user_id <> v_actor_user_id
     or not exists (
       select 1
       from public.atlas_internal_memberships as membership
       where membership.empresa_id = v_installation.empresa_id
         and membership.user_id = v_actor_user_id
         and membership.role_code = 'OWNER'
         and membership.status = 'ACTIVE'
     )
     or not public.atlas_internal_has_permission(
       v_installation.empresa_id,
       'INSTALLATION_NORMALIZATION_CLIENT_REVIEW'
     ) then
    raise exception using
      errcode = '42501', message = 'CLIENT_OWNER_PROMOTION_FORBIDDEN';
  end if;

  select
    count(*),
    count(*) filter (
      where normalized_record.normalization_status <> 'CLIENT_APPROVED'
    )
  into v_active_record_count, v_unapproved_record_count
  from public.atlas_normalized_records as normalized_record
  where normalized_record.normalization_batch_id = v_batch.id
    and normalized_record.normalization_status <> 'SUPERSEDED';

  if v_active_record_count = 0 then
    raise exception using
      errcode = '22023', message = 'CANONICAL_PROMOTION_REQUIRES_RECORDS';
  end if;

  if v_unapproved_record_count > 0 then
    raise exception using
      errcode = '22023', message = 'CANONICAL_PROMOTION_HAS_UNAPPROVED_RECORDS';
  end if;

  if exists (
    select 1
    from public.atlas_normalized_records as normalized_record
    where normalized_record.normalization_batch_id = v_batch.id
      and normalized_record.normalization_status = 'CLIENT_APPROVED'
      and not exists (
        select 1
        from public.atlas_normalization_review_decisions as decision_record
        where decision_record.normalized_record_id = normalized_record.id
          and decision_record.decision = 'APPROVED'
          and decision_record.reviewed_record_version =
            normalized_record.record_version
          and decision_record.decision_version = (
            select max(latest_decision.decision_version)
            from public.atlas_normalization_review_decisions as latest_decision
            where latest_decision.normalized_record_id = normalized_record.id
          )
      )
  ) then
    raise exception using
      errcode = '22023',
      message = 'CANONICAL_PROMOTION_LATEST_CLIENT_APPROVAL_REQUIRED';
  end if;

  select count(*)
  into v_blocking_issue_count
  from public.atlas_normalization_issues as issue
  join public.atlas_normalization_issue_definitions as definition
    on definition.issue_code = issue.issue_code
   and definition.active = true
  where issue.normalization_batch_id = v_batch.id
    and issue.issue_status = 'OPEN'
    and definition.blocks_client_review = true;

  if v_blocking_issue_count > 0 then
    raise exception using
      errcode = '22023', message = 'CANONICAL_PROMOTION_BLOCKING_ISSUES_PRESENT';
  end if;

  select count(*)
  into v_uncovered_requirement_count
  from public.atlas_installation_inventory_requirements as requirement
  where requirement.installation_id = v_batch.installation_id
    and requirement.source_manifest_id = v_batch.source_manifest_id
    and requirement.requirement_mode <> 'NOT_APPLICABLE'
    and not exists (
      select 1
      from public.atlas_normalized_records as normalized_record
      where normalized_record.normalization_batch_id = v_batch.id
        and normalized_record.inventory_requirement_id = requirement.id
        and normalized_record.normalization_status = 'CLIENT_APPROVED'
    );

  if v_uncovered_requirement_count > 0 then
    raise exception using
      errcode = '22023',
      message = 'CANONICAL_PROMOTION_APPLICABLE_REQUIREMENTS_UNCOVERED';
  end if;

  select coalesce(max(canonical_version.canonical_version), 0) + 1
  into v_canonical_version
  from public.atlas_canonical_data_versions as canonical_version
  where canonical_version.installation_id = v_batch.installation_id;

  select jsonb_build_object(
    'schema_version', v_batch.schema_version,
    'installation_id', v_batch.installation_id,
    'empresa_id', v_batch.empresa_id,
    'normalization_batch_id', v_batch.id,
    'source_manifest_id', v_batch.source_manifest_id,
    'canonical_version', v_canonical_version,
    'records', jsonb_agg(
      jsonb_build_object(
        'normalized_record_id', normalized_record.id,
        'inventory_requirement_id', normalized_record.inventory_requirement_id,
        'inventory_code', normalized_record.inventory_code,
        'record_key', normalized_record.record_key,
        'record_version', normalized_record.record_version,
        'value', normalized_record.proposed_value,
        'value_sha256', normalized_record.value_sha256,
        'source_file_id', normalized_record.source_file_id,
        'source_file_sha256', source_file.sha256,
        'source_reference',
          normalized_record.source_locator->>'source_reference',
        'confidence', normalized_record.confidence,
        'valid_from', normalized_record.valid_from,
        'valid_until', normalized_record.valid_until,
        'security_classification', source_file.security_classification,
        'retention_policy_code', source_file.retention_policy_code
      )
      order by
        normalized_record.inventory_code,
        normalized_record.record_key,
        normalized_record.record_version
    )
  )
  into v_canonical_payload
  from public.atlas_normalized_records as normalized_record
  join public.atlas_installation_files as source_file
    on source_file.id = normalized_record.source_file_id
   and source_file.installation_id = v_batch.installation_id
   and source_file.empresa_id = v_batch.empresa_id
  where normalized_record.normalization_batch_id = v_batch.id
    and normalized_record.normalization_status = 'CLIENT_APPROVED';

  if jsonb_array_length(v_canonical_payload->'records') <>
       v_active_record_count then
    raise exception using
      errcode = '22023', message = 'CANONICAL_PROMOTION_SOURCE_LINEAGE_INCOMPLETE';
  end if;

  v_canonical_sha256 := public.atlas_normalization_sha256(
    v_canonical_payload::text
  );

  insert into public.atlas_canonical_data_versions (
    id, installation_id, empresa_id, normalization_batch_id,
    source_manifest_id, canonical_version, schema_version,
    version_status, canonical_payload, canonical_sha256,
    approved_by_user_id, approved_by_role_code,
    approval_reason, approval_evidence, request_id, metadata
  )
  values (
    v_canonical_id, v_batch.installation_id, v_batch.empresa_id,
    v_batch.id, v_batch.source_manifest_id, v_canonical_version,
    v_batch.schema_version, 'APPROVED', v_canonical_payload,
    v_canonical_sha256, v_actor_user_id, 'OWNER',
    btrim(p_approval_reason), p_approval_evidence, p_request_id,
    jsonb_build_object('request_metadata', p_metadata)
  );

  update public.atlas_normalization_batches
  set
    batch_status = 'APPROVED',
    state_version = state_version + 1,
    completed_at = now(),
    metadata = metadata || jsonb_build_object(
      'canonical_data_version_id', v_canonical_id,
      'canonical_sha256', v_canonical_sha256,
      'promotion_request_id', p_request_id
    ),
    updated_at = now()
  where id = v_batch.id
  returning * into v_batch;

  insert into public.atlas_normalization_events (
    installation_id, empresa_id, normalization_batch_id,
    entity_type, entity_id, event_code, from_status, to_status,
    actor_user_id, actor_role_code, reason, request_id,
    evidence, metadata
  )
  values (
    v_batch.installation_id, v_batch.empresa_id, v_batch.id,
    'BATCH', v_batch.id, 'NORMALIZATION_CANONICAL_VERSION_APPROVED',
    'IN_CLIENT_REVIEW', 'APPROVED',
    v_actor_user_id, 'OWNER', btrim(p_approval_reason), p_request_id,
    p_approval_evidence || jsonb_build_object(
      'canonical_data_version_id', v_canonical_id,
      'canonical_version', v_canonical_version,
      'canonical_sha256', v_canonical_sha256,
      'record_count', v_active_record_count
    ),
    jsonb_build_object('request_metadata', p_metadata)
  );

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_batch.empresa_id, v_actor_user_id, null, null,
    'NORMALIZATION_CANONICAL_VERSION_APPROVED',
    'B2_NORMALIZATION_REVIEW_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'normalization_batch_id', v_batch.id,
      'expected_batch_state_version', p_expected_batch_state_version
    ),
    jsonb_build_object(
      'canonical_data_version_id', v_canonical_id,
      'canonical_version', v_canonical_version,
      'canonical_sha256', v_canonical_sha256,
      'record_count', v_active_record_count,
      'batch_state_version', v_batch.state_version
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'NORMALIZATION_CANONICAL_VERSION_APPROVED',
    'canonical_data_version_id', v_canonical_id,
    'canonical_version', v_canonical_version,
    'canonical_sha256', v_canonical_sha256,
    'normalization_batch_id', v_batch.id,
    'batch_status', v_batch.batch_status,
    'batch_state_version', v_batch.state_version,
    'record_count', v_active_record_count
  );
end;
$$;

revoke all on function public.atlas_promote_normalization_batch(
  uuid, text, jsonb, uuid, bigint, jsonb
) from public, anon;
grant execute on function public.atlas_promote_normalization_batch(
  uuid, text, jsonb, uuid, bigint, jsonb
) to authenticated, service_role;

create or replace function
public.atlas_compute_installation_g02_readiness(
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
  v_batch public.atlas_normalization_batches%rowtype;
  v_canonical public.atlas_canonical_data_versions%rowtype;
  v_definition_count bigint := 0;
  v_requirement_count bigint := 0;
  v_unresolved_condition_count bigint := 0;
  v_active_record_count bigint := 0;
  v_unapproved_record_count bigint := 0;
  v_blocking_issue_count bigint := 0;
  v_catalog_uncovered bigint := 0;
  v_knowledge_uncovered bigint := 0;
  v_personality_uncovered bigint := 0;
  v_commercial_uncovered bigint := 0;
  v_classification_incomplete bigint := 0;
  v_required_data_inventoried boolean := false;
  v_catalogs_normalized boolean := false;
  v_knowledge_prepared boolean := false;
  v_personality_defined boolean := false;
  v_commercial_rules_approved boolean := false;
  v_classification_assigned boolean := false;
  v_client_review_completed boolean := false;
  v_canonical_versions_approved boolean := false;
  v_ready boolean := false;
  v_blockers jsonb := '[]'::jsonb;
begin
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

  select batch.*
  into v_batch
  from public.atlas_normalization_batches as batch
  where batch.installation_id = v_installation.id
  order by batch.batch_version desc, batch.created_at desc, batch.id desc
  limit 1;

  if found then
    select canonical_version.*
    into v_canonical
    from public.atlas_canonical_data_versions as canonical_version
    where canonical_version.installation_id = v_installation.id
      and canonical_version.normalization_batch_id = v_batch.id
    order by canonical_version.canonical_version desc
    limit 1;

    select count(*)
    into v_definition_count
    from public.atlas_installation_inventory_definitions as definition
    where definition.active = true;

    select
      count(*),
      count(*) filter (
        where requirement.requirement_mode = 'CONDITIONAL'
      )
    into v_requirement_count, v_unresolved_condition_count
    from public.atlas_installation_inventory_requirements as requirement
    where requirement.installation_id = v_installation.id
      and requirement.source_manifest_id = v_batch.source_manifest_id;

    select
      count(*),
      count(*) filter (
        where normalized_record.normalization_status <> 'CLIENT_APPROVED'
      )
    into v_active_record_count, v_unapproved_record_count
    from public.atlas_normalized_records as normalized_record
    where normalized_record.normalization_batch_id = v_batch.id
      and normalized_record.normalization_status <> 'SUPERSEDED';

    select count(*)
    into v_blocking_issue_count
    from public.atlas_normalization_issues as issue
    join public.atlas_normalization_issue_definitions as definition
      on definition.issue_code = issue.issue_code
     and definition.active = true
    where issue.normalization_batch_id = v_batch.id
      and issue.issue_status = 'OPEN'
      and definition.blocks_client_review = true;

    select
      count(*) filter (where definition.logical_section = 'CATALOG'),
      count(*) filter (where definition.logical_section = 'KNOWLEDGE'),
      count(*) filter (where definition.logical_section = 'PERSONALITY'),
      count(*) filter (where definition.logical_section = 'COMMERCIAL_RULES')
    into
      v_catalog_uncovered,
      v_knowledge_uncovered,
      v_personality_uncovered,
      v_commercial_uncovered
    from public.atlas_installation_inventory_requirements as requirement
    join public.atlas_installation_inventory_definitions as definition
      on definition.inventory_code = requirement.inventory_code
     and definition.active = true
    where requirement.installation_id = v_installation.id
      and requirement.source_manifest_id = v_batch.source_manifest_id
      and requirement.requirement_mode <> 'NOT_APPLICABLE'
      and not exists (
        select 1
        from public.atlas_normalized_records as normalized_record
        where normalized_record.normalization_batch_id = v_batch.id
          and normalized_record.inventory_requirement_id = requirement.id
          and normalized_record.normalization_status = 'CLIENT_APPROVED'
      );

    select count(*)
    into v_classification_incomplete
    from public.atlas_normalized_records as normalized_record
    left join public.atlas_installation_files as source_file
      on source_file.id = normalized_record.source_file_id
     and source_file.installation_id = v_installation.id
     and source_file.empresa_id = v_installation.empresa_id
    where normalized_record.normalization_batch_id = v_batch.id
      and normalized_record.normalization_status = 'CLIENT_APPROVED'
      and (
        source_file.id is null
        or source_file.security_classification is null
        or source_file.retention_policy_code is null
      );

    v_required_data_inventoried :=
      v_definition_count > 0
      and v_requirement_count = v_definition_count
      and v_unresolved_condition_count = 0;
    v_catalogs_normalized := v_catalog_uncovered = 0;
    v_knowledge_prepared := v_knowledge_uncovered = 0;
    v_personality_defined := v_personality_uncovered = 0;
    v_commercial_rules_approved := v_commercial_uncovered = 0;
    v_classification_assigned :=
      v_active_record_count > 0 and v_classification_incomplete = 0;
    v_client_review_completed :=
      v_batch.batch_status = 'APPROVED'
      and v_active_record_count > 0
      and v_unapproved_record_count = 0
      and v_blocking_issue_count = 0;
    v_canonical_versions_approved :=
      v_canonical.id is not null
      and v_canonical.version_status = 'APPROVED'
      and v_canonical.source_manifest_id = v_batch.source_manifest_id
      and v_canonical.canonical_sha256 =
        public.atlas_normalization_sha256(
          v_canonical.canonical_payload::text
        )
      and jsonb_array_length(v_canonical.canonical_payload->'records') =
        v_active_record_count;
  end if;

  v_ready :=
    v_required_data_inventoried
    and v_catalogs_normalized
    and v_knowledge_prepared
    and v_personality_defined
    and v_commercial_rules_approved
    and v_classification_assigned
    and v_client_review_completed
    and v_canonical_versions_approved;

  select coalesce(jsonb_agg(blocker), '[]'::jsonb)
  into v_blockers
  from jsonb_array_elements(jsonb_build_array(
    case when not v_required_data_inventoried then jsonb_build_object(
      'criterion', 'REQUIRED_DATA_INVENTORIED',
      'reason', 'COMPLETE_RESOLVED_INVENTORY_REQUIRED'
    ) end,
    case when not v_catalogs_normalized then jsonb_build_object(
      'criterion', 'CATALOGS_AND_POLICIES_NORMALIZED',
      'reason', 'APPROVED_CATALOG_RECORDS_REQUIRED'
    ) end,
    case when not v_knowledge_prepared then jsonb_build_object(
      'criterion', 'KNOWLEDGE_BASE_PREPARED',
      'reason', 'APPROVED_KNOWLEDGE_RECORDS_REQUIRED'
    ) end,
    case when not v_personality_defined then jsonb_build_object(
      'criterion', 'PERSONALITY_DEFINED',
      'reason', 'APPROVED_PERSONALITY_RECORDS_REQUIRED'
    ) end,
    case when not v_commercial_rules_approved then jsonb_build_object(
      'criterion', 'COMMERCIAL_RULES_APPROVED',
      'reason', 'APPROVED_COMMERCIAL_RULE_RECORDS_REQUIRED'
    ) end,
    case when not v_classification_assigned then jsonb_build_object(
      'criterion', 'DATA_CLASSIFICATION_ASSIGNED',
      'reason', 'SOURCE_CLASSIFICATION_AND_RETENTION_REQUIRED'
    ) end,
    case when not v_client_review_completed then jsonb_build_object(
      'criterion', 'CLIENT_REVIEW_COMPLETED',
      'reason', 'ALL_ACTIVE_RECORDS_REQUIRE_CURRENT_CLIENT_APPROVAL'
    ) end,
    case when not v_canonical_versions_approved then jsonb_build_object(
      'criterion', 'CANONICAL_VERSIONS_APPROVED',
      'reason', 'MATCHING_IMMUTABLE_CANONICAL_VERSION_REQUIRED'
    ) end
  )) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  return jsonb_build_object(
    'ok', true,
    'code', case when v_ready
      then 'G02_DATA_READINESS_COMPLETE'
      else 'G02_DATA_READINESS_INCOMPLETE'
    end,
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'ready', v_ready,
    'normalization_batch_id', v_batch.id,
    'batch_status', v_batch.batch_status,
    'batch_state_version', v_batch.state_version,
    'canonical_data_version_id', v_canonical.id,
    'canonical_version', v_canonical.canonical_version,
    'canonical_sha256', v_canonical.canonical_sha256,
    'active_inventory_definitions', v_definition_count,
    'manifest_inventory_requirements', v_requirement_count,
    'active_normalized_records', v_active_record_count,
    'blocking_issue_count', v_blocking_issue_count,
    'criteria', jsonb_build_object(
      'REQUIRED_DATA_INVENTORIED', v_required_data_inventoried,
      'CATALOGS_AND_POLICIES_NORMALIZED', v_catalogs_normalized,
      'KNOWLEDGE_BASE_PREPARED', v_knowledge_prepared,
      'PERSONALITY_DEFINED', v_personality_defined,
      'COMMERCIAL_RULES_APPROVED', v_commercial_rules_approved,
      'DATA_CLASSIFICATION_ASSIGNED', v_classification_assigned,
      'CLIENT_REVIEW_COMPLETED', v_client_review_completed,
      'CANONICAL_VERSIONS_APPROVED', v_canonical_versions_approved
    ),
    'blockers', v_blockers,
    'evaluated_at', now()
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_g02_readiness(uuid)
  from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_g02_readiness(uuid)
  to service_role;

create or replace function public.atlas_get_installation_g02_readiness(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_can_read_installation(p_installation_id) then
    raise exception using
      errcode = '42501', message = 'INSTALLATION_G02_READ_FORBIDDEN';
  end if;

  return public.atlas_compute_installation_g02_readiness(
    p_installation_id
  );
end;
$$;

revoke all on function public.atlas_get_installation_g02_readiness(uuid)
  from public, anon;
grant execute on function public.atlas_get_installation_g02_readiness(uuid)
  to authenticated, service_role;

create or replace function public.atlas_enforce_g02_approval_readiness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
begin
  if new.gate_code = 'G02'
     and new.authority_type = 'CLIENT'
     and new.decision = 'APPROVED' then
    if new.actor_role_code <> 'OWNER' then
      raise exception using
        errcode = '42501', message = 'G02_REQUIRES_CLIENT_OWNER';
    end if;

    v_readiness := public.atlas_compute_installation_g02_readiness(
      new.installation_id
    );

    if not coalesce((v_readiness->>'ready')::boolean, false) then
      raise exception using
        errcode = '42501',
        message = 'G02_DATA_READINESS_INCOMPLETE',
        detail = v_readiness::text;
    end if;

    if (new.evidence->>'canonical_data_version_id') is distinct from
         (v_readiness->>'canonical_data_version_id')
       or (new.evidence->>'canonical_sha256') is distinct from
         (v_readiness->>'canonical_sha256') then
      raise exception using
        errcode = '22023',
        message = 'G02_CANONICAL_EVIDENCE_MISMATCH';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.atlas_enforce_g02_approval_readiness()
  from public, anon, authenticated;
grant execute on function public.atlas_enforce_g02_approval_readiness()
  to service_role;

drop trigger if exists trg_atlas_g02_approval_readiness
  on public.atlas_installation_approvals;
create trigger trg_atlas_g02_approval_readiness
before insert on public.atlas_installation_approvals
for each row execute function public.atlas_enforce_g02_approval_readiness();

create or replace function
public.atlas_enforce_normalization_transition_readiness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
begin
  if old.current_state_code = 'DATA_NORMALIZATION'
     and new.current_state_code = 'CLIENT_REVIEW' then
    if not exists (
      select 1
      from public.atlas_normalization_batches as batch
      where batch.installation_id = old.id
        and batch.batch_status = 'IN_CLIENT_REVIEW'
        and not exists (
          select 1
          from public.atlas_normalization_issues as issue
          join public.atlas_normalization_issue_definitions as definition
            on definition.issue_code = issue.issue_code
           and definition.active = true
          where issue.normalization_batch_id = batch.id
            and issue.issue_status = 'OPEN'
            and definition.blocks_client_review = true
        )
    ) then
      raise exception using
        errcode = '42501',
        message = 'CLIENT_REVIEW_REQUIRES_SUBMITTED_NORMALIZATION_BATCH';
    end if;
  end if;

  if old.current_state_code = 'CLIENT_REVIEW'
     and new.current_state_code = 'DATA_NORMALIZATION' then
    if not exists (
      select 1
      from public.atlas_normalization_batches as batch
      where batch.installation_id = old.id
        and batch.batch_status = 'NORMALIZING'
        and exists (
          select 1
          from public.atlas_normalized_records as normalized_record
          join public.atlas_normalization_review_decisions as decision_record
            on decision_record.normalized_record_id = normalized_record.id
          where normalized_record.normalization_batch_id = batch.id
            and normalized_record.normalization_status = 'CLIENT_REJECTED'
            and decision_record.decision = 'CORRECTION_REQUIRED'
        )
    ) then
      raise exception using
        errcode = '42501',
        message = 'DATA_NORMALIZATION_RETURN_REQUIRES_CLIENT_CORRECTION';
    end if;
  end if;

  if old.current_state_code = 'CLIENT_REVIEW'
     and new.current_state_code = 'DATA_APPROVED' then
    if not exists (
      select 1
      from public.atlas_installation_gates as gate_record
      where gate_record.installation_id = old.id
        and gate_record.gate_code = 'G02'
        and gate_record.status = 'APPROVED'
        and gate_record.client_approved = true
    ) then
      raise exception using
        errcode = '42501', message = 'G02_GATE_APPROVAL_REQUIRED';
    end if;

    v_readiness := public.atlas_compute_installation_g02_readiness(old.id);

    if not coalesce((v_readiness->>'ready')::boolean, false) then
      raise exception using
        errcode = '42501',
        message = 'G02_DATA_READINESS_STALE_OR_INCOMPLETE',
        detail = v_readiness::text;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_normalization_transition_readiness()
  from public, anon, authenticated;
grant execute on function
public.atlas_enforce_normalization_transition_readiness()
  to service_role;

drop trigger if exists trg_atlas_normalization_transition_readiness
  on public.atlas_installations;
create trigger trg_atlas_normalization_transition_readiness
before update of current_state_code on public.atlas_installations
for each row execute function
public.atlas_enforce_normalization_transition_readiness();

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_normalization_review_decisions'
      and policyname = 'atlas_norm_review_decisions_read'
  ) then
    execute $policy$
      create policy atlas_norm_review_decisions_read
        on public.atlas_normalization_review_decisions
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_canonical_data_versions'
      and policyname = 'atlas_canonical_data_versions_read'
  ) then
    execute $policy$
      create policy atlas_canonical_data_versions_read
        on public.atlas_canonical_data_versions
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_normalization_review_decisions is
  'B2: decisiones OWNER append-only sobre registros normalizados.';
comment on table public.atlas_canonical_data_versions is
  'B2: snapshots canonicos inmutables aprobados por el OWNER cliente.';
comment on function public.atlas_submit_normalization_for_client_review(
  uuid, uuid, bigint, bigint, jsonb
) is
  'B2: somete un lote completo a revision humana y transiciona a CLIENT_REVIEW.';
comment on function public.atlas_decide_normalized_record(
  uuid, uuid, text, text, jsonb, uuid, bigint, jsonb
) is
  'B2: registra la decision versionada del OWNER sobre un dato propuesto.';
comment on function public.atlas_return_normalization_for_correction(
  uuid, text, uuid, bigint, bigint, jsonb
) is
  'B2: devuelve un lote rechazado a correccion con trazabilidad.';
comment on function public.atlas_supersede_normalized_record(
  uuid, uuid, uuid, text, uuid, bigint, jsonb
) is
  'B2: enlaza la correccion y conserva inmutable el dato rechazado.';
comment on function public.atlas_promote_normalization_batch(
  uuid, text, jsonb, uuid, bigint, jsonb
) is
  'B2: congela la version canonica aprobada por el OWNER con SHA-256.';
comment on function public.atlas_get_installation_g02_readiness(uuid) is
  'B2: frontera de lectura del alistamiento objetivo G02.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2F3_CLIENT_REVIEW_CANONICAL_INSTALLED',
  'next_action', 'CERTIFY_CLIENT_REVIEW_AND_G02_ENFORCEMENT',
  'review_tables', 2,
  'review_write_rpcs', 5,
  'g02_readiness_rpcs', 2,
  'enforcement_triggers', 4,
  'review_decision_records', (
    select count(*)
    from public.atlas_normalization_review_decisions
  ),
  'canonical_version_records', (
    select count(*)
    from public.atlas_canonical_data_versions
  ),
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'direct_authenticated_write', false,
  'canonical_promotion_enabled', true,
  'g02_enforcement_enabled', true
) as result;
