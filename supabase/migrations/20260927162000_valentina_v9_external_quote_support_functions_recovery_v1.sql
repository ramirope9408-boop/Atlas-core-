-- ATLAS / VALENTINA V9 support-function recovery
-- Recovered read-only from production on 2026-09-27 for isolated certification.

-- atlas_apply_quote_revision_patch_v2
CREATE OR REPLACE FUNCTION public.atlas_apply_quote_revision_patch_v2(p_quote_builder_id uuid, p_empresa_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_q public.atlas_quote_builders%rowtype;
 v_parent public.atlas_quote_builders%rowtype;
 v_people integer;
 v_old_people integer;
 v_item jsonb;
 v_product_id uuid;
 v_qty numeric;
 v_op text;
 v_service_id uuid;
 v_validation jsonb;
 v_scaled_count integer := 0;
begin
 if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception 'QUOTE_PATCH_OBJECT_REQUIRED'; end if;

 select * into v_q from public.atlas_quote_builders
 where id=p_quote_builder_id and empresa_id=p_empresa_id for update;
 if not found then raise exception 'Quote Builder no encontrado para la empresa'; end if;
 if v_q.quote_version <= 1 or v_q.supersedes_quote_builder_id is null then
   raise exception 'QUOTE_PATCH_REQUIRES_REVISION_V2';
 end if;
 if v_q.document_issued_at is not null then raise exception 'ISSUED_QUOTE_REVISION_IS_IMMUTABLE'; end if;

 select * into v_parent from public.atlas_quote_builders
 where id=v_q.supersedes_quote_builder_id and empresa_id=p_empresa_id;
 if not found then raise exception 'SUPERSEDED_QUOTE_NOT_FOUND'; end if;
 v_old_people := v_parent.people_count;

 if p_patch ? 'people_count' then
   v_people := (p_patch->>'people_count')::integer;
   if v_people <= 0 then raise exception 'INVALID_PEOPLE_COUNT'; end if;

   -- Deterministic proportional rule:
   -- Lines copied from the previous revision whose quantity exactly matched the
   -- previous people_count are treated as person-aligned. When people_count
   -- changes, scale those lines to the new people_count unless that product is
   -- explicitly addressed in the patch; explicit product instructions win.
   if v_old_people is not null and v_old_people > 0 and v_people <> v_old_people then
     update public.atlas_quote_line_items li
        set cantidad=v_people,
            updated_at=now(),
            metadata=coalesce(li.metadata,'{}'::jsonb) || jsonb_build_object(
              'people_count_autoscaled',true,
              'autoscaled_from',v_old_people,
              'autoscaled_to',v_people,
              'autoscale_contract','PERSON_ALIGNED_EXACT_MATCH_V1'
            )
      where li.quote_builder_id=p_quote_builder_id
        and li.empresa_id=p_empresa_id
        and li.cantidad=v_old_people
        and not exists (
          select 1
          from jsonb_array_elements(coalesce(p_patch->'products','[]'::jsonb)) x
          where (x->>'product_id')::uuid = li.producto_id
        );
     get diagnostics v_scaled_count = row_count;
   end if;

   update public.atlas_quote_builders
      set people_count=v_people,
          metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
            'people_count_scaling_contract','PERSON_ALIGNED_EXACT_MATCH_V1',
            'people_count_scaling_from',v_old_people,
            'people_count_scaling_to',v_people,
            'people_count_scaled_lines',v_scaled_count
          ),
          updated_at=now()
    where id=p_quote_builder_id and empresa_id=p_empresa_id;
 end if;

 if p_patch ? 'event_date' then
   update public.atlas_quote_builders set event_date=(p_patch->>'event_date')::date,updated_at=now()
   where id=p_quote_builder_id and empresa_id=p_empresa_id;
 end if;

 if p_patch ? 'event_location' then
   if btrim(coalesce(p_patch->>'event_location',''))='' then raise exception 'INVALID_EVENT_LOCATION'; end if;
   update public.atlas_quote_builders set event_location=btrim(p_patch->>'event_location'),updated_at=now()
   where id=p_quote_builder_id and empresa_id=p_empresa_id;
 end if;

 if p_patch ? 'products' then
   if jsonb_typeof(p_patch->'products') <> 'array' then raise exception 'PRODUCT_PATCH_ARRAY_REQUIRED'; end if;
   for v_item in select value from jsonb_array_elements(p_patch->'products')
   loop
     v_op:=upper(coalesce(v_item->>'op','SET'));
     v_product_id:=(v_item->>'product_id')::uuid;
     if v_op='REMOVE' then
       delete from public.atlas_quote_line_items
       where quote_builder_id=p_quote_builder_id and empresa_id=p_empresa_id and producto_id=v_product_id;
     elsif v_op in ('SET','ADD') then
       v_qty:=(v_item->>'quantity')::numeric;
       if v_qty is null or v_qty<=0 then raise exception 'INVALID_PRODUCT_QUANTITY'; end if;
       perform public.atlas_quote_builder_add_product(p_quote_builder_id,p_empresa_id,v_product_id,v_qty);
     else
       raise exception 'UNSUPPORTED_PRODUCT_PATCH_OPERATION: %',v_op;
     end if;
   end loop;
 end if;

 if p_patch ? 'services' then
   if jsonb_typeof(p_patch->'services') <> 'array' then raise exception 'SERVICE_PATCH_ARRAY_REQUIRED'; end if;
   for v_item in select value from jsonb_array_elements(p_patch->'services')
   loop
     v_op:=upper(coalesce(v_item->>'op','SET'));
     if v_op='REMOVE' then
       v_service_id:=(v_item->>'service_item_id')::uuid;
       delete from public.atlas_quote_service_items
       where id=v_service_id and quote_builder_id=p_quote_builder_id and empresa_id=p_empresa_id;
     elsif v_op='SET_QUANTITY' then
       v_service_id:=(v_item->>'service_item_id')::uuid;
       v_qty:=(v_item->>'quantity')::numeric;
       if v_qty is null or v_qty<=0 then raise exception 'INVALID_SERVICE_QUANTITY'; end if;
       update public.atlas_quote_service_items set cantidad=v_qty,updated_at=now()
       where id=v_service_id and quote_builder_id=p_quote_builder_id and empresa_id=p_empresa_id;
       if not found then raise exception 'SERVICE_ITEM_NOT_FOUND'; end if;
     else
       raise exception 'UNSUPPORTED_SERVICE_PATCH_OPERATION: %',v_op;
     end if;
   end loop;
 end if;

 perform public.atlas_recalculate_quote_builder(p_quote_builder_id);
 v_validation:=public.atlas_validate_quote_builder(p_quote_builder_id,p_empresa_id);
 select * into v_q from public.atlas_quote_builders where id=p_quote_builder_id and empresa_id=p_empresa_id;

 return jsonb_build_object(
   'ok',true,
   'code','QUOTE_REVISION_PATCH_APPLIED_V2',
   'quote_builder_id',v_q.id,
   'quote_version',v_q.quote_version,
   'people_count',v_q.people_count,
   'people_count_scaled_lines',v_scaled_count,
   'scaling_contract','PERSON_ALIGNED_EXACT_MATCH_V1',
   'total',v_q.total,
   'deposit_amount',v_q.deposit_amount,
   'balance_amount',v_q.balance_amount,
   'validation',v_validation
 );
