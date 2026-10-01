import { interpret, response, assertQuote, type Json } from './contract.ts';
export interface Backend {
  rpc(name:string,args:Json):Promise<any>;
  model(context:Json):Promise<unknown>;
  document(type:string,result:Json):Promise<Json>;
  audio(text:string,result:Json):Promise<Json>;
}
export async function processTurn(b:Backend,input:Json):Promise<Json>{
  const scope={p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id,p_source_message_id:input.source_message_id};
  // Re-evaluate an interpretation if another turn committed while the model was thinking.
  let result:Json|undefined,context:Json={};
  for(let attempt=0;attempt<2;attempt++){
    context=await b.rpc('atlas_commercial_context',scope);
    const raw=await b.model(context);let decision:Json;
    try{decision=interpret(raw,context);}catch(e){
      // A malformed interpretation cannot perform an action or echo the model's prose.
      decision={requested_action:'NONE',work_intent:'GENERAL',event_patch:{},requirements:{},recommended_products:[],selected_products:[],current_reference:{type:'NONE',product_ids:[]},interpretation_error:(e as Error).message};
    }
    try{result=await b.rpc('atlas_commercial_execute_turn',{...scope,p_expected_state_id:context.state_id||null,p_expected_version:context.state_version||0,p_decision:decision});break;}
    catch(e){if(attempt===0&&String(e).includes('STALE_TURN_CONTEXT'))continue;throw e;}
  }
  if(!result)throw new Error('TURN_NOT_COMMITTED');
  if(result.code==='HUMAN_CONTROL')return {...result,deliveries:[]};
  result={...result,context};
  if(result.quote)assertQuote(result.quote,input.empresa_id,input.conversation_id);
  const text=response(result);const items:Json[]=[];
  if(result.delivery_type==='PDF'||result.delivery_type==='PAYMENT'){
    // Rendering errors propagate. No conversation fallback can claim a missing document.
    const doc=await b.document(result.delivery_type==='PDF'?'QUOTE_CLIENT':'PAYMENT_CLIENT',result);
    if(!doc.document_id||!doc.storage?.path||!doc.checksum_sha256)throw new Error('DOCUMENT_PROOF_REQUIRED');
    items.push({kind:result.delivery_type==='PDF'?'PDF':'IMAGE',document_id:doc.document_id,storage:doc.storage,file_name:doc.file_name,caption:text});
  }else if(result.delivery_type==='VISUAL'){
    const visuals=await b.rpc('atlas_resolve_conversation_visuals_v1',{p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id,p_product_ids:result.decision.visual_product_ids||[],p_scope:result.decision.visual_scope||'WORK_STATE_REFERENCE'});
    const pictures=visuals.items||visuals.visuals||[];
    if(!visuals.ready||!pictures.length)throw new Error('CANONICAL_VISUAL_NOT_AVAILABLE');
    for(const p of pictures){if(!p.product_id||!(p.public_url||p.url))throw new Error('VISUAL_PROOF_REQUIRED');items.push({kind:'IMAGE',url:p.public_url||p.url,caption:p.canonical_name||p.product_name||p.name||'',product_ids:[p.product_id]});}
  }else if(result.delivery_type==='POLICIES'){
    const doc=await b.document('EVENT_POLICIES',result);items.push({kind:'IMAGE',storage:doc.storage,caption:text});
  }else if(result.decision?.response_mode==='AUDIO'||result.decision?.response_mode==='TEXT_PLUS_AUDIO'){
    const audio=await b.audio(text,result);items.push({kind:'AUDIO',storage:audio.storage,text});
    if(result.decision.response_mode==='TEXT_PLUS_AUDIO')items.push({kind:'TEXT',text});
  }else if(text)items.push({kind:'TEXT',text});
  const deliveries=items.length?await b.rpc('atlas_commercial_enqueue',{p_empresa_id:input.empresa_id,p_turn_id:result.turn_id,p_items:items}):[];
  return{ok:true,contract:result.contract,turn_id:result.turn_id,code:result.code,executed:result.executed,proof:result.proof,deliveries};
}

