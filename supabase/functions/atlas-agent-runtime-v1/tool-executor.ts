import { loadAgentContext } from "./context-manager.ts";

type ToolEnv={client:any;empresa_id:string;conversation_id:string;source_message_id:string};

const asArray=(v:any)=>Array.isArray(v)?v:[];
const ids=(v:any)=>asArray(v).map(String).filter(Boolean);
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
      const productIds=ids(args?.product_ids);
      if(!productIds.length) throw new Error("PRODUCT_IDS_REQUIRED");
      const {data:products,error}=await client.from("productos").select("id,nombre")
        .eq("empresa_id",empresa_id).in("id",productIds).eq("activo",true).eq("estado","published").is("deleted_at",null);
      if(error||asArray(products).length!==new Set(productIds).size) throw new Error("NON_CANONICAL_PRODUCT");
      const {data:currentState}=await client.rpc("atlas_get_active_conversation_work_state_v1",{
        p_empresa_id:empresa_id,p_conversation_id:conversation_id
      });
      const recommended=asArray(currentState?.recommended_items);
      const selected=asArray(products).map((p:any)=>{
        const prior=recommended.find((r:any)=>String(r?.product_id)===String(p.id));
        const quantity=Math.max(1,Number(prior?.quantity??1));
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
      const productIds=ids(args?.product_ids);
      if(!productIds.length) return {code:"PRODUCT_REFERENCE_REQUIRED",items:[]};
      const items=[];
      for(const product_id of productIds.slice(0,8)){
        const {data,error}=await client.rpc("atlas_resolve_product_visual_reference_v1",{p_empresa_id:empresa_id,p_product_id:product_id});
        if(!error&&data) items.push({product_id,visual:data});
      }
      return {code:"VISUALS_READY",items};
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
      if(action==="MODIFY") return {code:"MODIFICATION_ARGUMENTS_REQUIRED",enabled:false};
      if(!w?.state_id) throw new Error("ACTIVE_OPPORTUNITY_REQUIRED");
      const requested_action=action==="ACCEPT"?"ACCEPT":"PAYMENT";
      const evidence=await sourceEvidence(client,empresa_id,conversation_id,source_message_id);
      const decision={requested_action,action_evidence:evidence,confidence:.99,work_intent:requested_action};
      const {data,error:execError}=await client.rpc("atlas_commercial_execute_turn",{p_empresa_id:empresa_id,p_conversation_id:conversation_id,p_source_message_id:source_message_id,p_expected_state_id:w.state_id,p_expected_version:Number(w.state_version??0),p_decision:decision});
      if(execError) throw new Error("QUOTE_ACTION_FAILED");
      return data;
    }

    default: throw new Error("UNKNOWN_AGENT_TOOL");
  }
}