end;
$function$;

-- atlas_build_external_quote_delivery_payload_v2
CREATE OR REPLACE FUNCTION public.atlas_build_external_quote_delivery_payload_v2(p_empresa_id uuid, p_quote_builder_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_q public.atlas_quote_builders%rowtype; v_c uuid; v_items jsonb; v_pm jsonb;
begin
 select * into v_q from public.atlas_quote_builders where id=p_quote_builder_id and empresa_id=p_empresa_id;
 if not found then raise exception 'QUOTE_BUILDER_NOT_FOUND'; end if;
 select id into v_c from public.cotizaciones where empresa_id=p_empresa_id and quote_builder_id=p_quote_builder_id and deleted_at is null order by created_at desc limit 1;
 if v_c is null then raise exception 'MATERIALIZED_QUOTE_NOT_FOUND'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('item_id',ci.id,'product_id',ci.producto_id,'name',ci.descripcion,'description',ci.descripcion,'category','PRODUCTO','quantity',ci.cantidad,'unit',ci.unidad_medida,'unit_price',ci.precio_unitario,'line_total',ci.line_total,'subtotal',ci.line_total,'currency',coalesce(v_q.currency,'COP')) order by ci.orden,ci.created_at,ci.id),'[]'::jsonb) into v_items from public.cotizacion_items ci where ci.empresa_id=p_empresa_id and ci.cotizacion_id=v_c;
 select coalesce(jsonb_agg(jsonb_build_object('payment_method_id',mp.id,'name',mp.nombre,'type',mp.tipo,'detail',mp.detalle) order by mp.nombre,mp.id),'[]'::jsonb) into v_pm from public.medios_pago mp where mp.empresa_id=p_empresa_id and mp.activo=true and mp.deleted_at is null;
 return jsonb_build_object('ok',true,'code','EXTERNAL_WHATSAPP_QUOTE_CREATED','operation','QUOTE_DELIVERY_REQUEST','revision',coalesce(v_q.quote_version,1)>1,'safe_to_send',true,'contract_version','ATLAS_EXTERNAL_WHATSAPP_QUOTE_BRIDGE_V2_QUOTE_ONLY','quote_builder_id',v_q.id,'quote_version',v_q.quote_version,'cotizacion_id',v_c,'document_display_id',v_q.document_display_id,'document_issued_at',v_q.document_issued_at,'document_valid_until_at',v_q.document_valid_until_at,'validity_hours',coalesce((v_q.metadata->>'validity_hours')::int,96),'validity_timezone',coalesce(v_q.metadata->>'validity_timezone','America/Bogota'),'client_name',v_q.client_name,'people_count',v_q.people_count,'event_date',v_q.event_date,'event_time',v_q.metadata->>'event_time','event_location',v_q.event_location,'currency',coalesce(v_q.currency,'COP'),'total',v_q.total,'deposit_percent',v_q.deposit_percent,'deposit_amount',v_q.deposit_amount,'balance_amount',v_q.balance_amount,'items',v_items,'product_count',jsonb_array_length(v_items),'human_handoff_required',false,'delivery_sequence',jsonb_build_array(jsonb_build_object('sequence',1,'kind','QUOTE_DOCUMENT','document_type','QUOTE_CLIENT','caption_mode','SINGLE_QUOTE_CAPTION','caption_text','Aquí tienes tu cotización oficial de FingerFood en PDF.','suppress_additional_quote_confirmation',true)),'payment_document_policy',jsonb_build_object('automatic_after_quote',false,'requires_quote_acceptance',true,'template_code','FF-TMP-0002','amount_source','CURRENT_ACCEPTED_QUOTE_DEPOSIT'),'next_action','RENDER_DELIVER_QUOTE_ONLY','route_intent','deliver_quote','routing_contract','ATLAS_EXTERNAL_QUOTE_ROUTE_V2');
end $function$;

