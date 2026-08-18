import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

// ============================================================
// ATLAS — INTERNAL FINAL RESPONSE V1
//
// Authenticated operator
// -> canonical final-response context
// -> deterministic state gate
// -> OpenAI final response when generation is authorized
// -> strict response validation
// -> canonical assistant message registration
// -> AI message audit
// -> safe runtime response
//
// SECURITY PRINCIPLES:
// - Caller supplies decision_id only.
// - Caller cannot inject empresa, conversation, persona, memory,
//   relationship, tool results, permissions or prompt.
// - Canonical context is loaded server-side.
// - No tool execution occurs here.
// - No chain-of-thought is requested or returned.
// ============================================================

const UUID_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

const ALLOWED_INPUT_KEYS = new Set([
  "decision_id",
]);

const ALLOWED_RESPONSE_KEYS = new Set([
  "response_type",
  "response_mode",
  "text_response",
  "audio_script",
  "facts_used",
  "tool_result_used",
  "humor_used",
  "seriousness_level",
  "safe_to_continue",
]);

const RESPONSE_TYPES = new Set([
  "FINAL",
  "CLARIFICATION",
  "SAFE_STOP",
]);

const RESPONSE_MODES = new Set([
  "TEXT",
  "AUDIO",
  "TEXT_PLUS_AUDIO",
]);

const SERIOUSNESS_LEVELS = new Set([
  "RELAXED",
  "NORMAL",
  "SERIOUS",
  "CRITICAL",
]);

type RequestBody = {
  decision_id?: string;
};

type FinalResponse = {
  response_type: "FINAL" | "CLARIFICATION" | "SAFE_STOP";
  response_mode: "TEXT" | "AUDIO" | "TEXT_PLUS_AUDIO";
  text_response: string | null;
  audio_script: string | null;
  facts_used: string[];
  tool_result_used: boolean;
  humor_used: boolean;
  seriousness_level:
    | "RELAXED"
    | "NORMAL"
    | "SERIOUS"
    | "CRITICAL";
  safe_to_continue: boolean;
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

function isObject(
  value: unknown,
): value is Record<string, unknown> {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value)
  );
}

function parseModelJson(
  content: string,
): unknown {
  const fenced =
    content.match(
      /```(?:json)?\s*([\s\S]*?)```/i,
    );

  const jsonText =
    fenced
      ? fenced[1].trim()
      : content.trim();

  return JSON.parse(jsonText);
}

