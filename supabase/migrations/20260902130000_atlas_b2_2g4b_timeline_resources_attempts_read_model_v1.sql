-- ATLAS B2.2G.4B
-- Modelo de lectura de cronologia, recursos e intentos de aprovisionamiento.
-- Corte: 2026-09-02
--
-- Este bloque es exclusivamente de lectura. Deriva vistas seguras desde los
-- libros mayores canonicos; no crea snapshots ni modifica instalaciones.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_get_installation_provisioning_observability(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_list_installation_provisioning_step_observability(uuid)'
     ) is null
     or to_regclass(
       'public.atlas_provisioning_operation_receipts'
     ) is null
     or to_regclass(
       'public.atlas_provisioned_resources'
     ) is null
     or to_regclass(
       'public.atlas_installation_platform_control_decisions'
     ) is null then
    raise exception
      'B2.2G.4B requiere B2.2G.4A instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_list_installation_provisioning_timeline(
  p_provisioning_plan_id uuid,
  p_limit integer default 100,
  p_before_at timestamptz default null,
  p_before_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_items jsonb := '[]'::jsonb;
  v_has_more boolean := false;
  v_next_cursor jsonb;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_READ'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_OBSERVABILITY_READ_FORBIDDEN';
  end if;

  if p_provisioning_plan_id is null then
    raise exception using
      errcode = '22023', message = 'PROVISIONING_PLAN_ID_REQUIRED';
  end if;

  if p_limit is null or p_limit not between 1 and 200 then
    raise exception using
      errcode = '22023', message = 'OBSERVABILITY_PAGE_LIMIT_INVALID';
  end if;

  if (p_before_at is null) <> (p_before_id is null) then
    raise exception using
      errcode = '22023', message = 'OBSERVABILITY_CURSOR_INCOMPLETE';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = p_provisioning_plan_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  with unified_activity as (
    select
      event_record.id as activity_id,
      event_record.created_at as occurred_at,
      jsonb_build_object(
        'activity_id', event_record.id,
        'activity_type', 'STATE_EVENT',
        'occurred_at', event_record.created_at,
        'entity_type', event_record.entity_type,
        'entity_id', event_record.entity_id,
        'event_code', event_record.event_code,
        'from_status', event_record.from_status,
        'to_status', event_record.to_status,
        'actor', jsonb_build_object(
          'user_id', event_record.actor_user_id,
          'role_code', event_record.actor_role_code
        ),
        'reason_available',
          nullif(btrim(event_record.reason), '') is not null,
        'reason_redacted', true,
        'evidence_reference', nullif(
          btrim(event_record.evidence->>'evidence_reference'), ''
        )
      ) as payload
    from public.atlas_installation_provisioning_events as event_record
    where event_record.provisioning_plan_id = v_plan.id

    union all

    select
      preflight.id,
      preflight.created_at,
      jsonb_build_object(
        'activity_id', preflight.id,
        'activity_type', 'VALIDATION',
        'occurred_at', preflight.created_at,
        'check_code', preflight.check_code,
        'check_name', definition.display_name,
        'check_group', definition.check_group,
        'outcome', preflight.outcome,
        'severity', preflight.severity,
        'evaluation_version', preflight.evaluation_version,
        'evaluated_plan_state_version',
          preflight.evaluated_plan_state_version,
        'actor', jsonb_build_object(
          'user_id', preflight.evaluator_user_id,
          'role_code', preflight.evaluator_role_code
        ),
        'evidence_reference', nullif(
          btrim(preflight.evidence->>'evidence_reference'), ''
        )
      )
    from public.atlas_installation_preflight_results as preflight
    join public.atlas_provisioning_preflight_definitions as definition
      on definition.check_code = preflight.check_code
    where preflight.provisioning_plan_id = v_plan.id

    union all

    select
      receipt.id,
      receipt.completed_at,
      jsonb_build_object(
        'activity_id', receipt.id,
        'activity_type', 'ATTEMPT',
        'occurred_at', receipt.completed_at,
        'receipt_id', receipt.id,
        'step_id', receipt.provisioning_step_id,
        'step_code', receipt.step_code,
        'resource_code', receipt.resource_code,
        'phase', receipt.operation_phase,
        'attempt_number', receipt.attempt_number,
        'outcome', receipt.outcome,
        'executor_code', receipt.executor_code,
        'actor', jsonb_build_object(
          'user_id', receipt.actor_user_id,
          'role_code', receipt.actor_role_code
        ),
        'duration_ms', round(
          extract(epoch from (
            receipt.completed_at - receipt.started_at
          )) * 1000
        )::bigint,
        'error', case
          when receipt.error_code is null then null
          else jsonb_build_object(
            'error_code', receipt.error_code,
            'message_available',
              nullif(btrim(receipt.error_message), '') is not null,
            'message_redacted', true
          )
        end,
        'evidence_reference', nullif(
          btrim(receipt.evidence->>'evidence_reference'), ''
        )
      )
    from public.atlas_provisioning_operation_receipts as receipt
    where receipt.provisioning_plan_id = v_plan.id

    union all

    select
      decision.id,
      decision.decided_at,
      jsonb_build_object(
        'activity_id', decision.id,
        'activity_type', 'HUMAN_DECISION',
        'occurred_at', decision.decided_at,
        'decision_type', decision.decision_type,
        'decision', decision.decision,
        'from_state', decision.from_state_code,
        'target_state', decision.target_state_code,
        'actor', jsonb_build_object(
          'user_id', decision.actor_user_id,
          'role_code', decision.actor_role_code
        ),
        'reason_available',
          nullif(btrim(decision.reason), '') is not null,
        'reason_redacted', true,
        'evidence_reference', nullif(
          btrim(decision.evidence->>'evidence_reference'), ''
        ),
        'decision_sha256', decision.decision_sha256
      )
    from public.atlas_installation_platform_control_decisions as decision
    where decision.provisioning_plan_id = v_plan.id
  ),
  filtered_activity as (
    select activity.*
    from unified_activity as activity
    where p_before_at is null
       or (activity.occurred_at, activity.activity_id) <
          (p_before_at, p_before_id)
  ),
  ranked_activity as (
    select
      activity.*,
      row_number() over (
        order by activity.occurred_at desc, activity.activity_id desc
      ) as row_number
    from filtered_activity as activity
    order by activity.occurred_at desc, activity.activity_id desc
    limit p_limit + 1
  )
  select
    coalesce(
      jsonb_agg(
        activity.payload
        order by activity.occurred_at desc, activity.activity_id desc
      ) filter (where activity.row_number <= p_limit),
      '[]'::jsonb
    ),
    count(*) > p_limit
  into v_items, v_has_more
  from ranked_activity as activity;

  if v_has_more and jsonb_array_length(v_items) > 0 then
    v_next_cursor := jsonb_build_object(
      'before_at', v_items->-1->>'occurred_at',
      'before_id', v_items->-1->>'activity_id'
    );
  end if;

  return jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_OBSERVABILITY_V1',
    'generated_at', now(),
    'installation_id', v_plan.installation_id,
    'empresa_id', v_plan.empresa_id,
    'provisioning_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'page', jsonb_build_object(
      'limit', p_limit,
      'returned', jsonb_array_length(v_items),
      'has_more', v_has_more,
      'next_cursor', v_next_cursor
    ),
    'timeline', v_items
  );