-- atlas_create_quote_revision_v2
CREATE OR REPLACE FUNCTION public.atlas_create_quote_revision_v2(p_quote_builder_id uuid, p_empresa_id uuid, p_revision_reason text, p_source_message text DEFAULT NULL::text, p_source_channel text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_source public.atlas_quote_builders%rowtype;
  v_root_id uuid;
  v_next_version integer;
  v_new_id uuid;
begin
  if p_revision_reason is null or btrim(p_revision_reason)='' then raise exception 'QUOTE_REVISION_REASON_REQUIRED'; end if;

  select * into v_source from public.atlas_quote_builders
  where id=p_quote_builder_id and empresa_id=p_empresa_id for share;
  if not found then raise exception 'Quote Builder no encontrado para la empresa'; end if;

  v_root_id := coalesce(v_source.root_quote_builder_id,v_source.id);
  select coalesce(max(q.quote_version),0)+1 into v_next_version
  from public.atlas_quote_builders q
  where q.empresa_id=p_empresa_id and (q.id=v_root_id or q.root_quote_builder_id=v_root_id);

  insert into public.atlas_quote_builders(
    empresa_id,cliente_id,source_channel,source_message,context_code,people_count,event_date,event_location,status,
    subtotal_productos,subtotal_servicios,descuento_total,total,currency,metadata,
    client_name,client_phone,client_email,requires_electronic_invoice,billing_name,billing_document_type,
    billing_document_number,billing_email,deposit_mode,deposit_percent,deposit_amount,balance_amount,
    deposit_override,deposit_override_reason,billing_provider_id,electronic_invoice_status,
    electronic_invoice_external_id,electronic_invoice_number,electronic_invoice_cufe,
    electronic_invoice_pdf_url,electronic_invoice_xml_url,electronic_invoice_error,
    document_display_id,document_issued_at,document_valid_until,document_valid_until_at,
    quote_version,root_quote_builder_id,supersedes_quote_builder_id,revision_reason
  )
  values(
    v_source.empresa_id,v_source.cliente_id,coalesce(p_source_channel,v_source.source_channel),
    coalesce(p_source_message,v_source.source_message),v_source.context_code,v_source.people_count,
    v_source.event_date,v_source.event_location,'BUILDING',
    v_source.subtotal_productos,v_source.subtotal_servicios,v_source.descuento_total,v_source.total,v_source.currency,
    coalesce(v_source.metadata,'{}'::jsonb)||jsonb_build_object('revision_contract','V2','revision_reason',btrim(p_revision_reason),'supersedes_quote_builder_id',v_source.id,'root_quote_builder_id',v_root_id,'quote_version',v_next_version),
    v_source.client_name,v_source.client_phone,v_source.client_email,v_source.requires_electronic_invoice,
    v_source.billing_name,v_source.billing_document_type,v_source.billing_document_number,v_source.billing_email,
    v_source.deposit_mode,v_source.deposit_percent,v_source.deposit_amount,v_source.balance_amount,
    v_source.deposit_override,v_source.deposit_override_reason,v_source.billing_provider_id,
    v_source.electronic_invoice_status,v_source.electronic_invoice_external_id,v_source.electronic_invoice_number,
    v_source.electronic_invoice_cufe,v_source.electronic_invoice_pdf_url,v_source.electronic_invoice_xml_url,
    v_source.electronic_invoice_error,null,null,null,null,
    v_next_version,v_root_id,v_source.id,btrim(p_revision_reason)
  ) returning id into v_new_id;

  insert into public.atlas_quote_line_items(
    quote_builder_id,empresa_id,producto_id,cantidad,precio_unitario,descuento_unitario,metadata
  )
  select v_new_id,empresa_id,producto_id,cantidad,precio_unitario,descuento_unitario,
         coalesce(metadata,'{}'::jsonb)||jsonb_build_object('copied_from_quote_builder_id',p_quote_builder_id)
  from public.atlas_quote_line_items
  where quote_builder_id=p_quote_builder_id and empresa_id=p_empresa_id;

  insert into public.atlas_quote_service_items(
    quote_builder_id,empresa_id,service_type,descripcion,cantidad,precio_unitario,metadata,unidad_medida
  )
  select v_new_id,empresa_id,service_type,descripcion,cantidad,precio_unitario,
         coalesce(metadata,'{}'::jsonb)||jsonb_build_object('copied_from_quote_builder_id',p_quote_builder_id),
         unidad_medida
  from public.atlas_quote_service_items
  where quote_builder_id=p_quote_builder_id and empresa_id=p_empresa_id;

  perform public.atlas_recalculate_quote_builder(v_new_id);

  return jsonb_build_object('ok',true,'code','QUOTE_REVISION_CREATED_V2','quote_builder_id',v_new_id,
    'quote_version',v_next_version,'root_quote_builder_id',v_root_id,'supersedes_quote_builder_id',v_source.id,'status','BUILDING');
end;
$function$;

-- atlas_execute_external_quote_request_v1_legacy
CREATE OR REPLACE FUNCTION public.atlas_execute_external_quote_request_v1_legacy(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_quote_request jsonb, p_request_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_conversation public.atlas_conversations%rowtype;
  v_source_message public.atlas_conversation_messages%rowtype;
  v_gate jsonb;
  v_existing_result jsonb;
  v_tool_request_id uuid;
  v_result jsonb;

  v_client_name text;
  v_people_count integer;
  v_event_date date;
  v_event_date_text text;
  v_event_location text;
  v_event_time text;
  v_items jsonb;
  v_item jsonb;
  v_item_index integer := 0;
  v_query text;
  v_query_norm text;
  v_query_singular text;
  v_quantity numeric;
  v_product_id uuid;
  v_product_name text;
  v_product_price numeric;
  v_product_score numeric;
  v_second_score numeric;
  v_unresolved_query text;
  v_resolved_product_ids uuid[] := array[]::uuid[];
  v_catalog_id uuid;

  v_quote_builder_id uuid;
  v_validation jsonb;
  v_document jsonb;
  v_materialization jsonb;
  v_lines jsonb;
  v_quote public.atlas_quote_builders%rowtype;
begin
  if p_empresa_id is null
     or p_conversation_id is null
     or p_source_message_id is null
  then
    raise exception 'ATLAS_EXTERNAL_QUOTE_SCOPE_REQUIRED'
      using errcode = '22004';
  end if;

  if p_request_key is null or trim(p_request_key) = '' then
    raise exception 'ATLAS_EXTERNAL_QUOTE_REQUEST_KEY_REQUIRED'
      using errcode = '22004';
  end if;

  perform public.atlas_require_empresa_active(p_empresa_id);

  -- One inbound message can create at most one governed quote attempt at a time.
  perform pg_advisory_xact_lock(
    hashtextextended(
      p_empresa_id::text || ':' || p_source_message_id::text || ':ATLAS_QUOTE_BUILDER',
      0
    )
  );

  select tr.result_payload
  into v_existing_result
  from public.atlas_agent_tool_requests tr
  where tr.empresa_id = p_empresa_id
    and tr.conversation_id = p_conversation_id
    and tr.source_message_id = p_source_message_id
    and tr.tool_code = 'ATLAS_QUOTE_BUILDER'
    and tr.status in ('COMPLETED', 'CANCELLED')
    and tr.result_payload is not null
  order by tr.requested_at desc, tr.id desc
  limit 1;

  if v_existing_result is not null then
    return v_existing_result || jsonb_build_object('idempotent_replay', true);
  end if;

  select *
  into v_conversation
  from public.atlas_conversations c
  where c.id = p_conversation_id
    and c.empresa_id = p_empresa_id
    and c.channel = 'WHATSAPP'
    and c.status = 'OPEN'
  for update;

  if not found then
    raise exception 'ATLAS_EXTERNAL_QUOTE_CONVERSATION_NOT_AVAILABLE'
      using errcode = '22023';
  end if;

  select *
  into v_source_message
  from public.atlas_conversation_messages m
  where m.id = p_source_message_id
    and m.empresa_id = p_empresa_id
    and m.conversation_id = p_conversation_id
    and m.direction = 'INBOUND'
    and m.actor_type = 'CUSTOMER'
    and m.channel = 'WHATSAPP'
  for update;

  if not found then
    raise exception 'ATLAS_EXTERNAL_QUOTE_SOURCE_MESSAGE_NOT_AVAILABLE'
      using errcode = '22023';
  end if;

  v_gate := public.atlas_check_conversation_automation_gate(
    p_empresa_id,
    p_conversation_id
  );

  if coalesce((v_gate ->> 'automation_allowed')::boolean, false) is not true then
    return jsonb_build_object(
      'ok', false,
      'code', 'EXTERNAL_QUOTE_AUTOMATION_BLOCKED',
      'safe_to_send', false,
      'human_handoff_required', true,
      'idempotent_replay', false
    );
  end if;

  insert into public.atlas_agent_tool_requests (
    empresa_id,
    conversation_id,
    source_message_id,
    agent_code,
    tool_code,
    status,
    input_payload,
    requested_at,
    started_at
  ) values (
    p_empresa_id,
    p_conversation_id,
    p_source_message_id,
    'VALENTINA',
    'ATLAS_QUOTE_BUILDER',
    'IN_PROGRESS',
    jsonb_build_object(
      'contract_version', 'ATLAS_EXTERNAL_WHATSAPP_QUOTE_BRIDGE_V1',
      'request_key', trim(p_request_key),
      'quote_request', coalesce(p_quote_request, '{}'::jsonb)
    ),
    now(),
    now()
  )
  returning id into v_tool_request_id;

  begin
    if p_quote_request is null
       or jsonb_typeof(p_quote_request) <> 'object'
    then
      v_result := jsonb_build_object(
        'ok', false,
        'code', 'QUOTE_CLARIFICATION_ITEMS_REQUIRED',
        'safe_to_send', true,
        'reply_text', 'Claro. ¿Qué productos y cantidades deseas incluir en la cotización?',
        'human_handoff_required', false,
        'tool_request_id', v_tool_request_id,
        'idempotent_replay', false
      );
      update public.atlas_agent_tool_requests
      set status = 'CANCELLED', result_payload = v_result, completed_at = now()
      where id = v_tool_request_id;
      return v_result;
    end if;

    v_client_name := coalesce(
      nullif(trim(p_quote_request ->> 'client_name'), ''),
      nullif(trim(v_conversation.customer_name), '')
    );

    begin
      v_people_count := nullif(trim(p_quote_request ->> 'people_count'), '')::integer;
    exception when others then
      v_people_count := null;
    end;

    v_event_date_text := nullif(trim(p_quote_request ->> 'event_date'), '');
    begin
      if v_event_date_text ~ '^\d{4}-\d{2}-\d{2}$' then
        v_event_date := v_event_date_text::date;
      else
        v_event_date := null;
      end if;
    exception when others then
      v_event_date := null;
    end;

    v_event_location := nullif(trim(p_quote_request ->> 'event_location'), '');
    v_event_time := nullif(trim(p_quote_request ->> 'event_time'), '');
    v_items := p_quote_request -> 'items';

    if v_client_name is null then
      v_result := jsonb_build_object(
        'ok', false,
        'code', 'QUOTE_CLARIFICATION_CLIENT_NAME_REQUIRED',
        'safe_to_send', true,
        'reply_text', 'Perfecto. ¿A nombre de quién preparo la cotización?',
        'human_handoff_required', false,
        'tool_request_id', v_tool_request_id,
        'idempotent_replay', false
      );
      update public.atlas_agent_tool_requests
      set status = 'CANCELLED', result_payload = v_result, completed_at = now()
      where id = v_tool_request_id;
      return v_result;
    end if;

    if v_people_count is null or v_people_count <= 0 then
      v_result := jsonb_build_object(
        'ok', false,
        'code', 'QUOTE_CLARIFICATION_PEOPLE_REQUIRED',
        'safe_to_send', true,
        'reply_text', 'Perfecto. ¿Para cuántas personas sería el evento?',
        'human_handoff_required', false,
        'tool_request_id', v_tool_request_id,
        'idempotent_replay', false
      );
      update public.atlas_agent_tool_requests
      set status = 'CANCELLED', result_payload = v_result, completed_at = now()
      where id = v_tool_request_id;
      return v_result;
    end if;

    if v_event_date is null or v_event_date < current_date then
      v_result := jsonb_build_object(
        'ok', false,
        'code', 'QUOTE_CLARIFICATION_EVENT_DATE_REQUIRED',
        'safe_to_send', true,
        'reply_text', 'Perfecto. ¿Qué fecha tendrá el evento?',
        'human_handoff_required', false,
        'tool_request_id', v_tool_request_id,
        'idempotent_replay', false
      );
      update public.atlas_agent_tool_requests
      set status = 'CANCELLED', result_payload = v_result, completed_at = now()
      where id = v_tool_request_id;
      return v_result;
    end if;

    if v_event_location is null then
      v_result := jsonb_build_object(
        'ok', false,
        'code', 'QUOTE_CLARIFICATION_LOCATION_REQUIRED',
        'safe_to_send', true,
        'reply_text', 'Perfecto. ¿En qué sector o dirección será el evento?',
        'human_handoff_required', false,
        'tool_request_id', v_tool_request_id,
        'idempotent_replay', false
      );
      update public.atlas_agent_tool_requests
      set status = 'CANCELLED', result_payload = v_result, completed_at = now()
      where id = v_tool_request_id;
      return v_result;
    end if;

    if v_items is null
       or jsonb_typeof(v_items) <> 'array'
       or jsonb_array_length(v_items) = 0
       or jsonb_array_length(v_items) > 50
    then
      v_result := jsonb_build_object(
        'ok', false,
        'code', 'QUOTE_CLARIFICATION_ITEMS_REQUIRED',
        'safe_to_send', true,
        'reply_text', 'Perfecto. ¿Qué productos y cantidades deseas incluir en la cotización?',
        'human_handoff_required', false,
        'tool_request_id', v_tool_request_id,
        'idempotent_replay', false
      );
      update public.atlas_agent_tool_requests
      set status = 'CANCELLED', result_payload = v_result, completed_at = now()
      where id = v_tool_request_id;
      return v_result;
    end if;

    -- Resolve every requested line against real, active, published catalog data.
    for v_item in select value from jsonb_array_elements(v_items)
    loop
      v_item_index := v_item_index + 1;
      v_query := nullif(trim(v_item ->> 'query'), '');
      begin
        v_quantity := nullif(trim(v_item ->> 'quantity'), '')::numeric;
      exception when others then
        v_quantity := null;
      end;

      if v_query is null or v_quantity is null or v_quantity <= 0 then
        v_unresolved_query := coalesce(v_query, 'producto ' || v_item_index::text);
        exit;
      end if;

      v_query_norm := public.atlas_normalize_quote_query_v1(v_query);
      v_query_singular := public.atlas_singularize_quote_query_v1(v_query_norm);

      with candidates as (
        select distinct
          p.id,
          p.nombre,
          p.precio_base,
          public.atlas_normalize_quote_query_v1(p.nombre) as name_norm,
          public.atlas_singularize_quote_query_v1(
            public.atlas_normalize_quote_query_v1(p.nombre)
          ) as name_singular,
          public.atlas_normalize_quote_query_v1(
            concat_ws(
              ' ',
              p.nombre,
              p.descripcion_resumen,
              array_to_string(p.keywords, ' ')
            )
          ) as search_norm
        from public.productos p
        join public.catalogo_productos cp
          on cp.producto_padre_id = p.id
         and cp.empresa_id = p.empresa_id
         and cp.deleted_at is null
         and cp.visible = true
        join public.catalogos c
          on c.id = cp.catalogo_id
         and c.empresa_id = cp.empresa_id
         and c.deleted_at is null
         and c.estado = 'published'
         and (c.vigente_desde is null or c.vigente_desde <= current_date)
         and (c.vigente_hasta is null or c.vigente_hasta >= current_date)
        where p.empresa_id = p_empresa_id
          and p.deleted_at is null
          and p.activo = true
          and p.estado = 'published'
          and p.precio_base is not null
          and p.precio_base >= 0
          and (p.vigencia_desde is null or p.vigencia_desde <= current_date)
          and (p.vigencia_hasta is null or p.vigencia_hasta >= current_date)
      ), scored as (
        select
          c.*,
          case
            when c.name_norm = v_query_norm then 1.00
            when c.name_singular = v_query_singular then 0.99
            when c.name_norm like '%' || v_query_norm || '%'
              or v_query_norm like '%' || c.name_norm || '%' then 0.92
            when c.name_singular like '%' || v_query_singular || '%'
              or v_query_singular like '%' || c.name_singular || '%' then 0.90
            when c.search_norm like '%' || v_query_norm || '%' then 0.86
            else greatest(
              similarity(c.name_norm, v_query_norm),
              word_similarity(v_query_norm, c.search_norm)
            )
          end::numeric as match_score
        from candidates c
      ), ranked as (
        select
          s.*,
          row_number() over (
            order by s.match_score desc, length(s.name_norm), s.nombre, s.id
          ) as match_rank,
          lead(s.match_score) over (
            order by s.match_score desc, length(s.name_norm), s.nombre, s.id
          ) as next_match_score
        from scored s
      )
      select
        id,
        nombre,
        precio_base,
        match_score,
        next_match_score
      into
        v_product_id,
        v_product_name,
        v_product_price,
        v_product_score,
        v_second_score
      from ranked
      where match_rank = 1;

      if v_product_id is null
         or coalesce(v_product_score, 0) < 0.60
         or (
           v_second_score is not null
           and v_product_score < 0.98
           and (v_product_score - v_second_score) < 0.08
         )
      then
        v_unresolved_query := v_query;
        exit;
      end if;

      -- Duplicate mentions are rejected instead of silently changing quantities.
      if v_product_id = any(v_resolved_product_ids) then
        v_unresolved_query := v_query;
        exit;
      end if;

      v_resolved_product_ids := array_append(v_resolved_product_ids, v_product_id);
    end loop;

    if v_unresolved_query is not null then
      v_result := jsonb_build_object(
        'ok', false,
        'code', 'QUOTE_CLARIFICATION_PRODUCT_REQUIRED',
        'safe_to_send', true,
        'reply_text', 'Quiero cotizarte exactamente lo que pediste. ¿Me confirmas el nombre de «' || v_unresolved_query || '» tal como aparece en nuestro menú?',
        'unresolved_product_query', v_unresolved_query,
        'human_handoff_required', false,
        'tool_request_id', v_tool_request_id,
        'idempotent_replay', false
      );
      update public.atlas_agent_tool_requests
      set status = 'CANCELLED', result_payload = v_result, completed_at = now()
      where id = v_tool_request_id;
      return v_result;
    end if;

    select c.id
    into v_catalog_id
    from public.catalogos c
    join public.catalogo_productos cp
      on cp.catalogo_id = c.id
     and cp.empresa_id = c.empresa_id
     and cp.deleted_at is null
     and cp.visible = true
     and cp.producto_padre_id = any(v_resolved_product_ids)
    where c.empresa_id = p_empresa_id
      and c.deleted_at is null
      and c.estado = 'published'
      and (c.vigente_desde is null or c.vigente_desde <= current_date)
      and (c.vigente_hasta is null or c.vigente_hasta >= current_date)
    group by c.id, c.version, c.vigente_desde, c.created_at
    having count(distinct cp.producto_padre_id) = cardinality(v_resolved_product_ids)
    order by c.version desc, c.vigente_desde desc nulls last, c.created_at desc
    limit 1;

    if v_catalog_id is null then
      v_result := jsonb_build_object(
        'ok', false,
        'code', 'QUOTE_CATALOG_NOT_AVAILABLE',
        'safe_to_send', true,
        'reply_text', 'Voy a revisar esa combinación con el equipo para enviarte una cotización correcta.',
        'human_handoff_required', true,
        'handoff_reason', 'PUBLISHED_CATALOG_DOES_NOT_CONTAIN_ALL_REQUESTED_PRODUCTS',
        'tool_request_id', v_tool_request_id,
        'idempotent_replay', false
      );
      update public.atlas_agent_tool_requests
      set status = 'CANCELLED', result_payload = v_result, completed_at = now()
      where id = v_tool_request_id;
      return v_result;
    end if;

    v_quote_builder_id := public.atlas_create_quote_builder(
      p_empresa_id,
      coalesce(v_source_message.text_content, v_source_message.transcription_text, ''),
      'EXTERNAL_WHATSAPP_QUOTE_V1',
      v_people_count,
      v_event_date,
      v_event_location,
      'WHATSAPP'
    );

    update public.atlas_quote_builders qb
    set metadata = coalesce(qb.metadata, '{}'::jsonb) || jsonb_build_object(
      'contract_version', 'ATLAS_EXTERNAL_WHATSAPP_QUOTE_BRIDGE_V1',
      'conversation_id', p_conversation_id,
      'source_message_id', p_source_message_id,
      'request_key', trim(p_request_key),
      'event_time', v_event_time,
      'quote_request', p_quote_request
    )
    where qb.id = v_quote_builder_id
      and qb.empresa_id = p_empresa_id;

    perform public.atlas_quote_builder_set_client(
      v_quote_builder_id,
      p_empresa_id,
      v_client_name,
      v_conversation.customer_phone,
      v_conversation.customer_email
    );

    v_item_index := 0;
    for v_item in select value from jsonb_array_elements(v_items)
    loop
      v_item_index := v_item_index + 1;
      v_query := trim(v_item ->> 'query');
      v_quantity := (v_item ->> 'quantity')::numeric;
      v_product_id := v_resolved_product_ids[v_item_index];

      perform public.atlas_quote_builder_add_product(
        v_quote_builder_id,
        p_empresa_id,
        v_product_id,
        v_quantity
      );
    end loop;

    perform public.atlas_quote_builder_set_billing(
      v_quote_builder_id,
      p_empresa_id,
      false,
      null,
      null,
      null,
      null
    );

    perform public.atlas_quote_builder_set_payment(
      v_quote_builder_id,
      p_empresa_id,
      'STANDARD_PERCENT',
      null,
      null,
      null
    );

    v_validation := public.atlas_validate_quote_builder(
      v_quote_builder_id,
      p_empresa_id
    );

    if coalesce((v_validation ->> 'ready_for_quote')::boolean, false) is not true then
      raise exception 'ATLAS_EXTERNAL_QUOTE_CANONICAL_VALIDATION_FAILED'
        using errcode = '22023';
    end if;

    v_document := public.atlas_prepare_quote_document(
      v_quote_builder_id,
      p_empresa_id,
      current_date + 7
    );

    v_materialization := public.atlas_quote_builder_materialize_external_v1(
      v_quote_builder_id,
      p_empresa_id,
      v_catalog_id,
      p_conversation_id,
      p_source_message_id
    );

    select *
    into v_quote
    from public.atlas_quote_builders qb
    where qb.id = v_quote_builder_id
      and qb.empresa_id = p_empresa_id;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'product_id', li.producto_id,
          'name', p.nombre,
          'quantity', li.cantidad,
          'unit_price', li.precio_unitario_final,
          'line_total', li.line_total,
          'currency', coalesce(p.moneda, v_quote.currency, 'COP')
        )
        order by li.created_at, li.id
      ),
      '[]'::jsonb
    )
    into v_lines
    from public.atlas_quote_line_items li
    join public.productos p
      on p.id = li.producto_id
     and p.empresa_id = li.empresa_id
    where li.quote_builder_id = v_quote_builder_id
      and li.empresa_id = p_empresa_id;

    v_result := jsonb_build_object(
      'ok', true,
      'code', 'EXTERNAL_WHATSAPP_QUOTE_CREATED',
      'safe_to_send', true,
      'contract_version', 'ATLAS_EXTERNAL_WHATSAPP_QUOTE_BRIDGE_V1',
      'tool_request_id', v_tool_request_id,
      'quote_builder_id', v_quote_builder_id,
      'cotizacion_id', v_materialization ->> 'cotizacion_id',
      'document_display_id', v_quote.document_display_id,
      'document_issued_at', v_quote.document_issued_at,
      'document_valid_until', v_quote.document_valid_until,
      'client_name', v_quote.client_name,
      'people_count', v_quote.people_count,
      'event_date', v_quote.event_date,
      'event_time', v_event_time,
      'event_location', v_quote.event_location,
      'currency', coalesce(v_quote.currency, 'COP'),
      'total', v_quote.total,
      'deposit_percent', v_quote.deposit_percent,
      'deposit_amount', v_quote.deposit_amount,
      'balance_amount', v_quote.balance_amount,
      'balance_due_rule', 'EVENT_DAY',
      'items', v_lines,
      'human_handoff_required', false,
      'idempotent_replay', false
    );

    update public.atlas_agent_tool_requests
    set
      status = 'COMPLETED',
      result_payload = v_result,
      completed_at = now(),
      error_code = null,
      error_message = null
    where id = v_tool_request_id;

    return v_result;

  exception when others then
    v_result := jsonb_build_object(
      'ok', false,
      'code', 'EXTERNAL_QUOTE_EXECUTION_FAILED',
      'safe_to_send', true,
      'reply_text', 'No pude cerrar la cotización automáticamente. Voy a dejarla en revisión para que el equipo la complete correctamente.',
      'human_handoff_required', true,
      'handoff_reason', 'CANONICAL_QUOTE_EXECUTION_FAILED',
      'tool_request_id', v_tool_request_id,
      'idempotent_replay', false
    );

    update public.atlas_agent_tool_requests
    set
      status = 'FAILED',
      result_payload = v_result,
      completed_at = now(),
      error_code = 'EXTERNAL_QUOTE_EXECUTION_FAILED',
      error_message = null
    where id = v_tool_request_id;

    return v_result;
  end;