function validateFinalResponse(
  value: unknown,
): {
  ok: boolean;
  error?: string;
  response?: FinalResponse;
} {
  if (!isObject(value)) {
    return {
      ok: false,
      error:
        "Model output must be a JSON object",
    };
  }

  for (
    const key
    of Object.keys(value)
  ) {
    if (
      !ALLOWED_RESPONSE_KEYS.has(key)
    ) {
      return {
        ok: false,
        error:
          `Unexpected response property: ${key}`,
      };
    }
  }

  for (
    const key
    of ALLOWED_RESPONSE_KEYS
  ) {
    if (!(key in value)) {
      return {
        ok: false,
        error:
          `Missing response property: ${key}`,
      };
    }
  }

  if (
    typeof value.response_type !==
      "string" ||
    !RESPONSE_TYPES.has(
      value.response_type,
    )
  ) {
    return {
      ok: false,
      error:
        "Invalid response_type",
    };
  }

  if (
    typeof value.response_mode !==
      "string" ||
    !RESPONSE_MODES.has(
      value.response_mode,
    )
  ) {
    return {
      ok: false,
      error:
        "Invalid response_mode",
    };
  }

  if (
    value.text_response !== null &&
    typeof value.text_response !==
      "string"
  ) {
    return {
      ok: false,
      error:
        "text_response must be string or null",
    };
  }

  if (
    value.audio_script !== null &&
    typeof value.audio_script !==
      "string"
  ) {
    return {
      ok: false,
      error:
        "audio_script must be string or null",
    };
  }

  if (
    !Array.isArray(
      value.facts_used,
    ) ||
    !value.facts_used.every(
      (item) =>
        typeof item === "string",
    )
  ) {
    return {
      ok: false,
      error:
        "facts_used must be an array of strings",
    };
  }

  if (
    typeof value.tool_result_used !==
      "boolean"
  ) {
    return {
      ok: false,
      error:
        "tool_result_used must be boolean",
    };
  }

  if (
    typeof value.humor_used !==
      "boolean"
  ) {
    return {
      ok: false,
      error:
        "humor_used must be boolean",
    };
  }

  if (
    typeof value.seriousness_level !==
      "string" ||
    !SERIOUSNESS_LEVELS.has(
      value.seriousness_level,
    )
  ) {
    return {
      ok: false,
      error:
        "Invalid seriousness_level",
    };
  }

  if (
    typeof value.safe_to_continue !==
      "boolean"
  ) {
    return {
      ok: false,
      error:
        "safe_to_continue must be boolean",
    };
  }

  if (
    value.response_mode === "TEXT" &&
    (
      typeof value.text_response !==
        "string" ||
      value.text_response.trim() === ""
    )
  ) {
    return {
      ok: false,
      error:
        "TEXT response requires text_response",
    };
  }

  if (
    value.response_mode === "TEXT" &&
    value.audio_script !== null
  ) {
    return {
      ok: false,
      error:
        "TEXT response requires audio_script=null",
    };
  }

  if (
    value.response_mode === "AUDIO" &&
    (
      typeof value.audio_script !==
        "string" ||
      value.audio_script.trim() === ""
    )
  ) {
    return {
      ok: false,
      error:
        "AUDIO response requires audio_script",
    };
  }

  if (
    value.response_mode ===
      "TEXT_PLUS_AUDIO" &&
    (
      typeof value.text_response !==
        "string" ||
      value.text_response.trim() === "" ||
      typeof value.audio_script !==
        "string" ||
      value.audio_script.trim() === ""
    )
  ) {
    return {
      ok: false,
      error:
        "TEXT_PLUS_AUDIO requires text_response and audio_script",
    };
  }

  return {
    ok: true,
    response:
      value as unknown as FinalResponse,
  };
}

function deterministicSafeResponse(
  context: any,
): FinalResponse {
  const decisionState =
    context?.decision_state ||
    "INVALID";

  const decision =
    context?.validated_decision ||
    {};

  const seriousness =
    SERIOUSNESS_LEVELS.has(
      decision?.seriousness_level,
    )
      ? decision.seriousness_level
      : "NORMAL";

  if (
    decisionState ===
      "CLARIFICATION"
  ) {
    const reason =
      typeof decision
          ?.clarification_reason ===
        "string" &&
      decision
        .clarification_reason
        .trim() !== ""
        ? decision
          .clarification_reason
          .trim()
        : "Necesito una aclaración antes de continuar.";

    return {
      response_type:
        "CLARIFICATION",

      response_mode:
        "TEXT",

      text_response:
        reason,

      audio_script:
        null,

      facts_used: [
        "decision_state",
        "validated_decision.clarification_required",
        "validated_decision.clarification_reason",
      ],

      tool_result_used:
        false,

      humor_used:
        false,

      seriousness_level:
        seriousness,

      safe_to_continue:
        true,
    };
  }

  if (
    decisionState === "DENIED"
  ) {
    return {
      response_type:
        "SAFE_STOP",

      response_mode:
        "TEXT",

      text_response:
        "No puedo continuar con esa acción porque la autorización requerida no está disponible.",

      audio_script:
        null,

      facts_used: [
        "decision_state",
        "validated_decision.permission_required",
        "validated_decision.permission_granted",
      ],

      tool_result_used:
        false,

      humor_used:
        false,

      seriousness_level:
        seriousness,

      safe_to_continue:
        false,
    };
  }

  const toolRequired =
    decision?.tool_required ===
    true;

  const toolExecutionStatus =
    context
      ?.canonical_tool_execution
      ?.status || null;

  if (
    toolRequired &&
    toolExecutionStatus !==
      "COMPLETED"
  ) {
    return {
      response_type:
        "SAFE_STOP",

      response_mode:
        "TEXT",

      text_response:
        "No puedo presentar un resultado final todavía porque la ejecución requerida no está completada.",

      audio_script:
        null,

      facts_used: [
        "validated_decision.tool_required",
        "canonical_tool_execution.status",
      ],

      tool_result_used:
        false,

      humor_used:
        false,

      seriousness_level:
        seriousness,

      safe_to_continue:
        false,
    };
  }

  return {
    response_type:
      "SAFE_STOP",

    response_mode:
      "TEXT",

    text_response:
      "No puedo generar una respuesta final de forma segura con el estado actual.",

    audio_script:
      null,

    facts_used: [
      "decision_state",
      "safe_to_generate",
    ],

    tool_result_used:
      false,

    humor_used:
      false,

    seriousness_level:
      seriousness,

    safe_to_continue:
      false,
  };
}

