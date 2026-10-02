# POC execution point

The system prompt is already source-controlled in:
`supabase/functions/atlas-agent-runtime-v1/system-prompt.ts`.

Do not paste the system prompt into n8n as the long-term architecture.

For the POC, n8n should call one ATLAS Agent Runtime endpoint with:
- empresa_id
- conversation_id
- source_message_id
- normalized customer message / media reference

The runtime loads:
1. dynamic company profile,
2. canonical opportunity context,
3. allowlisted relationship context,
4. system prompt,
5. registered tools.

Then it runs the model/tool loop and returns delivery instructions.

n8n remains transport. The prompt lives with the runtime, versioned in Git, and company-specific identity/policies are loaded dynamically.
