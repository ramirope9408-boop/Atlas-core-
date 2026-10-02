export type AgentContextInput = {
  empresa_id: string;
  conversation_id: string;
  source_message_id: string;
};

export async function loadAgentContext(client:any, input:AgentContextInput) {
  const { data: commercial, error } = await client.rpc("atlas_commercial_context", {
    p_empresa_id: input.empresa_id,
    p_conversation_id: input.conversation_id,
    p_source_message_id: input.source_message_id,
  });
  if (error) throw new Error("COMMERCIAL_CONTEXT_FAILED");

  const { data: workState } = await client.rpc("atlas_get_active_conversation_work_state_v1", {
    p_empresa_id: input.empresa_id,
    p_conversation_id: input.conversation_id,
  });

  return {
    authority: {
      commercial,
      work_state: workState ?? null,
    },
    memory_policy: {
      crm_is_relationship_context_only: true,
      prior_opportunities_auto_merge: false,
      event_specific_inheritance: false,
    },
  };
}