end;
$function$;

-- atlas_extract_external_quote_mentions_v1
CREATE OR REPLACE FUNCTION public.atlas_extract_external_quote_mentions_v1(p_empresa_id uuid, p_text text, p_people_count integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_norm text:=public.atlas_normalize_quote_query_v1(coalesce(p_text,''));
  v_items jsonb:='[]'::jsonb;
  v_groups jsonb:='[]'::jsonb;
  v_cands jsonb;
  v_cnt int;
  v_prior jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('product_id',li.producto_id,'name',p.nombre,'price',li.precio_unitario_final)),'[]'::jsonb)
  into v_prior
  from public.atlas_quote_line_items li
  join public.productos p on p.id=li.producto_id and p.empresa_id=li.empresa_id
  join public.atlas_quote_builders qb on qb.id=li.quote_builder_id and qb.empresa_id=li.empresa_id
  where 1=0;

  if v_norm like '%mini hamburguesa%' then
    select count(*),coalesce(jsonb_agg(jsonb_build_object('product_id',id,'name',nombre,'price',precio_base) order by nombre),'[]'::jsonb)
    into v_cnt,v_cands
    from public.productos
    where empresa_id=p_empresa_id and activo and estado='published' and deleted_at is null
      and public.atlas_normalize_quote_query_v1(nombre) like 'mini hamburguesa%';

    if v_cnt=1 then
      v_items:=v_items||jsonb_build_array(jsonb_build_object('query',v_cands->0->>'name','quantity',p_people_count,'resolution','EXACT_CANONICAL_MENTION'));
    elsif v_cnt>1 then
      v_groups:=v_groups||jsonb_build_array(jsonb_build_object('mention','mini hamburguesas','candidate_count',v_cnt,'candidates',v_cands));
    end if;
  end if;

  if v_norm ~ '(^| )tacos?( |$)' then
    select count(*),coalesce(jsonb_agg(jsonb_build_object('product_id',id,'name',nombre,'price',precio_base) order by nombre),'[]'::jsonb)
    into v_cnt,v_cands
    from public.productos
    where empresa_id=p_empresa_id and activo and estado='published' and deleted_at is null
      and public.atlas_normalize_quote_query_v1(nombre) like 'taco%';

    if v_cnt=1 then
      v_items:=v_items||jsonb_build_array(jsonb_build_object('query',v_cands->0->>'name','quantity',p_people_count,'resolution','EXACT_CANONICAL_MENTION'));
    elsif v_cnt>1 then
      v_groups:=v_groups||jsonb_build_array(jsonb_build_object('mention','tacos','candidate_count',v_cnt,'candidates',v_cands));
    end if;
  end if;

  if v_norm ~ '(^| )mini dogg?is?( |$)' or v_norm like '%mini doggi%' then
    select count(*),coalesce(jsonb_agg(jsonb_build_object('product_id',id,'name',nombre,'price',precio_base) order by nombre),'[]'::jsonb)
    into v_cnt,v_cands
    from public.productos
    where empresa_id=p_empresa_id and activo and estado='published' and deleted_at is null
      and public.atlas_normalize_quote_query_v1(nombre) like 'mini doggi%';

    if v_cnt=1 then
      v_items:=v_items||jsonb_build_array(jsonb_build_object('query',v_cands->0->>'name','quantity',p_people_count,'resolution','EXACT_CANONICAL_MENTION'));
    elsif v_cnt>1 then
      v_groups:=v_groups||jsonb_build_array(jsonb_build_object('mention','mini doggis','candidate_count',v_cnt,'candidates',v_cands));
    end if;
  end if;

  return jsonb_build_object('items',v_items,'candidate_groups',v_groups);
