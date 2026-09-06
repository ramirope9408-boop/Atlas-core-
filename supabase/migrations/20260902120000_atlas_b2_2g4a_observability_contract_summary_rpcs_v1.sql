-- ATLAS B2.2G.4A
-- Contrato y RPCs base del modelo de observabilidad de aprovisionamiento.
-- Corte: 2026-09-02
--
-- Este bloque es exclusivamente de lectura. No crea snapshots duplicados,
-- no modifica planes ni instalaciones y no construye la interfaz visual.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_decide_installation_provisioning_rollback(uuid,text,text,jsonb,uuid,bigint,bigint,jsonb)'
     ) is null
     or to_regclass(
       'public.atlas_installation_platform_control_decisions'
     ) is null
     or to_regclass(
       'public.atlas_provisioning_operation_receipts'
     ) is null
     or to_regclass(
       'public.atlas_provisioned_resources'
     ) is null then
    raise exception
      'B2.2G.4A requiere B2.2G.3C.3 instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_map_provisioning_step_observability_status(
  p_step_status text,
  p_compensation_status text,
  p_attempt_count integer,
  p_max_attempts integer,
  p_last_error_code text
)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when upper(coalesce(p_compensation_status, '')) = 'COMPLETED'
         or upper(coalesce(p_step_status, '')) = 'COMPENSATED'
      then 'COMPENSATED'
    when upper(coalesce(p_step_status, '')) = 'SKIPPED'
      then 'SKIPPED'
    when upper(coalesce(p_step_status, '')) in (
           'EXECUTING', 'COMPENSATING'
         )
         or upper(coalesce(p_compensation_status, '')) = 'EXECUTING'
      then 'RUNNING'
    when upper(coalesce(p_step_status, '')) = 'FAILED'
         and coalesce(p_attempt_count, 0) <
           greatest(coalesce(p_max_attempts, 1), 1)
         and upper(coalesce(p_compensation_status, '')) <>
           'MANUAL_REVIEW'
         and nullif(btrim(p_last_error_code), '') is not null
      then 'RETRYING'
    when upper(coalesce(p_step_status, '')) = 'FAILED'
         or upper(coalesce(p_compensation_status, '')) in (
           'FAILED', 'MANUAL_REVIEW'
         )
      then 'FAILED'
    when upper(coalesce(p_step_status, '')) = 'SUCCEEDED'
      then 'SUCCEEDED'
    else 'PENDING'
  end;
$$;

revoke all on function
public.atlas_map_provisioning_step_observability_status(
  text, text, integer, integer, text
)
from public, anon, authenticated;
grant execute on function
public.atlas_map_provisioning_step_observability_status(
  text, text, integer, integer, text
)
to authenticated, service_role;

