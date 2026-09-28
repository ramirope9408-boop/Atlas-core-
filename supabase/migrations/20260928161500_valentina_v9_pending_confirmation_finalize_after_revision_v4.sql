-- VALENTINA V9
-- Finalizes the pending confirmation by its conversation-scoped open intent,
-- even after the confirmed modification has created a new quote version.

begin;

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
  v_id uuid;
begin
  select id
    into v_id
  from public.atlas_conversation_pending_intents
  where empresa_id=p_empresa_id
    and conversation_id=p_conversation_id
    and intent_type='QUOTE_MODIFICATION_CONFIRMATION'
    and status='OPEN'
    and (expires_at is null or expires_at>now())
  order by created_at desc
  limit 1;

  if v_id is null then
    return jsonb_build_object('ok',false,'code','OPEN_CONFIRMATION_NOT_FOUND');
  end if;

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
