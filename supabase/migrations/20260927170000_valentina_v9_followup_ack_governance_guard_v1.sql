-- ATLAS / VALENTINA V9 follow-up acknowledgement governance guard V1
-- Generic runtime behavior. Branch-only validation first.
-- Prevents acknowledgement-only messages from retriggering quote/modification/acceptance/payment flows.

begin;

alter function public.atlas_execute_external_quote_request_v1(uuid,uuid,uuid,jsonb,text)
  rename to atlas_execute_external_quote_request_v1_pre_v9_ack_guard;

create or replace function public.atlas_execute_external_quote_request_v1(
  p_empresa_id uuid,
  p_conversation_id uuid,
  p_source_message_id uuid,
  p_quote_request jsonb,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_source text;
  v_norm text;
  v_ctx jsonb;
  v_qb uuid;
begin
  if p_empresa_id is null or p_conversation_id is null or p_source_message_id is null then
    raise exception 'ATLAS_EXTERNAL_QUOTE_SCOPE_REQUIRED' using errcode='22004';
  end if;

  select coalesce(m.text_content,m.transcription_text,'')
    into v_source
  from public.atlas_conversation_messages m
  where m.id=p_source_message_id
    and m.empresa_id=p_empresa_id
    and m.conversation_id=p_conversation_id
    and m.direction='INBOUND'
    and m.actor_type='CUSTOMER';

  if not found then
    raise exception 'ATLAS_EXTERNAL_QUOTE_SOURCE_MESSAGE_NOT_AVAILABLE' using errcode='22023';
  end if;

  v_norm:=public.atlas_normalize_quote_query_v1(v_source);
  v_ctx:=public.atlas_resolve_active_quote_context_v2(p_empresa_id,p_conversation_id);
  v_qb:=nullif(v_ctx->>'quote_builder_id','')::uuid;

  if v_qb is not null
     and v_norm ~ '^(dale|listo|ok|okay|bueno|perfecto|gracias|muchas gracias)( (quedo|estoy) (atento|atenta|pendiente))?[.! ]*$'
  then
    return jsonb_build_object(
      'ok',true,
      'code','ACKNOWLEDGEMENT_NO_ACTION_V1',
      'route_intent','acknowledgement',
      'safe_to_send',true,
      'reply_text','Perfecto. Quedo atento a cualquier otro cambio que necesites.',
      'active_quote_builder_id',v_qb,
      'active_quote_version',v_ctx->>'quote_version',
      'executed',false,
      'modification_triggered',false,
      'acceptance_created',false,
      'payment_triggered',false,
      'next_action','NONE',
      'governance_contract','POST_ACTION_ACKNOWLEDGEMENT_GUARD_V1'
    );
  end if;

  return public.atlas_execute_external_quote_request_v1_pre_v9_ack_guard(
    p_empresa_id,
    p_conversation_id,
    p_source_message_id,
    p_quote_request,
    p_request_key
  );
end;
$function$;

revoke all on function public.atlas_execute_external_quote_request_v1(uuid,uuid,uuid,jsonb,text) from public, anon;
grant execute on function public.atlas_execute_external_quote_request_v1(uuid,uuid,uuid,jsonb,text) to authenticated, service_role;

commit;