export function messages(context:Json):Json[]{
  return [{role:'system',content:context.persona?.system_prompt||'Eres una asesora comercial amable y útil.'},
    {role:'system',content:`Interpreta SOLO la intención del mensaje actual. La base de datos ejecuta y decide; nunca inventes productos, importes, disponibilidad o reglas. Usa la memoria para continuidad humana, no para rellenar datos de otro evento. Conserva los datos ya presentes del evento. Haz como máximo una pregunta útil cada vez. Conversa antes de interrogar: saludo, cortesía o charla social no deben disparar preguntas de clasificación comercial. Sé cálida, breve, natural y resolutiva; evita sonar como formulario, menú o bot. Nuevo evento abre sesión limpia. Los saludos y ACK no crean ni aceptan cotizaciones. Una modificación junto con aceptación siempre es MODIFY. "Estos/esa/la misma" se resuelve contra current_reference; si es ambiguo pide precisión. Si el cliente pide ver, mostrar o enviar fotos/imágenes, usa visual_request:true, requested_action:"VISUAL" y visual_product_ids canónicos. Recomienda exclusivamente IDs del catálogo. Si el cliente te delega elegir, recomienda y selecciona productos canónicos con cantidades justificadas. Los nombres de lugares no verificados no son recomendaciones autorizadas.
Devuelve JSON: {requested_action:"NONE|CREATE|MODIFY|REJECT|ACCEPT|PAYMENT|PDF_RESEND|VISUAL|POLICIES|HANDOFF",action_evidence:"fragmento literal del mensaje que pide la acción",work_intent:"GREETING|GENERAL|EXPLORE|ASK_INFORMATION|ASK_PRICE|RECOMMEND|COMPARE_OPTIONS|REQUEST_AVAILABILITY|MEMORY_RECALL|SELECT_PRODUCTS|QUOTE_CREATE|CONTINUE_EVENT|QUOTE_QUESTION|COMPLAIN|POST_SALE",start_new_event:false,event_patch:{},field_evidence:{},requirements:{service_type:null},recommended_products:[{product_id:"UUID",quantity:1}],selected_products:[],replace_selected:false,replace_recommended:false,current_reference:{type:"NONE|RECOMMENDED_PRODUCTS|SELECTED_PRODUCTS|EXPLICIT_PRODUCTS",product_ids:[]},visual_request:false,visual_scope:"WORK_STATE_REFERENCE|EXPLICIT|ACTIVE_QUOTE",visual_product_ids:[],modification:{},confidence:0.99,question_field:null,policy_codes:[],response_mode:"TEXT|AUDIO|TEXT_PLUS_AUDIO",human_handoff_required:false}.
event_patch solo incluye campos afirmados en este mensaje: event_type,event_date YYYY-MM-DD,event_time,people_count,event_location,event_style,preferences. field_evidence debe contener un fragmento literal para cada campo. service_type se elige entre las reglas MINIMUM_SERVICE_VALUE de company_policy; no clasifiques por accesorios. Para cambios de cotización usa modification:{people_count,event_date,event_location,products:[{op:"ADD|REMOVE|SET",product_id,quantity,reference:"CURRENT_REFERENCE" opcional}]}. REMOVE omite quantity. ADD suma a lo existente; SET fija el nuevo total. No envíes precios ni totales. No generes reply_text: el backend redacta los hechos. Para responder a políticas usa policy_codes canónicos. Una negativa a la propuesta vigente es REJECT; no confundas una corrección con rechazo completo. Si ya existe una cotización formal y el cliente describe una fecha, cantidad de personas u ocasión diferente como una nueva necesidad, no la mezcles automáticamente con la cotización vieja: si el lenguaje indica claramente otro evento usa start_new_event:true; si no es claro, requested_action:"NONE" y pregunta si es evento nuevo o modificación. Los comentarios sobre el tono son GENERAL y deben respetarse inmediatamente. Para reclamos, atención posventa o solicitud de una persona usa HANDOFF y el work_intent correspondiente. REQUEST_AVAILABILITY nunca permite confirmar disponibilidad no verificada. ASK_PRICE/ASK_INFORMATION/COMPARE_OPTIONS usan current_reference.product_ids canónicos. Si hay una solicitud de cotizar pendiente y el cliente aporta el dato, actualiza ese dato; el backend reanuda la solicitud.`},
    {role:'system',content:JSON.stringify({current_date:context.current_date,work_state:context.work_state,catalog_products:context.catalog_products,company_policy:context.company_policy,stable_memory:context.stable_memory,active_quote:context.active_quote,pending:context.pending_quote_modification_confirmation})},
    ...(context.conversation_history||[]).filter((m:Json)=>m.message_id!==context.source_message_id).slice(-12).map((m:Json)=>({role:String(m.direction).toUpperCase()==='OUTBOUND'?'assistant':'user',content:String(m.content||m.text_content||'')})).filter((m:Json)=>m.content),
    {role:'user',content:context.current_message}];
}