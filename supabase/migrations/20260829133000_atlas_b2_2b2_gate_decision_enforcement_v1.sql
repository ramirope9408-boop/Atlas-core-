-- ATLAS B2.2B.2
-- Decisiones gobernadas de gates y enforcement en la maquina de estados.
-- Corte: 2026-08-29
--
-- Prerrequisitos:
--   B2.2A certificado.
--   20260829124500_atlas_b2_2b1_gate_core_v1.sql
--
-- Principios:
-- - una aprobacion exige autoridad explicita, version y evidencia completa;
-- - el OWNER cliente y la autoridad Atlas son identidades separadas;
-- - G04 exige ambas autoridades;
-- - cada decision es append-only, idempotente y auditable;
-- - ningun estado protegido se cruza sin su gate APPROVED.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_gate_definitions') is null
     or to_regclass('public.atlas_installation_gates') is null
     or to_regclass('public.atlas_installation_approvals') is null then
    raise exception 'B2.2B.2 requiere B2.2B.1 instalado y certificado';
  end if;

  if not exists (
    select 1
    from public.atlas_internal_permissions
    where permission_code = 'INSTALLATION_GATE_DECIDE'
  ) then
    raise exception 'B2.2B.2 requiere INSTALLATION_GATE_DECIDE';
  end if;
end;
$$;

-- G03 protege el paso desde pruebas hacia aprobacion final.
update public.atlas_installation_state_transitions
set
  requires_approval = true,
  updated_at = now()
where from_state_code = 'TESTING'
  and to_state_code = 'FINAL_APPROVAL'
  and transition_code = 'SUBMIT_FINAL_APPROVAL';

