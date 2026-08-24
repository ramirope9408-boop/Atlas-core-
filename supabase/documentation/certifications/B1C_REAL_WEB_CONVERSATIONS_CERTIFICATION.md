# Atlas Web B1C — Real Valentina Conversations Certification

## Certification status

**CERTIFIED 🔒**

- Certification code: `B1C_REAL_WEB_CONVERSATION_E2E`
- Certification date: 2026-08-24
- Tenant: FingerFood
- Empresa ID: `bf55a6aa-2e3f-4749-b2b8-135537a7c7bf`
- Authenticated OWNER: `fa8e19fa-b983-4e25-b3fa-53a3ffdf250b`
- Agent: `VALENTINA`

## Certified scope

B1C certifies the authenticated Atlas Web conversation path:

1. Atlas Web loads only the authenticated operator's Valentina conversations.
2. Atlas Web opens a personal `INTERNAL_OPERATOR` conversation.
3. Atlas Web registers a governed human `TEXT` / `INBOUND` message.
4. Atlas Web invokes `atlas-internal-orchestrator` with the authenticated session.
5. Semantic Decision creates the canonical decision.
6. Final Response registers Valentina's canonical `TEXT` / `OUTBOUND` response.
7. Atlas Web reloads and displays that response in the same conversation.

Q1–Q8 remain unchanged and were not recertified by B1C.

## Browser-safe database facade

Migration:

`20260824030000_atlas_web_internal_conversations_v1.sql`

Canonical migration SHA-256:

`B5C9FDCFE487BC0291BFC645F85785B3AC4208881D31A797535EA844AF66736B`

Installed RPCs:

- `atlas_web_list_internal_conversations(uuid, integer)`
- `atlas_web_get_internal_messages(uuid, integer)`
- `atlas_web_open_internal_conversation(uuid, text)`
- `atlas_web_register_internal_text_message(uuid, text)`

Installation assertions:

- All four RPCs exist.
- All four RPCs are `SECURITY DEFINER`.
- Anonymous execution is revoked.
- Execution is granted to `authenticated` and `service_role`.
- Conversation reads are constrained to `user_id = auth.uid()`.
- New conversations derive the canonical `VALENTINA` agent and `INTERNAL_OPERATOR` mode.
- Browser message registration derives `USER`, `INBOUND`, and `TEXT`; these fields are not caller-controlled.
- Fixture messages are excluded from the Atlas Web read contract.

## Definitive end-to-end evidence

- Conversation ID: `9a4f1a35-3138-487c-ae97-a59d7665122b`
- Source message ID: `2b8fc6fe-525a-41d5-b895-a07b9f7bbe0b`
- Decision ID: `cc66dbe5-11e1-4726-8e3d-1bf4eeadd56e`
- Final message ID: `2d9e1b23-1513-4698-a41a-c82c80f550f6`
- Conversation title: `Nueva conversación`
- Conversation mode: `INTERNAL_OPERATOR`
- Conversation status: `OPEN`

Source message:

> Hola, Valentina. Confirma que esta conversación nueva de Atlas Web B1C funciona de extremo a extremo.

Canonical Valentina response:

> Confirmado, Ramiro: la conversación nueva de Atlas Web B1C está funcionando de extremo a extremo. Tu mensaje llegó completo y aquí va la respuesta, sin despeinarse 😄

## Definitive assertions

All assertions returned `true`:

- `conversation_exists`
- `conversation_is_owner_personal`
- `conversation_is_internal_operator`
- `conversation_is_open`
- `source_message_exists`
- `source_is_atlas_web_b1c`
- `source_is_human_inbound`
- `final_message_exists`
- `final_is_valentina_outbound`
- `final_response_type_is_final`
- `final_runtime_is_canonical`
- `decision_id_present`
- `decision_id_is_uuid`
- `final_follows_source`
- `conversation_ids_match`

## Frontend implementation

The certified frontend introduces:

- A typed and Zod-validated Valentina conversation API.
- Real conversation listing and message loading through the B1C RPC facade.
- Personal conversation creation.
- Governed human message registration.
- Authenticated Orchestrator V2 invocation.
- Query invalidation and canonical response reload.
- Loading, empty, processing, and error states.
- Real authenticated company and conversation context.
- Removal of the fixed Quote Builder fixture from ordinary conversations.

## Local quality gates

- Lint: passed with 0 warnings and 0 errors.
- TypeScript type-check: passed.
- Vitest: 1 test file passed; 1 test passed.
- Production build: passed.
- Git diff check: passed.
- `.env.local`: ignored and excluded from version control.
- Frontend secret/service-role key: absent.

The Vite bundle-size warning is non-blocking for B1C and remains a future code-splitting optimization.

## Runtime recovery evidence

An initial web attempt encountered an expired/stale browser session:

- Bootstrap RPC returned HTTP 401.
- Orchestrator returned HTTP 502 as a downstream consequence.

After clearing the stale local session and authenticating again, the same governed path completed successfully. No bypass, service-role credential, manual database insertion, or fixture response was used for the definitive test.

## Explicit exclusions

B1C does not certify:

- Quote Builder selection or binding from the new web conversation.
- Arbitrary WRITE tool execution without an operational binding.
- Attachments or voice messages.
- Conversation rename, close, archive, or deletion.
- Realtime subscriptions or multi-tab synchronization.

These capabilities require their own contracts and certification. The Q8 WRITE path remains certified independently and unchanged.

## Conclusion

Atlas Web B1C is certified for authenticated, tenant-scoped, owner-personal, real Valentina text conversations from the browser through the canonical Orchestrator and Final Response path.
