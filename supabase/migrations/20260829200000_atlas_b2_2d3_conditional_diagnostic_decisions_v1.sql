-- ATLAS B2.2D.3
-- Diagnostico gobernado y decisiones de requisitos condicionados.
-- Corte: 2026-08-29
--
-- Prerrequisito: B2.2D.2 instalado y certificado.
--
-- Invariantes:
-- - solo se deciden requisitos cuyo catalogo base es CONDITIONAL;
-- - cada decision cita condicion, fuente, evidencia, motivo y version;
-- - APPLIES convierte el requisito en REQUIRED;
-- - DOES_NOT_APPLY lo convierte en NOT_APPLICABLE;
-- - las decisiones son idempotentes, auditadas y append-only;
-- - SECURITY_VALIDATION no avanza con condiciones sin resolver.

begin;

do $$
begin
  if to_regprocedure(
    'public.atlas_register_installation_manifest(uuid,uuid,integer,uuid,jsonb,text,uuid,jsonb)'
  ) is null
     or to_regprocedure(
       'public.atlas_materialize_installation_inventory(uuid,uuid,uuid,jsonb)'
     ) is null
     or to_regclass(
       'public.atlas_installation_inventory_requirements'
     ) is null then
    raise exception 'B2.2D.3 requiere B2.2D.2 instalado y certificado';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_DIAGNOSTIC_READ',
    'Consultar decisiones y progreso del diagnostico de instalacion.'
  ),
  (
    'INSTALLATION_DIAGNOSTIC_DECIDE',
    'Resolver requisitos condicionados mediante RPC gobernada.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_DIAGNOSTIC_READ'),
  ('ATLAS_OWNER', 'INSTALLATION_DIAGNOSTIC_DECIDE'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_DIAGNOSTIC_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_DIAGNOSTIC_DECIDE'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_DIAGNOSTIC_READ'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_DIAGNOSTIC_READ')
on conflict (role_code, permission_code) do nothing;

create table if not exists public.atlas_installation_diagnostic_decisions (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  source_manifest_id uuid not null,
  requirement_id uuid not null,
  inventory_code text not null,
  condition_code text not null,
  decision_outcome text not null,
  decision_source text not null,
  from_requirement_mode text not null,
  to_requirement_mode text not null,
  from_fulfillment_status text not null,
  to_fulfillment_status text not null,
  decision_reason text not null,
  evidence jsonb not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  request_id uuid not null,
  prior_requirement_version integer not null,
  resulting_requirement_version integer not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_diagnostic_decisions_request_key
    unique (installation_id, request_id),
  constraint atlas_diagnostic_decisions_requirement_version_key
    unique (requirement_id, resulting_requirement_version),
  constraint atlas_diagnostic_decisions_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_diagnostic_decisions_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_diagnostic_decisions_manifest_fkey
    foreign key (source_manifest_id)
    references public.atlas_installation_manifests(id)
    on delete restrict,
  constraint atlas_diagnostic_decisions_requirement_fkey
    foreign key (requirement_id)
    references public.atlas_installation_inventory_requirements(id)
    on delete restrict,
  constraint atlas_diagnostic_decisions_inventory_fkey
    foreign key (inventory_code)
    references public.atlas_installation_inventory_definitions(inventory_code)
    on delete restrict,
  constraint atlas_diagnostic_decisions_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_diagnostic_decisions_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_diagnostic_decisions_condition_check
    check (condition_code ~ '^[A-Z][A-Z0-9_]*$'),
  constraint atlas_diagnostic_decisions_outcome_check
    check (decision_outcome in ('APPLIES', 'DOES_NOT_APPLY')),
  constraint atlas_diagnostic_decisions_source_check
    check (
      decision_source in (
        'CLIENT_DECLARATION',
        'CONTRACT',
        'CAPABILITY',
        'RISK_REVIEW'
      )
    ),
  constraint atlas_diagnostic_decisions_mode_check
    check (
      from_requirement_mode = 'CONDITIONAL'
      and to_requirement_mode in ('REQUIRED', 'NOT_APPLICABLE')
      and (
        (decision_outcome = 'APPLIES' and to_requirement_mode = 'REQUIRED')
        or (
          decision_outcome = 'DOES_NOT_APPLY'
          and to_requirement_mode = 'NOT_APPLICABLE'
        )
      )
    ),
  constraint atlas_diagnostic_decisions_fulfillment_check
    check (
      from_fulfillment_status = 'PENDING'
      and (
        (
          to_requirement_mode = 'REQUIRED'
          and to_fulfillment_status = 'PENDING'
        )
        or (
          to_requirement_mode = 'NOT_APPLICABLE'
          and to_fulfillment_status = 'NOT_APPLICABLE'
        )
      )
    ),
  constraint atlas_diagnostic_decisions_reason_check
    check (length(btrim(decision_reason)) >= 10),
  constraint atlas_diagnostic_decisions_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
      and nullif(btrim(evidence->>'condition_code'), '') is not null
      and nullif(btrim(evidence->>'source_reference'), '') is not null
    ),
  constraint atlas_diagnostic_decisions_versions_check
    check (
      prior_requirement_version >= 1
      and resulting_requirement_version = prior_requirement_version + 1
    ),
  constraint atlas_diagnostic_decisions_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_atlas_diagnostic_decisions_timeline
  on public.atlas_installation_diagnostic_decisions (
    installation_id,
    inventory_code,
    created_at desc
  );

create index if not exists idx_atlas_diagnostic_decisions_manifest
  on public.atlas_installation_diagnostic_decisions (
    source_manifest_id,
    decision_outcome
  );

create or replace function public.atlas_block_diagnostic_decision_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_DIAGNOSTIC_DECISIONS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_diagnostic_decision_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_diagnostic_decision_mutation()
  to service_role;

drop trigger if exists trg_atlas_diagnostic_decisions_append_only
  on public.atlas_installation_diagnostic_decisions;
create trigger trg_atlas_diagnostic_decisions_append_only
before update or delete
on public.atlas_installation_diagnostic_decisions
for each row execute function public.atlas_block_diagnostic_decision_mutation();

alter table public.atlas_installation_diagnostic_decisions
  enable row level security;

revoke all on table public.atlas_installation_diagnostic_decisions
  from anon, authenticated;
grant select on table public.atlas_installation_diagnostic_decisions
  to authenticated;
grant all on table public.atlas_installation_diagnostic_decisions
  to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_diagnostic_decisions'
      and policyname = 'atlas_diagnostic_decisions_read'
  ) then
    execute $policy$
      create policy atlas_diagnostic_decisions_read
        on public.atlas_installation_diagnostic_decisions
        for select to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