end;
$$;

revoke all on function
public.atlas_list_installation_provisioning_timeline(
  uuid, integer, timestamptz, uuid
)
from public, anon, authenticated;
grant execute on function
public.atlas_list_installation_provisioning_timeline(
  uuid, integer, timestamptz, uuid
)
to authenticated, service_role;

create or replace function
public.atlas_list_installation_provisioned_resource_observability(
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
  v_resources jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_READ'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_OBSERVABILITY_READ_FORBIDDEN';
  end if;

  if p_provisioning_plan_id is null then
    raise exception using
      errcode = '22023', message = 'PROVISIONING_PLAN_ID_REQUIRED';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = p_provisioning_plan_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'resource_id', resource.id,
        'resource_code', resource.resource_code,
        'display_name', definition.display_name,
        'resource_group', definition.resource_group,
        'step_id', resource.provisioning_step_id,
        'step_code', resource.step_code,
        'step_order', step.step_order,
        'status', resource.resource_status,
        'state_version', resource.state_version,
        'target_kind', resource.target_kind,
        'dependencies', to_jsonb(step.dependency_step_codes),
        'configuration_sha256', resource.configuration_sha256,
        'resource_locator_exposed', false,
        'created_by_user_id', resource.created_by_user_id,
        'provisioned_at', resource.provisioned_at,
        'verified_at', resource.verified_at,
        'compensation_required_at',
          resource.compensation_required_at,
        'compensated_at', resource.compensated_at,
        'archived_at', resource.archived_at,
        'lifecycle_duration_ms', round(
          extract(epoch from (
            coalesce(
              resource.archived_at,
              resource.compensated_at,
              resource.verified_at,
              now()
            ) - resource.provisioned_at
          )) * 1000
        )::bigint,
        'verification', jsonb_build_object(
          'required', true,
          'satisfied', resource.verified_at is not null,
          'last_receipt_id', resource.last_receipt_id,
          'last_receipt_outcome', receipt.outcome,
          'executor_code', receipt.executor_code,
          'actor_role_code', receipt.actor_role_code,
          'evidence_reference', nullif(
            btrim(receipt.evidence->>'evidence_reference'), ''
          ),
          'completed_at', receipt.completed_at
        )
      )
      order by step.step_order, resource.id
    ),
    '[]'::jsonb
  )
  into v_resources
  from public.atlas_provisioned_resources as resource
  join public.atlas_installation_provisioning_steps as step
    on step.id = resource.provisioning_step_id
   and step.provisioning_plan_id = resource.provisioning_plan_id
  join public.atlas_provisioning_resource_definitions as definition
    on definition.resource_code = resource.resource_code
  join public.atlas_provisioning_operation_receipts as receipt
    on receipt.id = resource.last_receipt_id
  where resource.provisioning_plan_id = v_plan.id;

  return jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_OBSERVABILITY_V1',
    'generated_at', now(),
    'installation_id', v_plan.installation_id,
    'empresa_id', v_plan.empresa_id,
    'provisioning_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'resource_count', jsonb_array_length(v_resources),
    'resources', v_resources
  );
