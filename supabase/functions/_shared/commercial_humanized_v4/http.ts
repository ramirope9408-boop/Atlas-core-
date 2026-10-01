import { backend } from './backend.ts';
import { processTurn } from './service.ts';
import { type Json } from './contract.ts';
export function handlers(env:(key:string)=>string|undefined){
  const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
  const b=backend(env('SUPABASE_URL')||'',env('SUPABASE_SERVICE_ROLE_KEY')||'',env('OPENAI_API_KEY')||'');
  return async(req:Request,mode:'turn'|'claim')=>{
    const service=env('SUPABASE_SERVICE_ROLE_KEY');
    if(req.method!=='POST')return json({ok:false,code:'METHOD_NOT_ALLOWED'},405);
    if(!service||req.headers.get('Authorization')!==`Bearer ${service}`)return json({ok:false,code:'TRUSTED_BACKEND_ONLY'},403);
    let body:Json;try{body=await req.json();}catch{return json({ok:false,code:'INVALID_JSON'},400);}
    if(!body.empresa_id)return json({ok:false,code:'TENANT_REQUIRED'},400);
    try{
      if(mode==='turn'){
        if(!body.conversation_id||!body.source_message_id)return json({ok:false,code:'SCOPE_REQUIRED'},400);
        return json(await processTurn(b,body));
      }
      const claim=await b.rpc('atlas_commercial_claim_delivery',{p_empresa_id:body.empresa_id,p_outbox_id:body.outbox_id});
      if(!claim.send)return json(claim);
      try{
        const p=claim.payload;let link=p.url;
        if(p.storage){
          if(!p.storage.path?.startsWith(body.empresa_id+'/'))throw new Error('DELIVERY_STORAGE_SCOPE');
          const signed=await b.client.storage.from(p.storage.bucket).createSignedUrl(p.storage.path,300);
          if(signed.error||!signed.data?.signedUrl)throw new Error('SIGNED_DOCUMENT_FAILED');link=signed.data.signedUrl;
        }
        if(link){const u=new URL(link),allowed=new URL(env('SUPABASE_URL')||'').origin;if(u.origin!==allowed)throw new Error('NON_CANONICAL_MEDIA_ORIGIN');}
        const type=({TEXT:'text',PDF:'document',IMAGE:'image',AUDIO:'audio'} as Json)[claim.kind];
        const payload:Json={messaging_product:'whatsapp',to:claim.customer_phone,type};
        payload[type]=claim.kind==='TEXT'?{body:p.text}:claim.kind==='AUDIO'?{link}:{link,caption:p.caption,...(claim.kind==='PDF'?{filename:p.file_name}:{})};
        return json({...claim,whatsapp_payload:payload});
      }catch(e){
        await b.rpc('atlas_commercial_confirm_delivery',{p_empresa_id:body.empresa_id,p_outbox_id:claim.outbox_id,p_claim_token:claim.claim_token,p_provider_message_id:null,p_failed:true});throw e;
      }
    }catch(e){return json({ok:false,code:'COMMERCIAL_OPERATION_FAILED',detail:String((e as Error).message).slice(0,220)},422);}
  };
}