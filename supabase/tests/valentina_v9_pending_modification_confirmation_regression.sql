-- VALENTINA V9 REGRESSION
-- Bug: AI asks "is this modification correct?", customer replies "Exacto",
-- but runtime forgets the pending modification and asks for product/quantity again.
-- Expected: persist proposal -> bind to current quote version -> explicit confirmation
-- -> execute deterministic patch -> resolve pending intent.

do $$
declare
  v_empresa uuid:='bf55a6aa-2e3f-4749-b2b8-135537a7c7bf';
  v_conv uuid:='90000000-0000-4000-8000-000000000300';
  v_qb uuid:='90000000-0000-4000-8000-000000000310';
  v_proposal uuid:='90000000-0000-4000-8000-000000000320';
  v_confirm uuid:='90000000-0000-4000-8000-000000000321';
  v_station uuid:='5885631f-c198-4c10-97aa-6fce6bc6c9fc';
  v_arepita uuid:='296f6799-6240-4ce2-804b-c6199d66aa64';
  v_albondiga uuid:='e7ffd9f3-8d11-4fed-84bf-3a8d9ad5f03d';
  v_pending jsonb;
  v_plan jsonb;
  v_execution jsonb;
  v_finalize jsonb;
  v_new_qb uuid;
  v_station_qty numeric;
  v_arepita_qty numeric;
  v_albondiga_qty numeric;
  v_pending_status text;
begin
  delete from public.atlas_conversation_pending_intents where conversation_id=v_conv;
  delete from public.atlas_conversation_messages where conversation_id=v_conv;
  delete from public.atlas_quote_line_items where quote_builder_id=v_qb;
  delete from public.atlas_quote_builders where id=v_qb;
  delete from public.atlas_conversations where id=v_conv;

  insert into public.atlas_conversations(
    id,empresa_id,channel,external_conversation_id,customer_phone,customer_name,status,persona_code,metadata
  ) values(
    v_conv,v_empresa,'WHATSAPP','B2-CERT-V9-PENDING-CONF-REGRESSION',
    '+570000000002','B2 CERT CUSTOMER','OPEN','VALENTINA',
    '{"fixture":true,"scenario":"PENDING_MODIFICATION_CONFIRMATION_REGRESSION"}'::jsonb
  );

  insert into public.atlas_quote_builders(
    id,empresa_id,source_channel,source_message,context_code,people_count,event_date,event_location,status,
    subtotal_productos,subtotal_servicios,descuento_total,total,currency,metadata,
    client_name,client_phone,deposit_mode,deposit_percent,deposit_amount,balance_amount,
    document_display_id,document_issued_at,document_valid_until,document_valid_until_at,
    quote_version,root_quote_builder_id
  ) values(
    v_qb,v_empresa,'WHATSAPP','Fixture V9 pending confirmation','EXTERNAL_WHATSAPP_QUOTE_V1',
    20,current_date+30,'Cartagena','READY_FOR_QUOTE',
    1780000,0,0,1780000,'COP',
    jsonb_build_object('fixture',true,'conversation_id',v_conv::text),
    'B2 CERT CUSTOMER','+570000000002','STANDARD_PERCENT',50,890000,890000,
    'B2-CERT-000310',now()-interval '5 minutes',current_date+7,now()+interval '7 days',
    1,v_qb
  );

  insert into public.atlas_quote_line_items(
    quote_builder_id,empresa_id,producto_id,cantidad,precio_unitario,descuento_unitario,metadata
  ) values
  (v_qb,v_empresa,v_station,1,1500000,0,'{"fixture":true}'::jsonb),
  (v_qb,v_empresa,v_arepita,20,7500,0,'{"fixture":true}'::jsonb),
  (v_qb,v_empresa,v_albondiga,20,6500,0,'{"fixture":true}'::jsonb);

  insert into public.atlas_conversation_messages(
    id,empresa_id,conversation_id,direction,actor_type,channel,message_type,text_content,
    processing_status,model_metadata,raw_payload
  ) values(
    v_proposal,v_empresa,v_conv,'OUTBOUND','AI','WHATSAPP','TEXT',
    'Necesito confirmar si quieres que ajuste la cotización para incluir 10 unidades de cada opción, además de la mesa mexicana. ¿Es correcto?',
    'COMPLETED','{}'::jsonb,'{"fixture":true}'::jsonb
  );

  v_pending:=public.atlas_get_open_quote_modification_confirmation_v1(v_empresa,v_conv);

  if coalesce((v_pending->>'found')::boolean,false) is not true then
    raise exception 'REGRESSION_FAIL: pending confirmation was not persisted';
  end if;

  if v_pending#>>'{patch_resolution,exception_product_id}' is distinct from v_station::text then
    raise exception 'REGRESSION_FAIL: natural exception did not resolve to station product: %',v_pending;
  end if;

  insert into public.atlas_conversation_messages(
    id,empresa_id,conversation_id,direction,actor_type,channel,message_type,text_content,
    processing_status,model_metadata,raw_payload
  ) values(
    v_confirm,v_empresa,v_conv,'INBOUND','CUSTOMER','WHATSAPP','TEXT',
    'Exacto','READY_FOR_AI','{}'::jsonb,'{"fixture":true}'::jsonb
  );

  v_plan:=public.atlas_prepare_confirmed_pending_quote_modification_plan_v1(
    v_empresa,v_conv,v_confirm
  );

  if coalesce((v_plan->>'ready_to_act')::boolean,false) is not true
     or v_plan->>'code'<>'QUOTE_MODIFICATION_PLAN_READY_V2'
  then
    raise exception 'REGRESSION_FAIL: explicit confirmation did not produce executable plan: %',v_plan;
  end if;

  v_execution:=public.atlas_execute_quote_modification_plan_v2(
    v_empresa,v_conv,v_confirm,v_plan
  );

  v_new_qb:=nullif(v_execution->>'new_quote_builder_id','')::uuid;
  if v_new_qb is null then
    raise exception 'REGRESSION_FAIL: execution did not create revision: %',v_execution;
  end if;

  v_finalize:=public.atlas_finalize_confirmed_pending_quote_modification_v1(
    v_empresa,v_conv,v_confirm,v_execution
  );

  if coalesce((v_finalize->>'ok')::boolean,false) is not true then
    raise exception 'REGRESSION_FAIL: pending confirmation did not close: %',v_finalize;
  end if;

  select cantidad into v_station_qty
  from public.atlas_quote_line_items
  where quote_builder_id=v_new_qb and producto_id=v_station;

  select cantidad into v_arepita_qty
  from public.atlas_quote_line_items
  where quote_builder_id=v_new_qb and producto_id=v_arepita;

  select cantidad into v_albondiga_qty
  from public.atlas_quote_line_items
  where quote_builder_id=v_new_qb and producto_id=v_albondiga;

  if v_station_qty<>1 or v_arepita_qty<>10 or v_albondiga_qty<>10 then
    raise exception 'REGRESSION_FAIL: wrong resulting quantities station=% arepita=% albondiga=%',
      v_station_qty,v_arepita_qty,v_albondiga_qty;
  end if;

  select status into v_pending_status
  from public.atlas_conversation_pending_intents
  where conversation_id=v_conv
    and intent_type='QUOTE_MODIFICATION_CONFIRMATION'
  order by created_at desc
  limit 1;

  if v_pending_status<>'RESOLVED' then
    raise exception 'REGRESSION_FAIL: pending status=%',v_pending_status;
  end if;
end;
$$;

select jsonb_build_object(
  'ok',true,
  'code','VALENTINA_V9_PENDING_MODIFICATION_CONFIRMATION_PASS'
) as result;
