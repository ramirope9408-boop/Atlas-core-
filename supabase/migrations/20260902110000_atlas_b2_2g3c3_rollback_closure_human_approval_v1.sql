-- ATLAS B2.2G.3C.3
-- Cierre gobernado de rollback y aprobacion humana terminal.
-- Corte: 2026-09-02
--
-- Este bloque instala capacidad. No crea decisiones, no cierra planes y no
-- modifica la instalacion piloto de FingerFood durante la migracion.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_request_installation_provisioning_rollback(uuid,uuid,bigint,bigint,text,jsonb,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_begin_installation_provisioning_compensation(uuid,uuid,bigint,bigint,bigint,bigint,jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_complete_installation_provisioning_compensation(uuid,uuid,uuid,bigint,bigint,bigint,bigint,text,text,jsonb,jsonb,text,text,jsonb)'
     ) is null
     or to_regclass(
       'public.atlas_provisioning_operation_receipts'
     ) is null
     or to_regclass(
       'public.atlas_provisioned_resources'
     ) is null
     or to_regprocedure(
       'public.atlas_block_unapproved_platform_control()'
     ) is null then
    raise exception
      'B2.2G.3C.3 requiere B2.2G.3C.2 instalado y certificado';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values (
  'INSTALLATION_ROLLBACK_APPROVE',
  'Aprobar o rechazar humanamente el cierre terminal de un rollback de instalacion.'
)
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values (
  'ATLAS_OWNER',
  'INSTALLATION_ROLLBACK_APPROVE'
)
on conflict (role_code, permission_code) do nothing;

create table if not exists
public.atlas_installation_platform_control_decisions (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  provisioning_plan_id uuid not null,
  decision_type text not null,
  decision text not null,
  from_state_code text not null,
  target_state_code text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  reason text not null,
  evidence jsonb not null,
  technical_summary jsonb not null,
  summary_sha256 text not null,
  decision_sha256 text not null,
  request_id uuid not null,
  expected_installation_version bigint not null,
  resulting_installation_version bigint not null,
  expected_plan_state_version bigint not null,
  resulting_plan_state_version bigint not null,
  metadata jsonb not null default '{}'::jsonb,
  decided_at timestamptz not null default now(),

  constraint atlas_platform_control_decisions_request_key
    unique (installation_id, request_id),
  constraint atlas_platform_control_decisions_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_platform_control_decisions_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_platform_control_decisions_plan_fkey
    foreign key (provisioning_plan_id)
    references public.atlas_installation_provisioning_plans(id)
    on delete restrict,
  constraint atlas_platform_control_decisions_from_state_fkey
    foreign key (from_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_platform_control_decisions_target_state_fkey
    foreign key (target_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_platform_control_decisions_actor_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_platform_control_decisions_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_platform_control_decisions_type_check
    check (decision_type = 'PROVISIONING_ROLLBACK'),
  constraint atlas_platform_control_decisions_decision_check
    check (decision in ('APPROVED', 'REJECTED')),
  constraint atlas_platform_control_decisions_route_check
    check (
      from_state_code = 'PROVISIONING'
      and target_state_code = 'ROLLED_BACK'
    ),
  constraint atlas_platform_control_decisions_reason_check
    check (length(btrim(reason)) >= 10),
  constraint atlas_platform_control_decisions_payload_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
      and nullif(
        btrim(evidence->>'evidence_reference'), ''
      ) is not null
      and jsonb_typeof(technical_summary) = 'object'
      and technical_summary <> '{}'::jsonb
      and jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
      and not public.atlas_jsonb_has_forbidden_secret_key(
        technical_summary
      )
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    ),
  constraint atlas_platform_control_decisions_hash_check
    check (
      summary_sha256 ~ '^[0-9a-f]{64}$'
      and decision_sha256 ~ '^[0-9a-f]{64}$'
    ),
  constraint atlas_platform_control_decisions_versions_check
    check (
      expected_installation_version >= 1
      and expected_plan_state_version >= 1
      and (
        (
          decision = 'APPROVED'
          and resulting_installation_version =
            expected_installation_version + 1
          and resulting_plan_state_version =
            expected_plan_state_version + 1
        )
        or (
          decision = 'REJECTED'
          and resulting_installation_version =
            expected_installation_version
          and resulting_plan_state_version =
            expected_plan_state_version
        )
      )
    )
);

create unique index if not exists
  idx_atlas_platform_control_one_approved_rollback
on public.atlas_installation_platform_control_decisions (
  provisioning_plan_id
)
where decision_type = 'PROVISIONING_ROLLBACK'
  and decision = 'APPROVED';

create index if not exists
  idx_atlas_platform_control_decisions_timeline
on public.atlas_installation_platform_control_decisions (
  installation_id,
  decided_at desc,
  id desc
);

alter table public.atlas_installations
  add column if not exists last_platform_control_decision_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.atlas_installations'::regclass
      and conname =
        'atlas_installations_last_platform_control_decision_fkey'
  ) then
    alter table public.atlas_installations
      add constraint
        atlas_installations_last_platform_control_decision_fkey
      foreign key (last_platform_control_decision_id)
      references
        public.atlas_installation_platform_control_decisions(id)
      on delete restrict;
  end if;
end;
$$;

create index if not exists
  idx_atlas_installations_platform_control_decision
on public.atlas_installations (
  last_platform_control_decision_id
)
where last_platform_control_decision_id is not null;

drop trigger if exists
  trg_atlas_platform_control_decisions_append_only
on public.atlas_installation_platform_control_decisions;
create trigger trg_atlas_platform_control_decisions_append_only
before update or delete
on public.atlas_installation_platform_control_decisions
for each row execute function
public.atlas_block_provisioning_append_only_mutation();

alter table public.atlas_installation_platform_control_decisions
  enable row level security;

revoke all on table
  public.atlas_installation_platform_control_decisions
from anon, authenticated;
grant select on table
  public.atlas_installation_platform_control_decisions
to authenticated;
grant all on table
  public.atlas_installation_platform_control_decisions
to service_role;

drop policy if exists
  atlas_platform_control_decisions_platform_read
on public.atlas_installation_platform_control_decisions;
create policy atlas_platform_control_decisions_platform_read
on public.atlas_installation_platform_control_decisions
for select
to authenticated
using (
  public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_READ'
  )
);