create or replace function public.atlas_decide_installation_gate(
  p_installation_id uuid,
  p_gate_code text,
  p_authority_type text,
  p_decision text,
  p_reason text,
  p_evidence jsonb,
  p_request_id uuid,
  p_expected_gate_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_gate_code text := upper(nullif(btrim(p_gate_code), ''));
  v_authority_type text := upper(nullif(btrim(p_authority_type), ''));
  v_decision text := upper(nullif(btrim(p_decision), ''));
  v_installation public.atlas_installations%rowtype;
  v_definition public.atlas_installation_gate_definitions%rowtype;
  v_gate public.atlas_installation_gates%rowtype;
  v_existing public.atlas_installation_approvals%rowtype;
  v_actor_role_code text;
  v_platform_approved boolean;
  v_client_approved boolean;
  v_new_status text;
  v_new_gate_version bigint;
  v_approval_id uuid;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_installation_id is null
     or v_gate_code is null
     or v_authority_type is null
     or v_decision is null
     or p_request_id is null
     or p_expected_gate_version is null then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_GATE_AUTHORITY_DECISION_REQUEST_AND_VERSION_REQUIRED';
  end if;

  if v_authority_type not in ('PLATFORM', 'CLIENT') then
    raise exception using
      errcode = '22023',
      message = 'GATE_AUTHORITY_TYPE_INVALID';
  end if;

  if v_decision not in ('APPROVED', 'REJECTED') then
    raise exception using
      errcode = '22023',
      message = 'GATE_DECISION_INVALID';
  end if;

  if p_evidence is null or jsonb_typeof(p_evidence) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'GATE_EVIDENCE_MUST_BE_OBJECT';
  end if;

  if v_decision = 'REJECTED'
     and nullif(btrim(p_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'GATE_REJECTION_REASON_REQUIRED';
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

  select a.*
  into v_existing
  from public.atlas_installation_approvals as a
  where a.installation_id = p_installation_id
    and a.request_id = p_request_id
  limit 1;

  if found then
    select g.*
    into v_gate
    from public.atlas_installation_gates as g
    where g.id = v_existing.gate_id;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'approval_id', v_existing.id,
      'installation_id', v_existing.installation_id,
      'gate_code', v_existing.gate_code,
      'authority_type', v_existing.authority_type,
      'decision', v_existing.decision,
      'gate_status', v_gate.status,
      'gate_version', v_existing.gate_version
    );
  end if;

  select d.*
  into v_definition
  from public.atlas_installation_gate_definitions as d
  where d.gate_code = v_gate_code
    and d.active = true;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_GATE_INVALID';
  end if;

  select g.*
  into v_gate
  from public.atlas_installation_gates as g
  where g.installation_id = p_installation_id
    and g.gate_code = v_gate_code
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_GATE_NOT_INITIALIZED';
  end if;

  if p_expected_gate_version <> v_gate.gate_version then
    raise exception using
      errcode = '40001',
      message = 'INSTALLATION_GATE_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code <> v_definition.review_state_code then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_GATE_REVIEW_STATE';
  end if;

  if v_decision = 'APPROVED' then
    if not (p_evidence ? 'criteria')
       or jsonb_typeof(p_evidence->'criteria') <> 'object' then
      raise exception using
        errcode = '22023',
        message = 'GATE_CRITERIA_EVIDENCE_REQUIRED';
    end if;

    if exists (
      select 1
      from jsonb_array_elements(v_gate.criteria_snapshot) as criterion
      where coalesce(
        p_evidence->'criteria'->>(criterion->>'code'),
        'false'
      ) <> 'true'
    ) then
      raise exception using
        errcode = '22023',
        message = 'GATE_REQUIRED_CRITERIA_NOT_SATISFIED';
    end if;

    if exists (
      select 1
      from public.atlas_installation_gate_definitions as prior_definition
      join public.atlas_installation_gates as prior_gate
        on prior_gate.installation_id = v_installation.id
       and prior_gate.gate_code = prior_definition.gate_code
      where prior_definition.phase_order < v_definition.phase_order
        and prior_definition.active = true
        and prior_gate.status <> 'APPROVED'
    ) then
      raise exception using
        errcode = '22023',
        message = 'PRIOR_INSTALLATION_GATE_NOT_APPROVED';
    end if;
  end if;

  if v_authority_type = 'PLATFORM' then
    if not v_gate.requires_platform_approval then
      raise exception using
        errcode = '42501',
        message = 'PLATFORM_AUTHORITY_NOT_REQUIRED_FOR_GATE';
    end if;

    if not public.atlas_platform_has_permission(
      'INSTALLATION_GATE_DECIDE'
    ) then
      raise exception using
        errcode = '42501',
        message = 'INSTALLATION_GATE_DECIDE_FORBIDDEN';
    end if;

    select pm.role_code
    into v_actor_role_code
    from public.atlas_platform_memberships as pm
    join public.atlas_internal_roles as r
      on r.role_code = pm.role_code
     and r.active = true
    where pm.user_id = v_actor_user_id
      and pm.status = 'ACTIVE'
      and (
        pm.role_code = 'ATLAS_OWNER'
        or pm.role_code = v_definition.required_platform_role_code
      )
    order by
      case when pm.role_code = 'ATLAS_OWNER' then 0 else 1 end,
      r.priority asc,
      pm.created_at asc
    limit 1;

    if not found then
      raise exception using
        errcode = '42501',
        message = 'PLATFORM_ROLE_NOT_AUTHORIZED_FOR_GATE';
    end if;
  else
    if not v_gate.requires_client_approval then
      raise exception using
        errcode = '42501',
        message = 'CLIENT_AUTHORITY_NOT_REQUIRED_FOR_GATE';
    end if;

    if v_installation.empresa_id is null
       or v_installation.client_owner_user_id is null
       or v_installation.client_owner_user_id <> v_actor_user_id
       or not exists (
         select 1
         from public.atlas_internal_memberships as im
         where im.empresa_id = v_installation.empresa_id
           and im.user_id = v_actor_user_id
           and im.role_code = 'OWNER'
           and im.status = 'ACTIVE'
       ) then
      raise exception using
        errcode = '42501',
        message = 'CLIENT_OWNER_NOT_AUTHORIZED_FOR_GATE';
    end if;

    v_actor_role_code := 'OWNER';
  end if;

  v_platform_approved := v_gate.platform_approved;
  v_client_approved := v_gate.client_approved;

  if v_authority_type = 'PLATFORM' then
    v_platform_approved := (v_decision = 'APPROVED');
  else
    v_client_approved := (v_decision = 'APPROVED');
  end if;

  if v_decision = 'REJECTED' then
    v_new_status := 'REJECTED';
  elsif (not v_gate.requires_platform_approval or v_platform_approved)
        and (not v_gate.requires_client_approval or v_client_approved) then
    v_new_status := 'APPROVED';
  else
    v_new_status := 'IN_REVIEW';
  end if;

  v_new_gate_version := v_gate.gate_version + 1;
  v_approval_id := gen_random_uuid();

  update public.atlas_installation_gates
  set
    status = v_new_status,
    gate_version = v_new_gate_version,
    platform_approved = v_platform_approved,
    client_approved = v_client_approved,
    opened_at = coalesce(opened_at, now()),
    approved_at = case
      when v_new_status = 'APPROVED' then now()
      else null
    end,
    last_decided_at = now(),
    metadata = metadata || jsonb_build_object(
      'last_authority_type', v_authority_type,
      'last_decision', v_decision,
      'last_request_id', p_request_id
    ),
    updated_at = now()
  where id = v_gate.id
  returning * into v_gate;

  insert into public.atlas_installation_approvals (
    id,
    installation_id,
    empresa_id,
    gate_id,
    gate_code,
    authority_type,
    decision,
    actor_user_id,
    actor_role_code,
    reason,
    evidence,
    request_id,
    gate_version
  )
  values (
    v_approval_id,
    v_installation.id,
    v_installation.empresa_id,
    v_gate.id,
    v_gate.gate_code,
    v_authority_type,
    v_decision,
    v_actor_user_id,
    v_actor_role_code,
    nullif(btrim(p_reason), ''),
    p_evidence,
    p_request_id,
    v_new_gate_version
  );

  if v_installation.empresa_id is not null then
    insert into public.atlas_internal_audit_log (
      empresa_id,
      user_id,
      agent_code,
      conversation_id,
      action_type,
      tool_code,
      status,
      input_summary,
      output_summary,
      error_message
    )
    values (
      v_installation.empresa_id,
      v_actor_user_id,
      null,
      null,
      'INSTALLATION_GATE_DECIDED',
      'B2_GATE_ENGINE',
      'COMPLETED',
      jsonb_build_object(
        'request_id', p_request_id,
        'gate_code', v_gate.gate_code,
        'authority_type', v_authority_type,
        'decision', v_decision
      ),
      jsonb_build_object(
        'installation_id', v_installation.id,
        'approval_id', v_approval_id,
        'gate_status', v_gate.status,
        'gate_version', v_gate.gate_version
      ),
      null
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_GATE_DECIDED',
    'approval_id', v_approval_id,
    'installation_id', v_installation.id,
    'gate_code', v_gate.gate_code,
    'authority_type', v_authority_type,
    'decision', v_decision,
    'gate_status', v_gate.status,
    'gate_version', v_gate.gate_version,
    'platform_approved', v_gate.platform_approved,
    'client_approved', v_gate.client_approved
  );
end;
$$;

revoke all on function public.atlas_decide_installation_gate(
  uuid, text, text, text, text, jsonb, uuid, bigint
) from public, anon;
grant execute on function public.atlas_decide_installation_gate(
  uuid, text, text, text, text, jsonb, uuid, bigint
) to authenticated, service_role;

create or replace function public.atlas_transition_installation(
  p_installation_id uuid,
  p_to_state_code text,
  p_reason text,
  p_request_id uuid,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_target_state_code text := upper(btrim(p_to_state_code));
  v_installation public.atlas_installations%rowtype;
  v_transition public.atlas_installation_state_transitions%rowtype;
  v_existing_event public.atlas_installation_state_events%rowtype;
  v_from_state_code text;
  v_transition_code text;
  v_requires_reason boolean := false;
  v_requires_approval boolean := false;
  v_is_recovery boolean := false;
  v_gate_code text;
  v_new_resume_state_code text;
  v_new_version bigint;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TRANSITION') then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_TRANSITION_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or v_target_state_code is null
     or v_target_state_code = '' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_ID_TARGET_STATE_AND_REQUEST_ID_REQUIRED';
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

  v_from_state_code := v_installation.current_state_code;

  select ev.*
  into v_existing_event
  from public.atlas_installation_state_events as ev
  where ev.installation_id = p_installation_id
    and ev.request_id = p_request_id
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_installation.id,
      'state', v_existing_event.to_state_code,
      'version', v_existing_event.installation_version,
      'event_id', v_existing_event.id
    );
  end if;

  if p_expected_version is not null
     and p_expected_version <> v_installation.version then
    raise exception using
      errcode = '40001',
      message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_installation.current_state_code = v_target_state_code then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_IN_STATE',
      'installation_id', v_installation.id,
      'state', v_installation.current_state_code,
      'version', v_installation.version
    );
  end if;

  if exists (
    select 1
    from public.atlas_installation_states as s
    where s.state_code = v_installation.current_state_code
      and s.is_terminal = true
  ) then
    raise exception using
      errcode = '22023',
      message = 'TERMINAL_INSTALLATION_CANNOT_TRANSITION';
  end if;

  if not exists (
    select 1
    from public.atlas_installation_states as s
    where s.state_code = v_target_state_code
      and s.active = true
  ) then
    raise exception using
      errcode = '22023',
      message = 'TARGET_INSTALLATION_STATE_INVALID';
  end if;

  if v_installation.current_state_code in ('PAUSED', 'FAILED')
     and v_installation.resume_state_code = v_target_state_code then
    v_is_recovery := true;
    v_transition_code := 'RESUME_' || v_target_state_code;
    v_requires_reason := true;
    v_requires_approval := false;
  else
    select t.*
    into v_transition
    from public.atlas_installation_state_transitions as t
    where t.from_state_code = v_installation.current_state_code
      and t.to_state_code = v_target_state_code
      and t.active = true
    limit 1;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'INSTALLATION_TRANSITION_NOT_ALLOWED';
    end if;

    v_transition_code := v_transition.transition_code;
    v_requires_reason := v_transition.requires_reason;
    v_requires_approval := v_transition.requires_approval;
  end if;

  if v_requires_reason
     and nullif(btrim(p_reason), '') is null then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_TRANSITION_REASON_REQUIRED';
  end if;

  if v_requires_approval then
    select g.gate_code
    into v_gate_code
    from public.atlas_installation_gate_definitions as d
    join public.atlas_installation_gates as g
      on g.installation_id = v_installation.id
     and g.gate_code = d.gate_code
    where d.approved_target_state_code = v_target_state_code
      and d.active = true
    limit 1;

    if not found then
      raise exception using
        errcode = '42501',
        message = 'INSTALLATION_APPROVAL_GATE_NOT_CONFIGURED';
    end if;

    if not exists (
      select 1
      from public.atlas_installation_gates as g
      where g.installation_id = v_installation.id
        and g.gate_code = v_gate_code
        and g.status = 'APPROVED'
    ) then
      raise exception using
        errcode = '42501',
        message = 'INSTALLATION_GATE_NOT_APPROVED:' || v_gate_code;
    end if;
  end if;

  if v_target_state_code in ('PAUSED', 'FAILED') then
    v_new_resume_state_code := coalesce(
      v_installation.resume_state_code,
      v_installation.current_state_code
    );
  elsif v_is_recovery
        or v_target_state_code in ('ROLLED_BACK', 'CANCELLED') then
    v_new_resume_state_code := null;
  else
    v_new_resume_state_code := v_installation.resume_state_code;
  end if;

  v_new_version := v_installation.version + 1;

  update public.atlas_installations
  set
    current_state_code = v_target_state_code,
    resume_state_code = v_new_resume_state_code,
    version = v_new_version,
    activated_at = case
      when v_target_state_code = 'ACTIVE'
        then coalesce(activated_at, now())
      else activated_at
    end,
    updated_at = now()
  where id = v_installation.id
  returning * into v_installation;

  update public.atlas_installation_gates as g
  set
    status = case
      when g.status = 'APPROVED' then g.status
      else 'IN_REVIEW'
    end,
    opened_at = coalesce(g.opened_at, now()),
    updated_at = now()
  from public.atlas_installation_gate_definitions as d
  where g.installation_id = v_installation.id
    and g.gate_code = d.gate_code
    and d.review_state_code = v_target_state_code
    and d.active = true;

  if v_target_state_code = 'OBSERVED' then
    update public.atlas_installation_gates
    set
      status = 'IN_REVIEW',
      gate_version = gate_version + 1,
      platform_approved = false,
      client_approved = false,
      opened_at = now(),
      approved_at = null,
      metadata = metadata || jsonb_build_object(
        'reset_reason', 'TENANT_ENTERED_OBSERVED',
        'reset_at', now()
      ),
      updated_at = now()
    where installation_id = v_installation.id
      and gate_code = 'G04';
  end if;

  select pm.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as pm
  join public.atlas_internal_roles as r
    on r.role_code = pm.role_code
  where pm.user_id = v_actor_user_id
    and pm.status = 'ACTIVE'
  order by r.priority asc, pm.created_at asc
  limit 1;

  insert into public.atlas_installation_state_events (
    installation_id,
    empresa_id,
    event_code,
    from_state_code,
    to_state_code,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    installation_version,
    evidence,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_transition_code,
    v_from_state_code,
    v_target_state_code,
    v_actor_user_id,
    v_actor_role_code,
    nullif(btrim(p_reason), ''),
    p_request_id,
    v_new_version,
    jsonb_build_object(
      'expected_version', p_expected_version,
      'recovery', v_is_recovery,
      'approval_gate', v_gate_code
    ),
    '{}'::jsonb
  );

  if v_installation.empresa_id is not null then
    insert into public.atlas_internal_audit_log (
      empresa_id,
      user_id,
      agent_code,
      conversation_id,
      action_type,
      tool_code,
      status,
      input_summary,
      output_summary,
      error_message
    )
    values (
      v_installation.empresa_id,
      v_actor_user_id,
      null,
      null,
      'INSTALLATION_STATE_TRANSITIONED',
      'B2_INSTALLATION_CORE',
      'COMPLETED',
      jsonb_build_object(
        'request_id', p_request_id,
        'to_state', v_target_state_code,
        'reason', nullif(btrim(p_reason), ''),
        'approval_gate', v_gate_code
      ),
      jsonb_build_object(
        'installation_id', v_installation.id,
        'state', v_installation.current_state_code,
        'version', v_installation.version
      ),
      null
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_TRANSITIONED',
    'installation_id', v_installation.id,
    'state', v_installation.current_state_code,
    'resume_state', v_installation.resume_state_code,
    'version', v_installation.version,
    'transition_code', v_transition_code,
    'approval_gate', v_gate_code
  );
end;
$$;

revoke all on function public.atlas_transition_installation(
  uuid, text, text, uuid, bigint
) from public, anon;
grant execute on function public.atlas_transition_installation(
  uuid, text, text, uuid, bigint
) to authenticated, service_role;

comment on function public.atlas_decide_installation_gate(
  uuid, text, text, text, text, jsonb, uuid, bigint
) is
  'B2: decide un gate con autoridad explicita, checklist completo, evidencia, version e idempotencia.';

comment on function public.atlas_transition_installation(
  uuid, text, text, uuid, bigint
) is
  'B2: transiciona expedientes y exige gates APPROVED para estados protegidos.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2B2_GATE_DECISION_ENFORCEMENT_INSTALLED',
  'decision_rpc_enabled', exists (
    select 1
    from pg_proc as p
    join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'atlas_decide_installation_gate'
      and p.prosecdef = true
  ),
  'protected_transitions', (
    select count(*)
    from public.atlas_installation_state_transitions
    where requires_approval = true
      and active = true
  ),
  'gate_definitions', (
    select count(*)
    from public.atlas_installation_gate_definitions
    where active = true
  ),
  'current_approval_records', (
    select count(*)
    from public.atlas_installation_approvals
  ),
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'direct_authenticated_write', false,
  'next_action', 'CERTIFY_GATE_ENFORCEMENT'
) as result;
