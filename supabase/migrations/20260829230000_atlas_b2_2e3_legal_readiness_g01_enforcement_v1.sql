-- ATLAS B2.2E.3
-- Alistamiento juridico verificable y enforcement objetivo de G01.
-- Corte: 2026-08-29
--
-- Principios:
-- - G01 no se aprueba con casillas declarativas sin respaldo;
-- - contratos, versiones, firmas y objetos se verifican desde fuentes canonicas;
-- - identidad, terceros, condicion financiera y riesgos requieren decision
--   profesional append-only con evidencia y vigencia;
-- - solo ATLAS_LEGAL_REVIEWER puede emitir esas decisiones y aprobar G01;
-- - el alistamiento se revalida al aprobar el gate y al entrar a LEGAL_APPROVED.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_contracts') is null
     or to_regclass('public.atlas_installation_contract_events') is null
     or to_regclass('public.atlas_installation_gates') is null
     or to_regclass('public.atlas_installation_approvals') is null
     or to_regclass('public.atlas_installation_manifests') is null
     or to_regprocedure(
       'public.atlas_sign_installation_contract(uuid,uuid,uuid,text,text,timestamptz,text,jsonb,uuid,integer,jsonb)'
     ) is null then
    raise exception 'B2.2E.3 requiere B2.2A-E.2 instalado y certificado';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_LEGAL_READINESS_READ',
    'Consultar el alistamiento juridico objetivo de G01.'
  ),
  (
    'INSTALLATION_LEGAL_READINESS_DECIDE',
    'Emitir decisiones profesionales de alistamiento juridico para G01.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_LEGAL_READINESS_READ'),
  ('ATLAS_IMPLEMENTATION_OPERATOR', 'INSTALLATION_LEGAL_READINESS_READ'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_LEGAL_READINESS_READ'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_LEGAL_READINESS_DECIDE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_LEGAL_READINESS_READ')
on conflict (role_code, permission_code) do nothing;

create table if not exists
public.atlas_installation_legal_readiness_decisions (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  criterion_code text not null,
  decision text not null,
  reason text not null,
  evidence jsonb not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  request_id uuid not null,
  criterion_version bigint not null,
  expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_legal_readiness_decisions_request_key
    unique (installation_id, request_id),
  constraint atlas_legal_readiness_decisions_version_key
    unique (installation_id, criterion_code, criterion_version),
  constraint atlas_legal_readiness_decisions_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_legal_readiness_decisions_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_legal_readiness_decisions_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_legal_readiness_decisions_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_legal_readiness_decisions_criterion_check
    check (
      criterion_code in (
        'COMPANY_IDENTITY_VERIFIED',
        'THIRD_PARTIES_IDENTIFIED',
        'INITIAL_FINANCIAL_STATUS_VALID',
        'LEGAL_RISKS_RESOLVED'
      )
    ),
  constraint atlas_legal_readiness_decisions_decision_check
    check (decision in ('SATISFIED', 'BLOCKED')),
  constraint atlas_legal_readiness_decisions_reason_check
    check (length(btrim(reason)) >= 10),
  constraint atlas_legal_readiness_decisions_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
      and nullif(btrim(evidence->>'evidence_reference'), '') is not null
      and not public.atlas_jsonb_has_forbidden_secret_key(evidence)
    ),
  constraint atlas_legal_readiness_decisions_role_check
    check (actor_role_code = 'ATLAS_LEGAL_REVIEWER'),
  constraint atlas_legal_readiness_decisions_version_check_value
    check (criterion_version >= 1),
  constraint atlas_legal_readiness_decisions_expiry_check
    check (expires_at is null or expires_at > created_at),
  constraint atlas_legal_readiness_decisions_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

create index if not exists idx_atlas_legal_readiness_latest
  on public.atlas_installation_legal_readiness_decisions (
    installation_id,
    criterion_code,
    criterion_version desc
  );

