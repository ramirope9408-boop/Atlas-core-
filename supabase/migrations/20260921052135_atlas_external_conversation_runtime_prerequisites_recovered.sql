-- Recovered external conversation runtime prerequisites.
-- Source: certified production definitions, 2026-09-27.
begin;

create table if not exists public.atlas_conversation_control_events(
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id),
  conversation_id uuid not null references public.atlas_conversations(id),
  event_type text not null,
  from_mode text,
  to_mode text,
  actor_user_id uuid,
  actor_role_code text,
  actor_display_name text,
  reason text,
  request_id uuid,
  related_message_id uuid,
  outcome text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.atlas_conversation_control_events enable row level security;

CREATE OR REPLACE FUNCTION public.atlas_record_conversation_control_event(p_empresa_id uuid, p_conversation_id uuid, p_event_type text, p_from_mode text, p_to_mode text, p_actor_user_id uuid, p_actor_role_code text, p_actor_display_name text, p_reason text, p_request_id uuid, p_related_message_id uuid, p_outcome text, p_result jsonb, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_event_id uuid;
  v_audit_status text;
begin
  insert into public.atlas_conversation_control_events (
    empresa_id,
    conversation_id,
    event_type,
    from_mode,
    to_mode,
    actor_user_id,
    actor_role_code,
    actor_display_name,
    reason,
    request_id,
    related_message_id,
    outcome,
    metadata
  )
  values (
    p_empresa_id,
    p_conversation_id,
    p_event_type,
    p_from_mode,
    p_to_mode,
    p_actor_user_id,
    p_actor_role_code,
    p_actor_display_name,
    nullif(trim(p_reason), ''),
    p_request_id,
    p_related_message_id,
    p_outcome,
    coalesce(p_metadata, '{}'::jsonb)
      || jsonb_build_object('result', coalesce(p_result, '{}'::jsonb))
  )
  returning id into v_event_id;

  v_audit_status := case
    when p_outcome in ('DENIED', 'BLOCKED') then 'DENIED'
    else 'COMPLETED'
  end;

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
    p_actor_user_id,
    p_conversation_id,
    'CONVERSATION_CONTROL_' || p_event_type,
    v_audit_status,
    jsonb_strip_nulls(jsonb_build_object(
      'request_id', p_request_id,
      'reason', nullif(trim(p_reason), ''),
      'from_mode', p_from_mode,
      'to_mode', p_to_mode
    )),
    coalesce(p_result, '{}'::jsonb)
  );

  return v_event_id;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.atlas_register_ai_response_canonical_base(p_empresa_id uuid, p_conversation_id uuid, p_text_content text, p_model_name text DEFAULT NULL::text, p_model_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_state public.atlas_conversation_control_states%rowtype;
  v_message_id uuid;
  v_text text := nullif(trim(p_text_content), '');
  v_channel text;
  v_result jsonb;
begin
  if v_text is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'AI_RESPONSE_EMPTY'
    );
  end if;

  select c.channel into v_channel
  from public.atlas_conversations c
  where c.id = p_conversation_id
    and c.empresa_id = p_empresa_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_NOT_FOUND'
    );
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

  -- Esta fila serializa TAKE_CONTROL y el guardado final de la IA.
  select * into strict v_state
  from public.atlas_conversation_control_states s
  where s.empresa_id = p_empresa_id
    and s.conversation_id = p_conversation_id
  for update;

  if v_state.control_mode <> 'VALENTINA_ACTIVE' then
    v_result := jsonb_build_object(
      'ok', false,
      'code', 'AI_RESPONSE_BLOCKED_BY_HUMAN_CONTROL',
      'conversation_id', p_conversation_id,
      'control_mode', v_state.control_mode,
      'controlled_by_user_id', v_state.controlled_by_user_id,
      'controlled_by_display_name', v_state.controlled_by_display_name,
      'version', v_state.version
    );

    perform public.atlas_record_conversation_control_event(
      p_empresa_id,
      p_conversation_id,
      'AI_RESPONSE_BLOCKED',
      v_state.control_mode,
      v_state.control_mode,
      null,
      null,
      null,
      'Respuesta automatica tardia bloqueada',
      null,
      null,
      'BLOCKED',
      v_result,
      jsonb_strip_nulls(jsonb_build_object(
        'model_name', p_model_name
      ))
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
    model_name,
    model_metadata,
    processed_at
  )
  values (
    p_empresa_id,
    p_conversation_id,
    'OUTBOUND',
    'AI',
    'Valentina',
    v_channel,
    'TEXT',
    v_text,
    v_text,
    'NOT_REQUIRED',
    'COMPLETED',
    p_model_name,
    coalesce(p_model_metadata, '{}'::jsonb),
    now()
  )
  returning id into v_message_id;

  update public.atlas_conversations c
  set
    last_message_at = now(),
    updated_at = now()
  where c.id = p_conversation_id
    and c.empresa_id = p_empresa_id;

  return jsonb_build_object(
    'ok', true,
    'code', 'AI_RESPONSE_REGISTERED',
    'message_id', v_message_id,
    'conversation_id', p_conversation_id,
    'direction', 'OUTBOUND',
    'actor', 'VALENTINA',
    'message_type', 'TEXT',
    'text_content', v_text,
    'status', 'COMPLETED'
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.atlas_register_ai_response(p_empresa_id uuid, p_conversation_id uuid, p_text_content text, p_model_name text DEFAULT NULL::text, p_model_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_result jsonb; v_intent jsonb; v_delivery_id uuid;
begin
 v_result:=public.atlas_register_ai_response_canonical_base(p_empresa_id,p_conversation_id,p_text_content,p_model_name,p_model_metadata);
 if coalesce((v_result->>'ok')::boolean,false) and v_result->>'message_id' is not null then
   v_intent:=public.atlas_create_whatsapp_delivery_intent((v_result->>'message_id')::uuid,p_empresa_id,p_conversation_id,'AI');
   v_delivery_id:=(v_intent->>'delivery_id')::uuid;
   perform public.atlas_reconcile_whatsapp_delivery_intent(v_delivery_id);
 end if;
 return v_result;
end $function$
;

revoke all on function public.atlas_record_conversation_control_event(uuid,uuid,text,text,text,uuid,text,text,text,uuid,uuid,text,jsonb,jsonb) from public, anon;
grant execute on function public.atlas_record_conversation_control_event(uuid,uuid,text,text,text,uuid,text,text,text,uuid,uuid,text,jsonb,jsonb) to authenticated, service_role;

revoke all on function public.atlas_register_ai_response_canonical_base(uuid,uuid,text,text,jsonb) from public, anon;
grant execute on function public.atlas_register_ai_response_canonical_base(uuid,uuid,text,text,jsonb) to authenticated, service_role;

revoke all on function public.atlas_register_ai_response(uuid,uuid,text,text,jsonb) from public, anon;
grant execute on function public.atlas_register_ai_response(uuid,uuid,text,text,jsonb) to authenticated, service_role;

commit;
