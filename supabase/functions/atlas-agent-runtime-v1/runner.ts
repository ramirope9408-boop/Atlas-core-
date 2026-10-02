import { ATLAS_AGENT_SYSTEM } from "./system-prompt.ts";
import { ATLAS_AGENT_TOOLS } from "./tool-registry.ts";
import { executeAtlasTool } from "./tool-executor.ts";
import { loadAgentContext } from "./context-manager.ts";

export type AgentModelRequest={company_profile:Record<string,unknown>;context:Record<string,unknown>;customer_message:string};

export function buildAgentRequest(input:AgentModelRequest){
 return {
  instructions:ATLAS_AGENT_SYSTEM,
  tools:ATLAS_AGENT_TOOLS,
  input:[{role:"user",content:JSON.stringify({
   company_profile:input.company_profile,
   canonical_context:input.context,
   customer_message:input.customer_message
  })}]
 };
}

const parseArgs=(v:any)=>{
 try{return typeof v==="string"?JSON.parse(v||"{}"):(v??{});}
 catch{return {};}
};



function compactToolOutput(name:string,result:any){
 if(name!=="show_products") return result;
 const items=Array.isArray(result?.items)?result.items:[];
 return {
  code:result?.code??"VISUALS_READY",
  page:result?.page??null,
  page_size:result?.page_size??null,
  total:result?.total??null,
  has_more:result?.has_more??null,
  visual_delivery_requested:true,
  items:items.map((x:any)=>({
   product_id:x?.product_id??x?.id??x?.visual?.product_id??null,
   name:x?.nombre??x?.name??x?.visual?.canonical_name??x?.visual?.product_name??null,
   price:x?.precio_base??x?.price??null,
   visual_ready:Boolean(
    x?.visual?.public_url||x?.visual?.signed_url||x?.visual?.url||
    x?.public_url||x?.signed_url||x?.url
   )
  }))
 };
}

export async function runAgentLoop(opts:{client:any;empresa_id:string;conversation_id:string;source_message_id:string;request:any;model:string;apiKey:string;maxSteps?:number}){
 let input=opts.request.input;
 const trace:any[]=[];
 let previous_response_id:string|undefined;

 for(let step=0;step<(opts.maxSteps??8);step++){
  const body:any={
   model:opts.model,
   instructions:opts.request.instructions,
   tools:opts.request.tools,
   input,
   parallel_tool_calls:false
  };
  if(previous_response_id) body.previous_response_id=previous_response_id;

  const res=await fetch("https://api.openai.com/v1/responses",{
   method:"POST",
   headers:{"authorization":`Bearer ${opts.apiKey}`,"content-type":"application/json"},
   body:JSON.stringify(body)
  });

  const out=await res.json();
  if(!res.ok) throw new Error(`MODEL_REQUEST_FAILED:${out?.error?.message??out?.error?.code??res.status}`);

  previous_response_id=out.id;
  const calls=(out.output??[]).filter((x:any)=>x.type==="function_call");
  const stepTrace:any={
   step,
   response_id:out.id,
   model:out.model??opts.model,
   status:out.status??null,
   usage:out.usage??null,
   tool_calls:[]
  };

  if(!calls.length){
   const text=(out.output??[])
    .flatMap((x:any)=>x.content??[])
    .filter((x:any)=>x.type==="output_text")
    .map((x:any)=>x.text)
    .join("\n")
    .trim();

   trace.push(stepTrace);
   const canonical_after=await loadAgentContext(opts.client,{
    empresa_id:opts.empresa_id,
    conversation_id:opts.conversation_id,
    source_message_id:opts.source_message_id
   });

   return {ok:true,response_id:out.id,model:out.model??opts.model,text,trace,canonical_after};
  }

  const toolOutputs=[];
  for(const call of calls){
   const args=parseArgs(call.arguments);
   const result=await executeAtlasTool(
    {client:opts.client,empresa_id:opts.empresa_id,conversation_id:opts.conversation_id,source_message_id:opts.source_message_id,apiKey:opts.apiKey},
    call.name,
    args
   );
   stepTrace.tool_calls.push({name:call.name,call_id:call.call_id,arguments:args,result});
   toolOutputs.push({type:"function_call_output",call_id:call.call_id,output:JSON.stringify(compactToolOutput(call.name,result))});
  }

  trace.push(stepTrace);
  input=toolOutputs;
 }

 throw new Error("AGENT_TOOL_BUDGET_EXCEEDED");
}
