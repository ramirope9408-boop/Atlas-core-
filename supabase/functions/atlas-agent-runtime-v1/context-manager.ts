export type AgentContextInput={empresa_id:string;conversation_id:string;source_message_id:string};

export async function loadCompanyProfile(client:any,empresa_id:string){
 const {data:installation}=await client.from("atlas_company_agent_installations")
  .select("id,agent_code,installed_version,metadata").eq("empresa_id",empresa_id).eq("installation_status","ACTIVE")
  .order("updated_at",{ascending:false}).limit(1).maybeSingle();
 const {data:agent}=await client.from("agentes")
  .select("nombre,slug,rol,descripcion,idioma_principal,personalidad_base,perfil_regional,intensidad_regional,formalidad_base,energia_base,humor_maximo,emojis_maximos,usar_diminutivos,adaptacion_automatica,proveedor_ia,modelo_ia,version")
  .eq("empresa_id",empresa_id).order("updated_at",{ascending:false}).limit(1).maybeSingle();
 let config:Record<string,unknown>={};
 if(installation?.id){
  const {data:rows}=await client.from("atlas_company_agent_config").select("config_key,config_value").eq("installation_id",installation.id);
  for(const row of rows??[]) config[row.config_key]=row.config_value;
 }
 const {data:company}=await client.from("empresas").select("nombre,nombre_comercial,ciudad,pais,zona_horaria,metadata").eq("id",empresa_id).maybeSingle();
 return {company,installation,agent,config};
}

export async function loadAgentContext(client:any,input:AgentContextInput){
 const {data:commercial,error}=await client.rpc("atlas_commercial_context",{p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id,p_source_message_id:input.source_message_id});
 if(error)throw new Error("COMMERCIAL_CONTEXT_FAILED");
 const {data:workState}=await client.rpc("atlas_get_active_conversation_work_state_v1",{p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id});
 return {authority:{commercial,work_state:workState??null},memory_policy:{crm_is_relationship_context_only:true,prior_opportunities_auto_merge:false,event_specific_inheritance:false}};
}