create or replace function public.atlas_decide_conditional_requirement(
  p_installation_id uuid,
  p_inventory_code text,
  p_decision_outcome text,
  p_decision_source text,
  p_decision_reason text,
  p_evidence jsonb,
  p_request_id uuid,
  p_expected_requirement_version integer,
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
  v_inventory_code text := upper(nullif(btrim(p_inventory_code), ''));
  v_outcome text := upper(nullif(btrim(p_decision_outcome), ''));
  v_source text := upper(nullif(btrim(p_decision_source), ''));
  v_reason text := nullif(btrim(p_decision_reason), '');
  v_installation public.atlas_installations%rowtype;
  v_requirement public.atlas_installation_inventory_requirements%rowtype;
  v_definition public.atlas_installation_inventory_definitions%rowtype;
  v_existing public.atlas_installation_diagnostic_decisions%rowtype;
  v_created public.atlas_installation_diagnostic_decisions%rowtype;
  v_manifest_id uuid;
  v_condition_code text;
  v_to_mode text;
  v_to_fulfillment text;
  v_determination_source text;
  v_total_conditional integer;
  v_resolved_conditional integer;
  v_remaining_conditional integer;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_DIAGNOSTIC_DECIDE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_DIAGNOSTIC_DECIDE_FORBIDDEN';
  end if;

  if p_installation_id is null
     or v_inventory_code is null
     or v_outcome is null
     or v_source is null
     or v_reason is null
     or length(v_reason) < 10
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb
     or p_request_id is null
     or p_expected_requirement_version is null
     or p_expected_requirement_version < 1
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'DIAGNOSTIC_DECISION_REQUIRED_FIELDS_MISSING';
  end if;

  if v_outcome not in ('APPLIES', 'DOES_NOT_APPLY') then
    raise exception using
      errcode = '22023',
      message = 'DIAGNOSTIC_DECISION_OUTCOME_INVALID';
  end if;

  if v_source not in (
    'CLIENT_DECLARATION',
    'CONTRACT',
    'CAPABILITY',
    'RISK_REVIEW'
  ) then
    raise exception using
      errcode = '22023',
      message = 'DIAGNOSTIC_DECISION_SOURCE_INVALID';
  end if;

  if nullif(btrim(p_evidence->>'condition_code'), '') is null
     or nullif(btrim(p_evidence->>'source_reference'), '') is null then
    raise exception using
      errcode = '22023',
      message = 'DIAGNOSTIC_DECISION_EVIDENCE_INCOMPLETE';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'DIAGNOSTIC_DECISION_CONTAINS_SECRET';
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

  select d.*
  into v_existing
  from public.atlas_installation_diagnostic_decisions as d
  where d.installation_id = v_installation.id
    and d.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.inventory_code <> v_inventory_code
       or v_existing.decision_outcome <> v_outcome
       or v_existing.decision_source <> v_source
       or v_existing.decision_reason <> v_reason
       or v_existing.evidence <> p_evidence
       or v_existing.metadata <> p_metadata
       or v_existing.prior_requirement_version <>
         p_expected_requirement_version then
      raise exception using
        errcode = '22023',
        message = 'DIAGNOSTIC_IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'installation_id', v_existing.installation_id,
      'decision_id', v_existing.id,
      'inventory_code', v_existing.inventory_code,
      'condition_code', v_existing.condition_code,
      'decision_outcome', v_existing.decision_outcome,
      'requirement_mode', v_existing.to_requirement_mode,
      'requirement_version', v_existing.resulting_requirement_version
    );
  end if;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_SECURITY_VALIDATION';
  end if;

  select m.id
  into v_manifest_id
  from public.atlas_installation_manifests as m
  where m.installation_id = v_installation.id
    and m.manifest_status in ('VALIDATED', 'APPROVED')
  order by m.package_version desc, m.created_at desc, m.id desc
  limit 1;

  if v_manifest_id is null then
    raise exception using
      errcode = '42501',
      message = 'DIAGNOSTIC_VALID_MANIFEST_REQUIRED';
  end if;

  select requirement.*
  into v_requirement
  from public.atlas_installation_inventory_requirements as requirement
  where requirement.installation_id = v_installation.id
    and requirement.inventory_code = v_inventory_code
  for update of requirement;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_INVENTORY_REQUIREMENT_NOT_FOUND';
  end if;

  select definition.*
  into v_definition
  from public.atlas_installation_inventory_definitions as definition
  where definition.inventory_code = v_requirement.inventory_code
    and definition.active = true;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'ACTIVE_INVENTORY_DEFINITION_NOT_FOUND';
  end if;

  if v_requirement.source_manifest_id <> v_manifest_id then
    raise exception using
      errcode = '40001',
      message = 'DIAGNOSTIC_INVENTORY_MANIFEST_CONFLICT';
  end if;

  if v_definition.default_requirement_mode <> 'CONDITIONAL'
     or nullif(
       btrim(v_definition.applicability_rule->>'condition'),
       ''
     ) is null then
    raise exception using
      errcode = '22023',
      message = 'INVENTORY_REQUIREMENT_IS_NOT_CONDITIONAL';
  end if;

  if v_requirement.requirement_mode <> 'CONDITIONAL'
     or v_requirement.fulfillment_status <> 'PENDING' then
    raise exception using
      errcode = '22023',
      message = 'CONDITIONAL_REQUIREMENT_ALREADY_RESOLVED';
  end if;

  if v_requirement.requirement_version <>
     p_expected_requirement_version then
    raise exception using
      errcode = '40001',
      message = 'INVENTORY_REQUIREMENT_VERSION_CONFLICT';
  end if;

  v_condition_code :=
    v_definition.applicability_rule->>'condition';

  if upper(p_evidence->>'condition_code') <> v_condition_code then
    raise exception using
      errcode = '22023',
      message = 'DIAGNOSTIC_CONDITION_CODE_MISMATCH';
  end if;

  if v_outcome = 'APPLIES' then
    v_to_mode := 'REQUIRED';
    v_to_fulfillment := 'PENDING';
  else
    v_to_mode := 'NOT_APPLICABLE';
    v_to_fulfillment := 'NOT_APPLICABLE';
  end if;

  v_determination_source := case v_source
    when 'CONTRACT' then 'CONTRACT'
    when 'CAPABILITY' then 'CAPABILITY'
    when 'RISK_REVIEW' then 'RISK_REVIEW'
    else 'DIAGNOSTIC'
  end;

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

  update public.atlas_installation_inventory_requirements
  set
    requirement_mode = v_to_mode,
    determination_reason = v_reason,
    determination_source = v_determination_source,
    fulfillment_status = v_to_fulfillment,
    requirement_version = requirement_version + 1,
    determined_by_user_id = v_actor_user_id,
    approved_by_user_id = null,
    approved_at = null,
    rule_snapshot = rule_snapshot || jsonb_build_object(
      'diagnostic_decision', jsonb_build_object(
        'condition_code', v_condition_code,
        'decision_outcome', v_outcome,
        'decision_source', v_source,
        'request_id', p_request_id,
        'decided_at', now()
      )
    ),
    metadata = metadata || p_metadata || jsonb_build_object(
      'latest_diagnostic_request_id', p_request_id
    )
  where id = v_requirement.id
  returning * into v_requirement;

  insert into public.atlas_installation_diagnostic_decisions (
    installation_id,
    empresa_id,
    source_manifest_id,
    requirement_id,
    inventory_code,
    condition_code,
    decision_outcome,
    decision_source,
    from_requirement_mode,
    to_requirement_mode,
    from_fulfillment_status,
    to_fulfillment_status,
    decision_reason,
    evidence,
    actor_user_id,
    actor_role_code,
    request_id,
    prior_requirement_version,
    resulting_requirement_version,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_manifest_id,
    v_requirement.id,
    v_requirement.inventory_code,
    v_condition_code,
    v_outcome,
    v_source,
    'CONDITIONAL',
    v_to_mode,
    'PENDING',
    v_to_fulfillment,
    v_reason,
    p_evidence,
    v_actor_user_id,
    v_actor_role_code,
    p_request_id,
    p_expected_requirement_version,
    v_requirement.requirement_version,
    p_metadata
  )
  returning * into v_created;

  insert into public.atlas_installation_inventory_events (
    installation_id,
    empresa_id,
    requirement_id,
    inventory_code,
    event_code,
    from_requirement_mode,
    to_requirement_mode,
    from_fulfillment_status,
    to_fulfillment_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    requirement_version,
    evidence,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_requirement.id,
    v_requirement.inventory_code,
    'CONDITIONAL_REQUIREMENT_DECIDED',
    'CONDITIONAL',
    v_to_mode,
    'PENDING',
    v_to_fulfillment,
    v_actor_user_id,
    v_actor_role_code,
    v_reason,
    p_request_id,
    v_requirement.requirement_version,
    p_evidence || jsonb_build_object(
      'diagnostic_decision_id', v_created.id,
      'decision_outcome', v_outcome,
      'decision_source', v_source
    ),
    p_metadata
  );

  select count(*)
  into v_total_conditional
  from public.atlas_installation_inventory_definitions
  where active = true
    and default_requirement_mode = 'CONDITIONAL';

  select
    count(*) filter (where requirement_mode <> 'CONDITIONAL'),
    count(*) filter (where requirement_mode = 'CONDITIONAL')
  into
    v_resolved_conditional,
    v_remaining_conditional
  from public.atlas_installation_inventory_requirements as requirement
  join public.atlas_installation_inventory_definitions as definition
    on definition.inventory_code = requirement.inventory_code
   and definition.active = true
   and definition.default_requirement_mode = 'CONDITIONAL'
  where requirement.installation_id = v_installation.id
    and requirement.source_manifest_id = v_manifest_id;

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
    'INSTALLATION_CONDITIONAL_REQUIREMENT_DECIDED',
    'B2_DIAGNOSTIC_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'inventory_code', v_inventory_code,
      'condition_code', v_condition_code,
      'decision_outcome', v_outcome,
      'decision_source', v_source
    ),
    jsonb_build_object(
      'decision_id', v_created.id,
      'requirement_mode', v_to_mode,
      'requirement_version', v_requirement.requirement_version,
      'resolved_conditional', v_resolved_conditional,
      'remaining_conditional', v_remaining_conditional
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'CONDITIONAL_REQUIREMENT_DECIDED',
    'installation_id', v_installation.id,
    'decision_id', v_created.id,
    'inventory_code', v_requirement.inventory_code,
    'condition_code', v_condition_code,
    'decision_outcome', v_outcome,
    'requirement_mode', v_to_mode,
    'fulfillment_status', v_to_fulfillment,
    'requirement_version', v_requirement.requirement_version,
    'total_conditional', v_total_conditional,
    'resolved_conditional', v_resolved_conditional,
    'remaining_conditional', v_remaining_conditional,
    'diagnostic_complete', v_remaining_conditional = 0
  );
