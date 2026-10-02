import { loadAgentContext } from "./context-manager.ts";

type ToolEnv={client:any;empresa_id:string;conversation_id:string;source_message_id:string};

const asArray=(v:any)=>Array.isArray(v)?v:[];
const ids=(v:any)=>asArray(v).map(String).filter(Boolean);

async function requireStableVoiceConfirmation(
 client:any,
 empresa_id:string,
 conversation_id:string,
 source_message_id:string,
 action_key:string,
 action_context:any={}
){
 const {data:source,error:sourceError}=await client.from("atlas_conversation_messages")
  .select("channel,message_type,created_at")
  .eq("empresa_id",empresa_id)
  .eq("conversation_id",conversation_id)
  .eq("id",source_message_id)
  .maybeSingle();
 if(sourceError||!source) throw new Error("SOURCE_MESSAGE_READ_FAILED");
 if(source.channel!=="VOICE_CALL") return {required:false,confirmed:true};

 await client.from("atlas_voice_action_confirmations")
  .update({status:"EXPIRED",updated_at:new Date().toISOString()})
  .eq("empresa_id",empresa_id)
  .eq("conversation_id",conversation_id)
  .eq("status","PENDING")
  .lt("expires_at",new Date().toISOString());

 const {data:pending,error:pendingError}=await client.from("atlas_voice_action_confirmations")
  .select("id,action_key,action_context,originating_message_id,created_at,expires_at")
  .eq("empresa_id",empresa_id)
  .eq("conversation_id",conversation_id)
  .eq("status","PENDING")
  .eq("action_key",action_key)
  .gt("expires_at",new Date().toISOString())
  .order("created_at",{ascending:false})
  .limit(1)
  .maybeSingle();
 if(pendingError) throw new Error("VOICE_CONFIRMATION_READ_FAILED");

 if(!pending){
  const {data:created,error:createError}=await client.from("atlas_voice_action_confirmations")
   .insert({
    empresa_id,
    conversation_id,
    action_key,
    action_context:action_context??{},
    originating_message_id:source_message_id,
    status:"PENDING"
   })
   .select("id")
   .single();
  if(createError) throw new Error("VOICE_CONFIRMATION_CREATE_FAILED");
  return {
   required:true,
   confirmed:false,
   code:"VOICE_CONFIRMATION_REQUIRED",
   confirmation_id:created.id,
   action_key,
   next_action:"ASK_EXPLICIT_CONFIRMATION_IN_NEXT_FINAL_VOICE_TURN"
  };
 }

 if(String(pending.originating_message_id)===String(source_message_id)){
  return {
   required:true,
   confirmed:false,
   code:"VOICE_CONFIRMATION_REQUIRED",
   confirmation_id:pending.id,
   action_key,
   next_action:"ASK_EXPLICIT_CONFIRMATION_IN_NEXT_FINAL_VOICE_TURN"
  };
 }

 const sameContext=JSON.stringify(pending.action_context??{})===JSON.stringify(action_context??{});
 if(!sameContext){
  await client.from("atlas_voice_action_confirmations")
   .update({status:"CANCELLED",updated_at:new Date().toISOString()})
   .eq("id",pending.id)
   .eq("empresa_id",empresa_id);
  return {
   required:true,
   confirmed:false,
   code:"VOICE_CONFIRMATION_CONTEXT_CHANGED",
   action_key,
   next_action:"ASK_EXPLICIT_CONFIRMATION_AGAIN"
  };
 }

 const {error:confirmError}=await client.from("atlas_voice_action_confirmations")
  .update({
   status:"CONFIRMED",
   confirmed_by_message_id:source_message_id,
   updated_at:new Date().toISOString()
  })
  .eq("id",pending.id)
  .eq("empresa_id",empresa_id);
 if(confirmError) throw new Error("VOICE_CONFIRMATION_UPDATE_FAILED");

 return {required:true,confirmed:true,confirmation_id:pending.id,action_key};
}

async function sourceEvidence(client:any,empresa_id:string,conversation_id:string,source_message_id:string){
 const {data,error}=await client.from("atlas_conversation_messages").select("text_content,normalized_text").eq("empresa_id",empresa_id).eq("conversation_id",conversation_id).eq("id",source_message_id).maybeSingle();
 if(error) throw new Error("SOURCE_MESSAGE_READ_FAILED");
 const text=String(data?.normalized_text??data?.text_content??"").trim();
 if(!text) throw new Error("SOURCE_EVIDENCE_REQUIRED");
 return text;
}