create or replace function
public.atlas_get_installation_provisioning_observability(
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
  v_plan public.atlas_installation_provisioning_plans%rowtype;
  v_total_steps bigint := 0;
  v_pending_steps bigint := 0;
  v_running_steps bigint := 0;
  v_succeeded_steps bigint := 0;
  v_failed_steps bigint := 0;
  v_retrying_steps bigint := 0;
  v_compensated_steps bigint := 0;
  v_skipped_steps bigint := 0;
  v_blocked_steps bigint := 0;
  v_manual_review_steps bigint := 0;
  v_terminal_steps bigint := 0;
  v_total_attempts bigint := 0;
  v_retry_count bigint := 0;
  v_resource_count bigint := 0;
  v_verified_resources bigint := 0;
  v_compensated_resources bigint := 0;
  v_receipt_count bigint := 0;
  v_failed_receipts bigint := 0;
  v_event_count bigint := 0;
  v_human_decision_count bigint := 0;
  v_progress_percent numeric(5,2) := 0;
  v_health_status text := 'PENDING';
  v_latest_error jsonb;
  v_latest_activity jsonb;
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

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.installation_id = v_installation.id
  order by plan.plan_version desc, plan.created_at desc, plan.id desc
  limit 1;

  if not found then
    return jsonb_build_object(
      'contract_version', 'B2_INSTALLATION_OBSERVABILITY_V1',
      'generated_at', now(),
      'installation', jsonb_build_object(
        'installation_id', v_installation.id,
        'empresa_id', v_installation.empresa_id,
        'state', v_installation.current_state_code,
        'version', v_installation.version,
        'updated_at', v_installation.updated_at
      ),
      'overall_status', 'PENDING',
      'health_status', 'PENDING',
      'progress_percent', 0,
      'plan', null,
      'step_counts', jsonb_build_object(
        'total', 0,
        'pending', 0,
        'running', 0,
        'succeeded', 0,
        'failed', 0,
        'retrying', 0,
        'compensated', 0,
        'skipped', 0
      ),
      'attempts', jsonb_build_object(
        'total', 0,
        'retries', 0
      ),
      'resources', jsonb_build_object(
        'total', 0,
        'verified', 0,
        'compensated', 0
      ),
      'activity', jsonb_build_object(
        'receipts', 0,
        'failed_receipts', 0,
        'events', 0,
        'human_decisions', 0,
        'latest', null
      ),
      'latest_error', null,
      'has_provisioning_plan', false
    );
  end if;

  with projected_steps as (
    select
      step.*,
      public.atlas_map_provisioning_step_observability_status(
        step.step_status,
        step.compensation_status,
        step.attempt_count,
        step.max_attempts,
        step.last_error_code
      ) as display_status
    from public.atlas_installation_provisioning_steps as step
    where step.provisioning_plan_id = v_plan.id
  )
  select
    count(*),
    count(*) filter (where display_status = 'PENDING'),
    count(*) filter (where display_status = 'RUNNING'),
    count(*) filter (where display_status = 'SUCCEEDED'),
    count(*) filter (where display_status = 'FAILED'),
    count(*) filter (where display_status = 'RETRYING'),
    count(*) filter (where display_status = 'COMPENSATED'),
    count(*) filter (where display_status = 'SKIPPED'),
    count(*) filter (where step_status = 'BLOCKED'),
    count(*) filter (
      where compensation_status = 'MANUAL_REVIEW'
    ),
    coalesce(sum(attempt_count), 0),
    coalesce(sum(greatest(attempt_count - 1, 0)), 0)
  into
    v_total_steps,
    v_pending_steps,
    v_running_steps,
    v_succeeded_steps,
    v_failed_steps,
    v_retrying_steps,
    v_compensated_steps,
    v_skipped_steps,
    v_blocked_steps,
    v_manual_review_steps,
    v_total_attempts,
    v_retry_count
  from projected_steps;

  v_terminal_steps :=
    v_succeeded_steps + v_compensated_steps + v_skipped_steps;

  v_progress_percent := case
    when v_total_steps = 0 then 0
    else round(
      (v_terminal_steps::numeric / v_total_steps::numeric) * 100,
      2
    )
  end;

  select
    count(*),
    count(*) filter (
      where resource.resource_status = 'VERIFIED'
    ),
    count(*) filter (
      where resource.resource_status = 'COMPENSATED'
    )
  into
    v_resource_count,
    v_verified_resources,
    v_compensated_resources
  from public.atlas_provisioned_resources as resource
  where resource.provisioning_plan_id = v_plan.id;

  select
    count(*),
    count(*) filter (where receipt.outcome = 'FAILED')
  into v_receipt_count, v_failed_receipts
  from public.atlas_provisioning_operation_receipts as receipt
  where receipt.provisioning_plan_id = v_plan.id;

  select count(*)
  into v_event_count
  from public.atlas_installation_provisioning_events as event_record
  where event_record.provisioning_plan_id = v_plan.id;

  select count(*)
  into v_human_decision_count
  from public.atlas_installation_platform_control_decisions as decision
  where decision.provisioning_plan_id = v_plan.id;

  select jsonb_build_object(
    'step_id', step.id,
    'step_code', step.step_code,
    'resource_code', step.resource_code,
    'error_code', step.last_error_code,
    'message_redacted', true,
    'occurred_at', step.updated_at
  )
  into v_latest_error
  from public.atlas_installation_provisioning_steps as step
  where step.provisioning_plan_id = v_plan.id
    and nullif(btrim(step.last_error_code), '') is not null
  order by step.updated_at desc, step.step_order desc
  limit 1;

  select jsonb_build_object(
    'activity_type', 'OPERATION_RECEIPT',
    'receipt_id', receipt.id,
    'step_code', receipt.step_code,
    'phase', receipt.operation_phase,
    'outcome', receipt.outcome,
    'executor_code', receipt.executor_code,
    'actor_role_code', receipt.actor_role_code,
    'evidence_reference',
      nullif(btrim(receipt.evidence->>'evidence_reference'), ''),
    'started_at', receipt.started_at,
    'completed_at', receipt.completed_at
  )
  into v_latest_activity
  from public.atlas_provisioning_operation_receipts as receipt
  where receipt.provisioning_plan_id = v_plan.id
  order by receipt.completed_at desc, receipt.created_at desc
  limit 1;

  v_health_status := case
    when v_failed_steps > 0
         or v_manual_review_steps > 0 then 'FAILED'
    when v_blocked_steps > 0 then 'BLOCKED'
    when v_running_steps > 0 then 'RUNNING'
    when v_retrying_steps > 0 then 'RETRYING'
    when v_total_steps > 0
         and v_terminal_steps = v_total_steps then 'SUCCEEDED'
    else 'PENDING'
  end;

  return jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_OBSERVABILITY_V1',
    'generated_at', now(),
    'installation', jsonb_build_object(
      'installation_id', v_installation.id,
      'empresa_id', v_installation.empresa_id,
      'state', v_installation.current_state_code,
      'version', v_installation.version,
      'updated_at', v_installation.updated_at
    ),
    'overall_status', case
      when v_installation.current_state_code = 'ROLLED_BACK'
        then 'COMPENSATED'
      when v_installation.current_state_code = 'FAILED'
        then 'FAILED'
      when v_plan.plan_status = 'COMPLETED'
        then 'SUCCEEDED'
      when v_plan.plan_status = 'ROLLED_BACK'
        then 'COMPENSATED'
      when v_plan.plan_status in ('EXECUTING', 'ROLLBACK_REQUIRED')
        then 'RUNNING'
      else v_health_status
    end,
    'health_status', v_health_status,
    'progress_percent', v_progress_percent,
    'has_provisioning_plan', true,
    'plan', jsonb_build_object(
      'plan_id', v_plan.id,
      'plan_version', v_plan.plan_version,
      'state_version', v_plan.state_version,
      'status', v_plan.plan_status,
      'package_id', v_plan.package_id,
      'package_version', v_plan.package_version,
      'plan_sha256', v_plan.plan_sha256,
      'started_at', v_plan.started_at,
      'completed_at', v_plan.completed_at,
      'duration_ms', case
        when v_plan.started_at is null then null
        else round(
          extract(epoch from (
            coalesce(v_plan.completed_at, now()) - v_plan.started_at
          )) * 1000
        )::bigint
      end
    ),
    'step_counts', jsonb_build_object(
      'total', v_total_steps,
      'pending', v_pending_steps,
      'running', v_running_steps,
      'succeeded', v_succeeded_steps,
      'failed', v_failed_steps,
      'retrying', v_retrying_steps,
      'compensated', v_compensated_steps,
      'skipped', v_skipped_steps,
      'blocked', v_blocked_steps,
      'manual_review', v_manual_review_steps
    ),
    'attempts', jsonb_build_object(
      'total', v_total_attempts,
      'retries', v_retry_count
    ),
    'resources', jsonb_build_object(
      'total', v_resource_count,
      'verified', v_verified_resources,
      'compensated', v_compensated_resources
    ),
    'activity', jsonb_build_object(
      'receipts', v_receipt_count,
      'failed_receipts', v_failed_receipts,
      'events', v_event_count,
      'human_decisions', v_human_decision_count,
      'latest', v_latest_activity
    ),
    'latest_error', v_latest_error
  );