end;
$$;

revoke all on function public.atlas_decide_conditional_requirement(
  uuid, text, text, text, text, jsonb, uuid, integer, jsonb
) from public, anon;
grant execute on function public.atlas_decide_conditional_requirement(
  uuid, text, text, text, text, jsonb, uuid, integer, jsonb
) to authenticated, service_role;

create or replace function public.atlas_enforce_security_file_completion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total_files bigint;
  v_unaccepted_files bigint;
  v_valid_manifest_count bigint;
  v_valid_manifest_id uuid;
  v_active_definition_count bigint;
  v_inventory_requirement_count bigint;
  v_unresolved_conditional_count bigint;
begin
  if old.current_state_code = 'SECURITY_VALIDATION'
     and new.current_state_code = 'LEGAL_REVIEW' then
    select
      count(*),
      count(*) filter (where f.validation_status <> 'ACCEPTED')
    into
      v_total_files,
      v_unaccepted_files
    from (
      select distinct on (
        source_file.logical_section,
        source_file.canonical_file_name
      )
        source_file.validation_status
      from public.atlas_installation_files as source_file
      where source_file.installation_id = old.id
      order by
        source_file.logical_section,
        source_file.canonical_file_name,
        source_file.file_version desc,
        source_file.created_at desc,
        source_file.id desc
    ) as f;

    if v_total_files = 0 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_FILES_REQUIRED';
    end if;

    if v_unaccepted_files > 0 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_UNACCEPTED_FILES_REMAIN',
        detail = jsonb_build_object(
          'current_files', v_total_files,
          'unaccepted_files', v_unaccepted_files
        )::text;
    end if;

    select
      count(*),
      (array_agg(
        m.id
        order by m.package_version desc, m.created_at desc, m.id desc
      ))[1]
    into
      v_valid_manifest_count,
      v_valid_manifest_id
    from public.atlas_installation_manifests as m
    where m.installation_id = old.id
      and m.manifest_status in ('VALIDATED', 'APPROVED')
      and not exists (
        select 1
        from public.atlas_installation_manifests as newer
        where newer.installation_id = m.installation_id
          and newer.package_id = m.package_id
          and newer.package_version > m.package_version
      );

    if v_valid_manifest_count <> 1 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_VALID_MANIFEST_REQUIRED';
    end if;

    select count(*)
    into v_active_definition_count
    from public.atlas_installation_inventory_definitions
    where active = true;

    select count(*)
    into v_inventory_requirement_count
    from public.atlas_installation_inventory_requirements as requirement
    join public.atlas_installation_inventory_definitions as definition
      on definition.inventory_code = requirement.inventory_code
     and definition.active = true
    where requirement.installation_id = old.id
      and requirement.source_manifest_id = v_valid_manifest_id;

    if v_inventory_requirement_count <> v_active_definition_count then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_INVENTORY_NOT_MATERIALIZED',
        detail = jsonb_build_object(
          'active_definitions', v_active_definition_count,
          'materialized_requirements', v_inventory_requirement_count
        )::text;
    end if;

    select count(*)
    into v_unresolved_conditional_count
    from public.atlas_installation_inventory_requirements as requirement
    join public.atlas_installation_inventory_definitions as definition
      on definition.inventory_code = requirement.inventory_code
     and definition.active = true
     and definition.default_requirement_mode = 'CONDITIONAL'
    where requirement.installation_id = old.id
      and requirement.source_manifest_id = v_valid_manifest_id
      and requirement.requirement_mode = 'CONDITIONAL';

    if v_unresolved_conditional_count > 0 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_CONDITIONAL_REQUIREMENTS_UNRESOLVED',
        detail = jsonb_build_object(
          'unresolved_conditional', v_unresolved_conditional_count
        )::text;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.atlas_enforce_security_file_completion()
  from public, anon, authenticated;