create or replace function
public.atlas_block_legal_readiness_decision_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_LEGAL_READINESS_DECISIONS_APPEND_ONLY';
end;
$$;

revoke all on function
public.atlas_block_legal_readiness_decision_mutation()
  from public, anon, authenticated;
grant execute on function
public.atlas_block_legal_readiness_decision_mutation()
  to service_role;

drop trigger if exists trg_atlas_legal_readiness_decisions_append_only
  on public.atlas_installation_legal_readiness_decisions;
create trigger trg_atlas_legal_readiness_decisions_append_only
before update or delete
on public.atlas_installation_legal_readiness_decisions
for each row execute function
public.atlas_block_legal_readiness_decision_mutation();

alter table public.atlas_installation_legal_readiness_decisions
  enable row level security;

revoke all on table public.atlas_installation_legal_readiness_decisions
  from anon, authenticated;
grant select on table public.atlas_installation_legal_readiness_decisions
  to authenticated;
grant all on table public.atlas_installation_legal_readiness_decisions
  to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_legal_readiness_decisions'
      and policyname = 'atlas_legal_readiness_decisions_read'
  ) then
    execute $policy$
      create policy atlas_legal_readiness_decisions_read
        on public.atlas_installation_legal_readiness_decisions
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

create or replace function
public.atlas_compute_installation_g01_readiness(
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
  v_manifest public.atlas_installation_manifests%rowtype;
  v_manifest_valid boolean := false;
  v_owner_authorized boolean := false;
  v_documents jsonb := '{}'::jsonb;
  v_identity_attested boolean := false;
  v_third_parties_attested boolean := false;
  v_financial_attested boolean := false;
  v_risks_attested boolean := false;
  v_company_identity_verified boolean := false;
  v_service_order_approved boolean := false;
  v_main_contract_signed boolean := false;
  v_required_annexes_present boolean := false;
  v_data_channel_authorizations boolean := false;
  v_third_parties_identified boolean := false;
  v_initial_financial_valid boolean := false;
  v_legal_risks_resolved boolean := false;
  v_ready boolean := false;
  v_g01_definition_count bigint := 0;
  v_resolved_document_count bigint := 0;
  v_signed_document_count bigint := 0;
  v_blockers jsonb := '[]'::jsonb;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'ready', false
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_NOT_FOUND',
      'installation_id', p_installation_id,
      'ready', false
    );
  end if;

  select manifest.*
  into v_manifest
  from public.atlas_installation_manifests as manifest
  where manifest.installation_id = v_installation.id
    and manifest.manifest_status in ('VALIDATED', 'APPROVED')
    and not exists (
      select 1
      from public.atlas_installation_manifests as newer_manifest
      where newer_manifest.installation_id = manifest.installation_id
        and newer_manifest.package_id = manifest.package_id
        and newer_manifest.package_version > manifest.package_version
    )
  order by
    manifest.package_version desc,
    manifest.created_at desc,
    manifest.id desc
  limit 1;

  if found then
    v_manifest_valid := exists (
      select 1
      from public.atlas_installation_files as source_file
      join storage.objects as storage_object
        on storage_object.bucket_id = source_file.storage_bucket
       and storage_object.name = source_file.storage_object_path
       and storage_object.archived_at is null
       and storage_object.is_delete_marker = false
      where source_file.id = v_manifest.source_file_id
        and source_file.installation_id = v_installation.id
        and source_file.validation_status = 'ACCEPTED'
        and source_file.sha256 = v_manifest.manifest_sha256
        and not exists (
          select 1
          from public.atlas_installation_files as newer_file
          where newer_file.installation_id = source_file.installation_id
            and newer_file.logical_section = source_file.logical_section
            and newer_file.canonical_file_name =
              source_file.canonical_file_name
            and (
              newer_file.file_version > source_file.file_version
              or (
                newer_file.file_version = source_file.file_version
                and newer_file.created_at > source_file.created_at
              )
            )
        )
    );

    v_owner_authorized := v_manifest_valid
      and v_installation.client_owner_user_id is not null
      and v_manifest.manifest_payload->'owner'->>'identity_reference' =
        v_installation.client_owner_user_id::text
      and v_manifest.manifest_payload->'owner'->>'authorization_status' =
        'APPROVED'
      and exists (
        select 1
        from public.atlas_internal_memberships as membership
        where membership.empresa_id = v_installation.empresa_id
          and membership.user_id = v_installation.client_owner_user_id
          and membership.role_code = 'OWNER'
          and membership.status = 'ACTIVE'
      );
  end if;

  select
    count(*),
    coalesce(
      jsonb_object_agg(
        definition.document_code,
        jsonb_build_object(
          'definition_applicability', definition.default_applicability,
          'contract_id', latest_contract.id,
          'document_version', latest_contract.document_version,
          'applicability_status', latest_contract.applicability_status,
          'lifecycle_status', latest_contract.lifecycle_status,
          'professional_review_status',
            latest_contract.professional_review_status,
          'resolved', coalesce(latest_contract.resolved, false),
          'signed_and_current',
            coalesce(latest_contract.signed_and_current, false)
        )
      ),
      '{}'::jsonb
    ),
    count(*) filter (
      where coalesce(latest_contract.resolved, false)
    ),
    count(*) filter (
      where coalesce(latest_contract.signed_and_current, false)
    )
  into
    v_g01_definition_count,
    v_documents,
    v_resolved_document_count,
    v_signed_document_count
  from public.atlas_legal_document_definitions as definition
  left join lateral (
    select
      contract.id,
      contract.document_version,
      contract.applicability_status,
      contract.lifecycle_status,
      contract.professional_review_status,
      (
        contract.applicability_status = 'REQUIRED'
        and contract.lifecycle_status = 'SIGNED'
        and contract.professional_review_status = 'APPROVED'
        and contract.signed_source_file_id is not null
        and contract.signed_content_sha256 is not null
        and (contract.effective_from is null or contract.effective_from <= now())
        and (contract.effective_until is null or contract.effective_until > now())
        and exists (
          select 1
          from public.atlas_installation_files as signed_file
          join storage.objects as signed_object
            on signed_object.bucket_id = signed_file.storage_bucket
           and signed_object.name = signed_file.storage_object_path
           and signed_object.archived_at is null
           and signed_object.is_delete_marker = false
          where signed_file.id = contract.signed_source_file_id
            and signed_file.installation_id = contract.installation_id
            and signed_file.empresa_id = contract.empresa_id
            and signed_file.logical_section = 'LEGAL'
            and signed_file.validation_status = 'ACCEPTED'
            and signed_file.sha256 = contract.signed_content_sha256
            and not exists (
              select 1
              from public.atlas_installation_files as newer_signed_file
              where newer_signed_file.installation_id =
                signed_file.installation_id
                and newer_signed_file.logical_section =
                  signed_file.logical_section
                and newer_signed_file.canonical_file_name =
                  signed_file.canonical_file_name
                and (
                  newer_signed_file.file_version > signed_file.file_version
                  or (
                    newer_signed_file.file_version = signed_file.file_version
                    and newer_signed_file.created_at > signed_file.created_at
                  )
                )
            )
        )
      ) as signed_and_current,
      (
        (
          definition.default_applicability = 'CONDITIONAL'
          and contract.applicability_status = 'NOT_APPLICABLE'
        )
        or (
          contract.applicability_status = 'REQUIRED'
          and contract.lifecycle_status = 'SIGNED'
          and contract.professional_review_status = 'APPROVED'
          and contract.signed_source_file_id is not null
          and contract.signed_content_sha256 is not null
          and (contract.effective_from is null or contract.effective_from <= now())
          and (contract.effective_until is null or contract.effective_until > now())
          and exists (
            select 1
            from public.atlas_installation_files as signed_file
            join storage.objects as signed_object
              on signed_object.bucket_id = signed_file.storage_bucket
             and signed_object.name = signed_file.storage_object_path
             and signed_object.archived_at is null
             and signed_object.is_delete_marker = false
            where signed_file.id = contract.signed_source_file_id
              and signed_file.installation_id = contract.installation_id
              and signed_file.empresa_id = contract.empresa_id
              and signed_file.logical_section = 'LEGAL'
              and signed_file.validation_status = 'ACCEPTED'
              and signed_file.sha256 = contract.signed_content_sha256
              and not exists (
                select 1
                from public.atlas_installation_files as newer_signed_file
                where newer_signed_file.installation_id =
                  signed_file.installation_id
                  and newer_signed_file.logical_section =
                    signed_file.logical_section
                  and newer_signed_file.canonical_file_name =
                    signed_file.canonical_file_name
                  and (
                    newer_signed_file.file_version > signed_file.file_version
                    or (
                      newer_signed_file.file_version = signed_file.file_version
                      and newer_signed_file.created_at > signed_file.created_at
                    )
                  )
              )
          )
        )
      ) as resolved
    from public.atlas_installation_contracts as contract
    where contract.installation_id = v_installation.id
      and contract.document_code = definition.document_code
    order by
      contract.document_version desc,
      contract.created_at desc,
      contract.id desc
    limit 1
  ) as latest_contract on true
  where definition.target_gate_code = 'G01'
    and definition.active = true;

  select coalesce((
    select decision_record.decision = 'SATISFIED'
      and (
        decision_record.expires_at is null
        or decision_record.expires_at > now()
      )
    from public.atlas_installation_legal_readiness_decisions
      as decision_record
    where decision_record.installation_id = v_installation.id
      and decision_record.criterion_code = 'COMPANY_IDENTITY_VERIFIED'
    order by decision_record.criterion_version desc
    limit 1
  ), false)
  into v_identity_attested;

  select coalesce((
    select decision_record.decision = 'SATISFIED'
      and (
        decision_record.expires_at is null
        or decision_record.expires_at > now()
      )
    from public.atlas_installation_legal_readiness_decisions
      as decision_record
    where decision_record.installation_id = v_installation.id
      and decision_record.criterion_code = 'THIRD_PARTIES_IDENTIFIED'
    order by decision_record.criterion_version desc
    limit 1
  ), false)
  into v_third_parties_attested;

  select coalesce((
    select decision_record.decision = 'SATISFIED'
      and (
        decision_record.expires_at is null
        or decision_record.expires_at > now()
      )
    from public.atlas_installation_legal_readiness_decisions
      as decision_record
    where decision_record.installation_id = v_installation.id
      and decision_record.criterion_code =
        'INITIAL_FINANCIAL_STATUS_VALID'
    order by decision_record.criterion_version desc
    limit 1
  ), false)
  into v_financial_attested;

  select coalesce((
    select decision_record.decision = 'SATISFIED'
      and (
        decision_record.expires_at is null
        or decision_record.expires_at > now()
      )
    from public.atlas_installation_legal_readiness_decisions
      as decision_record
    where decision_record.installation_id = v_installation.id
      and decision_record.criterion_code = 'LEGAL_RISKS_RESOLVED'
    order by decision_record.criterion_version desc
    limit 1
  ), false)
  into v_risks_attested;

  v_company_identity_verified :=
    v_manifest_valid and v_identity_attested;
  v_service_order_approved :=
    coalesce((v_documents->'C01'->>'signed_and_current')::boolean, false)
    and coalesce(
      (v_documents->'C03'->>'signed_and_current')::boolean,
      false
    );
  v_main_contract_signed :=
    coalesce((v_documents->'C02'->>'signed_and_current')::boolean, false);
  v_required_annexes_present := not exists (
    select 1
    from jsonb_each(v_documents) as document_entry(document_code, details)
    where document_entry.document_code not in ('C01', 'C02')
      and not coalesce(
        (document_entry.details->>'resolved')::boolean,
        false
      )
  ) and v_g01_definition_count = 11;
  v_data_channel_authorizations :=
    coalesce((v_documents->'C05'->>'resolved')::boolean, false)
    and coalesce((v_documents->'C09'->>'resolved')::boolean, false);
  v_third_parties_identified :=
    v_third_parties_attested
    and coalesce((v_documents->'C09'->>'resolved')::boolean, false);
  v_initial_financial_valid :=
    v_financial_attested
    and coalesce(
      (v_documents->'C01'->>'signed_and_current')::boolean,
      false
    );
  v_legal_risks_resolved := v_risks_attested;

  v_ready :=
    v_company_identity_verified
    and v_owner_authorized
    and v_service_order_approved
    and v_main_contract_signed
    and v_required_annexes_present
    and v_data_channel_authorizations
    and v_third_parties_identified
    and v_initial_financial_valid
    and v_legal_risks_resolved;

  select coalesce(jsonb_agg(blocker), '[]'::jsonb)
  into v_blockers
  from jsonb_array_elements(
    jsonb_build_array(
      case when not v_company_identity_verified
        then jsonb_build_object(
          'criterion', 'COMPANY_IDENTITY_VERIFIED',
          'reason', 'VALID_MANIFEST_AND_PROFESSIONAL_ATTESTATION_REQUIRED'
        ) end,
      case when not v_owner_authorized
        then jsonb_build_object(
          'criterion', 'CLIENT_OWNER_AUTHORIZED',
          'reason', 'MANIFEST_OWNER_MUST_MATCH_ACTIVE_INSTALLATION_OWNER'
        ) end,
      case when not v_service_order_approved
        then jsonb_build_object(
          'criterion', 'SERVICE_ORDER_APPROVED',
          'reason', 'C01_AND_C03_SIGNED_CURRENT_REQUIRED'
        ) end,
      case when not v_main_contract_signed
        then jsonb_build_object(
          'criterion', 'MAIN_CONTRACT_SIGNED',
          'reason', 'C02_SIGNED_CURRENT_REQUIRED'
        ) end,
      case when not v_required_annexes_present
        then jsonb_build_object(
          'criterion', 'REQUIRED_ANNEXES_PRESENT',
          'reason', 'CURRENT_G01_DOCUMENT_SET_UNRESOLVED'
        ) end,
      case when not v_data_channel_authorizations
        then jsonb_build_object(
          'criterion', 'DATA_AND_CHANNEL_AUTHORIZATIONS',
          'reason', 'C05_AND_C09_MUST_BE_SIGNED_OR_NOT_APPLICABLE'
        ) end,
      case when not v_third_parties_identified
        then jsonb_build_object(
          'criterion', 'THIRD_PARTIES_IDENTIFIED',
          'reason', 'C09_RESOLUTION_AND_PROFESSIONAL_ATTESTATION_REQUIRED'
        ) end,
      case when not v_initial_financial_valid
        then jsonb_build_object(
          'criterion', 'INITIAL_FINANCIAL_STATUS_VALID',
          'reason', 'C01_AND_CURRENT_FINANCIAL_ATTESTATION_REQUIRED'
        ) end,
      case when not v_legal_risks_resolved
        then jsonb_build_object(
          'criterion', 'LEGAL_RISKS_RESOLVED',
          'reason', 'CURRENT_PROFESSIONAL_RISK_ATTESTATION_REQUIRED'
        ) end
    )
  ) as blockers(blocker)
  where blocker <> 'null'::jsonb;

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_ready then 'G01_LEGAL_READINESS_COMPLETE'
      else 'G01_LEGAL_READINESS_INCOMPLETE'
    end,
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'ready', v_ready,
    'manifest_valid', v_manifest_valid,
    'g01_document_definitions', v_g01_definition_count,
    'resolved_g01_documents', v_resolved_document_count,
    'signed_g01_documents', v_signed_document_count,
    'criteria', jsonb_build_object(
      'COMPANY_IDENTITY_VERIFIED', v_company_identity_verified,
      'CLIENT_OWNER_AUTHORIZED', v_owner_authorized,
      'SERVICE_ORDER_APPROVED', v_service_order_approved,
      'MAIN_CONTRACT_SIGNED', v_main_contract_signed,
      'REQUIRED_ANNEXES_PRESENT', v_required_annexes_present,
      'DATA_AND_CHANNEL_AUTHORIZATIONS',
        v_data_channel_authorizations,
      'THIRD_PARTIES_IDENTIFIED', v_third_parties_identified,
      'INITIAL_FINANCIAL_STATUS_VALID', v_initial_financial_valid,
      'LEGAL_RISKS_RESOLVED', v_legal_risks_resolved
    ),
    'documents', v_documents,
    'blockers', v_blockers,
    'evaluated_at', now()
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_g01_readiness(uuid)
  from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_g01_readiness(uuid)
  to service_role;

