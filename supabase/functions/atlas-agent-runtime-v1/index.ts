import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { loadAgentContext } from "./context-manager.ts";
import { buildAgentRequest } from "./runner.ts";

type Body = {
  empresa_id: string;
  conversation_id: string;
  source_message_id: string;
  customer_message: string;
  company_profile?: Record<string, unknown>;
  dry_run?: boolean;
};

const json=(status:number,body:unknown)=>new Response(JSON.stringify(body),{
  status,headers:{"content-type":"application/json"}
});

Deno.serve(async(req)=>{
  if(req.method!=="POST") return json(405,{ok:false,error:"METHOD_NOT_ALLOWED"});
  try{
    const body=await req.json() as Body;
    for(const k of ["empresa_id","conversation_id","source_message_id","customer_message"] as const){
      if(!body[k]) return json(400,{ok:false,error:`MISSING_${k.toUpperCase()}`});
    }

    const url=Deno.env.get("SUPABASE_URL");
    const key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if(!url||!key) return json(500,{ok:false,error:"RUNTIME_CONFIG_MISSING"});
    const client=createClient(url,key,{auth:{persistSession:false}});

    const context=await loadAgentContext(client,body);
    const request=buildAgentRequest({
      company_profile: body.company_profile ?? {},
      context,
      customer_message: body.customer_message,
    });

    // POC safety gate: endpoint can now assemble the real agent request,
    // but it cannot mutate canonical state or send WhatsApp until the
    // bounded tool executor is installed and regression-tested.
    if(body.dry_run!==false){
      return json(200,{ok:true,mode:"DRY_RUN",request});
    }

    return json(409,{
      ok:false,
      error:"TOOL_EXECUTOR_NOT_ENABLED",
      message:"Agent request assembled successfully; canonical tool execution is intentionally gated."
    });
  }catch(e){
    return json(500,{ok:false,error:"AGENT_RUNTIME_FAILED",detail:e instanceof Error?e.message:String(e)});
  }
});