grant execute on function public.atlas_enforce_security_file_completion()
  to service_role;

comment on table public.atlas_installation_diagnostic_decisions is
  'B2: decisiones append-only que resuelven requisitos condicionados con evidencia.';

comment on function public.atlas_decide_conditional_requirement(
  uuid, text, text, text, text, jsonb, uuid, integer, jsonb
) is
  'B2: decide un requisito condicionado con fuente, evidencia, version e idempotencia.';

comment on function public.atlas_enforce_security_file_completion() is
  'B2: exige archivos, manifest, inventario y diagnostico condicionado completo antes de LEGAL_REVIEW.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2D3_CONDITIONAL_DIAGNOSTIC_INSTALLED',
  'next_action', 'CERTIFY_CONDITIONAL_DIAGNOSTIC_GUARDS',
  'diagnostic_decision_rpc_enabled', (
    to_regprocedure(
      'public.atlas_decide_conditional_requirement(uuid,text,text,text,text,jsonb,uuid,integer,jsonb)'
    ) is not null
  ),
  'diagnostic_decision_records', (
    select count(*)
    from public.atlas_installation_diagnostic_decisions
  ),
  'conditional_definitions', (
    select count(*)
    from public.atlas_installation_inventory_definitions
    where active = true
      and default_requirement_mode = 'CONDITIONAL'
  ),
  'diagnostic_permission_mappings', (
    select count(*)
    from public.atlas_internal_role_permissions
    where permission_code in (
      'INSTALLATION_DIAGNOSTIC_READ',
      'INSTALLATION_DIAGNOSTIC_DECIDE'
    )
  ),
  'decision_table_rls', (
    select c.relrowsecurity
    from pg_class as c
    where c.oid =
      'public.atlas_installation_diagnostic_decisions'::regclass
  ),
  'direct_authenticated_write', false,
  'security_exit_requires_resolved_conditions', true,
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