create or replace function
public.atlas_compute_installation_provisioning_rollback_readiness(
  p_provisioning_plan_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_resource_count bigint;
  v_compensated_resource_count bigint;
  v_remaining_resource_count bigint;
  v_active_compensation_count bigint;
  v_manual_review_count bigint;
  v_receipt_lineage_gap_count bigint;
  v_step_terminal_gap_count bigint;
  v_compensation_receipt_count bigint;
  v_rollback_request_present boolean;
  v_plan_hash_valid boolean;
  v_transition_configured boolean;
  v_ready boolean;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
       'INSTALLATION_PROVISIONING_READ'
     )
     and not public.atlas_platform_has_permission(
       'INSTALLATION_ROLLBACK_APPROVE'
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ROLLBACK_READINESS_FORBIDDEN';
  end if;

  if p_provisioning_plan_id is null then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_ID_REQUIRED';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = p_provisioning_plan_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_plan.installation_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  select count(*)
  into v_resource_count
  from public.atlas_provisioned_resources as resource
  where resource.provisioning_plan_id = v_plan.id;

  select count(*)
  into v_compensated_resource_count
  from public.atlas_provisioned_resources as resource
  where resource.provisioning_plan_id = v_plan.id
    and resource.resource_status = 'COMPENSATED';

  v_remaining_resource_count :=
    v_resource_count - v_compensated_resource_count;

  select count(*)
  into v_active_compensation_count
  from public.atlas_installation_provisioning_steps as step
  where step.provisioning_plan_id = v_plan.id
    and (
      step.step_status = 'COMPENSATING'
      or step.compensation_status = 'EXECUTING'
    );

  select count(*)
  into v_manual_review_count
  from public.atlas_installation_provisioning_steps as step
  where step.provisioning_plan_id = v_plan.id
    and step.compensation_status = 'MANUAL_REVIEW';

  select count(*)
  into v_receipt_lineage_gap_count
  from public.atlas_provisioned_resources as resource
  where resource.provisioning_plan_id = v_plan.id
    and resource.resource_status = 'COMPENSATED'
    and not exists (
      select 1
      from public.atlas_provisioning_operation_receipts as receipt
      where receipt.id = resource.last_receipt_id
        and receipt.provisioning_plan_id = v_plan.id
        and receipt.provisioning_step_id =
          resource.provisioning_step_id
        and receipt.operation_phase = 'COMPENSATION'
        and receipt.outcome in ('SUCCEEDED', 'SKIPPED')
        and nullif(
          btrim(receipt.evidence->>'evidence_reference'), ''
        ) is not null
    );

  select count(*)
  into v_step_terminal_gap_count
  from public.atlas_provisioned_resources as resource
  join public.atlas_installation_provisioning_steps as step
    on step.id = resource.provisioning_step_id
  where resource.provisioning_plan_id = v_plan.id
    and resource.resource_status = 'COMPENSATED'
    and (
      step.step_status <> 'COMPENSATED'
      or step.compensation_status <> 'COMPLETED'
    );

  select count(*)
  into v_compensation_receipt_count
  from public.atlas_provisioning_operation_receipts as receipt
  where receipt.provisioning_plan_id = v_plan.id
    and receipt.operation_phase = 'COMPENSATION'
    and receipt.outcome in ('SUCCEEDED', 'SKIPPED');

  select exists (
    select 1
    from public.atlas_installation_provisioning_events as event_record
    where event_record.provisioning_plan_id = v_plan.id
      and event_record.event_code =
        'PROVISIONING_ROLLBACK_REQUESTED'
      and event_record.to_status = 'ROLLBACK_REQUIRED'
  )
  into v_rollback_request_present;

  v_plan_hash_valid := v_plan.plan_sha256 =
    public.atlas_normalization_sha256(v_plan.plan_payload::text);

  select exists (
    select 1
    from public.atlas_installation_state_transitions as transition
    where transition.from_state_code = 'PROVISIONING'
      and transition.to_state_code = 'ROLLED_BACK'
      and transition.approval_scope = 'PLATFORM_CONTROL'
      and transition.requires_reason = true
      and transition.active = true
  )
  into v_transition_configured;

  v_ready :=
    v_plan.plan_status = 'ROLLBACK_REQUIRED'
    and v_installation.current_state_code = 'PROVISIONING'
    and v_plan.empresa_id = v_installation.empresa_id
    and v_plan_hash_valid
    and v_rollback_request_present
    and v_transition_configured
    and v_remaining_resource_count = 0
    and v_active_compensation_count = 0
    and v_manual_review_count = 0
    and v_receipt_lineage_gap_count = 0
    and v_step_terminal_gap_count = 0;

  return jsonb_build_object(
    'ready', v_ready,
    'schema_version', 'B2_ROLLBACK_READINESS_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'provisioning_plan_id', v_plan.id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'plan_status', v_plan.plan_status,
    'plan_state_version', v_plan.state_version,
    'plan_sha256', v_plan.plan_sha256,
    'plan_hash_valid', v_plan_hash_valid,
    'rollback_request_present', v_rollback_request_present,
    'terminal_transition_configured', v_transition_configured,
    'resource_count', v_resource_count,
    'compensated_resource_count',
      v_compensated_resource_count,
    'remaining_resource_count', v_remaining_resource_count,
    'active_compensation_count', v_active_compensation_count,
    'manual_review_count', v_manual_review_count,
    'compensation_receipt_count',
      v_compensation_receipt_count,
    'receipt_lineage_gap_count',
      v_receipt_lineage_gap_count,
    'step_terminal_gap_count', v_step_terminal_gap_count
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_provisioning_rollback_readiness(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_provisioning_rollback_readiness(uuid)
to authenticated, service_role;

create or replace function
public.atlas_block_unapproved_platform_control()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_approval_scope text;
  v_decision
    public.atlas_installation_platform_control_decisions%rowtype;
begin
  if old.current_state_code is not distinct from
       new.current_state_code then
    if old.last_platform_control_decision_id is distinct from
         new.last_platform_control_decision_id then
      raise exception using
        errcode = '42501',
        message =
          'INSTALLATION_PLATFORM_CONTROL_DECISION_BINDING_FORBIDDEN';
    end if;

    return new;
  end if;

  select transition.approval_scope
  into v_approval_scope
  from public.atlas_installation_state_transitions as transition
  where transition.from_state_code = old.current_state_code
    and transition.to_state_code = new.current_state_code
    and transition.active = true
  limit 1;

  if v_approval_scope = 'PLATFORM_CONTROL' then
    if new.last_platform_control_decision_id is null
       or new.last_platform_control_decision_id is not distinct from
         old.last_platform_control_decision_id then
      raise exception using
        errcode = '42501',
        message =
          'INSTALLATION_PLATFORM_CONTROL_AUTHORIZATION_REQUIRED';
    end if;

    select decision_record.*
    into v_decision
    from public.atlas_installation_platform_control_decisions
      as decision_record
    where decision_record.id =
      new.last_platform_control_decision_id;

    if not found
       or v_decision.decision <> 'APPROVED'
       or v_decision.installation_id <> old.id
       or v_decision.empresa_id is distinct from old.empresa_id
       or v_decision.from_state_code <> old.current_state_code
       or v_decision.target_state_code <>
         new.current_state_code
       or v_decision.expected_installation_version <>
         old.version
       or v_decision.resulting_installation_version <>
         new.version then
      raise exception using
        errcode = '42501',
        message =
          'INSTALLATION_PLATFORM_CONTROL_AUTHORIZATION_INVALID';
    end if;
  elsif old.last_platform_control_decision_id is distinct from
        new.last_platform_control_decision_id then
    raise exception using
      errcode = '42501',
      message =
        'INSTALLATION_PLATFORM_CONTROL_DECISION_BINDING_FORBIDDEN';
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_block_unapproved_platform_control()
from public, anon, authenticated;
grant execute on function
public.atlas_block_unapproved_platform_control()
to service_role;

drop trigger if exists
  trg_atlas_installations_platform_control_guard
on public.atlas_installations;
create trigger trg_atlas_installations_platform_control_guard
before update of current_state_code,
  last_platform_control_decision_id
on public.atlas_installations
for each row execute function
public.atlas_block_unapproved_platform_control();

create or replace function
public.atlas_decide_installation_provisioning_rollback(
  p_provisioning_plan_id uuid,
  p_decision text,
  p_reason text,
  p_evidence jsonb,
  p_request_id uuid,
  p_expected_plan_state_version bigint,
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
  v_decision_code text := upper(nullif(btrim(p_decision), ''));
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing
    public.atlas_installation_platform_control_decisions%rowtype;
  v_created
    public.atlas_installation_platform_control_decisions%rowtype;
  v_readiness jsonb;
  v_summary_sha256 text;
  v_decision_sha256 text;
  v_transition_code text;
  v_resulting_plan_state_version bigint;
  v_resulting_installation_version bigint;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_ROLLBACK_APPROVE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_ROLLBACK_APPROVAL_FORBIDDEN';
  end if;

  if p_provisioning_plan_id is null
     or v_decision_code not in ('APPROVED', 'REJECTED')
     or nullif(btrim(p_reason), '') is null
     or length(btrim(p_reason)) < 10
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb
     or nullif(
       btrim(p_evidence->>'evidence_reference'), ''
     ) is null
     or p_request_id is null
     or p_expected_plan_state_version is null
     or p_expected_plan_state_version < 1
     or p_expected_installation_version is null
     or p_expected_installation_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'ROLLBACK_DECISION_REQUIRED_FIELDS_INVALID';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = p_provisioning_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  select decision_record.*
  into v_existing
  from public.atlas_installation_platform_control_decisions
    as decision_record
  where decision_record.installation_id = v_plan.installation_id
    and decision_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.provisioning_plan_id <> v_plan.id
       or v_existing.decision_type <>
         'PROVISIONING_ROLLBACK'
       or v_existing.decision <> v_decision_code
       or v_existing.reason <> btrim(p_reason)
       or v_existing.evidence <> p_evidence
       or v_existing.expected_plan_state_version <>
         p_expected_plan_state_version
       or v_existing.expected_installation_version <>
         p_expected_installation_version
       or v_existing.metadata <> p_metadata then
      raise exception using
        errcode = '22023',
        message =
          'ROLLBACK_DECISION_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'decision_id', v_existing.id,
      'decision', v_existing.decision,
      'installation_id', v_existing.installation_id,
      'provisioning_plan_id',
        v_existing.provisioning_plan_id,
      'installation_state', case
        when v_existing.decision = 'APPROVED'
          then 'ROLLED_BACK'
        else v_existing.from_state_code
      end,
      'installation_version',
        v_existing.resulting_installation_version,
      'plan_status', case
        when v_existing.decision = 'APPROVED'
          then 'ROLLED_BACK'
        else 'ROLLBACK_REQUIRED'
      end,
      'plan_state_version',
        v_existing.resulting_plan_state_version,
      'decision_sha256', v_existing.decision_sha256
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = v_plan.installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'INSTALLATION_NOT_FOUND';
  end if;

  if v_plan.state_version <> p_expected_plan_state_version then
    raise exception using
      errcode = '40001',
      message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
  end if;

  if v_installation.version <>
       p_expected_installation_version then
    raise exception using
      errcode = '40001',
      message = 'INSTALLATION_VERSION_CONFLICT';
  end if;

  if v_plan.plan_status <> 'ROLLBACK_REQUIRED' then
    raise exception using
      errcode = '22023',
      message = 'PROVISIONING_PLAN_NOT_ROLLBACK_REQUIRED';
  end if;

  if v_installation.current_state_code <> 'PROVISIONING' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_PROVISIONING';
  end if;

  if v_plan.empresa_id <> v_installation.empresa_id then
    raise exception using
      errcode = '22023',
      message = 'ROLLBACK_DECISION_TENANT_MISMATCH';
  end if;

  select membership.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as membership
  where membership.user_id = v_actor_user_id
    and membership.role_code = 'ATLAS_OWNER'
    and membership.status = 'ACTIVE'
  order by membership.created_at asc
  limit 1;

  if v_actor_role_code is null then
    raise exception using
      errcode = '42501',
      message = 'ROLLBACK_DECISION_ATLAS_OWNER_REQUIRED';
  end if;

  v_readiness :=
    public.atlas_compute_installation_provisioning_rollback_readiness(
      v_plan.id
    );

  if v_decision_code = 'APPROVED'
     and not coalesce((v_readiness->>'ready')::boolean, false) then
    raise exception using
      errcode = '55000',
      message = 'PROVISIONING_ROLLBACK_NOT_READY_FOR_APPROVAL',
      detail = v_readiness::text;
  end if;

  v_summary_sha256 := public.atlas_normalization_sha256(
    v_readiness::text
  );

  v_resulting_plan_state_version :=
    v_plan.state_version + case
      when v_decision_code = 'APPROVED' then 1 else 0
    end;
  v_resulting_installation_version :=
    v_installation.version + case
      when v_decision_code = 'APPROVED' then 1 else 0
    end;

  v_decision_sha256 := public.atlas_normalization_sha256(
    jsonb_build_object(
      'schema_version', 'B2_PLATFORM_CONTROL_DECISION_V1',
      'installation_id', v_installation.id,
      'empresa_id', v_installation.empresa_id,
      'provisioning_plan_id', v_plan.id,
      'decision_type', 'PROVISIONING_ROLLBACK',
      'decision', v_decision_code,
      'from_state_code', v_installation.current_state_code,
      'target_state_code', 'ROLLED_BACK',
      'actor_user_id', v_actor_user_id,
      'actor_role_code', v_actor_role_code,
      'reason', btrim(p_reason),
      'evidence', p_evidence,
      'summary_sha256', v_summary_sha256,
      'request_id', p_request_id,
      'expected_installation_version',
        p_expected_installation_version,
      'resulting_installation_version',
        v_resulting_installation_version,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'resulting_plan_state_version',
        v_resulting_plan_state_version,
      'metadata', p_metadata
    )::text
  );

  insert into
    public.atlas_installation_platform_control_decisions (
      installation_id,
      empresa_id,
      provisioning_plan_id,
      decision_type,
      decision,
      from_state_code,
      target_state_code,
      actor_user_id,
      actor_role_code,
      reason,
      evidence,
      technical_summary,
      summary_sha256,
      decision_sha256,
      request_id,
      expected_installation_version,
      resulting_installation_version,
      expected_plan_state_version,
      resulting_plan_state_version,
      metadata
    )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_plan.id,
    'PROVISIONING_ROLLBACK',
    v_decision_code,
    v_installation.current_state_code,
    'ROLLED_BACK',
    v_actor_user_id,
    v_actor_role_code,
    btrim(p_reason),
    p_evidence,
    v_readiness,
    v_summary_sha256,
    v_decision_sha256,
    p_request_id,
    p_expected_installation_version,
    v_resulting_installation_version,
    p_expected_plan_state_version,
    v_resulting_plan_state_version,
    p_metadata
  )
  returning * into v_created;

  if v_decision_code = 'APPROVED' then
    update public.atlas_installation_provisioning_plans
    set
      plan_status = 'ROLLED_BACK',
      state_version = v_resulting_plan_state_version,
      started_at = coalesce(started_at, now()),
      completed_at = now(),
      metadata = metadata || jsonb_build_object(
        'rollback_decision_id', v_created.id,
        'rollback_decision_sha256', v_decision_sha256,
        'rollback_summary_sha256', v_summary_sha256,
        'rollback_approved_by_user_id', v_actor_user_id,
        'rollback_approved_at', now()
      ),
      updated_at = now()
    where id = v_plan.id
      and state_version = p_expected_plan_state_version
      and plan_status = 'ROLLBACK_REQUIRED';

    if not found then
      raise exception using
        errcode = '40001',
        message = 'PROVISIONING_PLAN_VERSION_CONFLICT';
    end if;

    select transition.transition_code
    into v_transition_code
    from public.atlas_installation_state_transitions as transition
    where transition.from_state_code =
      v_installation.current_state_code
      and transition.to_state_code = 'ROLLED_BACK'
      and transition.approval_scope = 'PLATFORM_CONTROL'
      and transition.active = true
    limit 1;

    if v_transition_code is null then
      raise exception using
        errcode = '42501',
        message =
          'ROLLBACK_PLATFORM_CONTROL_TRANSITION_NOT_CONFIGURED';
    end if;

    update public.atlas_installations
    set
      current_state_code = 'ROLLED_BACK',
      resume_state_code = null,
      version = v_resulting_installation_version,
      last_platform_control_decision_id = v_created.id,
      metadata = metadata || jsonb_build_object(
        'rollback_decision_id', v_created.id,
        'rollback_decision_sha256', v_decision_sha256,
        'rollback_summary_sha256', v_summary_sha256,
        'rolled_back_at', now()
      ),
      updated_at = now()
    where id = v_installation.id
      and version = p_expected_installation_version
      and current_state_code = 'PROVISIONING';

    if not found then
      raise exception using
        errcode = '40001',
        message = 'INSTALLATION_VERSION_CONFLICT';
    end if;

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
      v_installation.current_state_code,
      'ROLLED_BACK',
      v_actor_user_id,
      v_actor_role_code,
      btrim(p_reason),
      p_request_id,
      v_resulting_installation_version,
      jsonb_build_object(
        'platform_control_decision_id', v_created.id,
        'decision_sha256', v_decision_sha256,
        'summary_sha256', v_summary_sha256,
        'expected_version', p_expected_installation_version,
        'human_approval', true
      ),
      p_metadata
    );
  end if;

  insert into public.atlas_installation_provisioning_events (
    installation_id,
    empresa_id,
    provisioning_plan_id,
    entity_type,
    entity_id,
    event_code,
    from_status,
    to_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    evidence,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_plan.id,
    'PLAN',
    v_plan.id,
    case
      when v_decision_code = 'APPROVED'
        then 'PROVISIONING_ROLLBACK_APPROVED'
      else 'PROVISIONING_ROLLBACK_REJECTED'
    end,
    'ROLLBACK_REQUIRED',
    case
      when v_decision_code = 'APPROVED'
        then 'ROLLED_BACK'
      else 'ROLLBACK_REQUIRED'
    end,
    v_actor_user_id,
    v_actor_role_code,
    btrim(p_reason),
    p_request_id,
    jsonb_build_object(
      'platform_control_decision_id', v_created.id,
      'decision', v_decision_code,
      'decision_sha256', v_decision_sha256,
      'summary_sha256', v_summary_sha256,
      'human_approval', true,
      'resulting_plan_state_version',
        v_resulting_plan_state_version,
      'resulting_installation_version',
        v_resulting_installation_version
    ),
    p_metadata
  );

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
    'INSTALLATION_PROVISIONING_ROLLBACK_DECIDED',
    'B2_PLATFORM_CONTROL',
    case
      when v_decision_code = 'APPROVED'
        then 'COMPLETED'
      else 'REJECTED'
    end,
    jsonb_build_object(
      'provisioning_plan_id', v_plan.id,
      'request_id', p_request_id,
      'decision', v_decision_code,
      'expected_plan_state_version',
        p_expected_plan_state_version,
      'expected_installation_version',
        p_expected_installation_version
    ),
    jsonb_build_object(
      'platform_control_decision_id', v_created.id,
      'decision_sha256', v_decision_sha256,
      'summary_sha256', v_summary_sha256,
      'plan_status', case
        when v_decision_code = 'APPROVED'
          then 'ROLLED_BACK'
        else 'ROLLBACK_REQUIRED'
      end,
      'installation_state', case
        when v_decision_code = 'APPROVED'
          then 'ROLLED_BACK'
        else v_installation.current_state_code
      end
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_decision_code = 'APPROVED'
        then 'PROVISIONING_ROLLBACK_APPROVED_AND_CLOSED'
      else 'PROVISIONING_ROLLBACK_REJECTED'
    end,
    'decision_id', v_created.id,
    'decision', v_decision_code,
    'decision_sha256', v_decision_sha256,
    'summary_sha256', v_summary_sha256,
    'installation_id', v_installation.id,
    'provisioning_plan_id', v_plan.id,
    'installation_state', case
      when v_decision_code = 'APPROVED'
        then 'ROLLED_BACK'
      else v_installation.current_state_code
    end,
    'installation_version',
      v_resulting_installation_version,
    'plan_status', case
      when v_decision_code = 'APPROVED'
        then 'ROLLED_BACK'
      else 'ROLLBACK_REQUIRED'
    end,
    'plan_state_version', v_resulting_plan_state_version,
    'human_approval', true,
    'next_action', case
      when v_decision_code = 'APPROVED'
        then 'PRESERVE_ROLLBACK_EVIDENCE_AND_CLOSE_CASE'
      else 'REVIEW_ROLLBACK_EVIDENCE_AND_REMEDIATE'
    end
  );
end;
$$;

revoke all on function
public.atlas_decide_installation_provisioning_rollback(
  uuid, text, text, jsonb, uuid, bigint, bigint, jsonb
)
from public, anon, authenticated;
grant execute on function
public.atlas_decide_installation_provisioning_rollback(
  uuid, text, text, jsonb, uuid, bigint, bigint, jsonb
)
to authenticated, service_role;

comment on table
public.atlas_installation_platform_control_decisions is
  'B2: decisiones humanas append-only que sustentan transiciones terminales de control de plataforma.';

comment on column
public.atlas_installations.last_platform_control_decision_id is
  'B2: decision humana inmutable que autorizo la ultima transicion PLATFORM_CONTROL.';

comment on function
public.atlas_compute_installation_provisioning_rollback_readiness(uuid)
is
  'B2: calcula readiness objetivo y resumen tecnico sin secretos para cerrar rollback.';

comment on function
public.atlas_block_unapproved_platform_control() is
  'B2: solo permite transiciones PLATFORM_CONTROL ligadas a una decision humana APPROVED valida.';

comment on function
public.atlas_decide_installation_provisioning_rollback(
  uuid, text, text, jsonb, uuid, bigint, bigint, jsonb
) is
  'B2: ATLAS_OWNER aprueba o rechaza el cierre; APPROVED materializa plan e instalacion ROLLED_BACK atomicamente.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2G3C3_ROLLBACK_CLOSURE_HUMAN_APPROVAL_INSTALLED',
  'next_action',
    'CERTIFY_G3C3_HUMAN_APPROVAL_AND_TERMINAL_GUARDS',
  'platform_control_decision_records', (
    select count(*)
    from public.atlas_installation_platform_control_decisions
  ),
  'rollback_readiness_rpc_enabled',
    to_regprocedure(
      'public.atlas_compute_installation_provisioning_rollback_readiness(uuid)'
    ) is not null,
  'rollback_decision_rpc_enabled',
    to_regprocedure(
      'public.atlas_decide_installation_provisioning_rollback(uuid,text,text,jsonb,uuid,bigint,bigint,jsonb)'
    ) is not null,
  'human_approval_roles', (
    select count(*)
    from public.atlas_internal_role_permissions
    where permission_code = 'INSTALLATION_ROLLBACK_APPROVE'
      and role_code = 'ATLAS_OWNER'
  ),
  'append_only_decisions_enabled', true,
  'objective_readiness_enabled', true,
  'decision_hash_binding_enabled', true,
  'terminal_transition_requires_bound_decision', true,
  'rejection_preserves_open_rollback', true,
  'direct_authenticated_write', false,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id =
      'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id =
      'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  )
) as result;