function canonicalFactReferenceExists(
  context: any,
  reference: string,
): boolean {
  if (
    typeof reference !==
      "string" ||
    reference.trim() === ""
  ) {
    return false;
  }

  const parts =
    reference.split(".");

  let cursor: any =
    context;

  for (
    const part
    of parts
  ) {
    if (
      cursor === null ||
      cursor === undefined ||
      typeof cursor !==
        "object" ||
      !(part in cursor)
    ) {
      return false;
    }

    cursor =
      cursor[part];
  }

  return true;
}

export default {
  fetch: withSupabase(
    {
      auth: "user",
    },

    async (req, ctx) => {
      try {
        // ============================================================
        // 1. METHOD
        // ============================================================

        if (
          req.method !== "POST"
        ) {
          return errorResponse(
            "METHOD_NOT_ALLOWED",
            "Method not allowed",
            405,
          );
        }

        // ============================================================
        // 2. AUTH
        // ============================================================

        if (
          ctx.authMode !== "user" ||
          !ctx.userClaims ||
          !ctx.userClaims.id
        ) {
          return errorResponse(
            "AUTH_REQUIRED",
            "Authentication required",
            401,
          );
        }

        // ============================================================
        // 3. INPUT
        // ============================================================

        let body: RequestBody;

        try {
          body =
            await req.json();
        } catch {
          return errorResponse(
            "INVALID_INPUT",
            "Invalid or missing JSON body",
            400,
          );
        }

        if (
          !isObject(body)
        ) {
          return errorResponse(
            "INVALID_INPUT",
            "JSON body must be an object",
            400,
          );
        }

        for (
          const key
          of Object.keys(body)
        ) {
          if (
            !ALLOWED_INPUT_KEYS.has(
              key,
            )
          ) {
            return errorResponse(
              "INVALID_INPUT",
              `Unexpected input property: ${key}`,
              400,
            );
          }
        }

        const decision_id =
          body.decision_id;

        if (
          !decision_id ||
          !UUID_REGEX.test(
            decision_id,
          )
        ) {
          return errorResponse(
            "INVALID_INPUT",
            "decision_id must be a valid UUID",
            400,
          );
        }

        // ============================================================
        // 4. USER-SCOPED SUPABASE
        // ============================================================

        const supabase =
          ctx.supabase;

        if (!supabase) {
          return errorResponse(
            "INTERNAL_FINAL_RESPONSE_ERROR",
            "Supabase client unavailable",
            500,
          );
        }

        // ============================================================
        // 5. CANONICAL FINAL RESPONSE CONTEXT
        // ============================================================

        const contextRes =
          await supabase.rpc(
            "atlas_internal_prepare_final_response_context",
            {
              p_decision_id:
                decision_id,
            },
          );

        if (contextRes.error) {
          return errorResponse(
            "FINAL_CONTEXT_FAILED",
            "Final response context preparation failed",
            502,
          );
        }

        const context =
          contextRes.data;

        if (
          !context ||
          !isObject(context)
        ) {
          return errorResponse(
            "INVALID_FINAL_CONTEXT",
            "Invalid final response context",
            502,
          );
        }

        if (
          typeof context.error ===
            "string"
        ) {
          const canonicalError =
            context.error;

          if (
            canonicalError ===
              "AUTH_REQUIRED"
          ) {
            return errorResponse(
              "AUTH_REQUIRED",
              "Authentication required",
              401,
            );
          }

          if (
            canonicalError ===
              "OWNER_MISMATCH" ||
            canonicalError ===
              "NO_EMPRESA_ACCESS"
          ) {
            return errorResponse(
              "FINAL_CONTEXT_FAILED",
              "Decision is not available to the authenticated operator",
              403,
            );
          }

          if (
            canonicalError ===
              "DECISION_NOT_FOUND"
          ) {
            return errorResponse(
              "FINAL_CONTEXT_FAILED",
              "Decision not found",
              404,
            );
          }

          return errorResponse(
            "FINAL_CONTEXT_FAILED",
            "Canonical final response context is unavailable",
            502,
          );
        }

        const empresa_id =
          context.empresa_id;

        const conversation_id =
          context.conversation_id;

        const agent_code =
          context.agent_code;

        const canonicalDecisionId =
          context.decision_id;

        const decision =
          context.validated_decision;

        if (
          typeof empresa_id !==
            "string" ||
          typeof conversation_id !==
            "string" ||
          typeof agent_code !==
            "string" ||
          typeof canonicalDecisionId !==
            "string" ||
          !isObject(decision)
        ) {
          return errorResponse(
            "INVALID_FINAL_CONTEXT",
            "Canonical identifiers or decision are missing",
            502,
          );
        }

        if (
          canonicalDecisionId !==
            decision_id
        ) {
          return errorResponse(
            "INVALID_FINAL_CONTEXT",
            "Canonical decision mismatch",
            502,
          );
        }

        // ============================================================
        // 6. DETERMINE GENERATION PATH
        // ============================================================

        const decisionState =
          typeof context
              .decision_state ===
            "string"
            ? context
              .decision_state
            : "INVALID";

        const safeToGenerate =
          context
            .safe_to_generate ===
          true;

        let finalResponse:
          FinalResponse;

        let provider_response_id:
          string | null =
          null;

        let modelName =
          "DETERMINISTIC";

        // ============================================================
        // 7. VALID + SAFE => MODEL GENERATION
        // ============================================================

        if (
          decisionState ===
            "VALID" &&
          safeToGenerate === true
        ) {
          const promptContract =
            context
              .prompt_contract;

          if (
            !promptContract ||
            !isObject(
              promptContract,
            )
          ) {
            return errorResponse(
              "PROMPT_CONTRACT_FAILED",
              "Canonical prompt contract unavailable",
              502,
            );
          }

          const systemPrompt =
            typeof promptContract
                .system_prompt ===
              "string"
              ? promptContract
                .system_prompt
              : "";

          if (
            systemPrompt.trim() ===
            ""
          ) {
            return errorResponse(
              "PROMPT_CONTRACT_FAILED",
              "Prompt contract has no system prompt",
              502,
            );
          }

          const OPENAI_API_KEY =
            Deno.env.get(
              "OPENAI_API_KEY",
            );

          const OPENAI_MODEL =
            Deno.env.get(
              "OPENAI_MODEL",
            );

          if (
            !OPENAI_API_KEY ||
            !OPENAI_MODEL
          ) {
            return errorResponse(
              "INTERNAL_FINAL_RESPONSE_ERROR",
              "AI provider configuration unavailable",
              500,
            );
          }

          modelName =
            OPENAI_MODEL;

          const providerPayload = {
            canonical_context:
              context,

            output_contract: {
              response_type:
                "FINAL|CLARIFICATION|SAFE_STOP",

              response_mode:
                "TEXT|AUDIO|TEXT_PLUS_AUDIO",

              text_response:
                "string|null",

              audio_script:
                "string|null",

              facts_used:
                [
                  "canonical.field.reference",
                ],

              tool_result_used:
                "boolean",

              humor_used:
                "boolean",

              seriousness_level:
                "RELAXED|NORMAL|SERIOUS|CRITICAL",

              safe_to_continue:
                "boolean",
            },

            runtime_rules: [
              "Return JSON only.",
              "Return exactly the required fields and no extra fields.",
              "Do not expose chain-of-thought or hidden reasoning.",
              "Use only canonical facts contained in canonical_context.",
              "facts_used must contain canonical field references only.",
              "Do not recalculate canonical amounts.",
              "Do not invent missing facts.",
              "Do not convert quoted values into confirmed sales or confirmed revenue.",
              "Persona and relationship affect style only, never truth or authority.",
              "Do not change the validated decision.",
              "Do not grant permissions.",
              "Do not execute tools.",
              "If seriousness is SERIOUS or CRITICAL, humor_used must be false.",
            ],
          };

          const openaiResp =
            await fetch(
              "https://api.openai.com/v1/chat/completions",
              {
                method:
                  "POST",

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
                            providerPayload,
                          ),
                      },
                    ],

                    max_completion_tokens:
                      900,
                  }),
              },
            );

          if (!openaiResp.ok) {
            let providerCode =
              "OPENAI_REQUEST_FAILED";

            let providerMessage =
              `OpenAI responded with status ${openaiResp.status}`;

            try {
              const providerError:
                any =
                await openaiResp
                  .json();

              const errorObject =
                providerError
                  ?.error;

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
              // Never expose raw provider payloads.
            }

            return errorResponse(
              "FINAL_MODEL_FAILED",
              `${providerCode}: ${providerMessage}`,
              502,
            );
          }

          const openaiJson:
            any =
            await openaiResp.json();

          provider_response_id =
            typeof openaiJson?.id ===
              "string"
              ? openaiJson.id
              : null;

          const assistantContent =
            openaiJson
              ?.choices
              ?.[0]
              ?.message
              ?.content;

          if (
            typeof assistantContent !==
              "string" ||
            assistantContent
              .trim() === ""
          ) {
            return errorResponse(
              "FINAL_MODEL_EMPTY_OUTPUT",
              "AI provider returned empty output",
              502,
            );
          }

          let parsed:
            unknown;

          try {
            parsed =
              parseModelJson(
                assistantContent,
              );
          } catch {
            return errorResponse(
              "FINAL_MODEL_INVALID_JSON",
              "AI provider output is not valid JSON",
              502,
            );
          }

          const validation =
            validateFinalResponse(
              parsed,
            );

          if (
            !validation.ok ||
            !validation.response
          ) {
            return errorResponse(
              "FINAL_MODEL_INVALID_JSON",
              validation.error ||
                "Invalid final response",
              502,
            );
          }

          finalResponse =
            validation.response;

          // ==========================================================
          // 7.1 VALID STATE MUST PRODUCE FINAL
          // ==========================================================

          if (
            finalResponse
              .response_type !==
            "FINAL"
          ) {
            return errorResponse(
              "FINAL_MODEL_INVALID_JSON",
              "VALID canonical state requires FINAL response_type",
              502,
            );
          }

          // ==========================================================
          // 7.2 CANONICAL TOOL RESULT ENFORCEMENT
          // ==========================================================

          const canonicalToolUsed =
            context
              .tool_result_used ===
            true;

          if (
            finalResponse
              .tool_result_used !==
            canonicalToolUsed
          ) {
            return errorResponse(
              "FINAL_MODEL_INVALID_JSON",
              "tool_result_used does not match canonical context",
              502,
            );
          }

          // ==========================================================
          // 7.3 FACT REFERENCE ENFORCEMENT
          // ==========================================================

          for (
            const reference
            of finalResponse
              .facts_used
          ) {
            if (
              !canonicalFactReferenceExists(
                context,
                reference,
              )
            ) {
              return errorResponse(
                "FINAL_MODEL_INVALID_JSON",
                `Unknown canonical fact reference: ${reference}`,
                502,
              );
            }
          }

          // ==========================================================
          // 7.4 SERIOUSNESS IS CANONICAL
          // ==========================================================

          const canonicalSeriousness =
            typeof decision
                .seriousness_level ===
              "string" &&
            SERIOUSNESS_LEVELS.has(
              decision
                .seriousness_level,
            )
              ? decision
                .seriousness_level
              : "NORMAL";

          finalResponse
            .seriousness_level =
            canonicalSeriousness as
              FinalResponse[
                "seriousness_level"
              ];

          if (
            canonicalSeriousness ===
              "SERIOUS" ||
            canonicalSeriousness ===
              "CRITICAL"
          ) {
            finalResponse
              .humor_used =
              false;
          }

          // ==========================================================
          // 7.5 RESPONSE MODE CANNOT EXCEED CANONICAL DECISION
          // ==========================================================

          const canonicalMode =
            typeof decision
                .response_mode ===
              "string" &&
            RESPONSE_MODES.has(
              decision
                .response_mode,
            )
              ? decision
                .response_mode
              : "TEXT";

          if (
            finalResponse
              .response_mode !==
            canonicalMode
          ) {
            // V1 normalizes to TEXT rather than inventing audio.
            finalResponse
              .response_mode =
              "TEXT";

            finalResponse
              .audio_script =
              null;

            if (
              !finalResponse
                .text_response &&
              typeof finalResponse
                  .audio_script ===
                "string"
            ) {
              finalResponse
                .text_response =
                finalResponse
                  .audio_script;
            }
          }

          // Final V1 must always have visible text
          // because atlas_internal_messages supports TEXT/AUDIO,
          // not TEXT_PLUS_AUDIO as a stored message type.
          if (
            typeof finalResponse
                .text_response !==
              "string" ||
            finalResponse
              .text_response
              .trim() === ""
          ) {
            return errorResponse(
              "FINAL_MODEL_INVALID_JSON",
              "Final response requires text_response for canonical registration",
              502,
            );
          }
        } else {
          // ==========================================================
          // 8. UNSAFE STATES => DETERMINISTIC RESPONSE
          // ==========================================================

          finalResponse =
            deterministicSafeResponse(
              context,
            );
        }

        // ============================================================
        // 9. REGISTER CANONICAL AGENT MESSAGE
        // ============================================================

        const messageMetadata = {
          runtime:
            "INTERNAL_FINAL_RESPONSE_V1",

          decision_id,

          response_type:
            finalResponse
              .response_type,

          response_mode:
            finalResponse
              .response_mode,

          tool_result_used:
            finalResponse
              .tool_result_used,

          seriousness_level:
            finalResponse
              .seriousness_level,

          provider_response_id,

          prompt_contract_code:
            context
              ?.prompt_contract
              ?.contract_code ||
            "INTERNAL_FINAL_RESPONSE",

          prompt_contract_version:
            context
              ?.prompt_contract
              ?.version ||
            null,
        };

        const registerRes =
          await supabase.rpc(
            "atlas_internal_register_message",
            {
              p_empresa_id:
                empresa_id,

              p_conversation_id:
                conversation_id,

              p_actor_type:
                "AGENT",

              p_direction:
                "OUTBOUND",

              p_message_type:
                "TEXT",

              p_text_content:
                finalResponse
                  .text_response,

              p_audio_reference:
                null,

              p_transcription_text:
                null,

              p_transcription_metadata:
                {},

              p_metadata:
                messageMetadata,

              p_agent_code:
                agent_code,
            },
          );

        if (
          registerRes.error
        ) {
          return errorResponse(
            "MESSAGE_REGISTRATION_FAILED",
            "Final assistant message registration failed",
            502,
          );
        }

        const registration =
          registerRes.data;

        const registered_message_id =
          registration
            ?.message_id;

        if (
          typeof registered_message_id !==
            "string"
        ) {
          return errorResponse(
            "MESSAGE_REGISTRATION_FAILED",
            "Message registration returned no message_id",
            502,
          );
        }

        // ============================================================
        // 10. REGISTER AI MESSAGE AUDIT
        // ============================================================

        const selectedToolCode =
          typeof decision
              .selected_tool_code ===
            "string"
            ? decision
              .selected_tool_code
            : null;

        const requiredTools =
          selectedToolCode
            ? [selectedToolCode]
            : [];

        const auditMetadata = {
          runtime:
            "INTERNAL_FINAL_RESPONSE_V1",

          decision_id,

          source_message_id:
            context
              ?.current_message
              ?.message_id ||
            null,

          tool_request_id:
            context
              ?.canonical_tool_execution
              ?.tool_request_id ||
            null,

          provider_response_id,

          prompt_contract_code:
            context
              ?.prompt_contract
              ?.contract_code ||
            "INTERNAL_FINAL_RESPONSE",

          prompt_contract_version:
            context
              ?.prompt_contract
              ?.version ||
            null,

          facts_used:
            finalResponse
              .facts_used,

          tool_result_used:
            finalResponse
              .tool_result_used,

          humor_used:
            finalResponse
              .humor_used,

          safe_to_continue:
            finalResponse
              .safe_to_continue,

          decision_state:
            decisionState,
        };

        const auditRes =
          await supabase.rpc(
            "atlas_register_ai_message_audit",
            {
              p_empresa_id:
                empresa_id,

              p_conversation_id:
                conversation_id,

              p_ai_message_id:
                registered_message_id,

              p_agent_code:
                agent_code,

              p_model_name:
                modelName,

              p_original_reply_text:
                finalResponse
                  .text_response,

              p_final_reply_text:
                finalResponse
                  .text_response,

              p_reply_safety_status:
                finalResponse
                    .response_type ===
                  "SAFE_STOP"
                  ? "SAFE_STOP"
                  : "PASS",

              p_reply_rewrite_applied:
                false,

              p_reply_rewrite_reason:
                null,

              p_tool_enforcement_applied:
                false,

              p_tool_enforcement_reason:
                null,

              p_original_tool_required:
                decision
                  .tool_required ===
                true,

              p_original_required_tools:
                requiredTools,

              p_final_tool_required:
                finalResponse
                  .tool_result_used,

              p_final_required_tools:
                finalResponse
                    .tool_result_used
                  ? requiredTools
                  : [],

              p_response_mode:
                finalResponse
                  .response_mode,

              p_intent:
                typeof decision
                    .intent_code ===
                  "string"
                  ? decision
                    .intent_code
                  : null,

              p_sentiment:
                null,

              p_issue_type:
                finalResponse
                    .response_type ===
                  "SAFE_STOP"
                  ? "FINAL_RESPONSE_SAFE_STOP"
                  : null,

              p_issue_severity:
                finalResponse
                    .response_type ===
                  "SAFE_STOP"
                  ? finalResponse
                    .seriousness_level
                  : null,

              p_human_handoff_required:
                false,

              p_handoff_reason:
                null,

              p_external_context_required:
                false,

              p_external_context_types:
                [],

              p_learning_signal:
                {
                  runtime:
                    "INTERNAL_FINAL_RESPONSE_V1",

                  response_type:
                    finalResponse
                      .response_type,
                },

              p_metadata:
                auditMetadata,
            },
          );

        if (
          auditRes.error
        ) {
          return errorResponse(
            "AUDIT_FAILED",
            "Final response was registered but AI audit registration failed",
            502,
          );
        }

        const audit_id =
          auditRes.data
            ?.audit_id ||
          null;

        // ============================================================
        // 11. SAFE RETURN
        // ============================================================

        return jsonResponse({
          runtime_version:
            "INTERNAL_FINAL_RESPONSE_V1",

          decision_id,

          empresa_id,

          conversation_id,

          agent_code,

          response:
            finalResponse,

          registered_message_id,

          audit_id,

          provider_response_id,

          prompt_contract_code:
            context
              ?.prompt_contract
              ?.contract_code ||
            "INTERNAL_FINAL_RESPONSE",

          prompt_contract_version:
            context
              ?.prompt_contract
              ?.version ||
            null,
        });
      } catch {
        return errorResponse(
          "INTERNAL_FINAL_RESPONSE_ERROR",
          "Internal final response runtime error",
          500,
        );
      }
    },
  ),
};