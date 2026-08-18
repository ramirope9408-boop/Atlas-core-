import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

// SEMANTIC_LLM_EXECUTION V1 for ATLAS_AGENT_STANDARD V1
//
// Pipeline:
// Authenticated operator
// -> atlas_internal_prepare_decision_context
// -> atlas_get_prompt_contract
// -> OpenAI semantic decision
// -> atlas_internal_validate_decision
// -> semantic proposal + validated decision + next_action

const UUID_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

type RequestBody = {
  empresa_id?: string;
  conversation_id?: string;
};

function jsonResponse(
  body: unknown,
  status = 200,
) {
  return new Response(
    JSON.stringify(body),
    {
      status,
      headers: {
        "Content-Type": "application/json",
      },
    },
  );
}

function errorResponse(
  code: string,
  message: string,
  status = 400,
) {
  return jsonResponse(
    {
      error: code,
      message,
    },
    status,
  );
}

export default {
  fetch: withSupabase(
    {
      auth: "user",
    },

    async (req, ctx) => {
      try {
        // ============================================================
        // 0. METHOD
        // ============================================================

        if (req.method !== "POST") {
          return errorResponse(
            "METHOD_NOT_ALLOWED",
            "Method not allowed",
            405,
          );
        }

        // ============================================================
        // 1. AUTHENTICATED OPERATOR
        // ============================================================

        const authMode =
          ctx.authMode;

        const userClaims =
          ctx.userClaims;

        if (
          authMode !== "user" ||
          !userClaims ||
          !userClaims.id
        ) {
          return errorResponse(
            "AUTH_REQUIRED",
            "Authentication required",
            401,
          );
        }

        // ============================================================
        // 2. INPUT
        // ============================================================

        let body: RequestBody = {};

        try {
          body = await req.json();
        } catch {
          return errorResponse(
            "MISSING_REQUIRED_INPUT",
            "Invalid or missing JSON body",
            400,
          );
        }

        const {
          empresa_id,
          conversation_id,
        } = body;

        if (
          !empresa_id ||
          !conversation_id
        ) {
          return errorResponse(
            "MISSING_REQUIRED_INPUT",
            "empresa_id and conversation_id are required",
            400,
          );
        }

        if (
          !UUID_REGEX.test(empresa_id) ||
          !UUID_REGEX.test(conversation_id)
        ) {
          return errorResponse(
            "MISSING_REQUIRED_INPUT",
            "empresa_id and conversation_id must be valid UUIDs",
            400,
          );
        }

        // ============================================================
        // 3. USER-SCOPED SUPABASE CLIENT
        // ============================================================

        const supabase =
          ctx.supabase;

        if (!supabase) {
          return errorResponse(
            "SERVER_CONFIGURATION_ERROR",
            "Supabase client not available in runtime",
            500,
          );
        }

        // ============================================================
        // 4. PREPARE CANONICAL DECISION CONTEXT
        // ============================================================

        const prepareRes =
          await supabase.rpc(
            "atlas_internal_prepare_decision_context",
            {
              p_empresa_id:
                empresa_id,

              p_conversation_id:
                conversation_id,

              p_memory_limit:
                30,
            },
          );

        if (prepareRes.error) {
          return errorResponse(
            "DECISION_CONTEXT_FAILED",
            "Decision context preparation failed",
            502,
          );
        }

        const decisionContext =
          prepareRes.data;

        if (!decisionContext) {
          return errorResponse(
            "INVALID_DECISION_CONTEXT",
            "Empty decision context",
            502,
          );
        }

        if (
          decisionContext
            .identity_verified !== true
        ) {
          return errorResponse(
            "IDENTITY_NOT_VERIFIED",
            "Operator identity not verified in decision context",
            403,
          );
        }

        const source_message_id =
          decisionContext
            ?.current_message
            ?.message_id;

        if (!source_message_id) {
          return errorResponse(
            "INVALID_DECISION_CONTEXT",
            "current_message.message_id missing",
            502,
          );
        }

        // ============================================================
        // 5. RESOLVE PROMPT CONTRACT
        // ============================================================

        const contractRes =
          await supabase.rpc(
            "atlas_get_prompt_contract",
            {
              p_empresa_id:
                empresa_id,

              p_contract_code:
                "INTERNAL_SEMANTIC_DECISION",

              p_agent_code:
                decisionContext
                  .agent_code || null,
            },
          );

        if (contractRes.error) {
          return errorResponse(
            "PROMPT_CONTRACT_FAILED",
            "Prompt contract resolution failed",
            502,
          );
        }

        const promptContract =
          contractRes.data;

        if (!promptContract) {
          return errorResponse(
            "PROMPT_CONTRACT_FAILED",
            "Empty prompt contract",
            502,
          );
        }

        const systemPrompt =
          promptContract
            .system_prompt || "";

        const prompt_contract_code =
          promptContract
            .contract_code || null;

        const prompt_contract_version =
          promptContract
            .version || null;

        const prompt_resolution_level =
          promptContract
            .resolution || null;

        // ============================================================
        // 6. OPENAI CONFIGURATION
        // ============================================================

        const OPENAI_API_KEY =
          Deno.env.get(
            "OPENAI_API_KEY",
          );

        const OPENAI_MODEL =
          Deno.env.get(
            "OPENAI_MODEL",
          );

        if (!OPENAI_API_KEY) {
          return errorResponse(
            "SERVER_CONFIGURATION_ERROR",
            "OPENAI_API_KEY not configured",
            500,
          );
        }

        if (!OPENAI_MODEL) {
          return errorResponse(
            "SERVER_CONFIGURATION_ERROR",
            "OPENAI_MODEL not configured",
            500,
          );
        }

        // ============================================================
        // 7. BUILD SEMANTIC REQUEST
        // ============================================================

        const userPayload = {
          decision_context:
            decisionContext,

          instructions:
            "Produce a strict JSON object containing only the keys specified: " +
            "intent_code (string), " +
            "confidence (0-1 number), " +
            "tool_required (boolean), " +
            "selected_tool_code (string|null), " +
            "clarification_required (boolean), " +
            "clarification_reason (string|null), " +
            "seriousness_level (RELAXED|NORMAL|SERIOUS|CRITICAL), " +
            "humor_allowed (boolean), " +
            "response_mode (TEXT|AUDIO|TEXT_PLUS_AUDIO). " +
            "Do not add extra fields.",
        };

        // ============================================================
        // 8. OPENAI
        // ============================================================

        const openaiResp =
          await fetch(
            "https://api.openai.com/v1/chat/completions",
            {
              method: "POST",

              headers: {
                Authorization:
                  `Bearer ${OPENAI_API_KEY}`,

                "Content-Type":
                  "application/json",
              },

              body:
                JSON.stringify({
                  model:
                    OPENAI_MODEL,

                  messages: [
                    {
                      role:
                        "system",

                      content:
                        systemPrompt,
                    },

                    {
                      role:
                        "user",

                      content:
                        JSON.stringify(
                          userPayload,
                        ),
                    },
                  ],

                  // GPT-5.6 Chat Completions:
                  // use max_completion_tokens rather
                  // than legacy max_tokens.
                  max_completion_tokens:
                    512,
                }),
            },
          );

        // ============================================================
        // 8.1 SAFE PROVIDER ERROR DIAGNOSTIC
        // ============================================================

        if (!openaiResp.ok) {
          let providerCode =
            "OPENAI_REQUEST_FAILED";

          let providerMessage =
            `OpenAI responded with status ${openaiResp.status}`;

          try {
            const providerError:
              any =
              await openaiResp.json();

            const errorObject =
              providerError?.error;

            if (
              errorObject &&
              typeof errorObject ===
                "object"
            ) {
              if (
                typeof errorObject
                    .code ===
                  "string" &&
                errorObject.code
              ) {
                providerCode =
                  errorObject.code;
              } else if (
                typeof errorObject
                    .type ===
                  "string" &&
                errorObject.type
              ) {
                providerCode =
                  errorObject.type;
              }

              if (
                typeof errorObject
                    .message ===
                  "string" &&
                errorObject.message
              ) {
                providerMessage =
                  errorObject.message;
              }
            }
          } catch {
            // Never expose raw provider responses,
            // headers, credentials or stack traces.
          }

          return errorResponse(
            "SEMANTIC_MODEL_FAILED",
            `${providerCode}: ${providerMessage}`,
            502,
          );
        }

        // ============================================================
        // 9. OPENAI SUCCESS RESPONSE
        // ============================================================

        const openaiJson:
          any =
          await openaiResp.json();

        const provider_response_id =
          openaiJson?.id || null;

        const assistantContent =
          openaiJson
            ?.choices
            ?.[0]
            ?.message
            ?.content || null;

        if (!assistantContent) {
          return errorResponse(
            "SEMANTIC_MODEL_EMPTY_OUTPUT",
            "OpenAI returned empty assistant content",
            502,
          );
        }

        // ============================================================
        // 10. STRICT JSON PARSING
        // ============================================================

        let semanticProposal:
          any = null;

        try {
          const jsonMatch =
            assistantContent.match(
              /```(?:json)?\s*([\s\S]*?)```/i,
            );

          const jsonText =
            jsonMatch
              ? jsonMatch[1].trim()
              : assistantContent.trim();

          semanticProposal =
            JSON.parse(
              jsonText,
            );
        } catch {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "OpenAI output is not valid JSON",
            502,
          );
        }

        if (
          !semanticProposal ||
          typeof semanticProposal !==
            "object" ||
          Array.isArray(
            semanticProposal,
          )
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "OpenAI output must be a JSON object",
            502,
          );
        }

        // ============================================================
        // 11. ALLOWED OUTPUT KEYS
        // ============================================================

        const allowedKeys =
          new Set([
            "intent_code",
            "confidence",
            "tool_required",
            "selected_tool_code",
            "clarification_required",
            "clarification_reason",
            "seriousness_level",
            "humor_allowed",
            "response_mode",
          ]);

        const proposalKeys =
          Object.keys(
            semanticProposal,
          );

        for (
          const key
          of proposalKeys
        ) {
          if (
            !allowedKeys.has(key)
          ) {
            return errorResponse(
              "SEMANTIC_MODEL_INVALID_JSON",
              `Unexpected property in model output: ${key}`,
              502,
            );
          }
        }

        // ============================================================
        // 12. TYPE VALIDATION
        // ============================================================

        if (
          typeof semanticProposal
              .intent_code !==
            "string"
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "intent_code must be string",
            502,
          );
        }

        if (
          typeof semanticProposal
              .confidence !==
            "number" ||
          semanticProposal
              .confidence < 0 ||
          semanticProposal
              .confidence > 1
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "confidence must be number between 0 and 1",
            502,
          );
        }

        if (
          typeof semanticProposal
              .tool_required !==
            "boolean"
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "tool_required must be boolean",
            502,
          );
        }

        if (
          semanticProposal
              .selected_tool_code !==
            null &&
          typeof semanticProposal
              .selected_tool_code !==
            "string"
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "selected_tool_code must be string or null",
            502,
          );
        }

        if (
          typeof semanticProposal
              .clarification_required !==
            "boolean"
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "clarification_required must be boolean",
            502,
          );
        }

        if (
          semanticProposal
              .clarification_reason !==
            null &&
          typeof semanticProposal
              .clarification_reason !==
            "string"
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "clarification_reason must be string or null",
            502,
          );
        }

        const seriousnessAllowed =
          new Set([
            "RELAXED",
            "NORMAL",
            "SERIOUS",
            "CRITICAL",
          ]);

        if (
          !seriousnessAllowed.has(
            semanticProposal
              .seriousness_level,
          )
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "seriousness_level invalid",
            502,
          );
        }

        if (
          typeof semanticProposal
              .humor_allowed !==
            "boolean"
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "humor_allowed must be boolean",
            502,
          );
        }

        const responseModeAllowed =
          new Set([
            "TEXT",
            "AUDIO",
            "TEXT_PLUS_AUDIO",
          ]);

        if (
          !responseModeAllowed.has(
            semanticProposal
              .response_mode,
          )
        ) {
          return errorResponse(
            "SEMANTIC_MODEL_INVALID_JSON",
            "response_mode invalid",
            502,
          );
        }

        // ============================================================
        // 13. CANONICAL VALIDATOR
        // ============================================================

        const validateRes =
          await supabase.rpc(
            "atlas_internal_validate_decision",
            {
              p_empresa_id:
                empresa_id,

              p_conversation_id:
                conversation_id,

              p_source_message_id:
                source_message_id,

              p_intent_code:
                semanticProposal
                  .intent_code,

              p_confidence:
                semanticProposal
                  .confidence,

              p_tool_required:
                semanticProposal
                  .tool_required,

              p_selected_tool_code:
                semanticProposal
                  .selected_tool_code,

              p_clarification_required:
                semanticProposal
                  .clarification_required,

              p_clarification_reason:
                semanticProposal
                  .clarification_reason,

              p_seriousness_level:
                semanticProposal
                  .seriousness_level,

              p_humor_allowed:
                semanticProposal
                  .humor_allowed,

              p_response_mode:
                semanticProposal
                  .response_mode,

              p_decision_metadata: {
                runtime:
                  "SEMANTIC_LLM_EXECUTION_V1",

                model:
                  OPENAI_MODEL,

                prompt_contract_code,

                prompt_contract_version,

                prompt_resolution_level,

                provider_response_id,
              },
            },
          );

        if (validateRes.error) {
          return errorResponse(
            "DECISION_VALIDATION_FAILED",
            "Decision validation failed",
            502,
          );
        }

        const validatedDecision =
          validateRes.data;

        if (!validatedDecision) {
          return errorResponse(
            "DECISION_VALIDATION_FAILED",
            "Empty validation response",
            502,
          );
        }

        // ============================================================
        // 14. NEXT ACTION
        // ============================================================

        let next_action =
          "STOP";

        if (
          validatedDecision
            .clarification_required ===
            true
        ) {
          next_action =
            "GENERATE_CLARIFICATION";
        } else if (
          validatedDecision
              .safe_to_execute ===
            true &&
          validatedDecision
              .tool_required ===
            true
        ) {
          next_action =
            "EXECUTE_TOOL";
        } else if (
          validatedDecision
              .safe_to_execute ===
            true &&
          validatedDecision
              .tool_required ===
            false
        ) {
          next_action =
            "GENERATE_FINAL_RESPONSE";
        }

        // ============================================================
        // 15. SUCCESS
        // ============================================================

        return jsonResponse({
          semantic_proposal:
            semanticProposal,

          validated_decision:
            validatedDecision,

          next_action,
        });
      } catch {
        // Never leak secrets, stack traces,
        // provider payloads or raw DB errors.

        return errorResponse(
          "INTERNAL_SEMANTIC_RUNTIME_ERROR",
          "Internal semantic runtime error",
          500,
        );
      }
    },
  ),
};