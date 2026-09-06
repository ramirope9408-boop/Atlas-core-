-- ATLAS B2.2G.4C
-- Evidencia de verificacion y preparacion para certificado de instalacion.
-- Corte: 2026-09-02
--
-- Este bloque deriva evidencia y bloqueadores. No emite certificados, no
-- aprueba G04 y no habilita ACTIVE. La emision permanece deshabilitada hasta
-- que existan integraciones, pruebas, aceptacion y autoridad G04 certificadas.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_list_installation_provisioning_timeline(uuid,integer,timestamptz,uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_list_installation_provisioned_resource_observability(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_list_installation_provisioning_attempt_observability(uuid,uuid,integer,timestamptz,uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regclass('public.atlas_installation_gates') is null then
    raise exception
      'B2.2G.4C requiere B2.2G.4B instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_get_installation_provisioning_verification_evidence(
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
  v_step_evidence jsonb := '[]'::jsonb;
  v_total_steps bigint := 0;
  v_required_steps bigint := 0;
  v_complete_steps bigint := 0;
  v_required_complete_steps bigint := 0;
  v_incomplete_steps bigint := 0;
  v_hash_bound_steps bigint := 0;
  v_evidence_referenced_steps bigint := 0;
  v_dedicated_verification_steps bigint := 0;
  v_ready boolean := false;
  v_evidence_root_sha256 text;
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

  with evidence_rows as (
    select
      step.id as step_id,
      step.step_code,
      step.step_order,
      step.resource_code,
      definition.display_name,
      definition.resource_group,
      step.operation_type,
      step.required,
      step.step_status,
      step.state_version as step_state_version,
      step.attempt_count,
      step.max_attempts,
      receipt.id as receipt_id,
      receipt.outcome as receipt_outcome,
      receipt.input_sha256 as receipt_input_sha256,
      receipt.output_sha256 as receipt_output_sha256,
      receipt.executor_code,
      receipt.actor_user_id,
      receipt.actor_role_code,
      receipt.completed_at as receipt_completed_at,
      nullif(
        btrim(receipt.evidence->>'evidence_reference'), ''
      ) as evidence_reference,
      resource.id as resource_id,
      resource.resource_status,
      resource.state_version as resource_state_version,
      resource.configuration_sha256,
      resource.last_receipt_id,
      resource.provisioned_at,
      resource.verified_at,
      coalesce(
        jsonb_array_length(
          definition.verification_contract->'asserts'
        ),
        0
      ) as expected_assertion_count,
      case
        when not step.required and step.step_status = 'SKIPPED'
          then true
        when step.step_status = 'SUCCEEDED'
          and receipt.id is not null
          and receipt.outcome = 'SUCCEEDED'
          and receipt.operation_phase = 'EXECUTION'
          and receipt.input_sha256 = step.input_sha256
          and receipt.output_sha256 is not null
          and nullif(
            btrim(receipt.evidence->>'evidence_reference'), ''
          ) is not null
          and resource.id is not null
          and resource.last_receipt_id = receipt.id
          and resource.configuration_sha256 = receipt.output_sha256
          and (
            step.operation_type <> 'VERIFY'
            or (
              resource.resource_status = 'VERIFIED'
              and resource.verified_at is not null
            )
          )
          then true
        else false
      end as evidence_complete,
      case
        when receipt.id is not null
          and receipt.input_sha256 = step.input_sha256
          and receipt.output_sha256 is not null
          and resource.id is not null
          and resource.last_receipt_id = receipt.id
          and resource.configuration_sha256 = receipt.output_sha256
          then true
        else false
      end as hash_bound,
      case
        when step.operation_type = 'VERIFY'
          and resource.resource_status = 'VERIFIED'
          and resource.verified_at is not null
          then true
        else false
      end as dedicated_verification
    from public.atlas_installation_provisioning_steps as step
    join public.atlas_provisioning_resource_definitions as definition
      on definition.resource_code = step.resource_code
    left join lateral (
      select operation_receipt.*
      from public.atlas_provisioning_operation_receipts
        as operation_receipt
      where operation_receipt.provisioning_plan_id =
          step.provisioning_plan_id
        and operation_receipt.provisioning_step_id = step.id
        and operation_receipt.operation_phase = 'EXECUTION'
      order by
        operation_receipt.attempt_number desc,
        operation_receipt.completed_at desc,
        operation_receipt.id desc
      limit 1
    ) as receipt on true
    left join public.atlas_provisioned_resources as resource
      on resource.provisioning_plan_id = step.provisioning_plan_id
     and resource.provisioning_step_id = step.id
    where step.provisioning_plan_id = v_plan.id
  )
  select
    count(*),
    count(*) filter (where required),
    count(*) filter (where evidence_complete),
    count(*) filter (where required and evidence_complete),
    count(*) filter (where not evidence_complete),
    count(*) filter (where hash_bound),
    count(*) filter (where evidence_reference is not null),
    count(*) filter (where dedicated_verification),
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'step_id', evidence.step_id,
          'step_code', evidence.step_code,
          'step_order', evidence.step_order,
          'resource_code', evidence.resource_code,
          'display_name', evidence.display_name,
          'resource_group', evidence.resource_group,
          'operation_type', evidence.operation_type,
          'required', evidence.required,
          'step_status', evidence.step_status,
          'step_state_version', evidence.step_state_version,
          'attempt_count', evidence.attempt_count,
          'max_attempts', evidence.max_attempts,
          'verification_status', case
            when evidence.evidence_complete
              and evidence.step_status = 'SKIPPED' then 'SKIPPED'
            when evidence.evidence_complete then 'VERIFIED'
            when evidence.step_status in ('COMPENSATED', 'COMPENSATING')
              then 'COMPENSATED'
            when evidence.step_status = 'FAILED' then 'FAILED'
            else 'INCOMPLETE'
          end,
          'evidence_complete', evidence.evidence_complete,
          'hash_bound', evidence.hash_bound,
          'verification_mode', case
            when evidence.dedicated_verification
              then 'DEDICATED_VERIFICATION_STEP'
            when evidence.hash_bound
              then 'EXECUTION_RECEIPT_RESOURCE_BINDING'
            when not evidence.required
              and evidence.step_status = 'SKIPPED'
              then 'AUTHORIZED_OPTIONAL_SKIP'
            else 'NONE'
          end,
          'expected_assertion_count',
            evidence.expected_assertion_count,
          'receipt', case
            when evidence.receipt_id is null then null
            else jsonb_build_object(
              'receipt_id', evidence.receipt_id,
              'outcome', evidence.receipt_outcome,
              'input_sha256', evidence.receipt_input_sha256,
              'output_sha256', evidence.receipt_output_sha256,
              'executor_code', evidence.executor_code,
              'actor_user_id', evidence.actor_user_id,
              'actor_role_code', evidence.actor_role_code,
              'completed_at', evidence.receipt_completed_at,
              'evidence_reference', evidence.evidence_reference
            )
          end,
          'resource', case
            when evidence.resource_id is null then null
            else jsonb_build_object(
              'resource_id', evidence.resource_id,
              'status', evidence.resource_status,
              'state_version', evidence.resource_state_version,
              'configuration_sha256',
                evidence.configuration_sha256,
              'last_receipt_id', evidence.last_receipt_id,
              'provisioned_at', evidence.provisioned_at,
              'verified_at', evidence.verified_at,
              'resource_locator_exposed', false
            )
          end
        )
        order by evidence.step_order
      ),
      '[]'::jsonb
    )
  into
    v_total_steps,
    v_required_steps,
    v_complete_steps,
    v_required_complete_steps,
    v_incomplete_steps,
    v_hash_bound_steps,
    v_evidence_referenced_steps,
    v_dedicated_verification_steps,
    v_step_evidence
  from evidence_rows as evidence;

  v_ready :=
    v_plan.plan_status = 'COMPLETED'
    and v_required_steps > 0
    and v_required_complete_steps = v_required_steps
    and not exists (
      select 1
      from public.atlas_installation_provisioning_steps as step
      where step.provisioning_plan_id = v_plan.id
        and step.required = true
        and step.step_status <> 'SUCCEEDED'
    );

  if jsonb_array_length(v_step_evidence) > 0 then
    v_evidence_root_sha256 :=
      public.atlas_normalization_sha256(v_step_evidence::text);
  end if;

  return jsonb_build_object(
    'evidence_contract_version', 'B2_PROVISIONING_EVIDENCE_V1',
    'generated_at', now(),
    'installation_id', v_plan.installation_id,
    'empresa_id', v_plan.empresa_id,
    'provisioning_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version,
    'plan_state_version', v_plan.state_version,
    'plan_status', v_plan.plan_status,
    'plan_sha256', v_plan.plan_sha256,
    'provisioning_evidence_ready', v_ready,
    'evidence_root_sha256', v_evidence_root_sha256,
    'counts', jsonb_build_object(
      'total_steps', v_total_steps,
      'required_steps', v_required_steps,
      'complete_steps', v_complete_steps,
      'required_complete_steps', v_required_complete_steps,
      'incomplete_steps', v_incomplete_steps,
      'hash_bound_steps', v_hash_bound_steps,
      'evidence_referenced_steps', v_evidence_referenced_steps,
      'dedicated_verification_steps',
        v_dedicated_verification_steps
    ),
    'steps', v_step_evidence,
    'raw_payloads_exposed', false,
    'raw_error_messages_exposed', false,
    'resource_locators_exposed', false
  );
