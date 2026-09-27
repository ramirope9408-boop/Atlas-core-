-- Recovered human-control runtime prerequisites for WhatsApp delivery binding.
-- Source: certified production definitions, 2026-09-27.
begin;

CREATE OR REPLACE FUNCTION public.atlas_audit_conversation_control_denial(p_empresa_id uuid, p_conversation_id uuid, p_user_id uuid, p_action_type text, p_request_id uuid, p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.atlas_internal_audit_log (
    empresa_id,
    user_id,
    conversation_id,
    action_type,
    status,
    input_summary,
    output_summary
  )
  values (
    p_empresa_id,
    p_user_id,
    p_conversation_id,
    p_action_type,
    'DENIED',
    jsonb_strip_nulls(jsonb_build_object('request_id', p_request_id)),
    jsonb_build_object('ok', false, 'code', p_code)
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.atlas_register_human_operator_message_canonical_base(p_empresa_id uuid, p_conversation_id uuid, p_text_content text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_role_code text;
  v_display_name text;
  v_state public.atlas_conversation_control_states%rowtype;
  v_existing_event public.atlas_conversation_control_events%rowtype;
  v_message_id uuid;
  v_text text := nullif(trim(p_text_content), '');
  v_channel text;
  v_result jsonb;
begin
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'code', 'AUTHENTICATION_REQUIRED');
  end if;

  select c.channel into v_channel
  from public.atlas_conversations c
  where c.id = p_conversation_id
    and c.empresa_id = p_empresa_id;

  if not found then
    perform public.atlas_audit_conversation_control_denial(
      p_empresa_id,
      p_conversation_id,
      v_user_id,
      'CONVERSATION_CONTROL_HUMAN_MESSAGE_REGISTERED',
      p_request_id,
      'CONVERSATION_NOT_FOUND'
    );
    return jsonb_build_object('ok', false, 'code', 'CONVERSATION_NOT_FOUND');
  end if;

  insert into public.atlas_conversation_control_states (
    empresa_id,
    conversation_id,
    control_mode
  )
  values (
    p_empresa_id,
    p_conversation_id,
    'VALENTINA_ACTIVE'
  )
  on conflict (empresa_id, conversation_id) do nothing;

  select * into strict v_state
  from public.atlas_conversation_control_states s
  where s.empresa_id = p_empresa_id
    and s.conversation_id = p_conversation_id
  for update;

  select m.role_code, coalesce(m.display_name, v_user_id::text)
  into v_role_code, v_display_name
  from public.atlas_internal_memberships m
  where m.empresa_id = p_empresa_id
    and m.user_id = v_user_id
    and m.status = 'ACTIVE';

  if p_request_id is not null then
    select * into v_existing_event
    from public.atlas_conversation_control_events e
    where e.empresa_id = p_empresa_id
      and e.conversation_id = p_conversation_id
      and e.request_id = p_request_id;

    if found then
      if v_existing_event.event_type <> 'HUMAN_MESSAGE_REGISTERED'
         or v_existing_event.actor_user_id is distinct from v_user_id then
        perform public.atlas_audit_conversation_control_denial(
          p_empresa_id,
          p_conversation_id,
          v_user_id,
          'CONVERSATION_CONTROL_HUMAN_MESSAGE_REGISTERED',
          p_request_id,
          'REQUEST_ID_CONFLICT'
        );
        return jsonb_build_object('ok', false, 'code', 'REQUEST_ID_CONFLICT');
      end if;

      return v_existing_event.metadata -> 'result';
    end if;
  end if;

  if p_request_id is null then
    v_result := jsonb_build_object(
      'ok', false,
      'code', 'REQUEST_ID_REQUIRED'
    );
    perform public.atlas_record_conversation_control_event(
      p_empresa_id, p_conversation_id, 'HUMAN_MESSAGE_REGISTERED',
      v_state.control_mode, v_state.control_mode,
      v_user_id, v_role_code, v_display_name,
      null, null, null, 'DENIED', v_result,
      jsonb_build_object('validation', 'REQUEST_ID_REQUIRED')
    );
    return v_result;
  end if;

  if v_text is null then
    v_result := jsonb_build_object(
      'ok', false,
      'code', 'MESSAGE_TEXT_REQUIRED'
    );
    perform public.atlas_record_conversation_control_event(
      p_empresa_id, p_conversation_id, 'HUMAN_MESSAGE_REGISTERED',
      v_state.control_mode, v_state.control_mode,
      v_user_id, v_role_code, v_display_name,
      null, p_request_id, null, 'DENIED', v_result,
      jsonb_build_object('validation', 'MESSAGE_TEXT_REQUIRED')
    );
    return v_result;
  end if;

  if not public.atlas_internal_has_permission(
    p_empresa_id,
    'CONVERSATIONS_CONTROL'
  ) then
    v_result := jsonb_build_object('ok', false, 'code', 'PERMISSION_DENIED');
    perform public.atlas_record_conversation_control_event(
      p_empresa_id, p_conversation_id, 'HUMAN_MESSAGE_REGISTERED',
      v_state.control_mode, v_state.control_mode,
      v_user_id, v_role_code, v_display_name,
      null, p_request_id, null, 'DENIED', v_result, '{}'::jsonb
    );
    return v_result;
  end if;

  if v_state.control_mode <> 'HUMAN_CONTROL' then
    v_result := jsonb_build_object(
      'ok', false,
      'code', 'HUMAN_CONTROL_REQUIRED'
    );
    perform public.atlas_record_conversation_control_event(
      p_empresa_id, p_conversation_id, 'HUMAN_MESSAGE_REGISTERED',
      v_state.control_mode, v_state.control_mode,
      v_user_id, v_role_code, v_display_name,
      null, p_request_id, null, 'DENIED', v_result, '{}'::jsonb
    );
    return v_result;
  end if;

  if v_state.controlled_by_user_id <> v_user_id then
    v_result := jsonb_build_object(
      'ok', false,
      'code', 'NOT_CURRENT_CONTROLLER',
      'controlled_by_user_id', v_state.controlled_by_user_id,
      'controlled_by_display_name', v_state.controlled_by_display_name
    );
    perform public.atlas_record_conversation_control_event(
      p_empresa_id, p_conversation_id, 'HUMAN_MESSAGE_REGISTERED',
      v_state.control_mode, v_state.control_mode,
      v_user_id, v_role_code, v_display_name,
      null, p_request_id, null, 'DENIED', v_result, '{}'::jsonb
    );
    return v_result;
  end if;

  insert into public.atlas_conversation_messages (
    empresa_id,
    conversation_id,
    direction,
    actor_type,
    actor_name,
    channel,
    message_type,
    text_content,
    normalized_text,
    transcription_status,
    processing_status,
    model_metadata,
    raw_payload,
    processed_at
  )
  values (
    p_empresa_id,
    p_conversation_id,
    'OUTBOUND',
    'HUMAN_OPERATOR',
    v_display_name,
    v_channel,
    'TEXT',
    v_text,
    v_text,
    'NOT_REQUIRED',
    'COMPLETED',
    jsonb_build_object(
      'operator_user_id', v_user_id,
      'operator_role_code', v_role_code,
      'request_id', p_request_id
    ),
    '{}'::jsonb,
    now()
  )
  returning id into v_message_id;

  update public.atlas_conversations c
  set
    last_message_at = now(),
    updated_at = now()
  where c.id = p_conversation_id
    and c.empresa_id = p_empresa_id;

  v_result := jsonb_build_object(
    'ok', true,
    'code', 'HUMAN_MESSAGE_REGISTERED',
    'message_id', v_message_id,
    'conversation_id', p_conversation_id,
    'control_mode', v_state.control_mode,
    'actor', 'HUMAN_OPERATOR'
  );

  perform public.atlas_record_conversation_control_event(
    p_empresa_id, p_conversation_id, 'HUMAN_MESSAGE_REGISTERED',
    v_state.control_mode, v_state.control_mode,
    v_user_id, v_role_code, v_display_name,
    null, p_request_id, v_message_id, 'COMPLETED', v_result, '{}'::jsonb
  );

  return v_result;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.atlas_register_human_operator_message(p_empresa_id uuid, p_conversation_id uuid, p_text_content text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_result jsonb; v_intent jsonb; v_delivery_id uuid;
begin
 v_result:=public.atlas_register_human_operator_message_canonical_base(p_empresa_id,p_conversation_id,p_text_content,p_request_id);
 if coalesce((v_result->>'ok')::boolean,false) and v_result->>'message_id' is not null then
   v_intent:=public.atlas_create_whatsapp_delivery_intent((v_result->>'message_id')::uuid,p_empresa_id,p_conversation_id,'HUMAN_OPERATOR');
   v_delivery_id:=(v_intent->>'delivery_id')::uuid;
   perform public.atlas_reconcile_whatsapp_delivery_intent(v_delivery_id);
 end if;
 return v_result;
end $function$
;

revoke all on function public.atlas_audit_conversation_control_denial(uuid,uuid,uuid,text,uuid,text) from public, anon;
grant execute on function public.atlas_audit_conversation_control_denial(uuid,uuid,uuid,text,uuid,text) to authenticated, service_role;

revoke all on function public.atlas_register_human_operator_message_canonical_base(uuid,uuid,text,uuid) from public, anon;
grant execute on function public.atlas_register_human_operator_message_canonical_base(uuid,uuid,text,uuid) to authenticated, service_role;

revoke all on function public.atlas_register_human_operator_message(uuid,uuid,text,uuid) from public, anon, service_role;
grant execute on function public.atlas_register_human_operator_message(uuid,uuid,text,uuid) to authenticated;

commit;
