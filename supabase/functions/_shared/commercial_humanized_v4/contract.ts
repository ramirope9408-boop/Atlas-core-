// Model output is an interpretation, never a response or a financial source.
export type Json = Record<string, any>;
export const ACTIONS = ['NONE','CREATE','MODIFY','REJECT','ACCEPT','PAYMENT','PDF_RESEND','VISUAL','POLICIES','HANDOFF'] as const;
export function normalize(s: unknown): string {
  return String(s ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/\s+/g,' ').trim();
}
export function integer(v: unknown): number {
  const n=Number(v); if(!Number.isSafeInteger(n)||n<=0||n>100000) throw new Error('INVALID_QUANTITY'); return n;
}
export function businessDate(v: unknown): string {
  const s=String(v); if(!/^\d{4}-\d{2}-\d{2}$/.test(s)) throw new Error('INVALID_BUSINESS_DATE');
  const [y,m,d]=s.split('-').map(Number); const dt=new Date(Date.UTC(y,m-1,d));
  if(dt.getUTCFullYear()!==y||dt.getUTCMonth()!==m-1||dt.getUTCDate()!==d)throw new Error('INVALID_BUSINESS_DATE');
  return `${s.slice(8,10)}/${s.slice(5,7)}/${s.slice(0,4)}`;
}
export function amount(v:unknown,currency='COP'):string {
  const n=Number(v);if(!Number.isFinite(n)||n<0)throw new Error('INVALID_CANONICAL_AMOUNT');
  return new Intl.NumberFormat('es-CO',{style:'currency',currency,minimumFractionDigits:currency==='COP'&&Number.isInteger(n)?0:2,maximumFractionDigits:2}).format(n);
}
export function assertQuote(q:Json,tenant:string,conversation:string):void {
  if(q.empresa_id!==tenant || q.metadata?.conversation_id!==conversation)throw new Error('QUOTE_SCOPE_MISMATCH');
  for(const k of ['total','deposit_amount','balance_amount'])if(!Number.isFinite(Number(q[k]))||Number(q[k])<0)throw new Error('QUOTE_AMOUNT_INVALID');
  if(Math.abs(Number(q.total)-Number(q.deposit_amount)-Number(q.balance_amount))>0.005)throw new Error('QUOTE_AMOUNT_MISMATCH');
  businessDate(q.event_date);
}
export function interpret(raw:unknown,context:Json):Json {
  if(!raw||typeof raw!=='object'||Array.isArray(raw))throw new Error('MALFORMED_INTERPRETATION');
  const d=raw as Json; const source=normalize(context.current_message);const evidence=normalize(d.action_evidence);
  const ack=/^(dale|listo|ok|okay|bueno|perfecto|gracias|muchas gracias)[.! ]*$/.test(source);
  const referenceIds=context.work_state?.current_reference?.product_ids||[];
  const catalog=new Map((context.catalog_products||[]).map((p:Json)=>[p.product_id,p]));
  const products=(a:unknown)=>{if(a==null)return [];if(!Array.isArray(a))throw new Error('INVALID_PRODUCTS');const seen=new Set();return a.map((p:Json)=>{if(p.reference==='CURRENT_REFERENCE'){if(referenceIds.length!==1)throw new Error('AMBIGUOUS_REFERENCE');p={...p,product_id:referenceIds[0]};}if(!catalog.has(p.product_id)||seen.has(p.product_id))throw new Error('NON_CANONICAL_PRODUCT');seen.add(p.product_id);return{product_id:p.product_id,quantity:integer(p.quantity)};});};
  const ep:Json={};for(const k of ['event_type','event_date','event_time','people_count','event_location','event_style','preferences']) {
    const v=d.event_patch?.[k];if(v==null||v==='')continue;
    const span=normalize(d.field_evidence?.[k]);if(!span||!source.includes(span))throw new Error('UNGROUNDED_EVENT_FIELD');
    ep[k]=k==='people_count'?integer(v):v;if(k==='event_date')businessDate(v);
  }
  const service=d.requirements?.service_type;
  const allowed=(context.company_policy?.commercial_rules||[]).filter((r:Json)=>r.rule_type==='MINIMUM_SERVICE_VALUE').map((r:Json)=>r.service_type);
  if(service&&!allowed.includes(service))throw new Error('UNKNOWN_SERVICE_TYPE');
  const req:Json={};
  if(service)req.service_type=service;
  for(const k of ['decoration_needed','waiters_needed']){
    if(d.requirements?.[k]===true||d.requirements?.[k]===false){
      const span=normalize(d.requirement_evidence?.[k]);
      if(!span||!source.includes(span))throw new Error('UNGROUNDED_REQUIREMENT');
      req[k]=d.requirements[k];
    }
  }
  if(d.requirements?.service_duration_hours!=null){
    const span=normalize(d.requirement_evidence?.service_duration_hours);
    const n=Number(d.requirements.service_duration_hours);
    if(!span||!source.includes(span)||!Number.isFinite(n)||n<=0||n>24)throw new Error('INVALID_SERVICE_DURATION');
    req.service_duration_hours=n;
  }
  let action=String(d.requested_action||d.quote_action||'NONE').toUpperCase();if(!ACTIONS.includes(action as any))throw new Error('UNKNOWN_ACTION');
  if(d.visual_request===true)action='VISUAL';
  const hasEvidence=Boolean(evidence&&source.includes(evidence));
  if(action!=='NONE'&&action!=='HANDOFF'&&!hasEvidence)throw new Error('ACTION_EVIDENCE_REQUIRED');
  const patch:Json={};for(const k of ['people_count','event_date','event_location'])if(d.modification?.[k]!=null){patch[k]=k==='people_count'?integer(d.modification[k]):d.modification[k];if(k==='event_date')businessDate(patch[k]);}
  patch.products=[];
  for(const op of d.modification?.products||[]) {
    let id=op.product_id;
    if(op.reference==='CURRENT_REFERENCE'){
      const ids=context.work_state?.current_reference?.product_ids||[];
      if(ids.length!==1)throw new Error('AMBIGUOUS_REFERENCE'); id=ids[0];
    }
    if(!catalog.has(id))throw new Error('NON_CANONICAL_PRODUCT');
    if(!['ADD','REMOVE','SET'].includes(op.op))throw new Error('INVALID_PRODUCT_OPERATION');
    patch.products.push({op:op.op,product_id:id,...(op.op==='REMOVE'?{}:{quantity:integer(op.quantity)})});
  }
  if(!patch.products.length)delete patch.products;
  if(Object.keys(patch).length)action='MODIFY'; // a mixed accept+change never accepts
  if(ack)action='NONE';
  const start=d.start_new_event===true;
  if(start&&!hasEvidence)throw new Error('NEW_EVENT_EVIDENCE_REQUIRED');
  const visualIds=d.visual_product_ids||[];if(!Array.isArray(visualIds)||visualIds.some((id:string)=>!catalog.has(id)))throw new Error('NON_CANONICAL_VISUAL');
  if(action==='NONE'&&visualIds.length&&hasEvidence&&/(imagen|imagenes|foto|fotos|ver|muestr|mostrar|envia|enviar|manda|mandar)/i.test(normalize(d.action_evidence)))action='VISUAL';
  const refIds=(d.current_reference?.product_ids||[]);if(!Array.isArray(refIds)||refIds.some((id:string)=>!catalog.has(id)))throw new Error('NON_CANONICAL_REFERENCE');
  const secondaryIds=d.secondary_product_ids||[];
  if(!Array.isArray(secondaryIds)||secondaryIds.some((id:string)=>!catalog.has(id)))throw new Error('NON_CANONICAL_SECONDARY_PRODUCT');
  return {requested_action:action,action_evidence:hasEvidence?String(d.action_evidence):null,
    work_intent:ack?'ACK':String(d.work_intent||'GENERAL'),start_new_event:start,
    event_patch:ep,requirements:req,requirement_evidence:d.requirement_evidence||{},
    recommended_products:products(d.recommended_products),selected_products:products(d.selected_products),
    replace_selected:d.replace_selected===true,replace_recommended:d.replace_recommended===true,
    current_reference:{type:d.current_reference?.type||'NONE',product_ids:refIds},
    visual_scope:d.visual_scope||'WORK_STATE_REFERENCE',visual_product_ids:visualIds,
    modification:patch,confidence:Number(d.confidence??0),ack,
    question_field:d.question_field||null,product_ids:refIds.length?refIds:products(d.recommended_products).map((p:Json)=>p.product_id),secondary_intent:String(d.secondary_intent||'NONE'),secondary_product_ids:secondaryIds,policy_codes:Array.isArray(d.policy_codes)?d.policy_codes:[],
    response_mode:['TEXT','AUDIO','TEXT_PLUS_AUDIO'].includes(d.response_mode)?d.response_mode:'TEXT',
    human_handoff_required:d.human_handoff_required===true};
}