end
$function$;

-- atlas_finalize_external_quote_revision_v2
CREATE OR REPLACE FUNCTION public.atlas_finalize_external_quote_revision_v2(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_quote_builder_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_q public.atlas_quote_builders%rowtype;
  v_catalog_id uuid;
  v_materialization jsonb;
  v_document jsonb;
  v_lines jsonb;
begin
  select * into v_q
  from public.atlas_quote_builders
  where id=p_quote_builder_id and empresa_id=p_empresa_id
  for update;

  if not found then
    raise exception 'QUOTE_BUILDER_NOT_FOUND';
  end if;

  if v_q.status <> 'READY_FOR_QUOTE' then
    raise exception 'QUOTE_BUILDER_NOT_READY_FOR_FINALIZATION';
  end if;

  select c.catalogo_id
    into v_catalog_id
  from public.cotizaciones c
  where c.empresa_id=p_empresa_id
    and c.deleted_at is null
    and c.quote_builder_id = coalesce(v_q.supersedes_quote_builder_id,v_q.root_quote_builder_id)
  order by c.created_at desc
  limit 1;

  if v_catalog_id is null then
    select c.id
      into v_catalog_id
    from public.catalogos c
    where c.empresa_id=p_empresa_id
      and c.estado='published'
      and c.deleted_at is null
      and (c.vigente_desde is null or c.vigente_desde<=current_date)
      and (c.vigente_hasta is null or c.vigente_hasta>=current_date)
      and not exists (
        select 1
        from public.atlas_quote_line_items li
        where li.quote_builder_id=p_quote_builder_id
          and li.empresa_id=p_empresa_id
          and not exists (
            select 1
            from public.catalogo_productos cp
            where cp.empresa_id=p_empresa_id
              and cp.catalogo_id=c.id
              and cp.producto_padre_id=li.producto_id
              and cp.visible=true
              and cp.deleted_at is null
          )
      )
    order by c.version desc,c.created_at desc
    limit 1;
  end if;

  if v_catalog_id is null then
    raise exception 'QUOTE_CATALOG_NOT_RESOLVED_FOR_REVISION';
  end if;

  v_document:=public.atlas_prepare_quote_document_v2(
    p_quote_builder_id,
    p_empresa_id,
    96
  );

  v_materialization:=public.atlas_quote_builder_materialize_external_v1(
    p_quote_builder_id,
    p_empresa_id,
    v_catalog_id,
    p_conversation_id,
    p_source_message_id
  );

  select * into v_q
  from public.atlas_quote_builders
  where id=p_quote_builder_id and empresa_id=p_empresa_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'product_id',li.producto_id,
        'name',p.nombre,
        'quantity',li.cantidad,
        'unit_price',li.precio_unitario_final,
        'line_total',li.line_total,
        'currency',coalesce(p.moneda,v_q.currency,'COP')
      )
      order by li.created_at,li.id
    ),
    '[]'::jsonb
  )
  into v_lines
  from public.atlas_quote_line_items li
  join public.productos p
    on p.id=li.producto_id
   and p.empresa_id=li.empresa_id
  where li.quote_builder_id=p_quote_builder_id
    and li.empresa_id=p_empresa_id;

  return jsonb_build_object(
    'ok',true,
    'code','EXTERNAL_WHATSAPP_QUOTE_CREATED',
    'operation','QUOTE_REVISION',
    'revision',true,
    'safe_to_send',true,
    'contract_version','ATLAS_EXTERNAL_WHATSAPP_QUOTE_BRIDGE_V2_REVISION',
    'quote_builder_id',v_q.id,
    'quote_version',v_q.quote_version,
    'root_quote_builder_id',coalesce(v_q.root_quote_builder_id,v_q.id),
    'supersedes_quote_builder_id',v_q.supersedes_quote_builder_id,
    'cotizacion_id',v_materialization->>'cotizacion_id',
    'document_display_id',v_q.document_display_id,
    'document_issued_at',v_q.document_issued_at,
    'document_valid_until',v_q.document_valid_until,
    'document_valid_until_at',v_q.document_valid_until_at,
    'validity_hours',96,
    'validity_timezone','America/Bogota',
    'client_name',v_q.client_name,
    'people_count',v_q.people_count,
    'event_date',v_q.event_date,
    'event_time',v_q.metadata->>'event_time',
    'event_location',v_q.event_location,
    'currency',coalesce(v_q.currency,'COP'),
    'total',v_q.total,
    'deposit_percent',v_q.deposit_percent,
    'deposit_amount',v_q.deposit_amount,
    'balance_amount',v_q.balance_amount,
    'balance_due_rule','EVENT_DAY',
    'items',v_lines,
    'human_handoff_required',false,
    'idempotent_replay',coalesce((v_materialization->>'idempotent_replay')::boolean,false),
    'next_action','RENDER_AND_DELIVER_QUOTE_PDF'
  );
