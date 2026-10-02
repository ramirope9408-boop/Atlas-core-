import { interpret, response, assertQuote, type Json } from './contract.ts';
export interface Backend {
  client:any;
  rpc(name:string,args:Json):Promise<any>;
  model(context:Json):Promise<unknown>;
  document(type:string,result:Json):Promise<Json>;
  audio(text:string,result:Json):Promise<Json>;
}
async function relationshipContext(b:Backend,context:Json,input:Json):Promise<Json>{
  const w=context.work_state||{}; let conversation:Json={}; let customer:Json={}; let prefs:Json={};
  try{const q=await b.client.from('atlas_conversations').select('id,customer_phone,customer_name,metadata').eq('id',input.conversation_id).eq('empresa_id',input.empresa_id).maybeSingle();conversation=q.data||{};}catch{}
  try{
    const explicit=conversation?.metadata?.cliente_id;
    if(explicit){const q=await b.client.from('clientes').select('id,nombre,telefono,email,fecha_primer_contacto,fecha_ultimo_contacto').eq('id',explicit).eq('empresa_id',input.empresa_id).maybeSingle();customer=q.data||{};}
    else if(conversation.customer_phone){
      const digits=String(conversation.customer_phone).replace(/[^0-9]/g,'');
      const q=await b.client.from('clientes').select('id,nombre,telefono,email,fecha_primer_contacto,fecha_ultimo_contacto').eq('empresa_id',input.empresa_id);
      const rows=(q.data||[]).filter((x:Json)=>String(x.telefono||'').replace(/[^0-9]/g,'')===digits); if(rows.length===1)customer=rows[0];
    }
    const company=await b.client.from('empresas').select('metadata').eq('id',input.empresa_id).maybeSingle();
    const allowed=company.data?.metadata?.relationship_memory_allowed_fields||[];
    if(customer.id&&Array.isArray(allowed)&&allowed.length){
      const q=await b.client.from('perfiles_cliente').select('nivel_formalidad,acepta_emojis,acepta_diminutivos,perfil_regional').eq('cliente_id',customer.id).maybeSingle();
      if(q.data)for(const k of ['nivel_formalidad','acepta_emojis','acepta_diminutivos','perfil_regional'])if(allowed.includes(k)&&q.data[k]!=null)prefs[k]=q.data[k];
    }
  }catch{}
  const prior=(context.stable_memory||[]).filter((m:Json)=>m.message_id!==context.source_message_id);
  const continuity=w?.metadata?.commercial_continuity||{}; let delivered=false;
  try{if(w.active_quote_builder_id){const q=await b.client.from('atlas_commercial_outbox').select('id').eq('empresa_id',input.empresa_id).eq('conversation_id',input.conversation_id).eq('quote_builder_id',w.active_quote_builder_id).eq('kind','PDF').eq('status','SENT').in('provider_delivery_status',['delivered','read']).limit(1);delivered=Boolean(q.data?.length);}}catch{}
  return {customer:{customer_id:customer.id||null,name:customer.nombre||conversation.customer_name||null,returning:prior.length>0||Boolean(customer.id),communication_preferences:prefs},
    active_opportunity:{state_id:w.state_id||null,stage:w.commercial_stage||null,quote_id:w.active_quote_builder_id||null,quote_delivered:delivered,missing_fields:w.missing_fields||[]},
    continuity,follow_up:continuity?.status==='PENDING'?continuity:(delivered&&w.commercial_stage==='QUOTED'?{status:'PENDING',reason:'QUOTE_RESPONSE',outbound_allowed:false,due_at:null}:{}),authority:'RELATIONSHIP_CONTEXT_ONLY'};
}
async function persistContinuity(b:Backend,result:Json,decision:Json,input:Json):Promise<void>{
  const w=result.work_state||{}; if(!w.state_id)return; const x=decision.continuity||{}; const current=w?.metadata?.commercial_continuity||{}; let next:Json=current;
  if(current?.status==='PENDING'&&(w.commercial_stage==='PAID'||(current.reason==='QUOTE_RESPONSE'&&['ACCEPTED','PAYMENT_PENDING'].includes(w.commercial_stage))))next={...current,status:'COMPLETED',outbound_allowed:false,completion_source:input.source_message_id};
  if(x.mode){
    if(x.mode==='RESUME')next={...current,status:'COMPLETED',mode:'RESUME',outbound_allowed:false,completion_source:input.source_message_id};
    else next={empresa_id:input.empresa_id,conversation_id:input.conversation_id,opportunity_id:w.state_id,quote_id:w.active_quote_builder_id||null,commercial_stage:w.commercial_stage,mode:x.mode,reason:x.reason,status:'PENDING',created_from_message:input.source_message_id,source_evidence:x.evidence,last_customer_interaction:new Date().toISOString(),waiting_for:x.mode==='PROOF_SUBMITTED'?'TEAM':'CUSTOMER',expected_time_text:x.expected_time_text||null,due_at:null,outbound_allowed:false,proof_status:x.mode==='PROOF_SUBMITTED'?'UNVERIFIED':null,proof_message_id:x.mode==='PROOF_SUBMITTED'?input.source_message_id:null,completion_condition:'CUSTOMER_RESUMES_OR_CANONICAL_STAGE_CHANGES',cancellation_condition:'NEW_EVENT_OR_QUOTE_SUPERSEDED'};
  }
  if(JSON.stringify(next)===JSON.stringify(current))return;
  const metadata={...(w.metadata||{}),commercial_continuity:next};
  const upd=await b.client.from('atlas_conversation_work_states').update({metadata,state_version:Number(w.state_version||0)+1,updated_at:new Date().toISOString()}).eq('id',w.state_id).eq('empresa_id',input.empresa_id).eq('conversation_id',input.conversation_id).eq('status','ACTIVE');
  if(upd.error)throw new Error('CRM_CONTINUITY_PERSIST_FAILED');
}
export async function processTurn(b:Backend,input:Json):Promise<Json>{
  const scope={p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id,p_source_message_id:input.source_message_id};
  let result:Json|undefined,context:Json={},decision:Json={};
  for(let attempt=0;attempt<2;attempt++){
    context=await b.rpc('atlas_commercial_context',scope);
    try{const media=await b.rpc('atlas_commercial_scope',scope);context.current_media={message_type:media?.message_type||null,media_id:media?.media_id||null};}catch{}
    context.relationship=await relationshipContext(b,context,input);
    const raw=await b.model(context);
    try{decision=interpret(raw,context);}catch(e){decision={requested_action:'NONE',work_intent:'GENERAL',event_patch:{},requirements:{},recommended_products:[],selected_products:[],current_reference:{type:'NONE',product_ids:[]},interpretation_error:(e as Error).message};}
    try{result=await b.rpc('atlas_commercial_execute_turn',{...scope,p_expected_state_id:context.state_id||null,p_expected_version:context.state_version||0,p_decision:decision});break;}
    catch(e){if(attempt===0&&String(e).includes('STALE_TURN_CONTEXT'))continue;throw e;}
  }
  if(!result)throw new Error('TURN_NOT_COMMITTED'); if(result.code==='HUMAN_CONTROL')return {...result,deliveries:[]};
  await persistContinuity(b,result,decision,input);
  try{result.work_state=await b.rpc('atlas_get_active_conversation_work_state_v1',{p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id});}catch{}
  result={...result,context}; result.relationship=await relationshipContext(b,{...context,work_state:result.work_state},input);
  if(result.quote)assertQuote(result.quote,input.empresa_id,input.conversation_id);
  const text=response(result); const items:Json[]=[];
  if(result.delivery_type==='PDF'||result.delivery_type==='PAYMENT'){
    const doc=await b.document(result.delivery_type==='PDF'?'QUOTE_CLIENT':'PAYMENT_CLIENT',result); if(!doc.document_id||!doc.storage?.path||!doc.checksum_sha256)throw new Error('DOCUMENT_PROOF_REQUIRED');
    items.push({kind:result.delivery_type==='PDF'?'PDF':'IMAGE',document_id:doc.document_id,storage:doc.storage,file_name:doc.file_name,caption:text});
    if(result.decision?.secondary_product_ids?.length){const cat=result.context?.catalog_products||[];const picks=cat.filter((p:Json)=>result.decision.secondary_product_ids.includes(p.product_id)).slice(0,3);if(picks.length)items.push({kind:'TEXT',text:'Y sobre lo otro que me preguntaste, tengo estas opciones: '+picks.map((p:Json)=>p.name).join(', ')+'. Si quieres, te muestro fotos.'});}
  }else if(result.delivery_type==='VISUAL'){
    const visuals=await b.rpc('atlas_resolve_conversation_visuals_v1',{p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id,p_product_ids:result.decision.visual_product_ids||[],p_scope:result.decision.visual_scope||'WORK_STATE_REFERENCE'});const pictures=visuals.items||visuals.visuals||[];if(!visuals.ready||!pictures.length)throw new Error('CANONICAL_VISUAL_NOT_AVAILABLE');for(const p of pictures){if(!p.product_id||!(p.public_url||p.url))throw new Error('VISUAL_PROOF_REQUIRED');items.push({kind:'IMAGE',url:p.public_url||p.url,caption:p.canonical_name||p.product_name||p.name||'',product_ids:[p.product_id]});}
  }else if(result.delivery_type==='POLICIES'){const doc=await b.document('EVENT_POLICIES',result);items.push({kind:'IMAGE',storage:doc.storage,caption:text});
  }else if(result.decision?.response_mode==='AUDIO'||result.decision?.response_mode==='TEXT_PLUS_AUDIO'){const audio=await b.audio(text,result);items.push({kind:'AUDIO',storage:audio.storage,text});if(result.decision.response_mode==='TEXT_PLUS_AUDIO')items.push({kind:'TEXT',text});
  }else if(text)items.push({kind:'TEXT',text});
  const deliveries=items.length?await b.rpc('atlas_commercial_enqueue',{p_empresa_id:input.empresa_id,p_turn_id:result.turn_id,p_items:items}):[];
  return{ok:true,contract:result.contract,turn_id:result.turn_id,code:result.code,executed:result.executed,proof:result.proof,deliveries};
}
export function messages(context:Json):Json[]{
  return [{role:'system',content:context.persona?.system_prompt||'Eres una asesora comercial amable y útil.'},
    {role:'system',content:`Interpreta SOLO la intención del mensaje actual. La base de datos ejecuta y decide; nunca inventes productos, importes, disponibilidad o reglas. Usa la memoria para continuidad humana, no para rellenar datos de otro evento. Conserva los datos ya presentes del evento. Haz como máximo una pregunta útil cada vez. Conversa antes de interrogar: saludo, cortesía o charla social no deben disparar preguntas de clasificación comercial. Sé cálida, breve, natural y resolutiva; evita sonar como formulario, menú o bot. Nuevo evento abre sesión limpia. Los saludos y ACK no crean ni aceptan cotizaciones. Una modificación junto con aceptación siempre es MODIFY. "Estos/esa/la misma" se resuelve contra current_reference; si es ambiguo pide precisión. Si el cliente pide ver, mostrar o enviar fotos/imágenes, usa visual_request:true, requested_action:"VISUAL" y visual_product_ids canónicos. Recomienda exclusivamente IDs del catálogo. Si el cliente te delega elegir, recomienda y selecciona productos canónicos con cantidades justificadas. Los nombres de lugares no verificados no son recomendaciones autorizadas.
La relación del cliente es CONTEXTO y nunca reemplaza Work State, cotización o pago. Usa relationship para reconocer clientes que regresan y continuar la oportunidad activa. INTERPRETA SIEMPRE mensaje + estado actual: si no existe active_quote_builder_id, la información/corrección del evento NO es MODIFY_QUOTE; actualiza CONTINUE_EVENT. MODIFY solo existe sobre una cotización formal vigente. Si commercial_stage ya es ACCEPTED o PAYMENT_PENDING, no vuelvas a aceptar por una frase de cierre: usa continuidad/ACK/CLOSE según el sentido. Una solicitud natural de pago sobre una cotización entregada puede ser PAYMENT; ATLAS validará la acción. Audio y texto, una vez transcrito, pasan por exactamente la misma interpretación semántica. Tolera modismos, regionalismos, errores ortográficos, falta de puntuación, frases incompletas y autocorrecciones; no dependas de frases exactas. La comunicación puede cerrar sin cerrar la oportunidad. Interpreta semánticamente pausas, regreso, compromisos y comprobantes. Añade continuity solo con evidencia del turno: {mode:"PAUSE|RESUME|CLOSE|PROOF_SUBMITTED",reason:"INFORMATION|QUOTE_RESPONSE|PAYMENT|PAYMENT_PROOF",evidence:"fragmento literal",expected_time_text:null}. No inventes fechas, horas o promesas. Nunca verifiques un pago por una imagen. No programes seguimiento autónomo.\nDevuelve JSON: {requested_action:"NONE|CREATE|MODIFY|REJECT|ACCEPT|PAYMENT|PDF_RESEND|VISUAL|POLICIES|HANDOFF",action_evidence:"fragmento literal del mensaje que pide la acción",work_intent:"GREETING|GENERAL|EXPLORE|ASK_INFORMATION|ASK_PRICE|RECOMMEND|COMPARE_OPTIONS|REQUEST_AVAILABILITY|MEMORY_RECALL|SELECT_PRODUCTS|QUOTE_CREATE|CONTINUE_EVENT|QUOTE_QUESTION|COMPLAIN|POST_SALE",start_new_event:false,event_patch:{},field_evidence:{},requirements:{service_type:null,service_duration_hours:null,decoration_needed:null,waiters_needed:null},requirement_evidence:{},recommended_products:[{product_id:"UUID",quantity:1}],selected_products:[],replace_selected:false,replace_recommended:false,current_reference:{type:"NONE|RECOMMENDED_PRODUCTS|SELECTED_PRODUCTS|EXPLICIT_PRODUCTS",product_ids:[]},visual_request:false,visual_scope:"WORK_STATE_REFERENCE|EXPLICIT|ACTIVE_QUOTE",visual_product_ids:[],secondary_intent:"NONE|ASK_INFORMATION|ASK_PRICE|RECOMMEND|VISUAL",secondary_product_ids:[],modification:{},confidence:0.99,question_field:null,policy_codes:[],response_mode:"TEXT|AUDIO|TEXT_PLUS_AUDIO",human_handoff_required:false,continuity:{mode:null,reason:null,evidence:null,expected_time_text:null}}.
event_patch solo incluye campos afirmados en este mensaje: event_type,event_date YYYY-MM-DD,event_time,people_count,event_location,event_style,preferences. field_evidence debe contener un fragmento literal para cada campo. requirements puede guardar service_type, service_duration_hours, decoration_needed y waiters_needed; para duración/decoración/meseros requirement_evidence debe citar literalmente la respuesta del cliente. service_type se elige entre las reglas MINIMUM_SERVICE_VALUE de company_policy; no clasifiques por accesorios. Si el servicio es FINGER_TABLE o FULL_EVENT y faltan duración, decoración o meseros, recógelos de forma natural, uno por turno, antes de cerrar la cotización. Si un mismo mensaje contiene una acción principal y otra consulta, ejecuta la acción principal y conserva la segunda en secondary_intent/secondary_product_ids. Ejemplo: "agrégalo y tienes algo con camarones" = MODIFY del referente actual + secondary_intent RECOMMEND con IDs canónicos relacionados con camarones. Para cambios de cotización usa modification:{people_count,event_date,event_location,products:[{op:"ADD|REMOVE|SET",product_id,quantity,reference:"CURRENT_REFERENCE" opcional}]}. REMOVE omite quantity. ADD suma a lo existente; SET fija el nuevo total. No envíes precios ni totales. No generes reply_text: el backend redacta los hechos. Para responder a políticas usa policy_codes canónicos. Una negativa a la propuesta vigente es REJECT; no confundas una corrección con rechazo completo. Si ya existe una cotización formal y el cliente describe una fecha, cantidad de personas u ocasión diferente como una nueva necesidad, no la mezcles automáticamente con la cotización vieja: si el lenguaje indica claramente otro evento usa start_new_event:true; si no es claro, requested_action:"NONE" y pregunta si es evento nuevo o modificación. Los comentarios sobre el tono son GENERAL y deben respetarse inmediatamente. Si acabas de pedir una aclaración concreta y el cliente responde "seguro, cuéntame", "sí, dime" o equivalente, continúa explicando ESA aclaración; no reinicies el descubrimiento. Para reclamos, atención posventa o solicitud de una persona usa HANDOFF y el work_intent correspondiente. REQUEST_AVAILABILITY nunca permite confirmar disponibilidad no verificada. ASK_PRICE/ASK_INFORMATION/COMPARE_OPTIONS usan current_reference.product_ids canónicos. Si hay una solicitud de cotizar pendiente y el cliente aporta el dato, actualiza ese dato; el backend reanuda la solicitud.`},
    {role:'system',content:JSON.stringify({relationship:context.relationship,current_media:context.current_media,current_date:context.current_date,work_state:context.work_state,catalog_products:context.catalog_products,company_policy:context.company_policy,stable_memory:context.stable_memory,active_quote:context.active_quote,pending:context.pending_quote_modification_confirmation})},
    ...(context.conversation_history||[]).filter((m:Json)=>m.message_id!==context.source_message_id).slice(-12).map((m:Json)=>({role:String(m.direction).toUpperCase()==='OUTBOUND'?'assistant':'user',content:String(m.content||m.text_content||'')})).filter((m:Json)=>m.content),
    {role:'user',content:context.current_message}];
}