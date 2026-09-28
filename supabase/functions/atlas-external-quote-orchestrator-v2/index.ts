import { createClient } from "npm:@supabase/supabase-js@2.57.4";
const JSON_HEADERS={"Content-Type":"application/json"};
function fail(status:number,code:string,detail?:unknown){return new Response(JSON.stringify({ok:false,code,detail}),{status,headers:JSON_HEADERS});}
async function callFunction(base:string,name:string,service:string,body:unknown){const res=await fetch(`${base}/functions/v1/${name}`,{method:"POST",headers:{"Authorization":`Bearer ${service}`,"Content-Type":"application/json"},body:JSON.stringify(body)});const data=await res.json().catch(()=>({}));return{res,data};}
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST")return fail(405,"METHOD_NOT_ALLOWED");
 const auth=req.headers.get("Authorization");if(!auth?.startsWith("Bearer "))return fail(401,"AUTH_REQUIRED");
 const url=Deno.env.get("SUPABASE_URL")!;const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;if(!service)return fail(503,"SERVICE_ROLE_UNAVAILABLE");if(auth.slice(7)!==service)return fail(403,"TRUSTED_BACKEND_ONLY");
 const body=await req.json().catch(()=>null);const empresa_id=body?.empresa_id;const conversation_id=body?.conversation_id;const requested_source_message_id=body?.source_message_id??null;const execute=body?.execute===true;const render_pdf=body?.render_pdf===true;const render_only=body?.render_only===true;const quote_builder_id=body?.quote_builder_id??null;const validity_hours=Number(body?.validity_hours??96);
 if(!empresa_id||!conversation_id)return fail(400,"EMPRESA_AND_CONVERSATION_REQUIRED");
 if(render_pdf&&!execute&&!render_only)return fail(400,"RENDER_REQUIRES_EXECUTION_OR_RENDER_ONLY");
 if(render_only&&!quote_builder_id)return fail(400,"QUOTE_BUILDER_ID_REQUIRED_FOR_RENDER_ONLY");
 if(render_only&&execute)return fail(400,"RENDER_ONLY_CANNOT_EXECUTE");
 if(!Number.isInteger(validity_hours)||validity_hours<1||validity_hours>720)return fail(400,"VALIDITY_HOURS_INVALID");
 const admin=createClient(url,service);
 if(render_only){
  const{data:quote,error}=await admin.from("atlas_quote_builders").select("id,empresa_id,quote_version,status,people_count,total,deposit_amount,balance_amount,metadata,root_quote_builder_id,supersedes_quote_builder_id").eq("id",quote_builder_id).eq("empresa_id",empresa_id).maybeSingle();
  if(error)return fail(500,"QUOTE_LOOKUP_FAILED",error.message);if(!quote)return fail(404,"QUOTE_NOT_FOUND");
  if(String(quote?.metadata?.conversation_id??"")!==String(conversation_id))return fail(409,"QUOTE_CONVERSATION_MISMATCH");
  if(quote.status!=="READY_FOR_QUOTE")return fail(409,"QUOTE_NOT_READY_FOR_RENDER",{status:quote.status});
  const rendered=await callFunction(url,"atlas-quote-renderer-v2",service,{empresa_id,quote_builder_id,validity_hours});
  if(!rendered.res.ok)return fail(rendered.res.status,"QUOTE_RENDERER_V2_FAILED",rendered.data);
  return new Response(JSON.stringify({ok:true,mode:"RENDER_ONLY",executed:false,rendered:true,quote_builder_id,quote_version:quote.quote_version,quote_snapshot:{people_count:quote.people_count,total:quote.total,deposit_amount:quote.deposit_amount,balance_amount:quote.balance_amount,status:quote.status,root_quote_builder_id:quote.root_quote_builder_id,supersedes_quote_builder_id:quote.supersedes_quote_builder_id},document:rendered.data,next_step:"DELIVER_DOCUMENT"}),{status:200,headers:JSON_HEADERS});
 }
 if(execute&&requested_source_message_id){
  const{data:pendingPlan,error:pendingErr}=await admin.rpc("atlas_prepare_confirmed_pending_quote_modification_plan_v1",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:requested_source_message_id});
  if(pendingErr)return fail(422,"PENDING_CONFIRMATION_RESOLUTION_FAILED",pendingErr.message);
  const pendingReady=pendingPlan?.ready_to_act===true&&pendingPlan?.code==="QUOTE_MODIFICATION_PLAN_READY_V2"&&pendingPlan?.confirmation_contract==="QUOTE_MODIFICATION_CONFIRMATION_V2";
  if(pendingReady){
    const{data:execution,error:execErr}=await admin.rpc("atlas_execute_quote_modification_plan_v2",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:requested_source_message_id,p_validated_plan:pendingPlan});
    if(execErr)return fail(422,"PENDING_CONFIRMATION_EXECUTION_FAILED",execErr.message);
    const new_quote_builder_id=execution?.new_quote_builder_id;
    if(!new_quote_builder_id)return fail(500,"NEW_QUOTE_ID_MISSING",execution);
    const{data:finalization,error:finalizeErr}=await admin.rpc("atlas_finalize_confirmed_pending_quote_modification_v1",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:requested_source_message_id,p_execution_result:execution});
    if(finalizeErr)return fail(422,"PENDING_CONFIRMATION_FINALIZE_FAILED",finalizeErr.message);
    if(!render_pdf)return new Response(JSON.stringify({ok:true,mode:"CONFIRMED_PENDING_MODIFICATION",executed:true,rendered:false,source_message_id:requested_source_message_id,validated_plan:pendingPlan,execution,finalization,new_quote_builder_id,next_step:"RENDER_OR_RESPOND"}),{status:200,headers:JSON_HEADERS});
    const rendered=await callFunction(url,"atlas-quote-renderer-v2",service,{empresa_id,quote_builder_id:new_quote_builder_id,validity_hours});
    if(!rendered.res.ok)return fail(rendered.res.status,"QUOTE_RENDERER_V2_FAILED",rendered.data);
    return new Response(JSON.stringify({ok:true,mode:"CONFIRMED_PENDING_MODIFICATION",executed:true,rendered:true,source_message_id:requested_source_message_id,validated_plan:pendingPlan,execution,finalization,new_quote_builder_id,document:rendered.data,next_step:"DELIVER_DOCUMENT"}),{status:200,headers:JSON_HEADERS});
  }
 }
 const semantic=await callFunction(url,"atlas-external-quote-semantic-v2",service,{empresa_id,conversation_id,source_message_id:requested_source_message_id});if(!semantic.res.ok)return fail(semantic.res.status,"SEMANTIC_V2_FAILED",semantic.data);
 const resolved_source_message_id=semantic.data?.source_message_id;if(requested_source_message_id&&String(resolved_source_message_id)!==String(requested_source_message_id))return fail(409,"SOURCE_MESSAGE_ID_MISMATCH");const interpretation=semantic.data?.interpretation;const validated_plan=semantic.data?.validated_plan;if(!validated_plan)return fail(502,"VALIDATED_PLAN_MISSING");
 const modificationReady=validated_plan?.ready_to_act===true&&validated_plan?.code==="QUOTE_MODIFICATION_PLAN_READY_V2"&&validated_plan?.next_action==="CREATE_REVISION_THEN_APPLY_PATCH";
 const acceptanceReady=validated_plan?.ready_to_act===true&&validated_plan?.code==="QUOTE_ACCEPTANCE_PLAN_READY_V1"&&validated_plan?.next_action==="ACCEPT_CUSTOMER_VISIBLE_QUOTE";
 const ready=modificationReady||acceptanceReady;
 if(!execute)return new Response(JSON.stringify({ok:true,mode:"DRY_RUN",executed:false,rendered:false,source_message_id:resolved_source_message_id,interpretation,validated_plan,executable:ready,next_step:ready?(acceptanceReady?"ACCEPT_CUSTOMER_VISIBLE_QUOTE":"EXECUTE_QUOTE_MODIFICATION"):(validated_plan?.next_action??"NO_EXECUTION")}),{status:200,headers:JSON_HEADERS});
 if(!ready)return new Response(JSON.stringify({ok:true,mode:"NO_EXECUTION",executed:false,rendered:false,source_message_id:resolved_source_message_id,interpretation,validated_plan,executable:false,next_step:validated_plan?.next_action??"NO_EXECUTION"}),{status:200,headers:JSON_HEADERS});
 if(acceptanceReady){
  const acceptedQuoteBuilderId=validated_plan?.quote_builder_id;
  if(!acceptedQuoteBuilderId)return fail(500,"ACCEPTANCE_QUOTE_ID_MISSING",validated_plan);
  const{data:acceptance,error:acceptErr}=await admin.rpc("atlas_accept_customer_visible_quote_v1",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:resolved_source_message_id,p_quote_builder_id:acceptedQuoteBuilderId});
  if(acceptErr)return fail(422,"QUOTE_ACCEPTANCE_FAILED",acceptErr.message);
  return new Response(JSON.stringify({ok:true,mode:"ACCEPT_QUOTE",executed:true,rendered:false,source_message_id:resolved_source_message_id,interpretation,validated_plan,acceptance,quote_builder_id:acceptedQuoteBuilderId,next_step:"BUILD_DYNAMIC_PAYMENT"}),{status:200,headers:JSON_HEADERS});
 }
 const{data:execution,error:execErr}=await admin.rpc("atlas_execute_quote_modification_plan_v2",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:resolved_source_message_id,p_validated_plan:validated_plan});if(execErr)return fail(422,"QUOTE_EXECUTION_FAILED",execErr.message);
 const new_quote_builder_id=execution?.new_quote_builder_id;if(!new_quote_builder_id)return fail(500,"NEW_QUOTE_ID_MISSING",execution);
 if(!render_pdf)return new Response(JSON.stringify({ok:true,mode:"EXECUTE_ONLY",executed:true,rendered:false,source_message_id:resolved_source_message_id,interpretation,validated_plan,execution,new_quote_builder_id,next_step:"RENDER_OR_RESPOND"}),{status:200,headers:JSON_HEADERS});
 const rendered=await callFunction(url,"atlas-quote-renderer-v2",service,{empresa_id,quote_builder_id:new_quote_builder_id,validity_hours});if(!rendered.res.ok)return fail(rendered.res.status,"QUOTE_RENDERER_V2_FAILED",rendered.data);
 return new Response(JSON.stringify({ok:true,mode:"EXECUTE_AND_RENDER",executed:true,rendered:true,source_message_id:resolved_source_message_id,interpretation,validated_plan,execution,new_quote_builder_id,document:rendered.data,next_step:"DELIVER_DOCUMENT"}),{status:200,headers:JSON_HEADERS});
});