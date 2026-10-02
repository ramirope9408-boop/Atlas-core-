import { ATLAS_AGENT_SYSTEM } from "./system-prompt.ts";
import { ATLAS_AGENT_TOOLS } from "./tool-registry.ts";
import { executeAtlasTool } from "./tool-executor.ts";

export type AgentModelRequest={company_profile:Record<string,unknown>;context:Record<string,unknown>;customer_message:string};
export function buildAgentRequest(input:AgentModelRequest){
 return {instructions:ATLAS_AGENT_SYSTEM,tools:ATLAS_AGENT_TOOLS,input:[{role:"user",content:JSON.stringify({company_profile:input.company_profile,canonical_context:input.context,customer_message:input.customer_message})}]};
}
const parseArgs=(v:any)=>{try{return typeof v==="string"?JSON.parse(v||"{}"):(v??{});}catch{return {};}};
export async function runAgentLoop(opts:{client:any;empresa_id:string;conversation_id:string;source_message_id:string;request:any;model:string;apiKey:string;maxSteps?:number}){
 let input=opts.request.input; const trace:any[]=[]; let previous_response_id:string|undefined;
 for(let step=0;step<(opts.maxSteps??6);step++){
  const body:any={model:opts.model,instructions:opts.request.instructions,tools:opts.request.tools,input,parallel_tool_calls:false};
  if(previous_response_id) body.previous_response_id=previous_response_id;
  const res=await fetch("https://api.openai.com/v1/responses",{method:"POST",headers:{"authorization":`Bearer ${opts.apiKey}`,"content-type":"application/json"},body:JSON.stringify(body)});
  const out=await res.json(); if(!res.ok) throw new Error(`MODEL_REQUEST_FAILED:${out?.error?.code??res.status}`);
  previous_response_id=out.id;
  const calls=(out.output??[]).filter((x:any)=>x.type==="function_call");
  trace.push({step,response_id:out.id,tool_calls:calls.map((c:any)=>({name:c.name,call_id:c.call_id}))});
  if(!calls.length){
   const text=(out.output??[]).flatMap((x:any)=>x.content??[]).filter((x:any)=>x.type==="output_text").map((x:any)=>x.text).join("\n").trim();
   return {ok:true,response_id:out.id,text,trace};
  }
  const toolOutputs=[];
  for(const call of calls){
   const result=await executeAtlasTool({client:opts.client,empresa_id:opts.empresa_id,conversation_id:opts.conversation_id,source_message_id:opts.source_message_id},call.name,parseArgs(call.arguments));
   toolOutputs.push({type:"function_call_output",call_id:call.call_id,output:JSON.stringify(result)});
  }
  input=toolOutputs;
 }
 throw new Error("AGENT_TOOL_BUDGET_EXCEEDED");
}
