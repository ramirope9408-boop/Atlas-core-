-- VALENTINA V9
-- Converts a persisted natural-language modification proposal into a deterministic,
-- quote-version-bound patch, then allows an explicit affirmative reply to execute it.
-- Generic conversational governance; no company-specific products/prices.

begin;

create or replace function public.atlas_extract_pending_quote_modification_patch_v1(
  p_empresa_id uuid,
  p_quote_builder_id uuid,
  p_proposal_text text
)
returns jsonb
language plpgsql
stable
set search_path to 'public','pg_temp'
as $function$
declare
  v_norm text;
  v_qty numeric;
  v_match text[];
  v_except_text text;
  v_except jsonb;
  v_except_pid uuid;
  v_products jsonb:='[]'::jsonb;
begin
  if p_empresa_id is null or p_quote_builder_id is null then
    return jsonb_build_object('resolved',false,'reason','SCOPE_REQUIRED');
  end if;

  v_norm:=public.atlas_normalize_quote_query_v1(coalesce(p_proposal_text,''));

  -- Deterministic family: "N units of each/everything else", optionally with
  -- one active-quote exception introduced by "ademas de / excepto / menos / salvo".
  v_match:=regexp_match(v_norm,'([0-9]+)( |$).*unidades?( |$)');
  if v_match is null then
    return jsonb_build_object('resolved',false,'reason','QUANTITY_NOT_DETERMINISTIC');
  end if;

  v_qty:=(v_match[1])::numeric;
  if v_qty<=0 then
    return jsonb_build_object('resolved',false,'reason','QUANTITY_INVALID');
  end if;

  if not (
    v_norm like '%cada opcion%'
    or v_norm like '%cada cosa%'
    or v_norm like '%los demas%'
    or v_norm like '%lo demas%'
    or v_norm like '%todo lo demas%'
  ) then
    return jsonb_build_object('resolved',false,'reason','SET_ALL_SCOPE_NOT_DETERMINISTIC');
  end if;

  if v_norm like '%ademas de %' then
    v_except_text:=split_part(v_norm,'ademas de ',2);
  elsif v_norm like '%excepto %' then
    v_except_text:=split_part(v_norm,'excepto ',2);
  elsif v_norm like '%menos %' then
    v_except_text:=split_part(v_norm,'menos ',2);
  elsif v_norm like '%salvo %' then
    v_except_text:=split_part(v_norm,'salvo ',2);
  end if;

  if nullif(btrim(v_except_text),'') is not null then
    v_except:=public.atlas_resolve_active_quote_product_mention_v1(
      p_empresa_id,p_quote_builder_id,v_except_text
    );
    if coalesce((v_except->>'count')::int,0)=1 then
      v_except_pid=(v_except#>>'{matches,0,product_id}')::uuid;
    elsif coalesce((v_except->>'count')::int,0)>1 then
      return jsonb_build_object(
        'resolved',false,'reason','EXCEPTION_PRODUCT_AMBIGUOUS','matches',v_except->'matches'
      );
    end if;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'op','SET',
        'product_id',li.producto_id,
        'quantity',v_qty
      )
      order by li.created_at,li.id
    ),
    '[]'::jsonb
  )
  into v_products
  from public.atlas_quote_line_items li
  where li.empresa_id=p_empresa_id
    and li.quote_builder_id=p_quote_builder_id
    and (v_except_pid is null or li.producto_id<>v_except_pid);

  if jsonb_array_length(v_products)=0 then
    return jsonb_build_object('resolved',false,'reason','NO_PRODUCTS_TO_PATCH');
  end if;

  return jsonb_build_object(
    'resolved',true,
    'patch',jsonb_build_object('products',v_products),
    'quantity',v_qty,
    'exception_product_id',v_except_pid,
    'contract','PENDING_CONFIRMATION_PATCH_V1'
  );
end;
$function$;

