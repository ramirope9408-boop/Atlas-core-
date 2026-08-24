begin;

CREATE OR REPLACE FUNCTION public.atlas_web_list_internal_conversations(p_empresa_id uuid, p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user_id uuid;
  v_limit integer;
  v_conversations jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_empresa_id is null then
    raise exception using
      errcode = '22023',
      message = 'EMPRESA_ID_REQUIRED';
  end if;

  if not public.atlas_internal_has_permission(
    p_empresa_id,
    'INTERNAL_CHAT_USE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INTERNAL_CHAT_PERMISSION_REQUIRED';
  end if;

  v_limit := least(
    greatest(coalesce(p_limit, 30), 1),
    100
  );

  select coalesce(
    jsonb_agg(
      conversation_row.payload
      order by conversation_row.sort_at desc
    ),
    '[]'::jsonb
  )
  into v_conversations
  from (
    select
      coalesce(
        last_message.created_at,
        conversation.updated_at,
        conversation.created_at
      ) as sort_at,

      jsonb_build_object(
        'id',
        conversation.id,

        'empresa_id',
        conversation.empresa_id,

        'agent_code',
        conversation.agent_code,

        'mode',
        conversation.mode,

        'title',
        conversation.title,

        'status',
        conversation.status,

        'created_at',
        conversation.created_at,

        'updated_at',
        conversation.updated_at,

        'last_activity_at',
        coalesce(
          last_message.created_at,
          conversation.updated_at,
          conversation.created_at
        ),

        'last_message',
        case
          when last_message.id is null then null
          else jsonb_build_object(
            'id',
            last_message.id,
            'actor_type',
            last_message.actor_type,
            'direction',
            last_message.direction,
            'message_type',
            last_message.message_type,
            'text_content',
            last_message.text_content,
            'created_at',
            last_message.created_at
          )
        end,

        'message_count',
        (
          select count(*)
          from public.atlas_internal_messages message_count
          where message_count.empresa_id =
                  conversation.empresa_id
            and message_count.conversation_id =
                  conversation.id
            and lower(
              coalesce(
                message_count.metadata ->> 'fixture',
                'false'
              )
            ) <> 'true'
        )
      ) as payload

    from public.atlas_internal_conversations conversation

    left join lateral (
      select
        message.id,
        message.actor_type,
        message.direction,
        message.message_type,
        message.text_content,
        message.created_at
      from public.atlas_internal_messages message
      where message.empresa_id =
              conversation.empresa_id
        and message.conversation_id =
              conversation.id
        and lower(
          coalesce(
            message.metadata ->> 'fixture',
            'false'
          )
        ) <> 'true'
      order by message.created_at desc
      limit 1
    ) last_message on true

    where conversation.empresa_id = p_empresa_id
      and conversation.user_id = v_user_id
      and conversation.agent_code = 'VALENTINA'
      and conversation.status <> 'ARCHIVED'

    order by
      coalesce(
        last_message.created_at,
        conversation.updated_at,
        conversation.created_at
      ) desc

    limit v_limit
  ) conversation_row;

  return jsonb_build_object(
    'runtime_version',
    'ATLAS_WEB_INTERNAL_CONVERSATIONS_V1',

    'list_status',
    'READY',

    'safe_to_continue',
    true,

    'empresa_id',
    p_empresa_id,

    'user_id',
    v_user_id,

    'conversation_count',
    jsonb_array_length(v_conversations),

    'conversations',
    v_conversations
  );
end;
$function$


revoke all on function public.atlas_web_list_internal_conversations(uuid,integer) from public, anon;
grant execute on function public.atlas_web_list_internal_conversations(uuid,integer) to authenticated, service_role;
comment on function public.atlas_web_list_internal_conversations(uuid,integer) is 'B1C browser-safe personal Valentina conversation listing.';

CREATE OR REPLACE FUNCTION public.atlas_web_get_internal_messages(p_conversation_id uuid, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user_id uuid;
  v_limit integer;
  v_conversation public.atlas_internal_conversations%rowtype;
  v_messages jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_conversation_id is null then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_ID_REQUIRED';
  end if;

  select conversation.*
  into v_conversation
  from public.atlas_internal_conversations conversation
  where conversation.id = p_conversation_id
    and conversation.user_id = v_user_id
    and conversation.agent_code = 'VALENTINA';

  if not found then
    raise exception using
      errcode = '42501',
      message = 'CONVERSATION_NOT_AVAILABLE';
  end if;

  if not public.atlas_internal_has_permission(
    v_conversation.empresa_id,
    'INTERNAL_CHAT_USE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INTERNAL_CHAT_PERMISSION_REQUIRED';
  end if;

  v_limit := least(
    greatest(coalesce(p_limit, 100), 1),
    250
  );

  select coalesce(
    jsonb_agg(
      selected_message.payload
      order by selected_message.created_at asc
    ),
    '[]'::jsonb
  )
  into v_messages
  from (
    select
      message.created_at,

      jsonb_build_object(
        'id',
        message.id,

        'actor_type',
        message.actor_type,

        'agent_code',
        message.agent_code,

        'direction',
        message.direction,

        'message_type',
        message.message_type,

        'text_content',
        message.text_content,

        'audio_reference',
        message.audio_reference,

        'transcription_text',
        message.transcription_text,

        'created_at',
        message.created_at,

        'evidence',
        jsonb_strip_nulls(
          jsonb_build_object(
            'decision_id',
            message.metadata -> 'decision_id',

            'response_type',
            message.metadata -> 'response_type',

            'tool_result_used',
            message.metadata -> 'tool_result_used',

            'safe_to_continue',
            message.metadata -> 'safe_to_continue',

            'runtime_version',
            message.metadata -> 'runtime_version'
          )
        )
      ) as payload

    from public.atlas_internal_messages message

    where message.empresa_id =
            v_conversation.empresa_id
      and message.conversation_id =
            v_conversation.id
      and lower(
        coalesce(
          message.metadata ->> 'fixture',
          'false'
        )
      ) <> 'true'

    order by message.created_at desc
    limit v_limit
  ) selected_message;

  return jsonb_build_object(
    'runtime_version',
    'ATLAS_WEB_INTERNAL_MESSAGES_V1',

    'read_status',
    'READY',

    'safe_to_continue',
    true,

    'conversation',
    jsonb_build_object(
      'id',
      v_conversation.id,

      'empresa_id',
      v_conversation.empresa_id,

      'agent_code',
      v_conversation.agent_code,

      'mode',
      v_conversation.mode,

      'title',
      v_conversation.title,

      'status',
      v_conversation.status,

      'created_at',
      v_conversation.created_at,

      'updated_at',
      v_conversation.updated_at
    ),

    'message_count',
    jsonb_array_length(v_messages),

    'messages',
    v_messages
  );
end;
$function$


revoke all on function public.atlas_web_get_internal_messages(uuid,integer) from public, anon;
grant execute on function public.atlas_web_get_internal_messages(uuid,integer) to authenticated, service_role;
comment on function public.atlas_web_get_internal_messages(uuid,integer) is 'B1C browser-safe personal internal message reader.';

CREATE OR REPLACE FUNCTION public.atlas_web_open_internal_conversation(p_empresa_id uuid, p_title text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user_id uuid;
  v_title text;
  v_internal_result jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_empresa_id is null then
    raise exception using
      errcode = '22023',
      message = 'EMPRESA_ID_REQUIRED';
  end if;

  if not public.atlas_internal_has_permission(
    p_empresa_id,
    'INTERNAL_CHAT_USE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INTERNAL_CHAT_PERMISSION_REQUIRED';
  end if;

  v_title := nullif(btrim(p_title), '');

  if v_title is null then
    v_title := 'Nueva conversación';
  end if;

  if char_length(v_title) > 120 then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_TITLE_TOO_LONG';
  end if;

  select public.atlas_internal_open_conversation(
    p_empresa_id => p_empresa_id,
    p_agent_code => 'VALENTINA',
    p_mode => 'INTERNAL_OPERATOR',
    p_title => v_title
  )
  into v_internal_result;

  if coalesce(v_internal_result ->> 'status', '') <> 'OPEN' then
    raise exception using
      errcode = 'P0001',
      message = 'CONVERSATION_OPEN_FAILED';
  end if;

  return jsonb_build_object(
    'runtime_version',
    'ATLAS_WEB_OPEN_INTERNAL_CONVERSATION_V1',

    'open_status',
    'OPEN',

    'safe_to_continue',
    true,

    'conversation_id',
    v_internal_result -> 'conversation_id',

    'empresa_id',
    v_internal_result -> 'empresa_id',

    'user_id',
    v_internal_result -> 'user_id',

    'agent_code',
    'VALENTINA',

    'mode',
    'INTERNAL_OPERATOR',

    'title',
    v_title
  );
end;
$function$


revoke all on function public.atlas_web_open_internal_conversation(uuid,text) from public, anon;
grant execute on function public.atlas_web_open_internal_conversation(uuid,text) to authenticated, service_role;
comment on function public.atlas_web_open_internal_conversation(uuid,text) is 'B1C strict wrapper for opening a personal Valentina conversation.';

CREATE OR REPLACE FUNCTION public.atlas_web_register_internal_text_message(p_conversation_id uuid, p_text_content text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user_id uuid;
  v_text text;
  v_conversation public.atlas_internal_conversations%rowtype;
  v_internal_result jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if p_conversation_id is null then
    raise exception using
      errcode = '22023',
      message = 'CONVERSATION_ID_REQUIRED';
  end if;

  v_text := nullif(btrim(p_text_content), '');

  if v_text is null then
    raise exception using
      errcode = '22023',
      message = 'MESSAGE_TEXT_REQUIRED';
  end if;

  if char_length(v_text) > 8000 then
    raise exception using
      errcode = '22023',
      message = 'MESSAGE_TEXT_TOO_LONG';
  end if;

  select conversation.*
  into v_conversation
  from public.atlas_internal_conversations conversation
  where conversation.id = p_conversation_id
    and conversation.user_id = v_user_id
    and conversation.agent_code = 'VALENTINA';

  if not found then
    raise exception using
      errcode = '42501',
      message = 'CONVERSATION_NOT_AVAILABLE';
  end if;

  if v_conversation.status <> 'OPEN' then
    raise exception using
      errcode = '55000',
      message = 'CONVERSATION_IS_NOT_OPEN';
  end if;

  if not public.atlas_internal_has_permission(
    v_conversation.empresa_id,
    'INTERNAL_CHAT_USE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INTERNAL_CHAT_PERMISSION_REQUIRED';
  end if;

  select public.atlas_internal_register_message(
    p_empresa_id =>
      v_conversation.empresa_id,

    p_conversation_id =>
      v_conversation.id,

    p_actor_type =>
      'USER',

    p_direction =>
      'INBOUND',

    p_message_type =>
      'TEXT',

    p_text_content =>
      v_text,

    p_audio_reference =>
      null,

    p_transcription_text =>
      null,

    p_transcription_metadata =>
      '{}'::jsonb,

    p_metadata =>
      jsonb_build_object(
        'source',
        'ATLAS_WEB_B1C',

        'runtime_version',
        'ATLAS_WEB_REGISTER_INTERNAL_TEXT_V1',

        'registered_by',
        v_user_id
      ),

    p_agent_code =>
      'VALENTINA'
  )
  into v_internal_result;

  if coalesce(
    v_internal_result ->> 'status',
    ''
  ) <> 'REGISTERED' then
    raise exception using
      errcode = 'P0001',
      message = 'MESSAGE_REGISTRATION_FAILED';
  end if;

  update public.atlas_internal_conversations
  set updated_at = now()
  where id = v_conversation.id
    and empresa_id = v_conversation.empresa_id
    and user_id = v_user_id;

  return jsonb_build_object(
    'runtime_version',
    'ATLAS_WEB_REGISTER_INTERNAL_TEXT_V1',

    'registration_status',
    'REGISTERED',

    'safe_to_continue',
    true,

    'message_id',
    v_internal_result -> 'message_id',

    'conversation_id',
    v_conversation.id,

    'empresa_id',
    v_conversation.empresa_id,

    'message',
    jsonb_build_object(
      'id',
      v_internal_result -> 'message_id',

      'actor_type',
      'USER',

      'direction',
      'INBOUND',

      'message_type',
      'TEXT',

      'text_content',
      v_text
    )
  );
end;
$function$


revoke all on function public.atlas_web_register_internal_text_message(uuid,text) from public, anon;
grant execute on function public.atlas_web_register_internal_text_message(uuid,text) to authenticated, service_role;
comment on function public.atlas_web_register_internal_text_message(uuid,text) is 'B1C strict wrapper for registering an authenticated human text message.';

commit;