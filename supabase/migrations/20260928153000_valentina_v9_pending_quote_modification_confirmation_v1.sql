-- VALENTINA V9
-- Stateful pending confirmation for quote modifications.
-- Generic conversational governance. No FingerFood-specific business values.

begin;

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
begin
  if p_empresa_id is null or p_conversation_id is null or p_proposal_message_id is null
     or p_quote_builder_id is null or p_quote_version is null
  then
    raise exception 'QUOTE_MODIFICATION_CONFIRMATION_SCOPE_REQUIRED';
  end if;

  if nullif(btrim(p_proposal_text),'') is null then
    raise exception 'QUOTE_MODIFICATION_CONFIRMATION_PROPOSAL_REQUIRED';
  end if;

  update public.atlas_conversation_pending_intents
     set status='SUPERSEDED', resolved_at=now(), updated_at=now()
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
      'confirmation_contract','QUOTE_MODIFICATION_CONFIRMATION_V1'
    ),
    coalesce(p_expires_at,now()+interval '24 hours')
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok',true,'pending_intent_id',v_id,'status','OPEN',
    'intent_type','QUOTE_MODIFICATION_CONFIRMATION'
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

  select *
    into v_row
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
      'found',false,
      'stale',true,
      'pending_intent_id',v_row.id,
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
    'expires_at',v_row.expires_at
  );
end;
$function$;

create or replace function public.atlas_resolve_quote_modification_confirmation_reply_v1(
  p_empresa_id uuid,
  p_conversation_id uuid,
  p_source_message_id uuid
)
returns jsonb
language plpgsql
set search_path to 'public','pg_temp'
as $function$
declare
  v_source text;
  v_norm text;
  v_pending jsonb;
  v_pending_id uuid;
begin
  select coalesce(m.transcription_text,m.text_content,'')
    into v_source
  from public.atlas_conversation_messages m
  where m.id=p_source_message_id
    and m.empresa_id=p_empresa_id
    and m.conversation_id=p_conversation_id
    and m.direction='INBOUND'
    and m.actor_type='CUSTOMER';

  if not found then
    raise exception 'SOURCE_MESSAGE_NOT_AVAILABLE';
  end if;

  v_pending:=public.atlas_get_open_quote_modification_confirmation_v1(
    p_empresa_id,p_conversation_id
  );

  if coalesce((v_pending->>'found')::boolean,false) is not true then
    return jsonb_build_object('matched',false,'reason','NO_OPEN_CONFIRMATION');
  end if;

  v_pending_id:=(v_pending->>'id')::uuid;
  v_norm:=public.atlas_normalize_quote_query_v1(v_source);

  if v_norm ~ '^(si|sí|exacto|correcto|asi es|así es|confirmo|de acuerdo|eso es|dale)$' then
    return jsonb_build_object(
      'matched',true,
      'decision','CONFIRMED',
      'pending_intent_id',v_pending_id,
      'quote_builder_id',v_pending->>'quote_builder_id',
      'quote_version',v_pending->>'quote_version',
      'proposal_message_id',v_pending->>'proposal_message_id',
      'proposal_text',v_pending->>'proposal_text',
      'next_action','RESOLVE_PENDING_MODIFICATION_PROPOSAL'
    );
  end if;

  if v_norm ~ '^(no|no es correcto|no exactamente|negativo|cancelalo|cancela)$' then
    update public.atlas_conversation_pending_intents
       set status='CANCELLED',
           resolution_message_id=p_source_message_id,
           resolved_at=now(),
           updated_at=now()
     where id=v_pending_id and status='OPEN';

    return jsonb_build_object(
      'matched',true,
      'decision','REJECTED',
      'pending_intent_id',v_pending_id,
      'next_action','ASK_MINIMUM_CORRECTION'
    );
  end if;

  return jsonb_build_object(
    'matched',true,
    'decision','NEEDS_CLARIFICATION',
    'pending_intent_id',v_pending_id,
    'next_action','KEEP_PENDING_CONFIRMATION'
  );
end;
$function$;

create or replace function public.atlas_capture_quote_modification_confirmation_message_v1()
returns trigger
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_norm text;
  v_ctx jsonb;
  v_qb uuid;
  v_qv integer;
begin
  if new.direction<>'OUTBOUND'
     or new.actor_type<>'AI'
     or coalesce(new.message_type,'TEXT')<>'TEXT'
     or nullif(btrim(new.text_content),'') is null
  then
    return new;
  end if;

  v_norm:=public.atlas_normalize_quote_query_v1(new.text_content);

  if not (
    v_norm like '%cotizacion%'
    and (
      v_norm like '%es correcto%'
      or v_norm like '%es asi%'
      or v_norm like '%confirmar si quieres%'
      or v_norm like '%confirmas%'
    )
    and (
      v_norm like '%ajust%'
      or v_norm like '%modific%'
      or v_norm like '%cambi%'
      or v_norm like '%inclu%'
    )
  ) then
    return new;
  end if;

  v_ctx:=public.atlas_resolve_active_quote_context_v2(new.empresa_id,new.conversation_id);
  if coalesce((v_ctx->>'found')::boolean,false) is not true then
    return new;
  end if;

  v_qb:=(v_ctx->>'quote_builder_id')::uuid;
  v_qv:=(v_ctx->>'quote_version')::integer;

  perform public.atlas_open_pending_quote_modification_confirmation_v1(
    new.empresa_id,new.conversation_id,new.id,v_qb,v_qv,new.text_content,null
  );

  new.model_metadata:=coalesce(new.model_metadata,'{}'::jsonb)
    || jsonb_build_object(
      'pending_quote_modification_confirmation',true,
      'pending_quote_builder_id',v_qb,
      'pending_quote_version',v_qv
    );

  return new;
end;
$function$;

drop trigger if exists trg_atlas_capture_quote_modification_confirmation_v1
  on public.atlas_conversation_messages;

create trigger trg_atlas_capture_quote_modification_confirmation_v1
before insert on public.atlas_conversation_messages
for each row
execute function public.atlas_capture_quote_modification_confirmation_message_v1();

commit;