end;
$$;

revoke all on function
public.atlas_get_installation_provisioning_verification_evidence(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_get_installation_provisioning_verification_evidence(uuid)
to authenticated, service_role;

create or replace function
public.atlas_get_installation_certificate_readiness(
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
  v_provisioning_evidence jsonb;
  v_gate_statuses jsonb := '{}'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_provisioning_ready boolean := false;
  v_integration_stage_reached boolean := false;
  v_testing_stage_reached boolean := false;
  v_final_approval_stage_reached boolean := false;
  v_g04_approved boolean := false;
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

  select coalesce(
    jsonb_object_agg(
      gate_record.gate_code,
      jsonb_build_object(
        'status', gate_record.status,
        'gate_version', gate_record.gate_version,
        'platform_approved', gate_record.platform_approved,
        'client_approved', gate_record.client_approved,
        'approved_at', gate_record.approved_at
      )
      order by gate_record.gate_code
    ),
    '{}'::jsonb
  )
  into v_gate_statuses
  from public.atlas_installation_gates as gate_record
  where gate_record.installation_id = v_installation.id;

  v_g04_approved :=
    coalesce(v_gate_statuses->'G04'->>'status', '') = 'APPROVED'
    and coalesce(
      (v_gate_statuses->'G04'->>'platform_approved')::boolean,
      false
    )
    and coalesce(
      (v_gate_statuses->'G04'->>'client_approved')::boolean,
      false
    );

  select plan.*
  into v_plan
  from public.atlas_installation_provisioning_plans as plan
  where plan.installation_id = v_installation.id
  order by plan.plan_version desc, plan.created_at desc, plan.id desc
  limit 1;

  if found then
    v_provisioning_evidence :=
      public.atlas_get_installation_provisioning_verification_evidence(
        v_plan.id
      );
    v_provisioning_ready := coalesce(
      (
        v_provisioning_evidence->>
          'provisioning_evidence_ready'
      )::boolean,
      false
    );
  else
    v_provisioning_evidence := null;
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'PROVISIONING_PLAN_MISSING',
        'domain', 'PROVISIONING',
        'blocking', true
      )
    );
  end if;

  if not v_provisioning_ready then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'PROVISIONING_EVIDENCE_INCOMPLETE',
        'domain', 'PROVISIONING',
        'blocking', true
      )
    );
  end if;

  v_integration_stage_reached :=
    v_installation.current_state_code in (
      'INTEGRATION_SETUP', 'TESTING', 'FINAL_APPROVAL',
      'ACTIVE', 'OBSERVED'
    );
  v_testing_stage_reached :=
    v_installation.current_state_code in (
      'TESTING', 'FINAL_APPROVAL', 'ACTIVE', 'OBSERVED'
    );
  v_final_approval_stage_reached :=
    v_installation.current_state_code in (
      'FINAL_APPROVAL', 'ACTIVE', 'OBSERVED'
    );

  if not v_integration_stage_reached then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'INTEGRATION_SETUP_NOT_REACHED',
        'domain', 'INTEGRATION',
        'blocking', true
      )
    );
  end if;

  if not v_testing_stage_reached then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'TESTING_NOT_REACHED',
        'domain', 'TESTING',
        'blocking', true
      )
    );
  end if;

  if not v_final_approval_stage_reached then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'FINAL_APPROVAL_NOT_REACHED',
        'domain', 'GOVERNANCE',
        'blocking', true
      )
    );
  end if;

  if not v_g04_approved then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'G04_NOT_APPROVED',
        'domain', 'GOVERNANCE',
        'blocking', true
      )
    );
  end if;

  v_blockers := v_blockers || jsonb_build_array(
    jsonb_build_object(
      'code', 'INTEGRATION_EVIDENCE_ENGINE_PENDING',
      'domain', 'INTEGRATION',
      'blocking', true
    ),
    jsonb_build_object(
      'code', 'TEST_EVIDENCE_ENGINE_PENDING',
      'domain', 'TESTING',
      'blocking', true
    ),
    jsonb_build_object(
      'code', 'CLIENT_ACCEPTANCE_ENGINE_PENDING',
      'domain', 'ACCEPTANCE',
      'blocking', true
    ),
    jsonb_build_object(
      'code', 'CERTIFICATE_ISSUANCE_NOT_ENABLED',
      'domain', 'CERTIFICATE',
      'blocking', true
    )
  );

  if v_installation.current_state_code in (
    'ROLLED_BACK', 'CANCELLED', 'FAILED'
  ) then
    v_blockers := v_blockers || jsonb_build_array(
      jsonb_build_object(
        'code', 'INSTALLATION_NOT_CERTIFIABLE_IN_CURRENT_STATE',
        'domain', 'INSTALLATION',
        'blocking', true
      )
    );
  end if;

  return jsonb_build_object(
    'readiness_contract_version',
      'B2_INSTALLATION_CERTIFICATE_READINESS_V1',
    'generated_at', now(),
    'installation', jsonb_build_object(
      'installation_id', v_installation.id,
      'installation_code', v_installation.installation_code,
      'empresa_id', v_installation.empresa_id,
      'state', v_installation.current_state_code,
      'version', v_installation.version,
      'manifest_version', v_installation.manifest_version,
      'implementation_tier', v_installation.implementation_tier
    ),
    'certificate_ready', false,
    'certificate_issuance_enabled', false,
    'readiness_scope', 'PRE_CERTIFICATE_TECHNICAL_EVIDENCE',
    'provisioning_evidence_ready', v_provisioning_ready,
    'stage_markers', jsonb_build_object(
      'integration_setup_reached', v_integration_stage_reached,
      'testing_reached', v_testing_stage_reached,
      'final_approval_reached', v_final_approval_stage_reached,
      'g04_approved', v_g04_approved
    ),
    'gate_statuses', v_gate_statuses,
    'provisioning_evidence', v_provisioning_evidence,
    'blocking_count', jsonb_array_length(v_blockers),
    'blockers', v_blockers,
    'pending_domains', jsonb_build_array(
      'INTEGRATION_EVIDENCE',
      'TEST_EVIDENCE',
      'CLIENT_ACCEPTANCE',
      'G04_FINAL_APPROVAL',
      'CERTIFICATE_ISSUANCE'
    ),
    'secrets_exposed', false
  );