create or replace function public.atlas_open_pending_quote_modification_confirmation_v1(
  p_empresa_id uuid,
  p_conversation_id uuid,
  p_proposal_message_id uuid,
  p_quote_builder_id uuid,
  p_quote_version integer,
  p_proposal_text text,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql
set search_path to 'public','pg_temp'
as $function$
declare
  v_id uuid;
  v_patch_resolution jsonb;
begin
  if p_empresa_id is null or p_conversation_id is null or p_proposal_message_id is null
     or p_quote_builder_id is null or p_quote_version is null
  then
    raise exception 'QUOTE_MODIFICATION_CONFIRMATION_SCOPE_REQUIRED';
  end if;

  if nullif(btrim(p_proposal_text),'') is null then
    raise exception 'QUOTE_MODIFICATION_CONFIRMATION_PROPOSAL_REQUIRED';
  end if;

  v_patch_resolution:=public.atlas_extract_pending_quote_modification_patch_v1(
    p_empresa_id,p_quote_builder_id,p_proposal_text
  );

  update public.atlas_conversation_pending_intents
     set status='SUPERSEDED',resolved_at=now(),updated_at=now()
   where empresa_id=p_empresa_id
     and conversation_id=p_conversation_id
     and intent_type='QUOTE_MODIFICATION_CONFIRMATION'
     and status='OPEN';

  insert into public.atlas_conversation_pending_intents(
    empresa_id,conversation_id,intent_type,status,source_message_id,
    quote_builder_id,quote_version,payload,expires_at
  )
  values(
    p_empresa_id,p_conversation_id,'QUOTE_MODIFICATION_CONFIRMATION','OPEN',
    p_proposal_message_id,p_quote_builder_id,p_quote_version,
    jsonb_build_object(
      'proposal_message_id',p_proposal_message_id,
      'proposal_text',p_proposal_text,
      'patch_resolution',v_patch_resolution,
      'proposed_patch',case
        when coalesce((v_patch_resolution->>'resolved')::boolean,false)
          then v_patch_resolution->'patch'
        else '{}'::jsonb
      end,
      'confirmation_contract','QUOTE_MODIFICATION_CONFIRMATION_V2'
    ),
    coalesce(p_expires_at,now()+interval '24 hours')
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok',true,
    'pending_intent_id',v_id,
    'status','OPEN',
    'intent_type','QUOTE_MODIFICATION_CONFIRMATION',
    'patch_resolution',v_patch_resolution
  );
end;
$function$;

create or replace function public.atlas_get_open_quote_modification_confirmation_v1(
  p_empresa_id uuid,
  p_conversation_id uuid
)
returns jsonb
language plpgsql
stable
set search_path to 'public','pg_temp'
as $function$
declare
  v_row public.atlas_conversation_pending_intents%rowtype;
  v_ctx jsonb;
  v_active_qb uuid;
  v_active_version integer;
begin
  v_ctx:=public.atlas_resolve_active_quote_context_v2(p_empresa_id,p_conversation_id);
  v_active_qb:=nullif(v_ctx->>'quote_builder_id','')::uuid;
  v_active_version:=nullif(v_ctx->>'quote_version','')::integer;

  select * into v_row
  from public.atlas_conversation_pending_intents
  where empresa_id=p_empresa_id
    and conversation_id=p_conversation_id
    and intent_type='QUOTE_MODIFICATION_CONFIRMATION'
    and status='OPEN'
    and (expires_at is null or expires_at>now())
  order by created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('found',false);
  end if;

  if v_row.quote_builder_id is distinct from v_active_qb
     or v_row.quote_version is distinct from v_active_version
  then
    return jsonb_build_object(
      'found',false,'stale',true,'pending_intent_id',v_row.id,
      'reason','ACTIVE_QUOTE_VERSION_CHANGED'
    );
  end if;

  return jsonb_build_object(
    'found',true,
    'id',v_row.id,
    'quote_builder_id',v_row.quote_builder_id,
    'quote_version',v_row.quote_version,
    'proposal_message_id',v_row.payload->>'proposal_message_id',
    'proposal_text',v_row.payload->>'proposal_text',
    'proposed_patch',coalesce(v_row.payload->'proposed_patch','{}'::jsonb),
    'patch_resolution',coalesce(v_row.payload->'patch_resolution','{}'::jsonb),
    'expires_at',v_row.expires_at
  );
end;
$function$;

create or replace function public.atlas_prepare_confirmed_pending_quote_modification_plan_v1(
  p_empresa_id uuid,
  p_conversation_id uuid,
  p_source_message_id uuid
)
returns jsonb
language plpgsql
set search_path to 'public','pg_temp'
as $function$
declare
  v_resolution jsonb;
  v_pending_id uuid;
  v_patch jsonb;
  v_ctx jsonb;
  v_plan jsonb;
begin
  v_resolution:=public.atlas_resolve_quote_modification_confirmation_reply_v1(
    p_empresa_id,p_conversation_id,p_source_message_id
  );

  if coalesce((v_resolution->>'matched')::boolean,false) is not true
     or v_resolution->>'decision'<>'CONFIRMED'
  then
    return jsonb_build_object(
      'ready_to_act',false,
      'code','NO_CONFIRMED_PENDING_MODIFICATION',
      'confirmation_resolution',v_resolution
    );
  end if;

  v_pending_id:=(v_resolution->>'pending_intent_id')::uuid;

  select coalesce(payload->'proposed_patch','{}'::jsonb)
    into v_patch
  from public.atlas_conversation_pending_intents
  where id=v_pending_id
    and empresa_id=p_empresa_id
    and conversation_id=p_conversation_id
    and status='OPEN';

  if v_patch is null or v_patch='{}'::jsonb then
    return jsonb_build_object(
      'ready_to_act',false,
      'code','PENDING_MODIFICATION_PATCH_NOT_RESOLVED',
      'pending_intent_id',v_pending_id,
      'confirmation_resolution',v_resolution
    );
  end if;

  v_ctx:=public.atlas_resolve_customer_visible_quote_context_v1(
    p_empresa_id,p_conversation_id
  );

  v_plan:=jsonb_build_object(
    'ready_to_act',true,
    'code','QUOTE_MODIFICATION_PLAN_READY_V2',
    'intent','modify_quote',
    'confidence',1.0,
    'source_message_id',p_source_message_id,
    'source_text','EXPLICIT_CONFIRMATION_OF_PENDING_MODIFICATION',
    'active_quote',v_ctx,
    'patch',v_patch,
    'truth_basis','LAST_ISSUED_TO_CUSTOMER',
    'next_action','CREATE_REVISION_THEN_APPLY_PATCH',
    'confirmation_contract','QUOTE_MODIFICATION_CONFIRMATION_V2',
    'pending_intent_id',v_pending_id
  );

  return v_plan;
end;
$function$;

create or replace function public.atlas_finalize_confirmed_pending_quote_modification_v1(
  p_empresa_id uuid,
  p_conversation_id uuid,
  p_source_message_id uuid,
  p_execution_result jsonb
)
returns jsonb
language plpgsql
set search_path to 'public','pg_temp'
as $function$
declare
  v_pending jsonb;
  v_id uuid;
begin
  v_pending:=public.atlas_get_open_quote_modification_confirmation_v1(
    p_empresa_id,p_conversation_id
  );

  if coalesce((v_pending->>'found')::boolean,false) is not true then
    return jsonb_build_object('ok',false,'code','OPEN_CONFIRMATION_NOT_FOUND');
  end if;

  v_id:=(v_pending->>'id')::uuid;

  update public.atlas_conversation_pending_intents
     set status='RESOLVED',
         resolution_message_id=p_source_message_id,
         resolved_at=now(),
         updated_at=now(),
         payload=payload||jsonb_build_object(
           'execution_result',coalesce(p_execution_result,'{}'::jsonb)
         )
   where id=v_id
     and status='OPEN';

  return jsonb_build_object(
    'ok',found,
    'code','PENDING_MODIFICATION_CONFIRMATION_RESOLVED',
    'pending_intent_id',v_id
  );
end;
$function$;

commit;
