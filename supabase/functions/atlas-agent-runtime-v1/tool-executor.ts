import { loadAgentContext } from "./context-manager.ts";

type ToolEnv={client:any;empresa_id:string;conversation_id:string;source_message_id:string};

const asArray=(v:any)=>Array.isArray(v)?v:[];
const ids=(v:any)=>asArray(v).map(String).filter(Boolean);

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
      const selected=asArray(products).map((p:any)=>({product_id:p.id,quantity:1}));
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

    case "create_quote":
    case "quote_action":
      return {code:"CANONICAL_COMMERCIAL_ACTION_REQUIRES_TURN_ADAPTER",enabled:false};

    default: throw new Error("UNKNOWN_AGENT_TOOL");
  }
}