// No raw AI prose crosses this boundary. All facts are rendered from this turn's DB snapshot.
export function response(result:Json):string {
  const c=result.context||{},w=result.work_state||{},q=result.quote,p=result.payment;
  const intent=String(result.decision?.work_intent||'GENERAL');
  const current=normalize(c.current_message||'');
  const cat=c.catalog_products||[];
  const firstName=String(c.conversation?.customer_name||'').trim().split(/\s+/)[0]||'';
  const friendlyName=firstName&&firstName.length<22?firstName:'';

  if(result.code==='HUMAN_CONTROL')return '';
  if(result.code==='ACK')return 'Con gusto 😊. Aquí estoy pendiente.';
  if(result.code==='GREETING'){
    if(/como estas|como vas|todo bien|y tu|y tú/.test(current))return 'Muy bien 😊, gracias por preguntar. Cuéntame, ¿qué tienes en mente?';
    return friendlyName?`¡Hola, ${friendlyName}! 😊 Qué gusto leerte. Cuéntame, ¿en qué te ayudo?`:'¡Hola! 😊 Qué gusto leerte. Cuéntame, ¿en qué te ayudo?';
  }
  if(/no tan directa|muy directa|mas suave|más suave|con calma|tranqui|tranquila|despacio|jaja|jajaja/.test(current))return 'Jajaja, tienes razón 😅. Me fui de una. Cuéntame con calma qué estás organizando y te voy ayudando paso a paso.';
  if(q&&!w.requirements?.service_type&&/^(seguro|claro|si|sí|dale|cuentame|cuéntame|seguro cuentame|seguro cuéntame)[.! ]*$/.test(current))return 'Claro 😊. Lo que necesito definir es el tipo de servicio: ¿quieres cajas individuales, una mesa de finger food o un servicio completo para el evento?';
  if(result.code==='QUOTE_REJECTED')return 'Entendido. Dejamos esa cotización hasta ahí. Si quieres, armamos otra propuesta con una idea diferente.';
  if(result.code==='HANDOFF')return 'Claro. Voy a dejar esto con una persona del equipo para que te ayude directamente.';
  if(result.code==='POLICY_BLOCK'){
    if(result.policy?.code==='SERVICE_CLASSIFICATION_REQUIRED')return 'Antes de actualizar la cotización necesito ubicar bien el tipo de servicio. ¿Lo quieres en cajas individuales, como mesa de finger food o como servicio completo para el evento?';
    const v=result.policy?.violations?.[0];
    if(v?.required_total!=null)return `Para este tipo de servicio manejamos un mínimo de ${amount(v.required_total,q?.currency)}. Con lo que llevamos vamos en ${amount(v.actual_total,q?.currency)}. Si quieres, te ayudo a completarlo sin meter cosas porque sí.`;
    return 'Hay una condición comercial que debo validar antes de cerrar esto. Te digo exactamente cuál apenas la identifique en el estado del servicio.';
  }
  if(result.delivery_type==='PAYMENT'){
    if(!p?.ready||!q||p.quote_builder_id!==q.id||Number(p.payment?.quote_total)!==Number(q.total)||Number(p.payment?.amount)!==Number(q.deposit_amount))throw new Error('PAYMENT_TRUTH_MISMATCH');
    return `Perfecto. Para la cotización ${q.document_display_id} el total es ${amount(q.total,q.currency)}; el anticipo es ${amount(q.deposit_amount,q.currency)} y queda un saldo de ${amount(q.balance_amount,q.currency)}. Te comparto los datos de pago de esta cotización.`;
  }
  if(result.delivery_type==='PDF'&&q)return `Listo 😊. Te comparto la cotización ${q.document_display_id}, revisión ${q.quote_version}, por ${amount(q.total,q.currency)} para el ${businessDate(q.event_date)}. Revísala con calma y me dices: ¿agregamos algo más o la dejamos así?`;
  if(result.code==='PAYMENT_BLOCKED')return 'Todavía no puedo enviarte los medios de pago porque primero necesito tu aceptación explícita de la cotización vigente.';
  if(result.code==='ACCEPTANCE_BLOCKED')return 'Primero necesito que recibas y revises el PDF vigente. Después de eso sí puedo registrar tu aceptación.';
  if(result.code==='QUOTE_QUESTION'&&q)return `Claro. La cotización ${q.document_display_id}, revisión ${q.quote_version}, está en ${amount(q.total,q.currency)}; el anticipo es ${amount(q.deposit_amount,q.currency)} y el saldo ${amount(q.balance_amount,q.currency)}.`;
  if(result.code==='VISUAL_READY')return 'Sí 😊. Te muestro las imágenes que corresponden a lo que estamos viendo.';
  if(result.code==='POLICIES_READY')return 'Claro. Te comparto las políticas vigentes para que las tengas a mano.';
  if(result.code==='INTERPRETATION_BLOCKED')return 'No quiero asumir algo que no me dijiste. ¿Me explicas un poquito qué quieres hacer y lo organizamos?';
  if(result.code==='ACTION_BLOCKED'){
    const reason=String(result.execution?.blocked_reason||'');
    if(reason.includes('MODIFICATION_NOT_READY'))return 'Veo que esto puede tocar la cotización que ya tenemos. ¿Quieres modificar esa cotización o estamos hablando de un evento nuevo?';
    if(reason.includes('AMBIGUOUS_REFERENCE'))return 'Quiero asegurarme de tocar el producto correcto. ¿A cuál de los que acabamos de ver te refieres?';
    if(reason.includes('NO_CURRENT_QUOTE'))return 'Todavía no tengo una cotización vigente sobre la cual hacer ese cambio. Cuéntame qué quieres preparar y la armamos.';
    return 'No quiero hacer un cambio equivocado. Dime exactamente qué quieres ajustar y lo resolvemos contigo.';
  }
  const recommended=w.recommended_items||[];
  if(intent==='RECOMMEND'&&recommended.length){
    const picks=recommended.slice(0,3).map((x:Json)=>{const pr=cat.find((z:Json)=>z.product_id===x.product_id);return pr?pr.name:null;}).filter(Boolean);
    if(picks.length)return 'Para lo que me cuentas, yo miraría estas opciones: '+picks.join(', ')+'. Si quieres, te explico cuál encaja mejor y por qué.';
  }
  if(['ASK_INFORMATION','ASK_PRICE','COMPARE_OPTIONS'].includes(intent)){
    const ids=result.decision?.product_ids||[];
    if(!ids.length){
      if(/que necesitas aclarar|qué necesitas aclarar|que falta|qué falta/.test(current))return q?'Lo que quiero confirmar es si seguimos trabajando sobre la cotización que ya tienes o si esto es para un evento nuevo. Así no mezclo información de dos solicitudes.':'Dime qué parte quieres que aclaremos y te respondo sobre eso.';
      if(intent==='ASK_PRICE')return 'Claro. Dime cuál producto quieres revisar y te doy el precio exacto.';
      if(intent==='COMPARE_OPTIONS')return 'Claro. Dime cuáles opciones quieres comparar y te marco las diferencias más útiles.';
      return 'Claro. Dime de qué producto o parte del servicio quieres saber más y te lo explico.';
    }
    const choices=cat.filter((pr:Json)=>ids.includes(pr.product_id)).slice(0,3);
    if(choices.length){
      const lines=choices.map((pr:Json)=>`${pr.name}: ${amount(pr.price,c.company_policy?.payment_policy?.currency||'COP')} por ${pr.unit||'unidad'}${pr.summary?'. '+pr.summary:''}`);
      return lines.join('\n')+'\nSi quieres, te muestro fotos o te ayudo a escoger entre estas opciones.';
    }
  }
  if(intent==='EXPLORE'){
    const ids=result.decision?.product_ids||[];
    if(ids.length){const choices=cat.filter((pr:Json)=>ids.includes(pr.product_id)).slice(0,3);if(choices.length)return 'Mira, por ahí podemos empezar con '+choices.map((pr:Json)=>pr.name).join(', ')+'. ¿Quieres que te muestre fotos o prefieres que te recomiende según el tipo de evento?';}
    return 'Cuéntame primero qué estás organizando y qué estilo te gustaría. Con eso te muestro opciones que sí tengan sentido para ti.';
  }
  if(intent==='REQUEST_AVAILABILITY')return 'Eso sí prefiero confirmártelo antes de decirte que sí. Déjame verificar la disponibilidad con el equipo.';
  if(intent==='MEMORY_RECALL')return `Sí${friendlyName?', '+friendlyName:''}, tengo el contexto de lo que venimos hablando. ${w.event?.event_date?'El evento que tenemos activo está planteado para el '+businessDate(w.event.event_date)+'.':'Cuéntame qué parte quieres retomar.'}`;
  if(q&&result.requested_action==='NONE'&&['GENERAL','CONTINUE_EVENT'].includes(intent))return 'Te sigo 😊. Cuéntame qué quieres hacer ahora con esta propuesta y lo vamos viendo contigo.';
  const fields:Json={event_type:'¿Qué estás celebrando?',event_date:'¿Para qué fecha lo estás pensando?',people_count:'¿Más o menos para cuántas personas sería?',event_location:'¿Ya sabes dónde sería?',selected_items:'¿Quieres que te recomiende opciones o ya tienes algunos pasabocas en mente?',client_name:'¿A nombre de quién preparo la cotización?'};
  if(result.decision?.policy_codes?.length){const rules=(c.company_policy?.commercial_rules||[]).filter((r:Json)=>result.decision.policy_codes.includes(r.rule_code));if(rules.length)return rules.map((r:Json)=>r.metadata?.description).filter(Boolean).join('\n');}
  const missing=result.missing_fields||w.missing_fields||[];
  let field=missing[0]||result.decision?.question_field;
  const st=w.requirements?.service_type||result.decision?.requirements?.service_type;
  if(!field&&['FINGER_TABLE','FULL_EVENT'].includes(String(st||''))){
    if(w.requirements?.service_duration_hours==null)field='service_duration_hours';
    else if(w.requirements?.decoration_needed==null)field='decoration_needed';
    else if(w.requirements?.waiters_needed==null)field='waiters_needed';
  }
  if(field==='service_type'){
    if(!['QUOTE_CREATE','SELECT_PRODUCTS','RECOMMEND','CONTINUE_EVENT'].includes(intent)&&!['CREATE','MODIFY'].includes(String(result.requested_action||'')))return 'Cuéntame qué tienes pensado y yo te voy guiando.';
    return 'Para orientarte bien, ¿estás buscando algo tipo cajas de pasabocas, una mesa de finger food o un servicio más completo para el evento?';
  }
  return fields[field]||'Claro 😊. Cuéntame un poquito más y lo vamos organizando contigo.';
}