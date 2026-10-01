import type { Json } from './contract.ts';
export async function verifyMeta(raw:string,signature:string,secret:string){
  if(!secret||!/^sha256=[a-f0-9]{64}$/.test(signature))throw new Error('META_SIGNATURE_REQUIRED');
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
  const bytes=new Uint8Array(signature.slice(7).match(/../g)!.map(x=>parseInt(x,16)));
  if(!await crypto.subtle.verify('HMAC',key,bytes,new TextEncoder().encode(raw)))throw new Error('META_SIGNATURE_INVALID');
}
export async function parseMeta(body:Json,resolve:(phone:string)=>Promise<string>):Promise<Json[]>{
  const items:Json[]=[];
  for(const entry of body.entry||[])for(const change of entry.changes||[]){
    const value=change.value||{},phone=value.metadata?.phone_number_id;if(!(value.messages||[]).length)continue;
    if(!phone)throw new Error('META_PHONE_REQUIRED');const tenant=await resolve(phone);
    for(const m of value.messages){
      if(!m.id||!m.from)throw new Error('META_MESSAGE_ID_REQUIRED');
      const contact=(value.contacts||[]).find((c:Json)=>c.wa_id===m.from)||{};const media=m.audio||m.voice;
      items.push({empresa_id:tenant,external_message_id:m.id,customer_phone:m.from,customer_name:contact.profile?.name||null,
        message_type:media?'AUDIO':String(m.type||'UNKNOWN').toUpperCase(),text_content:m.text?.body||null,
        media_id:media?.id||null,media_mime_type:media?.mime_type||null,whatsapp_phone_number_id:phone,
        whatsapp_display_phone_number:value.metadata?.display_phone_number||null,raw_payload:body});
    }
  }return items;
}

export async function parseReceipts(body:Json,resolve:(phone:string)=>Promise<string>,record:(receipt:Json)=>Promise<void>):Promise<void>{
  for(const entry of body.entry||[])for(const change of entry.changes||[]){
    const v=change.value||{};if(!(v.statuses||[]).length)continue;
    if(!v.metadata?.phone_number_id)throw new Error('META_PHONE_REQUIRED');const tenant=await resolve(v.metadata.phone_number_id);
    for(const s of v.statuses){if(!s.id||!['sent','delivered','read','failed'].includes(s.status)||!/^\d+$/.test(String(s.timestamp)))throw new Error('INVALID_PROVIDER_RECEIPT');
      await record({p_empresa_id:tenant,p_provider_message_id:s.id,p_status:s.status,p_occurred_at:new Date(Number(s.timestamp)*1000).toISOString()});}
  }
}