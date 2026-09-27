-- ATLAS / VALENTINA V9 backend recovery snapshot
-- Recovered read-only from production on 2026-09-27.
-- Purpose: restore the external quote/acceptance/payment runtime into the isolated certification branch.
-- No production schema modification is performed by this file.

-- atlas_prepare_quote_acceptance_plan_v1
CREATE OR REPLACE FUNCTION public.atlas_prepare_quote_acceptance_plan_v1(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_interpretation jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_source text; v_norm text; v_ctx jsonb; v_conf numeric; v_intent text;
 v_ambiguities jsonb; v_patch jsonb; v_grounding jsonb; v_evidence text;
 v_issued timestamptz; v_created timestamptz;
begin
 select coalesce(m.text_content,m.transcription_text,''),m.created_at into v_source,v_created
 from public.atlas_conversation_messages m
 where m.id=p_source_message_id and m.empresa_id=p_empresa_id and m.conversation_id=p_conversation_id
   and m.direction='INBOUND' and m.actor_type='CUSTOMER';
 if not found then raise exception 'SOURCE_MESSAGE_NOT_AVAILABLE'; end if;
 v_intent:=lower(coalesce(p_interpretation->>'primary_intent',''));
 begin v_conf:=(p_interpretation->>'intent_confidence')::numeric; exception when others then v_conf:=0; end;
 v_patch:=coalesce(p_interpretation->'patch','{}'::jsonb);
 v_ambiguities:=coalesce(p_interpretation->'ambiguities','[]'::jsonb);
 v_grounding:=coalesce(p_interpretation->'grounding','{}'::jsonb);
 v_ctx:=public.atlas_resolve_customer_visible_quote_context_v1(p_empresa_id,p_conversation_id);
 if v_intent<>'accept_quote' then return jsonb_build_object('ready_to_act',false,'code','INTENT_NOT_ACCEPT_QUOTE','context',v_ctx); end if;
 if coalesce((v_ctx->>'found')::boolean,false) is not true then return jsonb_build_object('ready_to_act',false,'code','CUSTOMER_VISIBLE_QUOTE_NOT_FOUND','context',v_ctx); end if;
 if v_conf<0.90 then return jsonb_build_object('ready_to_act',false,'code','ACCEPTANCE_CONFIDENCE_TOO_LOW','clarification_required',true,'context',v_ctx); end if;
 if jsonb_typeof(v_ambiguities)<>'array' or jsonb_array_length(v_ambiguities)>0 then return jsonb_build_object('ready_to_act',false,'code','QUOTE_ACCEPTANCE_AMBIGUOUS','clarification_required',true,'context',v_ctx); end if;
 if jsonb_typeof(v_patch)<>'object' or v_patch<>'{}'::jsonb then return jsonb_build_object('ready_to_act',false,'code','ACCEPTANCE_WITH_PATCH_FORBIDDEN','clarification_required',true,'context',v_ctx); end if;
 if nullif(v_grounding->>'source_message_id','') is distinct from p_source_message_id::text then raise exception 'GROUNDING_SOURCE_MESSAGE_MISMATCH'; end if;
 v_evidence:=btrim(coalesce(v_grounding->>'acceptance_evidence',''));
 if length(v_evidence)<4 or position(lower(v_evidence) in lower(v_source))=0 then
   return jsonb_build_object('ready_to_act',false,'code','EXPLICIT_ACCEPTANCE_GROUNDING_REQUIRED','clarification_required',true,'context',v_ctx);
 end if;
 v_norm:=public.atlas_normalize_quote_query_v1(v_source);
 if v_norm ~ '(^| )(cambia|cambiame|cambiar|quita|quitame|elimina|eliminame|agrega|agregame|anade|anademe|modifica|modificame|ajusta|ajustame)( |$)'
    or v_norm like '%pero cambia%' or v_norm like '%pero quita%' or v_norm like '%pero agrega%' then
   return jsonb_build_object('ready_to_act',false,'code','MODIFICATION_SIGNAL_OVERRIDES_ACCEPTANCE','next_action','REINTERPRET_AS_MODIFICATION','context',v_ctx);
 end if;
 if position('?' in v_source)>0 then
   return jsonb_build_object('ready_to_act',false,'code','QUESTION_OVERRIDES_ACCEPTANCE','next_action','ANSWER_QUESTION','context',v_ctx);
 end if;
 if not (v_norm ~ '(^| )(acepto|aceptamos|confirmo|confirmamos|apruebo|aprobamos)( |$)'
         or v_norm like '%acepto la cotizacion%' or v_norm like '%confirmo la cotizacion%'
         or v_norm like '%apruebo la cotizacion%' or v_norm like '%acepto la propuesta%') then
   return jsonb_build_object('ready_to_act',false,'code','EXPLICIT_ACCEPTANCE_LANGUAGE_REQUIRED','clarification_required',true,'context',v_ctx);
 end if;
 v_issued:=nullif(v_ctx->>'document_issued_at','')::timestamptz;
 if v_issued is null or v_created<v_issued then
   return jsonb_build_object('ready_to_act',false,'code','ACCEPTANCE_SOURCE_PREDATES_VISIBLE_QUOTE','context',v_ctx);
 end if;
 return jsonb_build_object('ready_to_act',true,'code','QUOTE_ACCEPTANCE_PLAN_READY_V1','intent','accept_quote','confidence',v_conf,
  'source_message_id',p_source_message_id,'quote_builder_id',v_ctx->>'quote_builder_id','document_display_id',v_ctx->>'document_display_id',
  'quote_version',v_ctx->>'quote_version','acceptance_evidence',v_evidence,'active_quote',v_ctx,
  'truth_basis','LAST_ISSUED_TO_CUSTOMER_TEMPORALLY_VALID','next_action','ACCEPT_CUSTOMER_VISIBLE_QUOTE');
end $function$;

-- atlas_validate_external_quote_interpretation_v2
CREATE OR REPLACE FUNCTION public.atlas_validate_external_quote_interpretation_v2(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_interpretation jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_allowed_intents text[]:=array['explore','ask_information','ask_price','request_recommendation','request_quote','modify_quote','accept_quote','reject_quote','compare_options','request_availability','provide_data','complain','post_sale','request_human','unrelated','unknown'];
 v_allowed_keys text[]:=array['people_count','event_date','event_location','products','services'];
 v_intent text; v_conf numeric; v_patch jsonb; v_ambiguities jsonb; v_grounding jsonb; v_key text; v_item jsonb;
 v_source text; v_visible jsonb; v_visible_qb uuid; v_pid uuid; v_evidence text; v_has boolean;
begin
 if p_interpretation is null or jsonb_typeof(p_interpretation)<>'object' then raise exception 'INTERPRETATION_OBJECT_REQUIRED'; end if;
 select coalesce(m.transcription_text,m.text_content) into v_source from public.atlas_conversation_messages m
 where m.id=p_source_message_id and m.empresa_id=p_empresa_id and m.conversation_id=p_conversation_id and m.direction='INBOUND' and m.actor_type='CUSTOMER';
 if not found then raise exception 'SOURCE_MESSAGE_NOT_AVAILABLE'; end if;
 v_intent:=lower(coalesce(p_interpretation->>'primary_intent',''));
 if not(v_intent=any(v_allowed_intents)) then raise exception 'UNSUPPORTED_PRIMARY_INTENT'; end if;
 begin v_conf:=(p_interpretation->>'intent_confidence')::numeric; exception when others then raise exception 'INVALID_INTENT_CONFIDENCE'; end;
 if v_conf is null or v_conf<0 or v_conf>1 then raise exception 'INVALID_INTENT_CONFIDENCE'; end if;
 v_patch:=coalesce(p_interpretation->'patch','{}'::jsonb); v_ambiguities:=coalesce(p_interpretation->'ambiguities','[]'::jsonb); v_grounding:=coalesce(p_interpretation->'grounding','{}'::jsonb);
 if jsonb_typeof(v_patch)<>'object' then raise exception 'PATCH_OBJECT_REQUIRED'; end if;
 if jsonb_typeof(v_ambiguities)<>'array' then raise exception 'AMBIGUITIES_ARRAY_REQUIRED'; end if;
 if jsonb_typeof(v_grounding)<>'object' then raise exception 'GROUNDING_OBJECT_REQUIRED'; end if;
 if nullif(v_grounding->>'source_message_id','') is distinct from p_source_message_id::text then raise exception 'GROUNDING_SOURCE_MESSAGE_MISMATCH'; end if;
 for v_key in select jsonb_object_keys(v_patch) loop if not(v_key=any(v_allowed_keys)) then raise exception 'UNSUPPORTED_PATCH_KEY: %',v_key; end if; end loop;
 if v_intent='accept_quote' then
   return public.atlas_prepare_quote_acceptance_plan_v1(p_empresa_id,p_conversation_id,p_source_message_id,p_interpretation);
 end if;
 v_visible:=public.atlas_resolve_customer_visible_quote_context_v1(p_empresa_id,p_conversation_id);
 if v_intent='modify_quote' and coalesce((v_visible->>'found')::boolean,false) is not true then
   return jsonb_build_object('ready_to_act',false,'code','CUSTOMER_VISIBLE_QUOTE_NOT_FOUND','clarification_required',true,'context',v_visible);
 end if;
 v_visible_qb:=nullif(v_visible->>'quote_builder_id','')::uuid;
 if v_patch?'people_count' then
  if jsonb_typeof(v_patch->'people_count')<>'number' or (v_patch->>'people_count')::numeric<=0 or trunc((v_patch->>'people_count')::numeric)<>(v_patch->>'people_count')::numeric then raise exception 'INVALID_PEOPLE_COUNT_PATCH'; end if;
  v_evidence:=coalesce(v_grounding->>'people_count_evidence','');
  if btrim(v_evidence)='' or position(lower(v_evidence) in lower(v_source))=0 then raise exception 'PEOPLE_COUNT_GROUNDING_REQUIRED'; end if;
 end if;
 if v_patch?'event_date' then begin perform (v_patch->>'event_date')::date; exception when others then raise exception 'INVALID_EVENT_DATE_PATCH'; end; end if;
 if v_patch?'event_location' and btrim(coalesce(v_patch->>'event_location',''))='' then raise exception 'INVALID_EVENT_LOCATION_PATCH'; end if;
 if v_patch?'products' then
  if jsonb_typeof(v_patch->'products')<>'array' then raise exception 'PRODUCT_PATCH_ARRAY_REQUIRED'; end if;
  for v_item in select value from jsonb_array_elements(v_patch->'products') loop
   if upper(coalesce(v_item->>'op','')) not in ('SET','ADD','REMOVE') then raise exception 'INVALID_PRODUCT_PATCH_OP'; end if;
   begin v_pid:=(v_item->>'product_id')::uuid; exception when others then raise exception 'INVALID_PRODUCT_ID'; end;
   if upper(v_item->>'op') in ('SET','ADD') and (not(v_item?'quantity') or (v_item->>'quantity')::numeric<=0) then raise exception 'PRODUCT_QUANTITY_REQUIRED'; end if;
   if upper(v_item->>'op') in ('REMOVE','SET') then
    select exists(select 1 from public.atlas_quote_line_items li where li.empresa_id=p_empresa_id and li.quote_builder_id=v_visible_qb and li.producto_id=v_pid) into v_has;
    if not v_has then raise exception 'PRODUCT_PATCH_NOT_IN_CUSTOMER_VISIBLE_QUOTE'; end if;
   else
    select exists(select 1 from public.productos p where p.empresa_id=p_empresa_id and p.id=v_pid and p.activo=true and p.estado='published' and p.deleted_at is null) into v_has;
    if not v_has then raise exception 'ADD_PRODUCT_NOT_IN_CANONICAL_CATALOG'; end if;
   end if;
   select g->>'evidence_text' into v_evidence from jsonb_array_elements(coalesce(v_grounding->'product_operations','[]'::jsonb)) g
    where upper(coalesce(g->>'op',''))=upper(v_item->>'op') and g->>'product_id'=v_item->>'product_id' limit 1;
   if btrim(coalesce(v_evidence,''))='' or position(lower(v_evidence) in lower(v_source))=0 then raise exception 'PRODUCT_OPERATION_GROUNDING_REQUIRED'; end if;
   if not public.atlas_product_grounding_matches_v1(p_empresa_id,v_pid,v_evidence) then raise exception 'PRODUCT_OPERATION_SEMANTIC_GROUNDING_MISMATCH'; end if;
  end loop;
 end if;
 return public.atlas_prepare_quote_modification_plan_v2(p_empresa_id,p_conversation_id,p_source_message_id,
 jsonb_build_object('primary_intent',v_intent,'intent_confidence',v_conf,'patch',v_patch,'ambiguities',v_ambiguities));
end $function$;

-- atlas_accept_customer_visible_quote_v1
CREATE OR REPLACE FUNCTION public.atlas_accept_customer_visible_quote_v1(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_quote_builder_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_visible jsonb;
  v_q public.atlas_quote_builders%rowtype;
  v_id uuid;
  v_source_created_at timestamptz;
begin
  select m.created_at
    into v_source_created_at
  from public.atlas_conversation_messages m
  where m.id=p_source_message_id
    and m.empresa_id=p_empresa_id
    and m.conversation_id=p_conversation_id
    and m.direction='INBOUND'
    and m.actor_type='CUSTOMER';

  if v_source_created_at is null then
    raise exception 'ACCEPTANCE_SOURCE_MESSAGE_INVALID';
  end if;

  v_visible:=public.atlas_resolve_customer_visible_quote_context_v1(p_empresa_id,p_conversation_id);

  if not coalesce((v_visible->>'found')::boolean,false) then
    raise exception 'NO_CUSTOMER_VISIBLE_QUOTE';
  end if;

  if (v_visible->>'quote_builder_id')::uuid is distinct from p_quote_builder_id then
    raise exception 'ACCEPTANCE_QUOTE_NOT_CURRENTLY_VISIBLE';
  end if;

  select * into v_q
  from public.atlas_quote_builders
  where id=p_quote_builder_id and empresa_id=p_empresa_id
  for update;

  if not found or v_q.document_issued_at is null then
    raise exception 'ACCEPTANCE_QUOTE_NOT_ISSUED';
  end if;

  if v_source_created_at < v_q.document_issued_at then
    raise exception 'ACCEPTANCE_SOURCE_MESSAGE_PREDATES_QUOTE';
  end if;

  update public.atlas_quote_acceptances
  set status='SUPERSEDED',
      superseded_at=now(),
      superseded_by_quote_builder_id=p_quote_builder_id,
      updated_at=now()
  where empresa_id=p_empresa_id
    and conversation_id=p_conversation_id
    and status='ACCEPTED'
    and quote_builder_id<>p_quote_builder_id;

  select id into v_id
  from public.atlas_quote_acceptances
  where source_message_id=p_source_message_id;

  if v_id is null then
    insert into public.atlas_quote_acceptances(
      empresa_id,conversation_id,quote_builder_id,source_message_id,
      quote_version,document_display_id
    )
    values(
      p_empresa_id,p_conversation_id,p_quote_builder_id,p_source_message_id,
      v_q.quote_version,v_q.document_display_id
    )
    returning id into v_id;
  end if;

  return jsonb_build_object(
    'ok',true,
    'code','CUSTOMER_VISIBLE_QUOTE_ACCEPTED_V2',
    'acceptance_id',v_id,
    'quote_builder_id',v_q.id,
    'document_display_id',v_q.document_display_id,
    'quote_version',v_q.quote_version,
    'deposit_amount',v_q.deposit_amount,
    'balance_amount',v_q.balance_amount,
    'total',v_q.total,
    'source_message_created_at',v_source_created_at,
    'document_issued_at',v_q.document_issued_at,
    'truth_basis','LAST_ISSUED_TO_CUSTOMER_TEMPORALLY_VALID'
  );
end
$function$;

-- atlas_execute_external_quote_request_v1
CREATE OR REPLACE FUNCTION public.atlas_execute_external_quote_request_v1(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_quote_request jsonb, p_request_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_req jsonb:=coalesce(p_quote_request,'{}'::jsonb);
  v_ctx jsonb; v_source text; v_norm text; v_pc int; v_mentions jsonb;
  v_result jsonb; v_qb uuid; v_group jsonb; v_prior_count int; v_prior_name text;
  v_items jsonb:='[]'::jsonb; v_unresolved jsonb:='[]'::jsonb; v_route jsonb;
  v_plan jsonb; v_options text; v_new_qb uuid; v_old_date date; v_ctx_date date;
begin
  if p_empresa_id is null or p_conversation_id is null or p_source_message_id is null then
    raise exception 'ATLAS_EXTERNAL_QUOTE_SCOPE_REQUIRED' using errcode='22004';
  end if;

  select coalesce(m.text_content,m.transcription_text,'') into v_source
  from public.atlas_conversation_messages m
  where m.id=p_source_message_id and m.empresa_id=p_empresa_id
    and m.conversation_id=p_conversation_id and m.direction='INBOUND' and m.actor_type='CUSTOMER';
  if not found then raise exception 'ATLAS_EXTERNAL_QUOTE_SOURCE_MESSAGE_NOT_AVAILABLE' using errcode='22023'; end if;

  v_norm:=public.atlas_normalize_quote_query_v1(v_source);
  v_ctx:=public.atlas_resolve_active_quote_context_v2(p_empresa_id,p_conversation_id);
  v_qb:=nullif(v_ctx->>'quote_builder_id','')::uuid;

  if v_qb is not null and (
    v_norm ~ '(^| )(envia|enviame|manda|mandame|pasame|dame)( |$).*cotizacion'
    or v_norm like '%cotizacion actualizada%' or v_norm like '%pdf actualizado%'
  ) then
    if coalesce((v_ctx->>'issued')::boolean,false) is false then
      v_result:=public.atlas_finalize_external_quote_revision_v2(p_empresa_id,p_conversation_id,p_source_message_id,v_qb);
    end if;
    return public.atlas_build_external_quote_delivery_payload_v2(p_empresa_id,v_qb)
      || jsonb_build_object('recovery_path',coalesce((v_ctx->>'issued')::boolean,false) is false);
  end if;

  v_route:=public.atlas_prepare_external_quote_route_v2(p_empresa_id,p_conversation_id,p_source_message_id);

  if v_route->>'route'='modify_quote' then
    if jsonb_array_length(coalesce(v_route->'ambiguities','[]'::jsonb))>0 then
      select string_agg(x->>'name',' o ' order by x->>'name') into v_options
      from jsonb_array_elements(coalesce(v_route#>'{ambiguities,0,candidates}','[]'::jsonb)) x;
      return jsonb_build_object(
        'ok',false,'code',coalesce(v_route->>'code','QUOTE_MODIFICATION_CLARIFICATION_REQUIRED'),
        'route_intent','modify_quote','safe_to_send',true,
        'reply_text',case when nullif(v_options,'') is not null then 'Claro. ¿Quieres '||v_options||'?' else 'Claro. Solo me falta un dato puntual para modificar esa cotización.' end,
        'active_quote_builder_id',v_route#>>'{active_quote,quote_builder_id}',
        'active_quote_version',v_route#>>'{active_quote,quote_version}',
        'ambiguities',v_route->'ambiguities','human_handoff_required',false,
        'idempotent_replay',false,'routing_contract','ATLAS_EXTERNAL_QUOTE_ROUTE_V2'
      );
    end if;

    v_plan:=public.atlas_validate_external_quote_interpretation_v2(
      p_empresa_id,p_conversation_id,p_source_message_id,
      jsonb_build_object(
        'primary_intent','modify_quote',
        'intent_confidence',coalesce((v_route->>'confidence')::numeric,0.99),
        'patch',coalesce(v_route->'patch','{}'::jsonb),
        'ambiguities','[]'::jsonb,
        'grounding',jsonb_build_object(
          'source_message_id',p_source_message_id::text,
          'product_operations',coalesce((
            select jsonb_agg(jsonb_build_object(
              'op',upper(x->>'op'),
              'product_id',x->>'product_id',
              'evidence_text',v_source
            ))
            from jsonb_array_elements(coalesce(v_route#>'{patch,products}','[]'::jsonb)) x
          ),'[]'::jsonb),
          'people_count_evidence',case when (v_route->'patch') ? 'people_count' then v_source else null end
        )
      )
    );
    if coalesce((v_plan->>'ready_to_act')::boolean,false) is not true then
      return jsonb_build_object('ok',false,'code',coalesce(v_plan->>'code','QUOTE_MODIFICATION_NOT_READY'),
        'route_intent','modify_quote','safe_to_send',true,
        'reply_text','Claro. Solo me falta un dato puntual para modificar esa cotización.',
        'validated_plan',v_plan,'human_handoff_required',false,'idempotent_replay',false,
        'routing_contract','ATLAS_EXTERNAL_QUOTE_ROUTE_V2');
    end if;

    v_result:=public.atlas_execute_quote_modification_plan_v2(p_empresa_id,p_conversation_id,p_source_message_id,v_plan);
    v_new_qb:=nullif(v_result->>'new_quote_builder_id','')::uuid;
    if v_new_qb is null then raise exception 'QUOTE_MODIFICATION_NEW_QUOTE_ID_MISSING'; end if;

    if coalesce((v_result#>>'{result,validation,ready_for_quote}')::boolean,false) is not true then
      return jsonb_build_object(
        'ok',false,
        'code','QUOTE_MODIFICATION_APPLIED_NOT_READY_FOR_QUOTE',
        'route_intent','modify_quote',
        'safe_to_send',true,
        'reply_text',case
          when coalesce(v_result#>'{result,validation,missing_information}','[]'::jsonb) ? 'products'
            then 'Claro. Puedo quitarlo, pero con ese cambio la cotización quedaría sin productos. Dime qué quieres agregar o reemplazar y te la ajusto.'
          else 'Claro. Ya tomé el cambio, pero todavía falta información para poder emitir la cotización actualizada.'
        end,
        'new_quote_builder_id',v_new_qb,
        'validation',coalesce(v_result#>'{result,validation}','{}'::jsonb),
        'modification_execution',v_result,
        'human_handoff_required',false,
        'idempotent_replay',coalesce((v_result->>'idempotent_replay')::boolean,false),
        'routing_contract','ATLAS_EXTERNAL_QUOTE_ROUTE_V2'
      );
    end if;

    perform public.atlas_finalize_external_quote_revision_v2(p_empresa_id,p_conversation_id,p_source_message_id,v_new_qb);
    return public.atlas_build_external_quote_delivery_payload_v2(p_empresa_id,v_new_qb)
      || jsonb_build_object('route_intent','modify_quote','modification_execution',v_result);
  end if;

  if v_qb is not null then
    -- Product quantities must never silently overwrite event headcount.
    -- Only explicit headcount language may authorize a people_count change.
    if nullif(v_ctx->>'people_count','') is not null
       and v_norm !~ '(^| )(persona|personas|invitado|invitados|asistente|asistentes|comensal|comensales|pax)( |$)'
    then
      v_req:=jsonb_set(v_req,'{people_count}',to_jsonb((v_ctx->>'people_count')::int),true);
    end if;
    begin v_old_date:=nullif(btrim(v_req->>'event_date'),'')::date; exception when others then v_old_date:=null; end;
    begin v_ctx_date:=nullif(v_ctx->>'event_date','')::date; exception when others then v_ctx_date:=null; end;
    if v_ctx_date is not null and (v_old_date is null or v_old_date<current_date) then
      v_req:=jsonb_set(v_req,'{event_date}',to_jsonb(v_ctx_date::text),true);
    end if;
    if nullif(btrim(v_req->>'people_count'),'') is null and nullif(v_ctx->>'people_count','') is not null then
      v_req:=jsonb_set(v_req,'{people_count}',to_jsonb((v_ctx->>'people_count')::int),true);
    end if;
    if nullif(btrim(v_req->>'event_location'),'') is null and nullif(v_ctx->>'event_location','') is not null then
      v_req:=jsonb_set(v_req,'{event_location}',to_jsonb(v_ctx->>'event_location'),true);
    end if;
  end if;

  begin v_pc:=nullif(btrim(v_req->>'people_count'),'')::int; exception when others then v_pc:=null; end;
  if not (v_req?'items') or jsonb_typeof(v_req->'items')<>'array' or jsonb_array_length(v_req->'items')=0 then
    v_mentions:=public.atlas_extract_external_quote_mentions_v1(p_empresa_id,v_source,v_pc);
    v_items:=coalesce(v_mentions->'items','[]'::jsonb);
    for v_group in select value from jsonb_array_elements(coalesce(v_mentions->'candidate_groups','[]'::jsonb))
    loop
      v_prior_count:=0; v_prior_name:=null;
      if v_qb is not null then
        select count(*),min(p.nombre) into v_prior_count,v_prior_name
        from public.atlas_quote_line_items li join public.productos p on p.id=li.producto_id and p.empresa_id=li.empresa_id
        where li.quote_builder_id=v_qb and li.empresa_id=p_empresa_id
          and exists(select 1 from jsonb_array_elements(v_group->'candidates') c where (c->>'product_id')::uuid=li.producto_id);
      end if;
      if v_prior_count=1 then
        v_items:=v_items||jsonb_build_array(jsonb_build_object('query',v_prior_name,'quantity',v_pc,'resolution','ACTIVE_QUOTE_CONTEXT'));
      else v_unresolved:=v_unresolved||jsonb_build_array(v_group); end if;
    end loop;
    if jsonb_array_length(v_items)>0 then v_req:=jsonb_set(v_req,'{items}',v_items,true); end if;
  end if;

  if (not (v_req?'items') or jsonb_typeof(v_req->'items')<>'array' or jsonb_array_length(v_req->'items')=0)
     and jsonb_array_length(v_unresolved)>0 then
    return jsonb_build_object('ok',false,'code','QUOTE_CLARIFICATION_PRODUCT_VARIANT_REQUIRED','safe_to_send',true,
      'reply_text','Ya tengo los productos. Solo me falta precisar cuál variante quieres de cada uno para cotizarte exactamente.',
      'mentioned_products',v_unresolved,'human_handoff_required',false,'idempotent_replay',false);
  end if;

  v_result:=public.atlas_execute_external_quote_request_v1_legacy(p_empresa_id,p_conversation_id,p_source_message_id,v_req,p_request_key);
  return coalesce(v_result,'{}'::jsonb)||jsonb_build_object(
    'context_preservation_applied',true,'mention_extraction_applied',jsonb_array_length(v_items)>0,
    'compatibility_contract','ATLAS_EXTERNAL_WHATSAPP_QUOTE_BRIDGE_V1_7');
end
$function$;

-- atlas_execute_quote_modification_plan_v2
CREATE OR REPLACE FUNCTION public.atlas_execute_quote_modification_plan_v2(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_validated_plan jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_visible jsonb;
  v_source_id uuid;
  v_revision jsonb;
  v_new_id uuid;
  v_result jsonb;
  v_patch jsonb;
  v_exec public.atlas_quote_modification_executions%rowtype;
  v_supersede jsonb;
begin
  if p_validated_plan is null or jsonb_typeof(p_validated_plan)<>'object' then
    raise exception 'VALIDATED_PLAN_OBJECT_REQUIRED';
  end if;

  if coalesce((p_validated_plan->>'ready_to_act')::boolean,false) is not true
     or p_validated_plan->>'code'<>'QUOTE_MODIFICATION_PLAN_READY_V2'
     or p_validated_plan->>'next_action'<>'CREATE_REVISION_THEN_APPLY_PATCH' then
    raise exception 'VALIDATED_PLAN_NOT_EXECUTABLE';
  end if;

  if p_validated_plan->>'source_message_id' is distinct from p_source_message_id::text then
    raise exception 'SOURCE_MESSAGE_PLAN_MISMATCH';
  end if;

  if not exists(
    select 1
    from public.atlas_conversation_messages m
    where m.id=p_source_message_id
      and m.empresa_id=p_empresa_id
      and m.conversation_id=p_conversation_id
      and m.direction='INBOUND'
      and m.actor_type='CUSTOMER'
  ) then
    raise exception 'SOURCE_MESSAGE_NOT_AVAILABLE';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_empresa_id::text||':'||p_source_message_id::text,0));

  select * into v_exec
  from public.atlas_quote_modification_executions
  where empresa_id=p_empresa_id and source_message_id=p_source_message_id;

  if found then
    if v_exec.status='COMPLETED' then
      return v_exec.result||jsonb_build_object('idempotent_replay',true,'execution_id',v_exec.id);
    end if;
    raise exception 'QUOTE_MODIFICATION_EXECUTION_IN_PROGRESS';
  end if;

  v_visible:=public.atlas_resolve_customer_visible_quote_context_v1(p_empresa_id,p_conversation_id);

  if coalesce((v_visible->>'found')::boolean,false) is not true then
    raise exception 'CUSTOMER_VISIBLE_QUOTE_NOT_FOUND';
  end if;

  v_source_id:=(v_visible->>'quote_builder_id')::uuid;

  if p_validated_plan#>>'{active_quote,quote_builder_id}' is distinct from v_source_id::text then
    raise exception 'STALE_CUSTOMER_VISIBLE_QUOTE_PLAN';
  end if;

  v_patch:=p_validated_plan->'patch';

  if v_patch is null or jsonb_typeof(v_patch)<>'object' then
    raise exception 'PATCH_OBJECT_REQUIRED';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(coalesce(v_patch->'products','[]'::jsonb)) x
    where upper(coalesce(x->>'op','')) in ('REMOVE','SET')
      and not exists(
        select 1
        from public.atlas_quote_line_items li
        where li.quote_builder_id=v_source_id
          and li.empresa_id=p_empresa_id
          and li.producto_id=(x->>'product_id')::uuid
      )
  ) then
    raise exception 'PRODUCT_PATCH_NOT_IN_CUSTOMER_VISIBLE_QUOTE';
  end if;

  insert into public.atlas_quote_modification_executions(
    empresa_id,conversation_id,source_message_id,source_quote_builder_id
  )
  values(p_empresa_id,p_conversation_id,p_source_message_id,v_source_id)
  returning * into v_exec;

  v_revision:=public.atlas_create_quote_revision_v2(
    v_source_id,
    p_empresa_id,
    'Semantic modification from customer-visible quote '||p_source_message_id::text,
    (select coalesce(m.text_content,m.transcription_text)
       from public.atlas_conversation_messages m
      where m.id=p_source_message_id),
    'WHATSAPP'
  );

  v_new_id:=(v_revision->>'quote_builder_id')::uuid;

  v_result:=public.atlas_apply_quote_revision_patch_v2(v_new_id,p_empresa_id,v_patch);

  v_supersede:=public.atlas_supersede_quote_acceptance_on_revision_v1(
    p_empresa_id,
    p_conversation_id,
    v_new_id
  );

  v_result:=jsonb_build_object(
    'ok',true,
    'code','QUOTE_MODIFICATION_EXECUTED_CUSTOMER_VISIBLE_V4',
    'source_quote_builder_id',v_source_id,
    'new_quote_builder_id',v_new_id,
    'quote_version',v_result->'quote_version',
    'result',v_result,
    'acceptance_invalidation',v_supersede,
    'truth_basis','LAST_ISSUED_TO_CUSTOMER',
    'idempotent_replay',false,
    'execution_id',v_exec.id
  );

  update public.atlas_quote_modification_executions
  set new_quote_builder_id=v_new_id,
      status='COMPLETED',
      result=v_result,
      completed_at=now()
  where id=v_exec.id;

  return v_result;
end
$function$;

-- atlas_resolve_active_quote_context_v2
CREATE OR REPLACE FUNCTION public.atlas_resolve_active_quote_context_v2(p_empresa_id uuid, p_conversation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_c public.atlas_conversations%rowtype;
 v_q public.atlas_quote_builders%rowtype;
begin
 select * into v_c from public.atlas_conversations
 where id=p_conversation_id and empresa_id=p_empresa_id;
 if not found then raise exception 'CONVERSATION_NOT_FOUND_FOR_COMPANY'; end if;

 select qb.* into v_q
 from public.atlas_quote_builders qb
 where qb.empresa_id=p_empresa_id
   and (
     qb.metadata->>'conversation_id'=p_conversation_id::text
     or qb.id in (
       select c.quote_builder_id from public.cotizaciones c
       where c.empresa_id=p_empresa_id
         and c.referencia_externa like 'WHATSAPP:'||p_conversation_id::text||':%'
         and c.deleted_at is null
     )
   )
 order by coalesce(qb.document_issued_at,qb.updated_at,qb.created_at) desc,
          qb.quote_version desc, qb.updated_at desc
 limit 1;

 if not found then
   return jsonb_build_object('found',false,'conversation_id',p_conversation_id);
 end if;

 return jsonb_build_object(
  'found',true,'conversation_id',p_conversation_id,
  'quote_builder_id',v_q.id,'quote_version',v_q.quote_version,
  'root_quote_builder_id',coalesce(v_q.root_quote_builder_id,v_q.id),
  'status',v_q.status,'people_count',v_q.people_count,'event_date',v_q.event_date,
  'event_location',v_q.event_location,'total',v_q.total,
  'deposit_amount',v_q.deposit_amount,'balance_amount',v_q.balance_amount,
  'issued',v_q.document_issued_at is not null
 );
end;
$function$;

-- atlas_resolve_customer_visible_quote_context_v1
CREATE OR REPLACE FUNCTION public.atlas_resolve_customer_visible_quote_context_v1(p_empresa_id uuid, p_conversation_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
with q as (
 select qb.*
 from public.atlas_quote_builders qb
 left join public.cotizaciones c on c.quote_builder_id=qb.id
 where qb.empresa_id=p_empresa_id
   and qb.document_issued_at is not null
   and (qb.metadata->>'conversation_id'=p_conversation_id::text
        or c.referencia_externa='WHATSAPP:'||p_conversation_id::text)
 order by qb.document_issued_at desc,qb.created_at desc
 limit 1
)
select case when exists(select 1 from q) then
 (select jsonb_build_object(
  'found',true,'quote_builder_id',id,'document_display_id',document_display_id,
  'quote_version',quote_version,'root_quote_builder_id',root_quote_builder_id,
  'supersedes_quote_builder_id',supersedes_quote_builder_id,'document_issued_at',document_issued_at,
  'status',status,'people_count',people_count,'event_date',event_date,'event_location',event_location,
  'total',total,'deposit_amount',deposit_amount,'balance_amount',balance_amount,
  'conversation_id',p_conversation_id,'truth_basis','LAST_ISSUED_TO_CUSTOMER'
 ) from q)
 else jsonb_build_object('found',false,'conversation_id',p_conversation_id,'truth_basis','NO_ISSUED_QUOTE') end
$function$;

-- atlas_build_dynamic_payment_payload_v1
CREATE OR REPLACE FUNCTION public.atlas_build_dynamic_payment_payload_v1(p_empresa_id uuid, p_conversation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare a record; q public.atlas_quote_builders%rowtype; v_visible jsonb; methods jsonb;
begin
 select * into a from public.atlas_quote_acceptances where empresa_id=p_empresa_id and conversation_id=p_conversation_id and status='ACCEPTED' order by accepted_at desc limit 1;
 if not found then return jsonb_build_object('ready',false,'code','QUOTE_ACCEPTANCE_REQUIRED'); end if;
 v_visible:=public.atlas_resolve_customer_visible_quote_context_v1(p_empresa_id,p_conversation_id);
 if (v_visible->>'quote_builder_id')::uuid is distinct from a.quote_builder_id then return jsonb_build_object('ready',false,'code','ACCEPTED_QUOTE_IS_STALE'); end if;
 select * into q from public.atlas_quote_builders where id=a.quote_builder_id and empresa_id=p_empresa_id;
 if q.deposit_amount is null or q.deposit_amount<=0 or q.deposit_amount>q.total then return jsonb_build_object('ready',false,'code','INVALID_ACCEPTED_QUOTE_PAYMENT_AMOUNT'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('name',m.nombre,'type',m.tipo,'detail',m.detalle) order by m.nombre),'[]'::jsonb) into methods from public.medios_pago m where m.empresa_id=p_empresa_id and m.activo=true and m.deleted_at is null;
 return jsonb_build_object('ready',true,'code','DYNAMIC_PAYMENT_PAYLOAD_READY_V1','template_code','FF-TMP-0002','acceptance_id',a.id,'quote_builder_id',q.id,'document_display_id',q.document_display_id,'quote_version',q.quote_version,'customer',jsonb_build_object('name',q.client_name,'phone',q.client_phone,'email',q.client_email),'payment',jsonb_build_object('value_type','ANTICIPO','amount',q.deposit_amount,'currency',q.currency,'reference',q.document_display_id,'concept','Anticipo de reserva '||q.document_display_id,'quote_total',q.total,'balance_after_payment',q.balance_amount,'deposit_mode',q.deposit_mode,'deposit_percent',q.deposit_percent,'deposit_override',q.deposit_override,'deposit_override_reason',q.deposit_override_reason),'validity',jsonb_build_object('quote_valid_until_at',q.document_valid_until_at,'timezone','America/Bogota'),'payment_methods',methods,'policy',jsonb_build_object('requires_quote_acceptance',true,'automatic_after_quote',false,'amount_source','CURRENT_ACCEPTED_QUOTE_DEPOSIT'),'truth_basis','CURRENT_ACCEPTED_CUSTOMER_VISIBLE_QUOTE');
end $function$;