export async function executeAtlasTool(env:ToolEnv,name:string,args:any){
  const {client,empresa_id,conversation_id,source_message_id}=env;
  switch(name){
    case "get_commercial_context":
      return await loadAgentContext(client,{empresa_id,conversation_id,source_message_id});

    case "get_company_policy": {
      const {data,error}=await client.rpc("atlas_get_company_commercial_policy_v1",{p_empresa_id:empresa_id});
      if(error) throw new Error("COMPANY_POLICY_READ_FAILED");
      return {topic:String(args?.topic??"").trim()||null,policy:data};
    }

    case "list_opportunities": {
      const {data,error}=await client.from("atlas_conversation_work_states")
        .select("id,status,commercial_stage,event,requirements,selected_items,active_quote_builder_id,state_version,started_at,updated_at,closed_at")
        .eq("empresa_id",empresa_id)
        .eq("conversation_id",conversation_id)
        .order("updated_at",{ascending:false})
        .limit(20);
      if(error) throw new Error("OPPORTUNITY_LIST_FAILED");
      return {items:asArray(data)};
    }

    case "resume_opportunity": {
      const workStateId=String(args?.work_state_id??"").trim();
      if(!workStateId) throw new Error("WORK_STATE_ID_REQUIRED");

      const {data:target,error:targetError}=await client.from("atlas_conversation_work_states")
        .select("id,status")
        .eq("id",workStateId)
        .eq("empresa_id",empresa_id)
        .eq("conversation_id",conversation_id)
        .maybeSingle();

      if(targetError||!target) throw new Error("OPPORTUNITY_NOT_FOUND");

      const {data:active}=await client.from("atlas_conversation_work_states")
        .select("id")
        .eq("empresa_id",empresa_id)
        .eq("conversation_id",conversation_id)
        .eq("status","ACTIVE")
        .neq("id",workStateId);

      for(const row of asArray(active)){
        const {error}=await client.from("atlas_conversation_work_states")
          .update({status:"CLOSED",closed_at:new Date().toISOString(),updated_at:new Date().toISOString()})
          .eq("id",row.id)
          .eq("empresa_id",empresa_id)
          .eq("conversation_id",conversation_id);
        if(error) throw new Error("OPPORTUNITY_PAUSE_FAILED");
      }

      const {error:resumeError}=await client.from("atlas_conversation_work_states")
        .update({status:"ACTIVE",closed_at:null,updated_at:new Date().toISOString()})
        .eq("id",workStateId)
        .eq("empresa_id",empresa_id)
        .eq("conversation_id",conversation_id);

      if(resumeError) throw new Error("OPPORTUNITY_RESUME_FAILED");

      const {data:resumed,error:readError}=await client.rpc("atlas_get_active_conversation_work_state_v1",{
        p_empresa_id:empresa_id,p_conversation_id:conversation_id
      });
      if(readError) throw new Error("WORK_STATE_READ_FAILED");
      return resumed;
    }

    case "open_opportunity": {
      const {data,error}=await client.rpc("atlas_apply_conversation_work_state_v4",{
        p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:source_message_id,
        p_patch:{start_new_event:true,work_intent:"CONTINUE_EVENT"}
      });
      if(error) throw new Error("OPEN_OPPORTUNITY_FAILED");
      return data;
    }

    case "update_event": {
      const p=args?.patch??{};
      const patch:any={work_intent:"CONTINUE_EVENT"};
      if(p.event_patch) patch.event_patch=p.event_patch;
      if(p.requirements) patch.requirements=p.requirements;
      const {data,error}=await client.rpc("atlas_apply_conversation_work_state_v4",{
        p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:source_message_id,p_patch:patch
      });
      if(error) throw new Error("UPDATE_EVENT_FAILED");
      return data;
    }

    case "search_catalog": {
      const q=String(args?.query??"").trim();
      if(!q) throw new Error("CATALOG_QUERY_REQUIRED");
      let query=client.from("productos")
        .select("id,nombre,descripcion_resumen,sku,moneda,precio_base,atributos_extra,keywords")
        .eq("empresa_id",empresa_id).eq("activo",true).eq("estado","published").is("deleted_at",null)
        .or(`nombre.ilike.%${q.replace(/[%_,]/g," ")}%,descripcion_resumen.ilike.%${q.replace(/[%_,]/g," ")}%`)
        .limit(12);
      const {data,error}=await query;
      if(error) throw new Error("CATALOG_SEARCH_FAILED");
      const excluded=new Set(ids(args?.exclude_product_ids));
      return {items:asArray(data).filter((x:any)=>!excluded.has(String(x.id))).slice(0,8)};
    }

    case "select_products": {
      const explicitItems=asArray(args?.items);
      const productIds=explicitItems.length
        ? explicitItems.map((x:any)=>String(x?.product_id??"")).filter(Boolean)
        : ids(args?.product_ids);
      if(!productIds.length) throw new Error("PRODUCT_IDS_REQUIRED");

      const {data:products,error}=await client.from("productos").select("id,nombre")
        .eq("empresa_id",empresa_id).in("id",productIds).eq("activo",true).eq("estado","published").is("deleted_at",null);
      if(error||asArray(products).length!==new Set(productIds).size) throw new Error("NON_CANONICAL_PRODUCT");

      const {data:currentState}=await client.rpc("atlas_get_active_conversation_work_state_v1",{
        p_empresa_id:empresa_id,p_conversation_id:conversation_id
      });
      const recommended=asArray(currentState?.recommended_items);

      const selected=asArray(products).map((p:any)=>{
        const explicit=explicitItems.find((x:any)=>String(x?.product_id)===String(p.id));
        const prior=recommended.find((r:any)=>String(r?.product_id)===String(p.id));
        const quantity=Math.max(1,Number(explicit?.quantity??prior?.quantity??1));
        return {product_id:p.id,quantity};
      });
      const {data,error:applyError}=await client.rpc("atlas_apply_conversation_work_state_v4",{
        p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:source_message_id,
        p_patch:{work_intent:"SELECT",selected_products:selected}
      });
      if(applyError) throw new Error("SELECT_PRODUCTS_FAILED");
      return data;
    }

    case "show_products": {
      const scope=String(args?.scope??"REFERENCE");
      const page=Math.max(1,Number(args?.page??1));

      if(scope==="CATALOG_PAGE"){
        const pageSize=8;
        const from=(page-1)*pageSize;
        const to=from+pageSize-1;
        const {data,error,count}=await client.from("productos")
          .select("id,nombre,descripcion_resumen,sku,moneda,precio_base",{count:"exact"})
          .eq("empresa_id",empresa_id)
          .eq("activo",true)
          .eq("estado","published")
          .is("deleted_at",null)
          .order("nombre",{ascending:true})
          .range(from,to);
        if(error) throw new Error("CATALOG_PAGE_FAILED");

        const items=[];
        for(const p of asArray(data)){
          const {data:visual}=await client.rpc("atlas_resolve_product_visual_reference_v1",{
            p_empresa_id:empresa_id,p_product_id:p.id
          });
          items.push({...p,visual:visual??null});
        }
        return {
          code:"CATALOG_PAGE_READY",
          page,
          page_size:pageSize,
          total:count??null,
          has_more:typeof count==="number"?to+1<count:null,
          items
        };
      }

      const productIds=ids(args?.product_ids);
      if(!productIds.length) return {code:"PRODUCT_REFERENCE_REQUIRED",items:[]};
      const items=[];
      for(const product_id of productIds.slice(0,8)){
        const {data,error}=await client.rpc("atlas_resolve_product_visual_reference_v1",{p_empresa_id:empresa_id,p_product_id:product_id});
        if(!error&&data) items.push({product_id,visual:data});
      }
      return {code:"VISUALS_READY",items};
    }

    case "get_transaction_state": {
      const {data:w,error:wError}=await client.rpc("atlas_get_active_conversation_work_state_v1",{
        p_empresa_id:empresa_id,p_conversation_id:conversation_id
      });
      if(wError) throw new Error("WORK_STATE_READ_FAILED");

      const {data:acceptance}=await client.from("atlas_quote_acceptances")
        .select("id,quote_builder_id,quote_version,status,accepted_at,superseded_at")
        .eq("empresa_id",empresa_id)
        .eq("conversation_id",conversation_id)
        .order("accepted_at",{ascending:false})
        .limit(1)
        .maybeSingle();

      const {data:evidences,error:eError}=await client.from("atlas_payment_evidences")
        .select("id,quote_builder_id,expected_amount,claimed_amount,currency,status,provider_reference,received_at,reviewed_at,review_reason")
        .eq("empresa_id",empresa_id)
        .eq("conversation_id",conversation_id)
        .order("created_at",{ascending:false})
        .limit(10);
      if(eError) throw new Error("PAYMENT_EVIDENCE_READ_FAILED");

      const {data:reservation,error:rError}=await client.from("atlas_commercial_reservations")
        .select("id,quote_builder_id,payment_evidence_id,status,event_date,event_location,confirmed_at,cancelled_at")
        .eq("empresa_id",empresa_id)
        .eq("conversation_id",conversation_id)
        .order("created_at",{ascending:false})
        .limit(1)
        .maybeSingle();
      if(rError) throw new Error("RESERVATION_READ_FAILED");

      return {work_state:w??null,acceptance:acceptance??null,payment_evidences:asArray(evidences),reservation:reservation??null};
    }

    case "register_payment_evidence": {
      const {data:source,error:sourceError}=await client.from("atlas_conversation_messages")
        .select("message_type,raw_payload")
        .eq("id",source_message_id)
        .eq("empresa_id",empresa_id)
        .eq("conversation_id",conversation_id)
        .maybeSingle();
      if(sourceError||!source) throw new Error("SOURCE_MESSAGE_READ_FAILED");

      const mediaType=String(source.message_type??"").toUpperCase();
      if(!["IMAGE","DOCUMENT"].includes(mediaType)){
        return {
          ok:false,
          code:"PAYMENT_EVIDENCE_MEDIA_REQUIRED",
          source_message_type:mediaType,
          reservation_confirmed:false,
          next_action:"ASK_FOR_PAYMENT_EVIDENCE"
        };
      }

      const claimedAmount=args?.claimed_amount==null?null:Number(args.claimed_amount);
      const providerReference=args?.provider_reference==null?null:String(args.provider_reference);
      const note=args?.note==null?null:String(args.note);

      const {data,error}=await client.rpc("atlas_register_payment_evidence_v1",{
        p_empresa_id:empresa_id,
        p_conversation_id:conversation_id,
        p_source_message_id:source_message_id,
        p_claimed_amount:Number.isFinite(claimedAmount)?claimedAmount:null,
        p_provider_reference:providerReference,
        p_metadata:{note}
      });
      if(error) throw new Error("PAYMENT_EVIDENCE_REGISTER_FAILED");
      return data;
    }

    case "request_commercial_exception": {
      const type=String(args?.exception_type??"").trim();
      if(!type) throw new Error("EXCEPTION_TYPE_REQUIRED");

      const {data,error}=await client.rpc("atlas_request_commercial_exception_v1",{
        p_empresa_id:empresa_id,
        p_conversation_id:conversation_id,
        p_source_message_id:source_message_id,
        p_exception_type:type,
        p_customer_reason:args?.customer_reason==null?null:String(args.customer_reason),
        p_metadata:{requested_by:"GPT_5_6_AGENT"}
      });
      if(error) throw new Error("COMMERCIAL_EXCEPTION_REQUEST_FAILED");
      return data;
    }

    case "request_cancellation": {
      const guard=await requireStableVoiceConfirmation(
        client,empresa_id,conversation_id,source_message_id,
        "REQUEST_CANCELLATION",
        {reason:args?.customer_reason==null?null:String(args.customer_reason)}
      );
      if(guard.required&&!guard.confirmed) return guard;

      const {data,error}=await client.rpc("atlas_request_commercial_cancellation_v1",{
        p_empresa_id:empresa_id,
        p_conversation_id:conversation_id,
        p_source_message_id:source_message_id,
        p_customer_reason:args?.customer_reason==null?null:String(args.customer_reason)
      });
      if(error) throw new Error("COMMERCIAL_CANCELLATION_REQUEST_FAILED");
      return data;
    }

    case "create_quote": {
      const {data:w,error}=await client.rpc("atlas_get_active_conversation_work_state_v1",{p_empresa_id:empresa_id,p_conversation_id:conversation_id});
      if(error) throw new Error("WORK_STATE_READ_FAILED");
      const stateId=w?.state_id, stateVersion=Number(w?.state_version??0);
      if(!stateId) throw new Error("ACTIVE_OPPORTUNITY_REQUIRED");
      const evidence=await sourceEvidence(client,empresa_id,conversation_id,source_message_id);
      const decision={requested_action:"CREATE",action_evidence:evidence,confidence:.99,work_intent:"QUOTE_REQUEST"};
      const {data,error:execError}=await client.rpc("atlas_commercial_execute_turn",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:source_message_id,p_expected_state_id:stateId,p_expected_version:stateVersion,p_decision:decision});
      if(execError) throw new Error("CREATE_QUOTE_FAILED");
      return data;
    }

    case "quote_action": {
      const action=String(args?.action??"GET");
      const {data:w,error}=await client.rpc("atlas_get_active_conversation_work_state_v1",{p_empresa_id:empresa_id,p_conversation_id:conversation_id});
      if(error) throw new Error("WORK_STATE_READ_FAILED");
      const quoteId=w?.active_quote_builder_id??null;
      if(action==="GET"){
        const {data,error:qError}=await client.rpc("atlas_commercial_quote",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_quote_id:quoteId});
        if(qError) throw new Error("QUOTE_READ_FAILED");
        return data;
      }
      if(action==="MODIFY"){
        const {data:confirmedPayment}=await client.from("atlas_payment_evidences")
          .select("id,status,quote_builder_id")
          .eq("empresa_id",empresa_id)
          .eq("conversation_id",conversation_id)
          .eq("status","CONFIRMED")
          .order("reviewed_at",{ascending:false})
          .limit(1)
          .maybeSingle();

        const {data:confirmedReservation}=await client.from("atlas_commercial_reservations")
          .select("id,status,quote_builder_id")
          .eq("empresa_id",empresa_id)
          .eq("conversation_id",conversation_id)
          .eq("status","CONFIRMED")
          .order("confirmed_at",{ascending:false})
          .limit(1)
          .maybeSingle();

        if(confirmedPayment||confirmedReservation){
          return {
            ok:false,
            code:"POST_PAYMENT_CHANGE_REQUIRES_REVIEW",
            payment_evidence_id:confirmedPayment?.id??null,
            reservation_id:confirmedReservation?.id??null,
            quote_builder_id:confirmedReservation?.quote_builder_id??confirmedPayment?.quote_builder_id??quoteId,
            next_action:"REQUEST_EXCEPTION_OR_HANDOFF"
          };
        }

        const interpretation=args?.interpretation;
        if(!interpretation||typeof interpretation!=="object") return {code:"MODIFICATION_ARGUMENTS_REQUIRED",enabled:false};

        const canonicalInterpretation={
          primary_intent:"modify_quote",
          intent_confidence:Number(interpretation.intent_confidence??0),
          ambiguities:asArray(interpretation.ambiguities),
          patch:interpretation.patch??{}
        };

        const {data:plan,error:planError}=await client.rpc("atlas_prepare_quote_modification_plan_v2",{
          p_empresa_id:empresa_id,
          p_conversation_id:conversation_id,
          p_source_message_id:source_message_id,
          p_interpretation:canonicalInterpretation
        });
        if(planError) throw new Error("QUOTE_MODIFICATION_PLAN_FAILED");
        if(plan?.ready_to_act!==true) return plan;

        const {data:result,error:execError}=await client.rpc("atlas_execute_quote_modification_plan_v2",{
          p_empresa_id:empresa_id,
          p_conversation_id:conversation_id,
          p_source_message_id:source_message_id,
          p_validated_plan:plan
        });
        if(execError) throw new Error("QUOTE_MODIFICATION_EXECUTION_FAILED");

        const newQuoteId=result?.new_quote_builder_id??result?.quote_builder_id??null;
        if(newQuoteId){
          await client.rpc("atlas_attach_quote_to_work_state_v1",{
            p_empresa_id:empresa_id,
            p_conversation_id:conversation_id,
            p_quote_builder_id:newQuoteId
          });
        }

        return {plan,result};
      }
      if(!w?.state_id) throw new Error("ACTIVE_OPPORTUNITY_REQUIRED");
      const requested_action=action==="ACCEPT"?"ACCEPT":"PAYMENT";

      if(action==="ACCEPT"){
        const guard=await requireStableVoiceConfirmation(
          client,empresa_id,conversation_id,source_message_id,
          "ACCEPT_QUOTE",
          {quote_builder_id:quoteId}
        );
        if(guard.required&&!guard.confirmed) return guard;
      }

      const evidence=await sourceEvidence(client,empresa_id,conversation_id,source_message_id);
      const decision={requested_action,action_evidence:evidence,confidence:.99,work_intent:requested_action};
      const {data,error:execError}=await client.rpc("atlas_commercial_execute_turn",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:source_message_id,p_expected_state_id:w.state_id,p_expected_version:Number(w.state_version??0),p_decision:decision});
      if(execError) throw new Error("QUOTE_ACTION_FAILED");
      return data;
    }

    default: throw new Error("UNKNOWN_AGENT_TOOL");
  }
}