end;
$$;

revoke all on function
public.atlas_list_installation_provisioned_resource_observability(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_list_installation_provisioned_resource_observability(uuid)
to authenticated, service_role;

create or replace function
public.atlas_list_installation_provisioning_attempt_observability(
  p_provisioning_plan_id uuid,
  p_provisioning_step_id uuid default null,
  p_limit integer default 100,
  p_before_at timestamptz default null,
  p_before_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_items jsonb := '[]'::jsonb;
  v_has_more boolean := false;
  v_next_cursor jsonb;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_PROVISIONING_READ'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_OBSERVABILITY_READ_FORBIDDEN';
  end if;

  if p_provisioning_plan_id is null then
    raise exception using
      errcode = '22023', message = 'PROVISIONING_PLAN_ID_REQUIRED';
  end if;

  if p_limit is null or p_limit not between 1 and 200 then
    raise exception using
      errcode = '22023', message = 'OBSERVABILITY_PAGE_LIMIT_INVALID';
  end if;

  if (p_before_at is null) <> (p_before_id is null) then
    raise exception using
      errcode = '22023', message = 'OBSERVABILITY_CURSOR_INCOMPLETE';
  end if;

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.id = p_provisioning_plan_id;

  if not found then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_PLAN_NOT_FOUND';
  end if;

  if p_provisioning_step_id is not null
     and not exists (
       select 1
       from public.atlas_installation_provisioning_steps as step
       where step.id = p_provisioning_step_id
         and step.provisioning_plan_id = v_plan.id
     ) then
    raise exception using
      errcode = 'P0002', message = 'PROVISIONING_STEP_NOT_FOUND';
  end if;

  with filtered_attempts as (
    select receipt.*
    from public.atlas_provisioning_operation_receipts as receipt
    where receipt.provisioning_plan_id = v_plan.id
      and (
        p_provisioning_step_id is null
        or receipt.provisioning_step_id = p_provisioning_step_id
      )
      and (
        p_before_at is null
        or (receipt.completed_at, receipt.id) <
           (p_before_at, p_before_id)
      )
  ),
  ranked_attempts as (
    select
      receipt.*,
      row_number() over (
        order by receipt.completed_at desc, receipt.id desc
      ) as row_number
    from filtered_attempts as receipt
    order by receipt.completed_at desc, receipt.id desc
    limit p_limit + 1
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'receipt_id', receipt.id,
          'occurred_at', receipt.completed_at,
          'step_id', receipt.provisioning_step_id,
          'step_code', receipt.step_code,
          'resource_code', receipt.resource_code,
          'phase', receipt.operation_phase,
          'attempt_number', receipt.attempt_number,
          'outcome', receipt.outcome,
          'executor_code', receipt.executor_code,
          'actor', jsonb_build_object(
            'user_id', receipt.actor_user_id,
            'role_code', receipt.actor_role_code
          ),
          'input_sha256', receipt.input_sha256,
          'output_sha256', receipt.output_sha256,
          'started_at', receipt.started_at,
          'completed_at', receipt.completed_at,
          'duration_ms', round(
            extract(epoch from (
              receipt.completed_at - receipt.started_at
            )) * 1000
          )::bigint,
          'error', case
            when receipt.error_code is null then null
            else jsonb_build_object(
              'error_code', receipt.error_code,
              'message_available',
                nullif(btrim(receipt.error_message), '') is not null,
              'message_redacted', true
            )
          end,
          'evidence_reference', nullif(
            btrim(receipt.evidence->>'evidence_reference'), ''
          ),
          'target_reference_exposed', false,
          'result_payload_exposed', false
        )
        order by receipt.completed_at desc, receipt.id desc
      ) filter (where receipt.row_number <= p_limit),
      '[]'::jsonb
    ),
    count(*) > p_limit
  into v_items, v_has_more
  from ranked_attempts as receipt;

  if v_has_more and jsonb_array_length(v_items) > 0 then
    v_next_cursor := jsonb_build_object(
      'before_at', v_items->-1->>'occurred_at',
      'before_id', v_items->-1->>'receipt_id'
    );
  end if;

  return jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_OBSERVABILITY_V1',
    'generated_at', now(),
    'installation_id', v_plan.installation_id,
    'empresa_id', v_plan.empresa_id,
    'provisioning_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'step_filter', p_provisioning_step_id,
    'page', jsonb_build_object(
      'limit', p_limit,
      'returned', jsonb_array_length(v_items),
      'has_more', v_has_more,
      'next_cursor', v_next_cursor
    ),
    'attempts', v_items
  );
