export type AgentContextInput={empresa_id:string;conversation_id:string;source_message_id:string};

export async function loadCanonicalSourceMessage(client:any,input:AgentContextInput){
 const {data,error}=await client.from("atlas_conversation_messages")
  .select("id,direction,actor_type,channel,message_type,text_content,normalized_text,transcription_status,transcription_text,transcription_model,transcription_metadata,media_id,media_mime_type,media_url,media_duration_seconds,raw_payload,created_at")
  .eq("id",input.source_message_id)
  .eq("empresa_id",input.empresa_id)
  .eq("conversation_id",input.conversation_id)
  .maybeSingle();
 if(error||!data) throw new Error("SOURCE_MESSAGE_NOT_AVAILABLE");
 if(data.direction!=="INBOUND"||data.actor_type!=="CUSTOMER") throw new Error("SOURCE_MESSAGE_NOT_CUSTOMER_INBOUND");

 const text=String(data.normalized_text??data.text_content??data.transcription_text??"").trim();
 return {
  id:data.id,
  channel:data.channel,
  message_type:data.message_type,
  text,
  transcription_status:data.transcription_status??null,
  transcription_text:data.transcription_text??null,
  transcription_model:data.transcription_model??null,
  transcription_metadata:data.transcription_metadata??null,
  media:{
   id:data.media_id??null,
   mime_type:data.media_mime_type??null,
   url:data.media_url??null,
   duration_seconds:data.media_duration_seconds??null
  },
  has_text:Boolean(text),
  raw_payload:data.raw_payload??null,
  created_at:data.created_at
 };
}

export async function loadCompanyProfile(client:any,empresa_id:string){
 const {data:installation}=await client.from("atlas_company_agent_installations")
  .select("id,agent_code,installed_version,metadata").eq("empresa_id",empresa_id).eq("installation_status","ACTIVE")
  .order("updated_at",{ascending:false}).limit(1).maybeSingle();
 const {data:agent}=await client.from("agentes")
  .select("nombre,slug,rol,descripcion,idioma_principal,personalidad_base,perfil_regional,intensidad_regional,formalidad_base,energia_base,humor_maximo,emojis_maximos,usar_diminutivos,adaptacion_automatica,proveedor_ia,modelo_ia,version")
  .eq("empresa_id",empresa_id).order("updated_at",{ascending:false}).limit(1).maybeSingle();
 const {data:persona}=await client.from("atlas_ai_personas")
  .select("persona_code,display_name,locale,region_style,role_description,tone_description,behavior_rules,allowed_expressions,discouraged_expressions,version")
  .eq("empresa_id",empresa_id).eq("active",true).order("updated_at",{ascending:false}).limit(1).maybeSingle();
 let config:Record<string,unknown>={};
 if(installation?.id){
  const {data:rows}=await client.from("atlas_company_agent_config").select("config_key,config_value").eq("installation_id",installation.id);
  for(const row of rows??[]) config[row.config_key]=row.config_value;
 }
 const {data:company}=await client.from("empresas").select("nombre,nombre_comercial,ciudad,pais,zona_horaria,metadata").eq("id",empresa_id).maybeSingle();
 return {company,installation,agent,persona,config};
}

export async function loadAgentContext(client:any,input:AgentContextInput){
 const {data:commercial,error}=await client.rpc("atlas_commercial_context",{p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id,p_source_message_id:input.source_message_id});
 if(error)throw new Error("COMMERCIAL_CONTEXT_FAILED");
 const {data:workState}=await client.rpc("atlas_get_active_conversation_work_state_v1",{p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id});
 const {data:identityContext}=await client.rpc("atlas_get_conversation_identity_context_v1",{p_empresa_id:input.empresa_id,p_conversation_id:input.conversation_id});
 const source_message=await loadCanonicalSourceMessage(client,input);
 return {
  authority:{commercial,work_state:workState??null,identity_context:identityContext??null,source_message},
  memory_policy:{
   crm_is_relationship_context_only:true,
   prior_opportunities_auto_merge:false,
   event_specific_inheritance:false,
   cross_channel_merge_requires_verified_customer_link:true,
   channel_identifiers_are_not_customer_identifiers:true
  }
 };
}
