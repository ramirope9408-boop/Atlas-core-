import { createClient } from '@supabase/supabase-js';
import { renderPayment, renderQuote } from './renderer.ts';
import { messages, type Backend } from './service.ts';
import { type Json } from './contract.ts';
export const digest=async(b:Uint8Array)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',b as BufferSource))).map(x=>x.toString(16).padStart(2,'0')).join('');
export function backend(url:string,key:string,openAIKey:string):Backend & {client:any} {
  const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  const rpc=async(name:string,args:Json)=>{const {data,error}=await client.rpc(name,args);if(error)throw new Error(`${name}:${error.message}`);return data;};
  const asset=async(a:Json,tenant:string)=>{
    if(!a?.path?.startsWith(tenant+'/')||a.bucket!=='atlas-documents'||!a.sha256)throw new Error('TEMPLATE_ASSET_SCOPE');
    const {data,error}=await client.storage.from(a.bucket).download(a.path);if(error||!data)throw new Error('TEMPLATE_ASSET_UNAVAILABLE');
    const bytes=new Uint8Array(await data.arrayBuffer());if(await digest(bytes)!==a.sha256)throw new Error('TEMPLATE_ASSET_CHECKSUM');return bytes;
  };
  const document=async(type:string,result:Json)=>{
    const tenant=result.empresa_id,q=result.quote;
    const {data:t,error}=await client.from('atlas_company_document_templates').select('*').eq('empresa_id',tenant).eq('document_type',type).eq('active',true).order('version',{ascending:false}).limit(1).maybeSingle();
    if(error||!t||t.metadata?.renderer_contract!=='ATLAS_CANONICAL_ASSET_1')throw new Error('CANONICAL_TEMPLATE_NOT_CONFIGURED');
    const bytes=await asset(t.metadata.asset,tenant);
    if(type==='EVENT_POLICIES')return {storage:{bucket:t.metadata.asset.bucket,path:t.metadata.asset.path},checksum_sha256:t.metadata.asset.sha256};
    if(!q?.id)throw new Error('QUOTE_REQUIRED');
    const canonical=await rpc('atlas_commercial_quote',{p_empresa_id:tenant,p_conversation_id:result.conversation_id,p_quote_id:q.id});
    if(JSON.stringify([canonical.total,canonical.deposit_amount,canonical.balance_amount,canonical.quote_version])!==JSON.stringify([q.total,q.deposit_amount,q.balance_amount,q.quote_version]))throw new Error('QUOTE_CHANGED_BEFORE_RENDER');
    const payload=await rpc('atlas_commercial_document_payload',{p_empresa_id:tenant,p_conversation_id:result.conversation_id,p_quote_id:q.id});
    const rendererVersion='ATLAS_ASSET_1_'+(await digest(new TextEncoder().encode(JSON.stringify(t.metadata)))).slice(0,16);
    const docVersion='QUOTE_V'+q.quote_version;
    const {data:existing,error:lookupError}=await client.from('atlas_generated_documents').select('*').eq('empresa_id',tenant).eq('quote_builder_id',q.id).eq('document_type',type).eq('document_version',docVersion).eq('renderer_version',rendererVersion).maybeSingle();
    if(lookupError)throw new Error('DOCUMENT_LOOKUP_FAILED');
    if(existing?.storage_path&&existing.checksum_sha256&&['STORED','READY_FOR_DELIVERY'].includes(existing.status)){
      const stored=await client.storage.from(existing.storage_bucket).download(existing.storage_path);
      if(stored.error||!stored.data||await digest(new Uint8Array(await stored.data.arrayBuffer()))!==existing.checksum_sha256)throw new Error('STORED_DOCUMENT_CHECKSUM');
      return {document_id:existing.id,file_name:existing.file_name,storage:{bucket:existing.storage_bucket,path:existing.storage_path},checksum_sha256:existing.checksum_sha256};
    }
    const renderInput={...payload,quote:q,payment:result.payment,policy:result.context.company_policy,company:t.metadata.company_display,timezone:'America/Bogota'};
    if(type==='PAYMENT_CLIENT'){
      const payment=await rpc('atlas_build_dynamic_payment_payload_v1',{p_empresa_id:tenant,p_conversation_id:result.conversation_id});
      if(!payment.ready||payment.quote_builder_id!==q.id)throw new Error('PAYMENT_NOT_AUTHORIZED');
      renderInput.payment=payment;
      const normalized=(ms:any[])=>JSON.stringify(ms.map(x=>({name:x.name||x.nombre,type:x.type||x.tipo,detail:x.detail||x.detalle})).sort((a,b)=>a.name.localeCompare(b.name)));
      if(normalized(payment.payment_methods)!==normalized(t.metadata.approved_payment_methods||[]))throw new Error('PAYMENT_TEMPLATE_METHODS_STALE');
    }
    const out=type==='QUOTE_CLIENT'?await renderQuote(bytes,t.metadata.layout,renderInput,await asset(t.metadata.font,tenant)):await renderPayment(bytes,t.metadata.layout,renderInput,await asset(t.metadata.font,tenant));
    const sha=await digest(out),file_name=`${q.document_display_id}-V${q.quote_version}-${type==='QUOTE_CLIENT'?'cotizacion.pdf':'pago.png'}`;
    const path=`${tenant}/quotes/${q.id}/${rendererVersion}/${file_name}`;
    const upload=await client.storage.from('atlas-documents').upload(path,out,{contentType:type==='QUOTE_CLIENT'?'application/pdf':'image/png',upsert:false});
    if(upload.error){
      // A concurrent retry may have uploaded identical immutable bytes.
      const stored=await client.storage.from('atlas-documents').download(path);
      if(stored.error||!stored.data||await digest(new Uint8Array(await stored.data.arrayBuffer()))!==sha)throw new Error('DOCUMENT_STORAGE_FAILED');
    }
    const registered=await rpc('atlas_register_generated_document',{p_empresa_id:tenant,p_quote_builder_id:q.id,p_document_display_id:q.document_display_id,p_document_type:type,p_document_version:docVersion,p_renderer_version:rendererVersion,p_file_name:file_name,p_local_path:null,p_checksum_sha256:sha});
    const id=registered.document_id;if(!id)throw new Error('DOCUMENT_REGISTER_FAILED');
    const mime=await client.from('atlas_generated_documents').update({mime_type:type==='QUOTE_CLIENT'?'application/pdf':'image/png'}).eq('id',id).eq('empresa_id',tenant);
    if(mime.error)throw new Error('DOCUMENT_MIME_UPDATE_FAILED');
    await rpc('atlas_mark_document_stored',{p_document_id:id,p_empresa_id:tenant,p_storage_provider:'SUPABASE_STORAGE',p_storage_bucket:'atlas-documents',p_storage_path:path,p_storage_url:null});
    await rpc('atlas_mark_document_ready_for_delivery',{p_document_id:id,p_empresa_id:tenant});
    return{document_id:id,file_name,storage:{bucket:'atlas-documents',path},checksum_sha256:sha};
  };
  return {client,rpc,document,
    async model(context:Json){
      if(!openAIKey)throw new Error('MODEL_CREDENTIAL_MISSING');
      const r=await fetch('https://api.openai.com/v1/chat/completions',{method:'POST',headers:{Authorization:`Bearer ${openAIKey}`,'Content-Type':'application/json'},body:JSON.stringify({model:'gpt-4.1-mini',temperature:0,response_format:{type:'json_object'},messages:messages(context)}),signal:AbortSignal.timeout(45000)});
      if(!r.ok)throw new Error('MODEL_REQUEST_FAILED');const d=await r.json();try{return JSON.parse(d.choices?.[0]?.message?.content);}catch{return null;}
    },
    async audio(text:string,result:Json){
      const r=await fetch('https://api.openai.com/v1/audio/speech',{method:'POST',headers:{Authorization:`Bearer ${openAIKey}`,'Content-Type':'application/json'},body:JSON.stringify({model:'gpt-4o-mini-tts',voice:'coral',input:text,response_format:'mp3'}),signal:AbortSignal.timeout(45000)});
      if(!r.ok)throw new Error('TTS_FAILED');const bytes=new Uint8Array(await r.arrayBuffer());
      const path=`${result.empresa_id}/audio/${result.turn_id}.mp3`;const upload=await client.storage.from('atlas-documents').upload(path,bytes,{contentType:'audio/mpeg',upsert:false});
      if(upload.error&&!String(upload.error.message).includes('already exists'))throw new Error('AUDIO_STORAGE_FAILED');
      return{storage:{bucket:'atlas-documents',path}};
    }
  };
}