end;
$$;

revoke all on function
public.atlas_get_installation_provisioning_observability(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_get_installation_provisioning_observability(uuid)
to authenticated, service_role;

create or replace function
public.atlas_list_installation_provisioning_step_observability(
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
  v_steps jsonb;
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
    jsonb_agg(step_projection.payload order by step_projection.step_order),
    '[]'::jsonb
  )
  into v_steps
  from (
    select
      step.step_order,
      jsonb_build_object(
        'step_id', step.id,
        'step_code', step.step_code,
        'resource_code', step.resource_code,
        'step_order', step.step_order,
        'required', step.required,
        'display_status',
          public.atlas_map_provisioning_step_observability_status(
            step.step_status,
            step.compensation_status,
            step.attempt_count,
            step.max_attempts,
            step.last_error_code
          ),
        'raw_status', step.step_status,
        'compensation_status', step.compensation_status,
        'state_version', step.state_version,
        'attempts', step.attempt_count,
        'max_attempts', step.max_attempts,
        'dependencies', to_jsonb(step.dependency_step_codes),
        'blocked', step.step_status = 'BLOCKED',
        'started_at', step.started_at,
        'completed_at', step.completed_at,
        'duration_ms', case
          when step.started_at is null then null
          else round(
            extract(epoch from (
              coalesce(step.completed_at, now()) - step.started_at
            )) * 1000
          )::bigint
        end,
        'error', case
          when nullif(btrim(step.last_error_code), '') is null
            then null
          else jsonb_build_object(
            'error_code', step.last_error_code,
            'message_available',
              nullif(btrim(step.last_error_message), '') is not null,
            'message_redacted', true
          )
        end,
        'evidence_reference',
          nullif(btrim(step.evidence->>'evidence_reference'), ''),
        'resource', case
          when resource.id is null then null
          else jsonb_build_object(
            'resource_id', resource.id,
            'status', resource.resource_status,
            'state_version', resource.state_version,
            'provisioned_at', resource.provisioned_at,
            'verified_at', resource.verified_at,
            'compensation_required_at',
              resource.compensation_required_at,
            'compensated_at', resource.compensated_at
          )
        end,
        'latest_attempt', latest_receipt.payload
      ) as payload
    from public.atlas_installation_provisioning_steps as step
    left join public.atlas_provisioned_resources as resource
      on resource.provisioning_step_id = step.id
     and resource.provisioning_plan_id = step.provisioning_plan_id
    left join lateral (
      select jsonb_build_object(
        'receipt_id', receipt.id,
        'phase', receipt.operation_phase,
        'attempt_number', receipt.attempt_number,
        'outcome', receipt.outcome,
        'executor_code', receipt.executor_code,
        'actor_role_code', receipt.actor_role_code,
        'evidence_reference',
          nullif(btrim(receipt.evidence->>'evidence_reference'), ''),
        'started_at', receipt.started_at,
        'completed_at', receipt.completed_at,
        'duration_ms', round(
          extract(epoch from (
            receipt.completed_at - receipt.started_at
          )) * 1000
        )::bigint
      ) as payload
      from public.atlas_provisioning_operation_receipts as receipt
      where receipt.provisioning_step_id = step.id
        and receipt.provisioning_plan_id = step.provisioning_plan_id
      order by receipt.completed_at desc, receipt.created_at desc
      limit 1
    ) as latest_receipt on true
    where step.provisioning_plan_id = v_plan.id
  ) as step_projection;

  return jsonb_build_object(
    'contract_version', 'B2_INSTALLATION_OBSERVABILITY_V1',
    'generated_at', now(),
    'installation_id', v_plan.installation_id,
    'empresa_id', v_plan.empresa_id,
    'provisioning_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'plan_state_version', v_plan.state_version,
    'steps', v_steps
  );
end;
$$;

revoke all on function
public.atlas_list_installation_provisioning_step_observability(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_list_installation_provisioning_step_observability(uuid)
to authenticated, service_role;

comment on function
public.atlas_map_provisioning_step_observability_status(
  text, text, integer, integer, text
) is
  'B2: mapea estados tecnicos a PENDING, RUNNING, SUCCEEDED, FAILED, RETRYING, COMPENSATED o SKIPPED.';

comment on function
public.atlas_get_installation_provisioning_observability(uuid) is
  'B2: resumen derivado de instalacion, plan, progreso, salud, intentos, recursos y actividad sin duplicar estado.';

comment on function
public.atlas_list_installation_provisioning_step_observability(uuid) is
  'B2: proyeccion por pasos, dependencias, tiempos, errores redactados, evidencias y ultimo intento.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2G4A_OBSERVABILITY_CONTRACT_SUMMARY_RPCS_INSTALLED',
  'next_action',
    'CERTIFY_G4A_OBSERVABILITY_CONTRACT_AND_READ_GUARDS',
  'contract_version', 'B2_INSTALLATION_OBSERVABILITY_V1',
  'observability_rpcs', 2,
  'status_mapping_function', true,
  'canonical_display_statuses', 7,
  'derived_progress_enabled', true,
  'derived_duration_enabled', true,
  'derived_retrying_enabled', true,
  'dependency_projection_enabled', true,
  'actor_and_executor_projection_enabled', true,
  'evidence_reference_projection_enabled', true,
  'raw_error_messages_exposed', false,
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
