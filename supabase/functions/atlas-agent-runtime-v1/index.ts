import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {createClient} from "jsr:@supabase/supabase-js@2";
import {loadAgentContext,loadCompanyProfile,loadCanonicalSourceMessage} from "./context-manager.ts";
import {buildAgentRequest,runAgentLoop} from "./runner.ts";

type Body={
 empresa_id:string;
 conversation_id:string;
 source_message_id:string;
 customer_message?:string;
 dry_run?:boolean;
};

const json=(s:number,b:unknown)=>new Response(JSON.stringify(b),{
 status:s,
 headers:{"content-type":"application/json"}
});

Deno.serve(async(req)=>{
 if(req.method!=="POST")return json(405,{ok:false,error:"METHOD_NOT_ALLOWED"});

 try{
  const body=await req.json() as Body;
  for(const k of ["empresa_id","conversation_id","source_message_id"] as const){
   if(!body[k])return json(400,{ok:false,error:`MISSING_${k.toUpperCase()}`});
  }

  const url=Deno.env.get("SUPABASE_URL");
  const key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!key)return json(500,{ok:false,error:"RUNTIME_CONFIG_MISSING"});

  const client=createClient(url,key,{auth:{persistSession:false}});
  const sourceMessage=await loadCanonicalSourceMessage(client,body);
  const context=await loadAgentContext(client,body);
  const canonicalProfile=await loadCompanyProfile(client,body.empresa_id);

  const canonicalCustomerMessage=sourceMessage.text
    || (sourceMessage.message_type==="IMAGE"?"[Customer sent an image]":
        sourceMessage.message_type==="DOCUMENT"?"[Customer sent a document]":
        sourceMessage.message_type==="AUDIO"?"[Customer sent an audio message with no usable transcription]":
        "[Customer sent a message with no usable text]");

  const request=buildAgentRequest({
   company_profile:canonicalProfile,
   context,
   customer_message:canonicalCustomerMessage
  });

  if(body.dry_run!==false){
   return json(200,{ok:true,mode:"DRY_RUN",request});
  }

  const apiKey=Deno.env.get("OPENAI_API_KEY");
  if(!apiKey)return json(503,{ok:false,error:"MODEL_CONFIG_MISSING"});

  const model=Deno.env.get("ATLAS_AGENT_MODEL")??"gpt-5.6-sol";
  const result=await runAgentLoop({
   client,
   empresa_id:body.empresa_id,
   conversation_id:body.conversation_id,
   source_message_id:body.source_message_id,
   request,
   model,
   apiKey,
   maxSteps:8
  });

  return json(200,{
   ...result,
   mode:"AGENT_POC",
   delivery_enabled:false,
   source_grounding:{
    source_message_id:sourceMessage.id,
    message_type:sourceMessage.message_type,
    caller_text_ignored:true
   }
  });
 }catch(e){
  return json(500,{
   ok:false,
   error:"AGENT_RUNTIME_FAILED",
   detail:e instanceof Error?e.message:String(e)
  });
 }
});
