-- ATLAS B2 conversation certification package and UAT handoff V1
-- Date: 2026-09-27
-- Creates an auditable technical certification package once B2 V2.1 readiness is complete.
-- It does NOT replace the historical installation certificate and does NOT self-approve UAT.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_compute_installation_g03_readiness_v21(uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_compute_conversation_certification_batch_summary_v1(uuid)'
     ) is null
     or to_regclass('public.atlas_conversation_test_scenario_plans') is null then
    raise exception
      'Conversation certification package requires G03 V2.1 and batch summary';
  end if;

  if to_regclass('public.atlas_conversation_certification_packages') is not null then
    raise exception
      'Conversation certification packages already exist; reconcile before install';
  end if;
end;
$$;

create table public.atlas_conversation_certification_packages (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  test_plan_id uuid not null,
  scenario_plan_id uuid not null,
  package_version integer not null,
  package_status text not null default 'READY_FOR_UAT',
  contract_version text not null,
  technical_readiness_sha256 text not null,
  conversation_evidence_root_sha256 text not null,
  package_payload jsonb not null,
  package_sha256 text not null,
  created_by_user_id uuid not null,
  request_id uuid not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_conversation_cert_package_request_key
    unique (installation_id, request_id),
  constraint atlas_conversation_cert_package_version_key
    unique (installation_id, package_version),
  constraint atlas_conversation_cert_package_identity_key
    unique (id, installation_id, empresa_id),

  constraint atlas_conversation_cert_package_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,

  constraint atlas_conversation_cert_package_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,

  constraint atlas_conversation_cert_package_test_plan_fkey
    foreign key (test_plan_id, installation_id, empresa_id)
    references public.atlas_installation_test_plans(
      id, installation_id, empresa_id
    )
    on delete restrict,

  constraint atlas_conversation_cert_package_scenario_plan_fkey
    foreign key (scenario_plan_id, test_plan_id, installation_id, empresa_id)
    references public.atlas_conversation_test_scenario_plans(
      id, test_plan_id, installation_id, empresa_id
    )
    on delete restrict,

  constraint atlas_conversation_cert_package_actor_fkey
    foreign key (created_by_user_id)
    references auth.users(id)
    on delete restrict,

  constraint atlas_conversation_cert_package_version_check
    check (
      package_version >= 1
      and contract_version = 'B2_CONVERSATION_CERTIFICATION_PACKAGE_V1'
    ),

  constraint atlas_conversation_cert_package_status_check
    check (package_status in ('READY_FOR_UAT','UAT_ACCEPTED','UAT_REJECTED','SUPERSEDED')),

  constraint atlas_conversation_cert_package_hashes_check
    check (
      technical_readiness_sha256 ~ '^[0-9a-f]{64}$'
      and conversation_evidence_root_sha256 ~ '^[0-9a-f]{64}$'
      and package_sha256 ~ '^[0-9a-f]{64}$'
    ),

  constraint atlas_conversation_cert_package_payload_check
    check (
      jsonb_typeof(package_payload) = 'object'
      and package_payload->>'contract_version' = contract_version
      and package_payload->>'installation_id' = installation_id::text
      and package_payload->>'empresa_id' = empresa_id::text
      and package_payload->>'test_plan_id' = test_plan_id::text
      and package_payload->>'scenario_plan_id' = scenario_plan_id::text
      and not public.atlas_jsonb_has_forbidden_secret_key(package_payload)
      and package_sha256 = public.atlas_normalization_sha256(package_payload::text)
    ),

  constraint atlas_conversation_cert_package_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index idx_atlas_conversation_cert_packages_installation
  on public.atlas_conversation_certification_packages(
    installation_id, package_version desc, created_at desc
  );

create or replace function
public.atlas_create_conversation_certification_package_v1(
  p_installation_id uuid,
  p_request_id uuid,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_installation public.atlas_installations%rowtype;
  v_g03 jsonb;
  v_scenario_plan public.atlas_conversation_test_scenario_plans%rowtype;
  v_summary jsonb;
  v_existing public.atlas_conversation_certification_packages%rowtype;
  v_created public.atlas_conversation_certification_packages%rowtype;
  v_version integer;
  v_payload jsonb;
  v_sha text;
begin
  if v_actor is null then
    raise exception using errcode='42501', message='AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TEST_READ') then
    raise exception using errcode='42501', message='INSTALLATION_TEST_READ_FORBIDDEN';
  end if;

  if p_installation_id is null
     or p_request_id is null
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object'
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using errcode='22023', message='CERTIFICATION_PACKAGE_INPUT_INVALID';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id;

  if not found then
    raise exception using errcode='P0002', message='INSTALLATION_NOT_FOUND';
  end if;

  select package.*
  into v_existing
  from public.atlas_conversation_certification_packages as package
  where package.installation_id = p_installation_id
    and package.request_id = p_request_id
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'package_id', v_existing.id,
      'package_status', v_existing.package_status,
      'package_sha256', v_existing.package_sha256
    );
  end if;

  v_g03 := public.atlas_compute_installation_g03_readiness_v21(p_installation_id);

  if not coalesce((v_g03->>'ready')::boolean, false)
     or v_g03->>'readiness_sha256' !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode='42501',
      message='CONVERSATION_TECHNICAL_CERTIFICATION_NOT_READY',
      detail=coalesce(v_g03->'blockers','[]'::jsonb)::text;
  end if;

  select scenario_plan.*
  into v_scenario_plan
  from public.atlas_conversation_test_scenario_plans as scenario_plan
  where scenario_plan.id = (v_g03->>'conversation_scenario_plan_id')::uuid
    and scenario_plan.installation_id = p_installation_id
    and scenario_plan.empresa_id = v_installation.empresa_id
  limit 1;

  if not found then
    raise exception using errcode='P0002', message='CONVERSATION_SCENARIO_PLAN_NOT_FOUND';
  end if;

  v_summary := public.atlas_compute_conversation_certification_batch_summary_v1(
    v_scenario_plan.id
  );

  if not coalesce((v_summary->>'ready')::boolean, false)
     or v_summary->>'evidence_root_sha256' !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='42501', message='CONVERSATION_BATCH_NOT_READY';
  end if;

  select coalesce(max(package.package_version),0)+1
  into v_version
  from public.atlas_conversation_certification_packages as package
  where package.installation_id = p_installation_id;

  v_payload := jsonb_build_object(
    'contract_version', 'B2_CONVERSATION_CERTIFICATION_PACKAGE_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'test_plan_id', (v_g03->>'test_plan_id')::uuid,
    'scenario_plan_id', v_scenario_plan.id,
    'package_version', v_version,
    'g03_contract_version', v_g03->>'contract_version',
    'technical_readiness_sha256', v_g03->>'readiness_sha256',
    'conversation_evidence_root_sha256', v_summary->>'evidence_root_sha256',
    'scenario_counts', jsonb_build_object(
      'total', v_summary->'total_scenarios',
      'applicable', v_summary->'applicable_scenarios',
      'passed', v_summary->'passed_scenarios',
      'failed', v_summary->'failed_scenarios',
      'blocked', v_summary->'blocked_scenarios',
      'skipped', v_summary->'skipped_scenarios'
    ),
    'uat_required', true,
    'uat_status', 'PENDING_HUMAN_REVIEW',
    'production_ready', false
  );

  v_sha := public.atlas_normalization_sha256(v_payload::text);

  insert into public.atlas_conversation_certification_packages(
    installation_id, empresa_id, test_plan_id, scenario_plan_id,
    package_version, package_status, contract_version,
    technical_readiness_sha256, conversation_evidence_root_sha256,
    package_payload, package_sha256, created_by_user_id, request_id, metadata
  ) values (
    v_installation.id, v_installation.empresa_id,
    (v_g03->>'test_plan_id')::uuid, v_scenario_plan.id,
    v_version, 'READY_FOR_UAT', 'B2_CONVERSATION_CERTIFICATION_PACKAGE_V1',
    v_g03->>'readiness_sha256', v_summary->>'evidence_root_sha256',
    v_payload, v_sha, v_actor, p_request_id, p_metadata
  ) returning * into v_created;

  return jsonb_build_object(
    'ok', true,
    'code', 'CONVERSATION_CERTIFICATION_PACKAGE_READY_FOR_UAT',
    'package_id', v_created.id,
    'package_version', v_created.package_version,
    'package_status', v_created.package_status,
    'package_sha256', v_created.package_sha256,
    'uat_required', true,
    'production_ready', false,
    'next_action', 'RUN_HUMAN_UAT'
  );
end;
$$;

revoke all on table public.atlas_conversation_certification_packages
from public, anon, authenticated;
revoke all on function
public.atlas_create_conversation_certification_package_v1(uuid,uuid,jsonb)
from public, anon, authenticated;

grant select on table public.atlas_conversation_certification_packages
to service_role;
grant execute on function
public.atlas_create_conversation_certification_package_v1(uuid,uuid,jsonb)
to service_role;

commit;