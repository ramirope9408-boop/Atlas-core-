import { ATLAS_AGENT_SYSTEM } from "./system-prompt.ts";
import { ATLAS_AGENT_TOOLS } from "./tool-registry.ts";

export type AgentModelRequest = {
  company_profile: Record<string, unknown>;
  context: Record<string, unknown>;
  customer_message: string;
};

export function buildAgentRequest(input:AgentModelRequest) {
  return {
    instructions: ATLAS_AGENT_SYSTEM,
    tools: ATLAS_AGENT_TOOLS,
    input: [
      {
        role: "user",
        content: JSON.stringify({
          company_profile: input.company_profile,
          canonical_context: input.context,
          customer_message: input.customer_message,
        }),
      },
    ],
  };
}

/*
 Runtime loop contract:
 1. send buildAgentRequest() to the configured agent model;
 2. execute only registered tool calls;
 3. return canonical tool results to the model;
 4. repeat with a bounded tool-call budget;
 5. persist executed actions/activity;
 6. return final natural response.
 No arbitrary SQL/model-selected endpoint execution is permitted.
*/