end
$function$;

-- atlas_normalize_quote_query_v1
CREATE OR REPLACE FUNCTION public.atlas_normalize_quote_query_v1(p_value text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select trim(
    regexp_replace(
      regexp_replace(
        lower(unaccent(coalesce(p_value, ''))),
        '[^a-z0-9]+',
        ' ',
        'g'
      ),
      '\s+',
      ' ',
      'g'
    )
  );
$function$;

-- atlas_prepare_external_quote_route_v2
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

-- atlas_prepare_quote_modification_plan_v2
CREATE OR REPLACE FUNCTION public.atlas_prepare_quote_modification_plan_v2(p_empresa_id uuid, p_conversation_id uuid, p_source_message_id uuid, p_interpretation jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_msg public.atlas_conversation_messages%rowtype; v_ctx jsonb; v_patch jsonb; v_conf numeric; v_intent text; v_ambiguities jsonb;
begin
 select * into v_msg from public.atlas_conversation_messages where id=p_source_message_id and empresa_id=p_empresa_id and conversation_id=p_conversation_id and direction='INBOUND' and actor_type='CUSTOMER';
 if not found then raise exception 'SOURCE_MESSAGE_NOT_AVAILABLE'; end if;
 if p_interpretation is null or jsonb_typeof(p_interpretation)<>'object' then raise exception 'INTERPRETATION_OBJECT_REQUIRED'; end if;
 v_intent:=lower(coalesce(p_interpretation->>'primary_intent','')); v_conf:=coalesce((p_interpretation->>'intent_confidence')::numeric,0);
 v_patch:=coalesce(p_interpretation->'patch','{}'::jsonb); v_ambiguities:=coalesce(p_interpretation->'ambiguities','[]'::jsonb);
 v_ctx:=public.atlas_resolve_customer_visible_quote_context_v1(p_empresa_id,p_conversation_id);
 if v_intent<>'modify_quote' then return jsonb_build_object('ready_to_act',false,'code','INTENT_NOT_MODIFY_QUOTE','context',v_ctx); end if;
 if coalesce((v_ctx->>'found')::boolean,false) is not true then return jsonb_build_object('ready_to_act',false,'code','CUSTOMER_VISIBLE_QUOTE_NOT_FOUND','clarification_required',true,'context',v_ctx); end if;
 if v_conf<0.85 then return jsonb_build_object('ready_to_act',false,'code','INTENT_CONFIDENCE_TOO_LOW','clarification_required',true,'context',v_ctx); end if;
 if jsonb_typeof(v_ambiguities)<>'array' or jsonb_array_length(v_ambiguities)>0 then return jsonb_build_object('ready_to_act',false,'code','QUOTE_MODIFICATION_AMBIGUOUS','clarification_required',true,'ambiguities',v_ambiguities,'context',v_ctx); end if;
 if jsonb_typeof(v_patch)<>'object' or v_patch='{}'::jsonb then return jsonb_build_object('ready_to_act',false,'code','QUOTE_PATCH_EMPTY','clarification_required',true,'context',v_ctx); end if;
 return jsonb_build_object('ready_to_act',true,'code','QUOTE_MODIFICATION_PLAN_READY_V2','intent','modify_quote','confidence',v_conf,'source_message_id',p_source_message_id,'source_text',coalesce(v_msg.text_content,v_msg.transcription_text),'active_quote',v_ctx,'patch',v_patch,'truth_basis','LAST_ISSUED_TO_CUSTOMER','next_action','CREATE_REVISION_THEN_APPLY_PATCH');
end $function$;

-- atlas_product_grounding_matches_v1
CREATE OR REPLACE FUNCTION public.atlas_product_grounding_matches_v1(p_empresa_id uuid, p_product_id uuid, p_evidence_text text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_name text; v_ev text; v_nm text; v_tok text; v_stop text[]:=array['mini','de','del','la','el','con','y','al','para','clasico','clasica','especial','vegetariano','vegetariana'];
begin
 if btrim(coalesce(p_evidence_text,''))='' then return false; end if;
 select nombre into v_name from public.productos where empresa_id=p_empresa_id and id=p_product_id;
 if v_name is null then return false; end if;
 v_ev:=lower(translate(p_evidence_text,'áéíóúüñÁÉÍÓÚÜÑ','aeiouunAEIOUUN'));
 v_nm:=lower(translate(v_name,'áéíóúüñÁÉÍÓÚÜÑ','aeiouunAEIOUUN'));
 for v_tok in select t from regexp_split_to_table(v_nm,'[^a-z0-9]+') t where length(t)>=4 and not(t=any(v_stop)) loop
   if position(v_tok in v_ev)>0 or (length(v_tok)>=5 and position(left(v_tok,length(v_tok)-1) in v_ev)>0) then return true; end if;
 end loop;
 return false;
end $function$;

-- atlas_supersede_quote_acceptance_on_revision_v1
CREATE OR REPLACE FUNCTION public.atlas_supersede_quote_acceptance_on_revision_v1(p_empresa_id uuid, p_conversation_id uuid, p_new_quote_builder_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n integer;
begin
 update public.atlas_quote_acceptances
 set status='SUPERSEDED',superseded_at=now(),superseded_by_quote_builder_id=p_new_quote_builder_id,updated_at=now()
 where empresa_id=p_empresa_id and conversation_id=p_conversation_id and status='ACCEPTED' and quote_builder_id<>p_new_quote_builder_id;
 get diagnostics n=row_count;
 return jsonb_build_object('ok',true,'superseded_count',n,'new_quote_builder_id',p_new_quote_builder_id);
end $function$;
