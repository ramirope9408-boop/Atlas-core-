-- ATLAS B2.2C.2 - Certificacion de RPC de archivos seguros.
-- Corte: 2026-08-29
--
-- Esta prueba no crea objetos en Storage ni registra archivos ficticios.
-- Solo ejecuta dos pruebas negativas controladas y valida la estructura.

begin;

create temporary table b2_2c2_rpc_certification_probes (
  probe_code text primary key,
  blocked_as_expected boolean not null,
  captured_sqlstate text,
  captured_message text
) on commit drop;

create temporary table b2_2c2_certification_baseline (
  installation_id uuid primary key,
  state_code text not null,
  installation_version bigint not null,
  installation_events bigint not null,
  registered_files bigint not null,
  inspection_records bigint not null,
  file_events bigint not null
) on commit drop;

insert into b2_2c2_certification_baseline (
  installation_id,
  state_code,
  installation_version,
  installation_events,
  registered_files,
  inspection_records,
  file_events
)
select
  i.id,
  i.current_state_code,
  i.version,
  (
    select count(*)
    from public.atlas_installation_state_events as se
    where se.installation_id = i.id
  ),
  (
    select count(*)
    from public.atlas_installation_files as f
    where f.installation_id = i.id
  ),
  (
    select count(*)
    from public.atlas_installation_file_inspections as fi
    where fi.installation_id = i.id
  ),
  (
    select count(*)
    from public.atlas_installation_file_events as fe
    where fe.installation_id = i.id
  )
from public.atlas_installations as i
where i.id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

do $$
declare
  v_owner_user_id uuid;
  v_installation public.atlas_installations%rowtype;
  v_missing_file_id uuid := gen_random_uuid();
  v_probe_request_id uuid;
