import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.57.4";
import OpenAI from "npm:openai@7.17.0";

const json=(status:number,body:unknown)=>new Response(JSON.stringify(body),{
  status,headers:{"content-type":"application/json"}
});

function sipHeader(headers:any[],name:string){
  const row=(Array.isArray(headers)?headers:[]).find((x:any)=>String(x?.name??"").toLowerCase()===name.toLowerCase());
  return String(row?.value??"");
}

function e164FromSip(value:string){
  const m=String(value??"").match(/sip:(\+\d+)/i);
  return m?.[1]??null;
}

Deno.serve(async(req)=>{
  if(req.method!=="POST") return json(405,{ok:false,error:"METHOD_NOT_ALLOWED"});

  const apiKey=Deno.env.get("OPENAI_API_KEY");
  const webhookSecret=Deno.env.get("OPENAI_WEBHOOK_SECRET");
  const supabaseUrl=Deno.env.get("SUPABASE_URL");
  const serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if(!apiKey||!webhookSecret||!supabaseUrl||!serviceKey){
    return json(500,{ok:false,error:"VOICE_WEBHOOK_CONFIG_MISSING"});
  }

  const raw=await req.text();
  let event:any;
  try{
    const openai=new OpenAI({apiKey,webhookSecret});
    event=await openai.webhooks.unwrap(raw,Object.fromEntries(req.headers),webhookSecret);
  }catch{
    return json(400,{ok:false,error:"INVALID_OPENAI_WEBHOOK_SIGNATURE"});
  }

  if(!["live.transport.incoming","live.call.incoming","realtime.call.incoming"].includes(String(event?.type??""))){
    return json(200,{ok:true,ignored:true,type:event?.type??null});
  }

  const data=event?.data??{};
  const sessionId=String(data.session_id??"").trim();
  const legacyCallId=String(data.call_id??"").trim();
  const sipHeaders=Array.isArray(data.sip_headers)?data.sip_headers:[];
  const caller=e164FromSip(sipHeader(sipHeaders,"From"));
  const destination=e164FromSip(sipHeader(sipHeaders,"To"));

  if(!caller||!destination){
    return json(400,{ok:false,error:"VOICE_SIP_HEADERS_REQUIRED"});
  }

  const client=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false}});

  const {data:resolved,error:resolveError}=await client.rpc("atlas_resolve_voice_conversation_v1",{
    p_destination_e164:destination,
    p_caller_phone:caller,
    p_external_call_id:sessionId||legacyCallId,
    p_provider:"OPENAI_GPT_LIVE"
  });

  if(resolveError||resolved?.ok!==true){
    if(sessionId){
      await fetch(`https://api.openai.com/v1/live/sessions/${encodeURIComponent(sessionId)}/reject`,{
        method:"POST",
        headers:{Authorization:`Bearer ${apiKey}`,"Content-Type":"application/json"},
        body:JSON.stringify({status_code:404})
      }).catch(()=>null);
    }
    return json(404,{ok:false,error:"VOICE_ROUTE_NOT_FOUND"});
  }

  const externalCallId=sessionId||legacyCallId;
  const {data:voiceSession,error:sessionError}=await client.from("atlas_voice_call_sessions")
    .upsert({
      empresa_id:resolved.empresa_id,
      conversation_id:resolved.conversation_id,
      external_call_id:externalCallId,
      provider:"OPENAI_GPT_LIVE",
      transport:"SIP",
      live_session_id:sessionId||null,
      caller_phone:caller,
      status:"RINGING",
      metadata:{
        route_id:resolved.route_id,
        destination,
        webhook_event_id:event?.id??null,
        webhook_event_type:event?.type??null
      }
    },{onConflict:"empresa_id,provider,external_call_id"})
    .select("id")
    .single();

  if(sessionError||!voiceSession){
    return json(500,{ok:false,error:"VOICE_SESSION_PERSIST_FAILED"});
  }

  const liveInstructions=[
    "You are Valentina, the live voice interface for ATLAS.",
    "Speak in Colombian Spanish with a subtle Cartagena/Caribbean cadence.",
    "Sound like an adult woman with a warm, calm, medium-low register.",
    "Never sound childlike, shrill, like an announcer, or like a caricature.",
    "Keep spoken responses short, natural and conversational.",
    "Do not invent products, prices, policies, payment, reservation or business facts.",
    "Business truth and actions are delegated to the ATLAS backend.",
    "Treat interruptions and self-corrections naturally; never interpret silence as consent."
  ].join(" ");

  let acceptResponse:Response;
  if(sessionId){
    acceptResponse=await fetch(`https://api.openai.com/v1/live/sessions/${encodeURIComponent(sessionId)}/accept`,{
      method:"POST",
      headers:{Authorization:`Bearer ${apiKey}`,"Content-Type":"application/json"},
      body:JSON.stringify({
        session:{
          type:"live",
          model:"gpt-live-1",
          instructions:liveInstructions,
          audio:{output:{voice:"marin"}},
          delegation:{type:"client"}
        }
      })
    });
  }else{
    acceptResponse=await fetch(`https://api.openai.com/v1/realtime/calls/${encodeURIComponent(legacyCallId)}/accept`,{
      method:"POST",
      headers:{Authorization:`Bearer ${apiKey}`,"Content-Type":"application/json"},
      body:JSON.stringify({
        type:"realtime",
        model:"gpt-realtime-2.1",
        instructions:liveInstructions
      })
    });
  }

  if(!acceptResponse.ok){
    const detail=await acceptResponse.text().catch(()=>"");
    await client.from("atlas_voice_call_sessions")
      .update({status:"FAILED",ended_at:new Date().toISOString(),metadata:{accept_error:detail}})
      .eq("id",voiceSession.id)
      .eq("empresa_id",resolved.empresa_id);
    return json(502,{ok:false,error:"OPENAI_CALL_ACCEPT_FAILED",status:acceptResponse.status});
  }

  await client.from("atlas_voice_call_sessions")
    .update({status:"ACTIVE",connected_at:new Date().toISOString(),updated_at:new Date().toISOString()})
    .eq("id",voiceSession.id)
    .eq("empresa_id",resolved.empresa_id);

  return json(200,{
    ok:true,
    code:"VOICE_CALL_ACCEPTED",
    voice_session_id:voiceSession.id,
    live_session_id:sessionId||null,
    conversation_id:resolved.conversation_id,
    empresa_id:resolved.empresa_id,
    sideband_required:true
  });
});
