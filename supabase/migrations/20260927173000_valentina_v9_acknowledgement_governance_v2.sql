-- VALENTINA V9 deterministic acknowledgement governance V2
-- Centralizes pure acknowledgement detection and applies it at both
-- deterministic routing and LLM interpretation validation layers.

create or replace function public.atlas_is_non_action_acknowledgement_v1(p_text text)
returns boolean
language plpgsql
stable
set search_path to 'public','pg_temp'
as $function$
declare
  v_norm text;
begin
  v_norm := public.atlas_normalize_quote_query_v1(coalesce(p_text,''));
  return
    v_norm in (
      'dale','listo','ok','okay','perfecto','gracias','bueno',
      'quedo atento','quedo pendiente','estoy atento','estoy pendiente',
      'dale quedo atento','dale quedo pendiente',
      'listo quedo atento','listo quedo pendiente'
    )
    or v_norm ~ '^(dale|listo|ok|okay|perfecto|gracias|bueno) (quedo|estoy) (atento|pendiente)$';
end;
$function$;

CREATE OR REPLACE FUNCTION public.atlas_prepare_external_quote_route_v2(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_source text; v_norm text; v_ctx jsonb; v_active_qb uuid; v_qty int; v_match text[];
 v_pending jsonb; v_pending_id uuid; v_groups jsonb; v_candidates jsonb; v_candidate jsonb;
 v_origin_qty int; v_product_id uuid; v_products jsonb:='[]'::jsonb; v_res jsonb;
 v_is_remove boolean; v_is_add boolean;
begin
 select coalesce(m.text_content,m.transcription_text,'') into v_source
 from public.atlas_conversation_messages m
 where m.id=p_source_message_id and m.empresa_id=p_empresa_id and m.conversation_id=p_conversation_id
 and m.direction='INBOUND' and m.actor_type='CUSTOMER';
 if not found then raise exception 'ATLAS_EXTERNAL_QUOTE_SOURCE_MESSAGE_NOT_AVAILABLE' using errcode='22023'; end if;
 v_norm:=public.atlas_normalize_quote_query_v1(v_source);
 v_ctx:=public.atlas_resolve_active_quote_context_v2(p_empresa_id,p_conversation_id);
 v_active_qb:=nullif(v_ctx->>'quote_builder_id','')::uuid;

 -- V9 follow-up governance guard.
 if v_active_qb is not null
    and public.atlas_is_non_action_acknowledgement_v1(v_source)
 then
   return jsonb_build_object(
     'route','no_action',
     'primary_intent','acknowledgement',
     'confidence',1.0,
     'source_text',v_source,
     'active_quote',v_ctx,
     'code','ACKNOWLEDGEMENT_NO_QUOTE_ACTION_V9',
     'next_action','RESPOND_WITHOUT_QUOTE_ACTION',
     'safe_to_execute',false,
     'truth_basis','EXACT_ACKNOWLEDGEMENT_GUARD'
   );
 end if;

 if v_active_qb is not null and v_norm like '%cada uno%' and
   (v_norm like '%ya no quiero%' or v_norm like '%mejor dejame%' or v_norm like '%dejame%' or v_norm like '%cambiame%' or v_norm like '%cambia%' or v_norm like '%ponme%') then
   select (m)[1]::int into v_qty from regexp_matches(v_norm,'([0-9]+)','g') with ordinality t(m,ord) order by ord desc limit 1;
   if v_qty>0 then
    select coalesce(jsonb_agg(jsonb_build_object('op','SET','product_id',li.producto_id,'quantity',v_qty) order by li.created_at,li.id),'[]'::jsonb)
    into v_products from public.atlas_quote_line_items li where li.empresa_id=p_empresa_id and li.quote_builder_id=v_active_qb;
    if jsonb_array_length(v_products)>0 then
     return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,
      'patch',jsonb_build_object('products',v_products),'ambiguities','[]'::jsonb,'code','QUOTE_MODIFICATION_ALL_CURRENT_ITEMS_QUANTITY_V3','next_action','VALIDATE_MODIFICATION_PLAN','preserve_people_count',true);
    end if;
   end if;
 end if;

 -- REMOVE is resolved strictly against the active quote. Catalog variants are irrelevant.
 v_is_remove := v_active_qb is not null and (
   v_norm ~ '(^| )(quita|quitame|quitate|elimina|eliminame|saca|sacame|retira|retirame)( |$)'
   or v_norm like '%ya no quiero%'
   or v_norm like '%dejame sin%'
 );
 if v_is_remove then
   v_res:=public.atlas_resolve_active_quote_product_mention_v1(p_empresa_id,v_active_qb,v_source);
   if coalesce((v_res->>'count')::int,0)=1 then
     v_product_id=(v_res#>>'{matches,0,product_id}')::uuid;
     return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,
       'patch',jsonb_build_object('products',jsonb_build_array(jsonb_build_object('op','REMOVE','product_id',v_product_id))),
       'ambiguities','[]'::jsonb,'code','QUOTE_MODIFICATION_REMOVE_ACTIVE_PRODUCT_V3','next_action','VALIDATE_MODIFICATION_PLAN','preserve_untouched_lines',true);
   elsif coalesce((v_res->>'count')::int,0)>1 then
     return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,
       'patch','{}'::jsonb,'ambiguities',v_res->'matches','code','QUOTE_MODIFICATION_REMOVE_ACTIVE_PRODUCT_AMBIGUOUS_V3','next_action','CLARIFY_MINIMUM_PRODUCT');
   else
     return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,
       'patch','{}'::jsonb,'ambiguities',jsonb_build_array(jsonb_build_object('type','ACTIVE_PRODUCT_NOT_RESOLVED')),
       'code','QUOTE_MODIFICATION_REMOVE_ACTIVE_PRODUCT_NOT_RESOLVED_V3','next_action','CLARIFY_MINIMUM_PRODUCT');
   end if;
 end if;

 -- Only an explicit OPEN pending clarification can continue a prior ambiguity.
 if v_active_qb is not null then
   v_pending:=public.atlas_get_open_quote_clarification_v1(p_empresa_id,p_conversation_id,v_active_qb);
   if coalesce((v_pending->>'found')::boolean,false) then
    v_pending_id=(v_pending->>'id')::uuid; v_origin_qty=nullif(v_pending#>>'{payload,quantity}','')::int;
    v_groups=coalesce(v_pending#>'{payload,candidate_groups}','[]'::jsonb);
    if jsonb_array_length(v_groups)=1 then
     v_candidates=v_groups->0->'candidates';
     select c.value into v_candidate from jsonb_array_elements(v_candidates)c
     where public.atlas_normalize_quote_query_v1(c.value->>'name')=v_norm
       or public.atlas_normalize_quote_query_v1(c.value->>'name') like '%'||v_norm||'%'
       or v_norm like '%'||public.atlas_normalize_quote_query_v1(c.value->>'name')||'%'
       or (v_norm like '%clasico%' and public.atlas_normalize_quote_query_v1(c.value->>'name') like '%clasico%')
       or (v_norm like '%especial%' and public.atlas_normalize_quote_query_v1(c.value->>'name') like '%especial%')
     limit 1;
     if v_candidate is not null and v_origin_qty>0 then
      return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,
       'patch',jsonb_build_object('products',jsonb_build_array(jsonb_build_object('op','ADD','product_id',(v_candidate->>'product_id')::uuid,'quantity',v_origin_qty))),
       'ambiguities','[]'::jsonb,'code','QUOTE_MODIFICATION_CLARIFICATION_RESOLVED_V3','next_action','VALIDATE_MODIFICATION_PLAN','pending_intent_id',v_pending_id);
     end if;
     return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,'patch','{}'::jsonb,
       'ambiguities',v_groups,'code','QUOTE_MODIFICATION_PRODUCT_VARIANT_REQUIRED_V3','next_action','CLARIFY_MINIMUM_PRODUCT_VARIANT','pending_intent_id',v_pending_id);
    end if;
   end if;
 end if;

 -- ADD: explicit additive language; global catalog resolution is allowed because product may not yet be in active quote.
 v_is_add := v_active_qb is not null and v_norm ~ '(^| )(agrega|agregame|anade|anademe|incluye|incluyeme|suma|sumale|sumame)( |$)';
 if v_is_add then
   v_match:=regexp_match(v_norm,'(?:^| )([0-9]+)(?: |$)'); if v_match is not null then v_qty=(v_match[1])::int; end if;
   v_res:=public.atlas_extract_external_quote_mentions_v1(p_empresa_id,v_source,v_qty);
   v_groups=coalesce(v_res->'candidate_groups','[]'::jsonb);
   if jsonb_array_length(v_groups)>0 then
    return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,'patch','{}'::jsonb,
     'ambiguities',v_groups,'code','QUOTE_MODIFICATION_PRODUCT_VARIANT_REQUIRED_V3','next_action','CLARIFY_MINIMUM_PRODUCT_VARIANT');
   end if;
   if v_qty is null or v_qty<=0 then
    return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,'patch','{}'::jsonb,
     'ambiguities',jsonb_build_array(jsonb_build_object('type','QUANTITY_REQUIRED')),'code','QUOTE_MODIFICATION_QUANTITY_REQUIRED_V3','next_action','CLARIFY_MINIMUM_QUANTITY');
   end if;
   select coalesce(jsonb_agg(jsonb_build_object('op','ADD','product_id',p.id,'quantity',v_qty)),'[]'::jsonb) into v_products
   from jsonb_array_elements(coalesce(v_res->'items','[]'::jsonb)) i
   join public.productos p on p.empresa_id=p_empresa_id and p.activo and p.estado='published' and p.deleted_at is null
    and public.atlas_normalize_quote_query_v1(p.nombre)=public.atlas_normalize_quote_query_v1(i.value->>'query');
   if jsonb_array_length(v_products)>0 then
    return jsonb_build_object('route','modify_quote','primary_intent','modify_quote','confidence',0.99,'source_text',v_source,'active_quote',v_ctx,
     'patch',jsonb_build_object('products',v_products),'ambiguities','[]'::jsonb,'code','QUOTE_MODIFICATION_ADD_V3','next_action','VALIDATE_MODIFICATION_PLAN');
   end if;
 end if;

 return jsonb_build_object('route','quote_request','primary_intent','request_quote','confidence',0.50,'source_text',v_source,'active_quote',v_ctx,'reason','NO_DETERMINISTIC_MODIFICATION_SIGNAL');
end $function$;

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
 if public.atlas_is_non_action_acknowledgement_v1(v_source) then
   return jsonb_build_object(
     'ready_to_act',false,
     'code','ACKNOWLEDGEMENT_NO_QUOTE_ACTION_V9',
     'clarification_required',false,
     'next_action','RESPOND_WITHOUT_QUOTE_ACTION',
     'safe_to_execute',false,
     'source_message_id',p_source_message_id,
     'truth_basis','DETERMINISTIC_ACKNOWLEDGEMENT_GUARD'
   );
 end if;
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