begin
  select pm.user_id
  into v_owner_user_id
  from public.atlas_platform_memberships as pm
  where pm.role_code = 'ATLAS_OWNER'
    and pm.status = 'ACTIVE'
  order by pm.created_at asc
  limit 1;

  if v_owner_user_id is null then
    raise exception 'B2.2C.2 certification requires an active ATLAS_OWNER';
  end if;

  select i.*
  into v_installation
  from public.atlas_installations as i
  where i.id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid;

  if not found then
    raise exception 'B2.2C.2 certification installation not found';
  end if;

  perform set_config(
    'request.jwt.claim.sub',
    v_owner_user_id::text,
    true
  );
  perform set_config(
    'request.jwt.claim.role',
    'authenticated',
    true
  );
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_owner_user_id,
      'role', 'authenticated'
    )::text,
    true
  );

  v_probe_request_id := gen_random_uuid();

  begin
    perform public.atlas_register_installation_file(
      v_installation.id,
      'b2-certification-probe.exe',
      'b2-certification-probe.exe',
      'SECURITY',
      'exe',
      'application/octet-stream',
      1,
      repeat('0', 64),
      'INTERNAL',
      'SYSTEM_GENERATED',
      'ATLAS CERTIFICATION',
      1,
      now(),
      null,
      v_installation.empresa_id::text
        || '/installations/'
        || v_installation.id::text
        || '/security/b2-certification-probe.exe',
      'PENDING_CONTRACTUAL_ASSIGNMENT',
      v_probe_request_id,
      jsonb_build_object(
        'sha256_computed_by', 'B2_CERTIFICATION_PROBE',
        'sha256_computed_at', now()
      )
    );

    insert into b2_2c2_rpc_certification_probes
    values (
      'DISALLOWED_FILE_TYPE',
      false,
      null,
      'UNEXPECTED_SUCCESS'
    );
  exception
    when others then
      insert into b2_2c2_rpc_certification_probes
      values (
        'DISALLOWED_FILE_TYPE',
        sqlstate = '22023'
          and sqlerrm = 'INSTALLATION_FILE_TYPE_NOT_ALLOWED',
        sqlstate,
        sqlerrm
      );
  end;

  while exists (
    select 1
    from public.atlas_installation_files as f
    where f.id = v_missing_file_id
  ) loop
    v_missing_file_id := gen_random_uuid();
  end loop;

  begin
    perform public.atlas_record_installation_file_inspection(
      v_missing_file_id,
      'MIME_DETECTION',
      'PASSED',
      'B2_CERTIFICATION_PROBE',
      'V1',
      'application/pdf',
      null,
      '{}'::jsonb,
      jsonb_build_object('probe', true),
      gen_random_uuid()
    );

    insert into b2_2c2_rpc_certification_probes
    values (
      'MISSING_FILE_INSPECTION',
      false,
      null,
      'UNEXPECTED_SUCCESS'
    );
  exception
    when others then
      insert into b2_2c2_rpc_certification_probes
      values (
        'MISSING_FILE_INSPECTION',
        sqlstate = 'P0002'
          and sqlerrm = 'INSTALLATION_FILE_NOT_FOUND',
        sqlstate,
        sqlerrm
      );
  end;

  if exists (
    select 1
    from b2_2c2_rpc_certification_probes as p
    where not p.blocked_as_expected
  ) then
    raise exception 'B2.2C.2 negative RPC probe failed: %', (
      select jsonb_agg(to_jsonb(p))
      from b2_2c2_rpc_certification_probes as p
      where not p.blocked_as_expected
    );
  end if;

  if not exists (
    select 1
    from b2_2c2_certification_baseline
  ) then
    raise exception 'B2.2C.2 certification baseline missing';
  end if;

  if exists (
    select 1
    from b2_2c2_certification_baseline as b
    join public.atlas_installations as i
      on i.id = b.installation_id
    where i.current_state_code <> b.state_code
       or i.version <> b.installation_version
       or (
         select count(*)
         from public.atlas_installation_state_events as se
         where se.installation_id = i.id
       ) <> b.installation_events
       or (
         select count(*)
         from public.atlas_installation_files as f
         where f.installation_id = i.id
       ) <> b.registered_files
       or (
         select count(*)
         from public.atlas_installation_file_inspections as fi
         where fi.installation_id = i.id
       ) <> b.inspection_records
       or (
         select count(*)
         from public.atlas_installation_file_events as fe
         where fe.installation_id = i.id
       ) <> b.file_events
  ) then
    raise exception 'B2.2C.2 certification probes changed governed state';
  end if;

  if (
    select count(*)
    from public.atlas_installation_file_inspection_types
    where active = true
  ) <> 7 then
    raise exception 'B2.2C.2 expected seven active inspection types';
  end if;

  if (
    select count(*)
    from public.atlas_installation_file_rejection_reasons
    where active = true
  ) <> 9 then
    raise exception 'B2.2C.2 expected nine active rejection reasons';
  end if;

  if (
    select count(*)
    from pg_class as c
    join pg_namespace as n
      on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in (
        'atlas_installation_file_inspection_types',
        'atlas_installation_file_inspections'
      )
      and c.relrowsecurity = true
  ) <> 2 then
    raise exception 'B2.2C.2 RLS is not enabled on both inspection tables';
  end if;

  if (
    select count(*)
    from pg_policies
    where schemaname = 'public'
      and (
        (
          tablename = 'atlas_installation_file_inspection_types'
          and policyname = 'atlas_installation_file_inspection_types_read'
        )
        or (
          tablename = 'atlas_installation_file_inspections'
          and policyname = 'atlas_installation_file_inspections_read'
        )
      )
  ) <> 2 then
    raise exception 'B2.2C.2 canonical read policies missing';
  end if;

  if exists (
    select 1
    from unnest(array[
        'atlas_installation_file_inspection_types',
        'atlas_installation_file_inspections',
        'atlas_installation_files',
        'atlas_installation_file_events'
      ]) as table_names(table_name)
    cross join unnest(array['anon', 'authenticated'])
      as role_names(role_name)
    cross join unnest(array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'])
      as privileges(privilege_name)
    where has_table_privilege(
      role_names.role_name,
      'public.' || table_names.table_name,
      privileges.privilege_name
    )
  ) then
    raise exception 'B2.2C.2 direct client write privilege detected';
  end if;

  if (
    select count(*)
    from pg_proc as p
    where p.oid in (
      'public.atlas_register_installation_file(uuid,text,text,text,text,text,bigint,text,text,text,text,integer,timestamptz,timestamptz,text,text,uuid,jsonb)'::regprocedure,
      'public.atlas_record_installation_file_inspection(uuid,text,text,text,text,text,text,jsonb,jsonb,uuid)'::regprocedure
    )
      and p.prosecdef = true
  ) <> 2 then
    raise exception 'B2.2C.2 SECURITY DEFINER RPC contract missing';
  end if;

  if exists (
    select 1
    from pg_proc as p
    where p.oid in (
      'public.atlas_register_installation_file(uuid,text,text,text,text,text,bigint,text,text,text,text,integer,timestamptz,timestamptz,text,text,uuid,jsonb)'::regprocedure,
      'public.atlas_record_installation_file_inspection(uuid,text,text,text,text,text,text,jsonb,jsonb,uuid)'::regprocedure
    )
      and has_function_privilege('anon', p.oid, 'EXECUTE')
  ) then
    raise exception 'B2.2C.2 anonymous RPC execution detected';
  end if;

  if (
    select count(*)
    from pg_proc as p
    where p.oid in (
      'public.atlas_register_installation_file(uuid,text,text,text,text,text,bigint,text,text,text,text,integer,timestamptz,timestamptz,text,text,uuid,jsonb)'::regprocedure,
      'public.atlas_record_installation_file_inspection(uuid,text,text,text,text,text,text,jsonb,jsonb,uuid)'::regprocedure
    )
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) <> 2 then
    raise exception 'B2.2C.2 authenticated RPC grants missing';
  end if;

  if not exists (
    select 1
    from pg_trigger as t
    join pg_class as c
      on c.oid = t.tgrelid
    join pg_namespace as n
      on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'atlas_installation_file_inspections'
      and t.tgname = 'trg_atlas_installation_file_inspections_append_only'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  ) then
    raise exception 'B2.2C.2 append-only inspection trigger missing';
  end if;

  if exists (
    select 1
    from pg_proc as p
    where p.oid in (
      'public.atlas_register_installation_file(uuid,text,text,text,text,text,bigint,text,text,text,text,integer,timestamptz,timestamptz,text,text,uuid,jsonb)'::regprocedure,
      'public.atlas_record_installation_file_inspection(uuid,text,text,text,text,text,text,jsonb,jsonb,uuid)'::regprocedure
    )
      and pg_get_functiondef(p.oid) like '%''ACCEPTED''%'
  ) then
    raise exception 'B2.2C.2 acceptance was enabled before C.3';
  end if;

  if (
    select count(*)
    from pg_constraint as con
    join pg_class as c
      on c.oid = con.conrelid
    join pg_namespace as n
      on n.oid = c.relnamespace
    where n.nspname = 'public'
      and (
        (
          c.relname = 'atlas_installation_files'
          and con.conname in (
            'atlas_installation_files_request_key',
            'atlas_installation_files_hash_key'
          )
        )
        or (
          c.relname = 'atlas_installation_file_inspections'
          and con.conname = 'atlas_installation_file_inspections_request_key'
        )
        or (
          c.relname = 'atlas_installation_file_events'
          and con.conname = 'atlas_installation_file_events_request_key'
        )
      )
  ) <> 4 then
    raise exception 'B2.2C.2 idempotency or hash deduplication constraint missing';
  end if;

  if not exists (
    select 1
    from pg_proc as p
    where p.oid =
      'public.atlas_register_installation_file(uuid,text,text,text,text,text,bigint,text,text,text,text,integer,timestamptz,timestamptz,text,text,uuid,jsonb)'::regprocedure
      and pg_get_functiondef(p.oid) like '%STORAGE_OBJECT_NOT_FOUND%'
      and pg_get_functiondef(p.oid) like '%SHA256_COMPUTATION_EVIDENCE_REQUIRED%'
      and pg_get_functiondef(p.oid) like '%from storage.objects%'
  ) then
    raise exception 'B2.2C.2 real object or SHA-256 evidence guard missing';
  end if;
end;
$$;

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2C2_FILE_RPCS_CERTIFIED',
  'state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'version', (
    select version
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'inspection_types', 7,
  'rejection_reasons', 9,
  'rls_tables', 2,
  'read_policies', 2,
  'security_definer_rpcs', 2,
  'authenticated_rpc_grants', 2,
  'anonymous_rpc_grants', 0,
  'direct_client_write_grants', 0,
  'append_only_trigger_present', true,
  'acceptance_rpc_present', false,
  'idempotency_and_hash_constraints', 4,
  'disallowed_file_type_blocked', true,
  'missing_file_inspection_blocked', true,
  'real_object_and_sha256_guards', true,
  'registered_files', (
    select count(*)
    from public.atlas_installation_files
    where installation_id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'inspection_records', (
    select count(*)
    from public.atlas_installation_file_inspections
    where installation_id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'governed_records_unchanged', true,
  'next_block', 'B2.2C.3_FILE_ACCEPTANCE_AND_QUARANTINE_POLICY'
) as certification;