end;
$$;

revoke all on function
public.atlas_list_installation_provisioning_attempt_observability(
  uuid, uuid, integer, timestamptz, uuid
)
from public, anon, authenticated;
grant execute on function
public.atlas_list_installation_provisioning_attempt_observability(
  uuid, uuid, integer, timestamptz, uuid
)
to authenticated, service_role;

comment on function
public.atlas_list_installation_provisioning_timeline(
  uuid, integer, timestamptz, uuid
) is
  'B2: cronologia paginada de eventos, validaciones, intentos y decisiones humanas con datos sensibles redactados.';

comment on function
public.atlas_list_installation_provisioned_resource_observability(uuid) is
  'B2: inventario derivado de recursos aprovisionados, verificacion y evidencia sin exponer localizadores internos.';

comment on function
public.atlas_list_installation_provisioning_attempt_observability(
  uuid, uuid, integer, timestamptz, uuid
) is
  'B2: recibos e intentos paginados con hashes, actor, ejecutor, duracion, error sanitizado y evidencia.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2G4B_TIMELINE_RESOURCES_ATTEMPTS_READ_MODEL_INSTALLED',
  'next_action',
    'CERTIFY_G4B_TIMELINE_RESOURCES_ATTEMPTS_READ_GUARDS',
  'contract_version', 'B2_INSTALLATION_OBSERVABILITY_V1',
  'observability_detail_rpcs', 3,
  'timeline_sources', 4,
  'timeline_pagination_enabled', true,
  'attempt_pagination_enabled', true,
  'resource_verification_projection_enabled', true,
  'receipt_hash_lineage_projected', true,
  'raw_error_messages_exposed', false,
  'raw_reasons_exposed', false,
  'resource_locators_exposed', false,
  'target_references_exposed', false,
  'result_payloads_exposed', false,
  'snapshot_tables_created', 0,
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
