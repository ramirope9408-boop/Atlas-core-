# ATLAS Voice Sideband

Persistent server-side bridge for GPT-Live SIP/WebRTC sessions.

## Responsibility

- Attach to an already-running GPT-Live session.
- Observe input transcript fragments.
- Use `session.delegation.created.offset_ms` as the task boundary.
- Canonicalize only the transcript associated with that delegation through `atlas_register_voice_turn_v1`.
- Call the existing `atlas-agent-runtime-v1` (GPT-5.6 Sol + ATLAS tools).
- Return only the verified final text to GPT-Live using `session.commentary.append`.
- Never execute commercial mutations directly.
- Discard stale backend results when newer caller speech supersedes the active task.

## Required environment

- `OPENAI_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- optional `ATLAS_AGENT_RUNTIME_URL`

This process must run on persistent compute. Do not host it as a short-lived Supabase Edge Function.