create or replace function public.atlas_get_installation_g01_readiness(
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
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if coalesce(auth.role(), '') <> 'service_role'
     and not public.atlas_can_read_installation(p_installation_id) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_LEGAL_READINESS_READ_FORBIDDEN';
  end if;

  return public.atlas_compute_installation_g01_readiness(
    p_installation_id
  );
end;
$$;

revoke all on function public.atlas_get_installation_g01_readiness(uuid)
  from public, anon;
grant execute on function public.atlas_get_installation_g01_readiness(uuid)
  to authenticated, service_role;

create or replace function
public.atlas_decide_g01_readiness_criterion(
  p_installation_id uuid,
  p_criterion_code text,
  p_decision text,
  p_reason text,
  p_evidence jsonb,
  p_expires_at timestamptz,
  p_request_id uuid,
  p_expected_criterion_version bigint,
  p_metadata jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_criterion_code text := upper(nullif(btrim(p_criterion_code), ''));
  v_decision text := upper(nullif(btrim(p_decision), ''));
  v_installation public.atlas_installations%rowtype;
  v_existing
    public.atlas_installation_legal_readiness_decisions%rowtype;
  v_created
    public.atlas_installation_legal_readiness_decisions%rowtype;
  v_current_version bigint := 0;
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
  ) or not public.atlas_platform_has_permission(
    'INSTALLATION_LEGAL_READINESS_DECIDE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'ACTIVE_LEGAL_REVIEWER_REQUIRED';
  end if;

  if p_installation_id is null
     or v_criterion_code not in (
       'COMPANY_IDENTITY_VERIFIED',
       'THIRD_PARTIES_IDENTIFIED',
       'INITIAL_FINANCIAL_STATUS_VALID',
       'LEGAL_RISKS_RESOLVED'
     )
     or v_decision not in ('SATISFIED', 'BLOCKED')
     or nullif(btrim(p_reason), '') is null
     or length(btrim(p_reason)) < 10
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb
     or nullif(btrim(p_evidence->>'evidence_reference'), '') is null
     or p_request_id is null
     or p_expected_criterion_version is null
     or p_expected_criterion_version < 0
     or p_metadata is null
     or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'G01_READINESS_DECISION_REQUIRED_FIELDS_MISSING';
  end if;

  if p_expires_at is not null and p_expires_at <= now() then
    raise exception using
      errcode = '22023',
      message = 'G01_READINESS_DECISION_EXPIRY_INVALID';
  end if;

  if public.atlas_jsonb_has_forbidden_secret_key(p_evidence)
     or public.atlas_jsonb_has_forbidden_secret_key(p_metadata) then
    raise exception using
      errcode = '22023',
      message = 'G01_READINESS_DECISION_CONTAINS_SECRET';
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_NOT_FOUND';
  end if;

  select decision_record.*
  into v_existing
  from public.atlas_installation_legal_readiness_decisions
    as decision_record
  where decision_record.installation_id = v_installation.id
    and decision_record.request_id = p_request_id
  limit 1;

  if found then
    if v_existing.criterion_code <> v_criterion_code
       or v_existing.decision <> v_decision
       or v_existing.reason <> btrim(p_reason)
       or v_existing.evidence <> p_evidence
       or v_existing.expires_at is distinct from p_expires_at
       or v_existing.criterion_version <>
         p_expected_criterion_version + 1
       or v_existing.metadata <> p_metadata then
      raise exception using
        errcode = '22023',
        message = 'G01_READINESS_IDEMPOTENCY_COLLISION';
    end if;

    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'decision_id', v_existing.id,
      'installation_id', v_existing.installation_id,
      'criterion_code', v_existing.criterion_code,
      'decision', v_existing.decision,
      'criterion_version', v_existing.criterion_version,
      'expires_at', v_existing.expires_at
    );
  end if;

  if v_installation.current_state_code <> 'LEGAL_REVIEW' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_LEGAL_REVIEW';
  end if;

  select coalesce(max(decision_record.criterion_version), 0)
  into v_current_version
  from public.atlas_installation_legal_readiness_decisions
    as decision_record
  where decision_record.installation_id = v_installation.id
    and decision_record.criterion_code = v_criterion_code;

  if p_expected_criterion_version <> v_current_version then
    raise exception using
      errcode = '40001',
      message = 'G01_READINESS_CRITERION_VERSION_CONFLICT';
  end if;

  insert into public.atlas_installation_legal_readiness_decisions (
    installation_id,
    empresa_id,
    criterion_code,
    decision,
    reason,
    evidence,
    actor_user_id,
    actor_role_code,
    request_id,
    criterion_version,
    expires_at,
    metadata
  )
  values (
    v_installation.id,
    v_installation.empresa_id,
    v_criterion_code,
    v_decision,
    btrim(p_reason),
    p_evidence,
    v_actor_user_id,
    'ATLAS_LEGAL_REVIEWER',
    p_request_id,
    v_current_version + 1,
    p_expires_at,
    p_metadata
  )
  returning * into v_created;

  insert into public.atlas_internal_audit_log (
    empresa_id, user_id, agent_code, conversation_id,
    action_type, tool_code, status,
    input_summary, output_summary, error_message
  )
  values (
    v_created.empresa_id, v_actor_user_id, null, null,
    'G01_LEGAL_READINESS_CRITERION_DECIDED',
    'B2_LEGAL_ENGINE', 'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'criterion_code', v_criterion_code,
      'decision', v_decision
    ),
    jsonb_build_object(
      'installation_id', v_created.installation_id,
      'decision_id', v_created.id,
      'criterion_version', v_created.criterion_version,
      'expires_at', v_created.expires_at
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'G01_READINESS_CRITERION_DECIDED',
    'decision_id', v_created.id,
    'installation_id', v_created.installation_id,
    'criterion_code', v_created.criterion_code,
    'decision', v_created.decision,
    'criterion_version', v_created.criterion_version,
    'expires_at', v_created.expires_at
  );
end;
$$;

revoke all on function
public.atlas_decide_g01_readiness_criterion(
  uuid, text, text, text, jsonb, timestamptz, uuid, bigint, jsonb
) from public, anon;
grant execute on function
public.atlas_decide_g01_readiness_criterion(
  uuid, text, text, text, jsonb, timestamptz, uuid, bigint, jsonb
) to authenticated, service_role;

create or replace function public.atlas_enforce_g01_approval_readiness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
begin
  if new.gate_code = 'G01'
     and new.authority_type = 'PLATFORM'
     and new.decision = 'APPROVED' then
    if new.actor_role_code <> 'ATLAS_LEGAL_REVIEWER' then
      raise exception using
        errcode = '42501',
        message = 'G01_REQUIRES_ATLAS_LEGAL_REVIEWER';
    end if;

    v_readiness := public.atlas_compute_installation_g01_readiness(
      new.installation_id
    );

    if not coalesce((v_readiness->>'ready')::boolean, false) then
      raise exception using
        errcode = '42501',
        message = 'G01_LEGAL_READINESS_INCOMPLETE',
        detail = v_readiness::text;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.atlas_enforce_g01_approval_readiness()
  from public, anon, authenticated;
grant execute on function public.atlas_enforce_g01_approval_readiness()
  to service_role;

drop trigger if exists trg_atlas_g01_approval_readiness
  on public.atlas_installation_approvals;
create trigger trg_atlas_g01_approval_readiness
before insert on public.atlas_installation_approvals
for each row execute function public.atlas_enforce_g01_approval_readiness();

create or replace function public.atlas_enforce_g01_transition_readiness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
begin
  if old.current_state_code = 'LEGAL_REVIEW'
     and new.current_state_code = 'LEGAL_APPROVED' then
    if not exists (
      select 1
      from public.atlas_installation_gates as gate_record
      where gate_record.installation_id = old.id
        and gate_record.gate_code = 'G01'
        and gate_record.status = 'APPROVED'
        and gate_record.platform_approved = true
    ) then
      raise exception using
        errcode = '42501',
        message = 'G01_GATE_APPROVAL_REQUIRED';
    end if;

    v_readiness := public.atlas_compute_installation_g01_readiness(old.id);

    if not coalesce((v_readiness->>'ready')::boolean, false) then
      raise exception using
        errcode = '42501',
        message = 'G01_LEGAL_READINESS_STALE_OR_INCOMPLETE',
        detail = v_readiness::text;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.atlas_enforce_g01_transition_readiness()
  from public, anon, authenticated;
grant execute on function public.atlas_enforce_g01_transition_readiness()
  to service_role;

drop trigger if exists trg_atlas_installations_g01_transition_readiness
  on public.atlas_installations;
create trigger trg_atlas_installations_g01_transition_readiness
before update of current_state_code on public.atlas_installations
for each row execute function
public.atlas_enforce_g01_transition_readiness();

comment on table
public.atlas_installation_legal_readiness_decisions is
  'B2: decisiones profesionales append-only para hechos G01 no derivables automaticamente.';

comment on function
public.atlas_compute_installation_g01_readiness(uuid) is
  'B2: calcula G01 desde manifest, OWNER, contratos, firmas, Storage y decisiones profesionales vigentes.';

comment on function
public.atlas_get_installation_g01_readiness(uuid) is
  'B2: frontera de lectura del alistamiento juridico G01.';

comment on function
public.atlas_decide_g01_readiness_criterion(
  uuid, text, text, text, jsonb, timestamptz, uuid, bigint, jsonb
) is
  'B2: registra una decision profesional versionada para un criterio humano de G01.';

comment on function public.atlas_enforce_g01_approval_readiness() is
  'B2: impide aprobar G01 sin autoridad juridica y alistamiento objetivo completo.';

comment on function public.atlas_enforce_g01_transition_readiness() is
  'B2: revalida G01 antes de entrar a LEGAL_APPROVED.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2E3_LEGAL_READINESS_G01_INSTALLED',
  'next_action', 'CERTIFY_G01_READINESS_AND_ENFORCEMENT',
  'g01_human_criteria', 4,
  'g01_total_criteria', 9,
  'g01_document_definitions', (
    select count(*)
    from public.atlas_legal_document_definitions
    where target_gate_code = 'G01'
      and active = true
  ),
  'readiness_rpcs', 2,
  'enforcement_triggers', 2,
  'decision_records', (
    select count(*)
    from public.atlas_installation_legal_readiness_decisions
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
  'current_g01_ready', coalesce((
    public.atlas_compute_installation_g01_readiness(
      'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
    )->>'ready'
  )::boolean, false),
  'direct_authenticated_write', false
) as result;