end;
$$;

revoke all on function
public.atlas_get_installation_certificate_readiness(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_get_installation_certificate_readiness(uuid)
to authenticated, service_role;

comment on function
public.atlas_get_installation_provisioning_verification_evidence(uuid) is
  'B2: deriva evidencia por paso mediante recibos, hashes y recursos enlazados; no confunde ejecucion con verificacion.';

comment on function
public.atlas_get_installation_certificate_readiness(uuid) is
  'B2: informa preparacion precertificado y bloqueadores; no emite certificado, no aprueba G04 y no habilita ACTIVE.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2G4C_VERIFICATION_EVIDENCE_CERTIFICATE_READINESS_INSTALLED',
  'next_action',
    'CERTIFY_G4C_EVIDENCE_AND_PRECERTIFICATE_GUARDS',
  'provisioning_evidence_contract_version',
    'B2_PROVISIONING_EVIDENCE_V1',
  'certificate_readiness_contract_version',
    'B2_INSTALLATION_CERTIFICATE_READINESS_V1',
  'readiness_rpcs', 2,
  'receipt_resource_hash_binding_enabled', true,
  'required_step_evidence_enforced', true,
  'evidence_root_sha256_enabled', true,
  'dedicated_verification_steps_recognized', true,
  'certificate_issuance_enabled', false,
  'g04_auto_approval_enabled', false,
  'active_auto_transition_enabled', false,
  'downstream_evidence_domains_pending', 5,
  'raw_payloads_exposed', false,
  'raw_error_messages_exposed', false,
  'resource_locators_exposed', false,
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
