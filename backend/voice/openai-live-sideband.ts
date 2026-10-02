import WebSocket from "ws";
import { createClient } from "@supabase/supabase-js";

type SidebandOptions={
  sessionId:string;
  callSessionId:string;
  empresaId:string;
  conversationId:string;
};

type TranscriptFragment={
  delta:string;
  start_ms:number;
  end_ms:number;
};

const env=(name:string)=>{
  const value=process.env[name];
  if(!value) throw new Error(`MISSING_${name}`);
  return value;
};

const OPENAI_API_KEY=env("OPENAI_API_KEY");
const SUPABASE_URL=env("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY=env("SUPABASE_SERVICE_ROLE_KEY");
const AGENT_RUNTIME_URL=process.env.ATLAS_AGENT_RUNTIME_URL
  ?? `${SUPABASE_URL}/functions/v1/atlas-agent-runtime-v1`;

const supabase=createClient(SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,{
  auth:{persistSession:false}
});

function normalizeText(fragments:TranscriptFragment[],afterMs:number,throughMs:number){
  return fragments
    .filter(f=>f.end_ms>afterMs && f.end_ms<=throughMs)
    .sort((a,b)=>a.start_ms-b.start_ms)
    .map(f=>f.delta)
    .join("")
    .trim();
}

async function registerCanonicalTurn(opts:SidebandOptions,delegationId:string,offsetMs:number,text:string){
  const {data,error}=await supabase.rpc("atlas_register_voice_turn_v1",{
    p_empresa_id:opts.empresaId,
    p_conversation_id:opts.conversationId,
    p_call_session_id:opts.callSessionId,
    p_external_turn_id:delegationId,
    p_transcript:text,
    p_language:"es-CO",
    p_metadata:{
      live_session_id:opts.sessionId,
      delegation_id:delegationId,
      offset_ms:offsetMs,
      transcript_authority:"GPT_LIVE_FINALIZED_BY_DELEGATION_BOUNDARY"
    }
  });
  if(error) throw new Error(`VOICE_TURN_REGISTER_FAILED:${error.message}`);
  if(data?.ok!==true) throw new Error(`VOICE_TURN_NOT_CANONICALIZED:${data?.code??"UNKNOWN"}`);
  return data;
}

async function runAtlasAgent(opts:SidebandOptions,sourceMessageId:string){
  const res=await fetch(AGENT_RUNTIME_URL,{
    method:"POST",
    headers:{
      "Authorization":`Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type":"application/json"
    },
    body:JSON.stringify({
      empresa_id:opts.empresaId,
      conversation_id:opts.conversationId,
      source_message_id:sourceMessageId,
      dry_run:false
    })
  });
  const body=await res.json();
  if(!res.ok||body?.ok!==true){
    throw new Error(`ATLAS_AGENT_FAILED:${body?.detail??body?.error??res.status}`);
  }
  return body;
}

export async function attachAtlasVoiceSideband(opts:SidebandOptions){
  const socket=new WebSocket(
    `wss://api.openai.com/v1/live/sessions/${encodeURIComponent(opts.sessionId)}/attach`,
    {headers:{Authorization:`Bearer ${OPENAI_API_KEY}`}}
  );

  const inputFragments:TranscriptFragment[]=[];
  let committedThroughMs=0;
  let revision=0;
  const inFlight=new Map<string,number>();

  socket.on("open",()=>{
    console.log(JSON.stringify({event:"ATLAS_VOICE_SIDEBAND_ATTACHED",session_id:opts.sessionId}));
  });

  socket.on("message",async raw=>{
    let event:any;
    try{event=JSON.parse(raw.toString());}
    catch{return;}

    if(event.type==="session.input_transcript.delta"){
      const delta=String(event.delta??"");
      const start_ms=Number(event.start_ms??0);
      const end_ms=Number(event.end_ms??start_ms);
      if(delta){
        inputFragments.push({delta,start_ms,end_ms});
        revision++;
      }
      return;
    }

    if(event.type==="session.delegation.created" && event?.delegation?.target==="client"){
      const delegationId=String(event.delegation.id??"");
      const offsetMs=Number(event.offset_ms??0);
      if(!delegationId||!Number.isFinite(offsetMs)) return;

      const text=normalizeText(inputFragments,committedThroughMs,offsetMs);
      if(!text){
        socket.send(JSON.stringify({
          type:"session.commentary.append",
          event_id:`atlas_empty_${delegationId}`,
          delegation_id:delegationId,
          content:"No alcancé a entender esa parte con suficiente claridad. ¿Me la repites, por favor?"
        }));
        return;
      }

      committedThroughMs=Math.max(committedThroughMs,offsetMs);
      const taskRevision=revision;
      inFlight.set(delegationId,taskRevision);

      try{
        const canonical=await registerCanonicalTurn(opts,delegationId,offsetMs,text);
        const result=await runAtlasAgent(opts,String(canonical.message_id));

        if(inFlight.get(delegationId)!==taskRevision) return;
        if(revision!==taskRevision){
          socket.send(JSON.stringify({
            type:"session.thinking.append",
            event_id:`atlas_superseded_${delegationId}`,
            delegation_id:delegationId,
            content:"The caller continued or corrected the request while backend work was running. Do not announce a stale result. Wait for the next delegation."
          }));
          return;
        }

        const finalText=String(result.text??"").trim();
        if(!finalText) throw new Error("ATLAS_EMPTY_FINAL_TEXT");

        socket.send(JSON.stringify({
          type:"session.commentary.append",
          event_id:`atlas_result_${delegationId}`,
          delegation_id:delegationId,
          content:finalText
        }));
      }catch(error){
        console.error(JSON.stringify({
          event:"ATLAS_VOICE_DELEGATION_FAILED",
          delegation_id:delegationId,
          error:error instanceof Error?error.message:String(error)
        }));

        socket.send(JSON.stringify({
          type:"session.commentary.append",
          event_id:`atlas_error_${delegationId}`,
          delegation_id:delegationId,
          content:"No pude completar esa gestión con seguridad. Voy a dejarla sin ejecutar para no darte información incorrecta."
        }));
      }finally{
        inFlight.delete(delegationId);
      }
      return;
    }

    if(event.type==="session.closed"){
      await supabase.rpc("atlas_close_voice_call_session_v1",{
        p_empresa_id:opts.empresaId,
        p_call_session_id:opts.callSessionId,
        p_final_status:"ENDED",
        p_metadata:{live_session_id:opts.sessionId}
      });
      socket.close();
      return;
    }

    if(event.type==="error"){
      console.error(JSON.stringify({event:"OPENAI_LIVE_ERROR",detail:event}));
    }
  });

  socket.on("error",async error=>{
    console.error(JSON.stringify({event:"ATLAS_VOICE_SIDEBAND_ERROR",error:error.message}));
    await supabase.rpc("atlas_close_voice_call_session_v1",{
      p_empresa_id:opts.empresaId,
      p_call_session_id:opts.callSessionId,
      p_final_status:"FAILED",
      p_metadata:{live_session_id:opts.sessionId,error:error.message}
    });
  });

  return socket;
}

if(import.meta.url===`file://${process.argv[1]}`){
  const [sessionId,callSessionId,empresaId,conversationId]=process.argv.slice(2);
  if(!sessionId||!callSessionId||!empresaId||!conversationId){
    throw new Error("USAGE: npm start -- <sessionId> <callSessionId> <empresaId> <conversationId>");
  }
  await attachAtlasVoiceSideband({sessionId,callSessionId,empresaId,conversationId});
}
