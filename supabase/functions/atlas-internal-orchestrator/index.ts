import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

// ============================================================
// ATLAS - INTERNAL ORCHESTRATOR V1
//
// Authenticated operator
// -> Semantic Decision
// -> optional canonical Tool Executor
// -> Final Response
//
// PRINCIPLES:
// - Orchestrator does not reason.
// - Orchestrator does not invent decisions.
// - Orchestrator does not execute business logic directly.
// - Semantic Decision owns intent/decision.
// - Tool Executor owns canonical tool execution.
// - Final Response owns user-facing response.
// - Original authenticated user JWT is forwarded downstream.
// ============================================================

const UUID_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

const ALLOWED_INPUT_KEYS = new Set([
  "empresa_id",
  "conversation_id",
]);

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
  stage?: string,
) {
  return jsonResponse(
    {
      error: code,
      message,
      ...(stage ? { stage } : {}),
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

async function readJsonResponse(
  response: Response,
): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return null;
  }
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

        if (req.method !== "POST") {
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

        const authorization =
          req.headers.get("Authorization");

        if (
          !authorization ||
          !authorization.startsWith("Bearer ")
        ) {
          return errorResponse(
            "AUTH_REQUIRED",
            "Authenticated bearer token missing",
            401,
          );
        }

        // ============================================================
        // 3. INPUT
        // ============================================================

        let body: RequestBody;

        try {
          body = await req.json();
        } catch {
          return errorResponse(
            "INVALID_INPUT",
            "Invalid or missing JSON body",
            400,
          );
        }

        if (!isObject(body)) {
          return errorResponse(
            "INVALID_INPUT",
            "JSON body must be an object",
            400,
          );
        }

        for (const key of Object.keys(body)) {
          if (!ALLOWED_INPUT_KEYS.has(key)) {
            return errorResponse(
              "INVALID_INPUT",
              `Unexpected input field: ${key}`,
              400,
            );
          }
        }

        const empresa_id =
          body.empresa_id;

        const conversation_id =
          body.conversation_id;

        if (
          !empresa_id ||
          !conversation_id ||
          !UUID_REGEX.test(empresa_id) ||
          !UUID_REGEX.test(conversation_id)
        ) {
          return errorResponse(
            "INVALID_INPUT",
            "empresa_id and conversation_id must be valid UUIDs",
            400,
          );
        }

        // ============================================================
        // 4. INTERNAL ENDPOINT CONFIG
        // ============================================================

        const supabaseUrl =
          Deno.env.get("SUPABASE_URL");

        const anonKey =
          Deno.env.get("SUPABASE_ANON_KEY");

        if (
          !supabaseUrl ||
          !anonKey
        ) {
          return errorResponse(
            "ORCHESTRATOR_CONFIG_ERROR",
            "Internal runtime configuration unavailable",
            500,
          );
        }

        const baseUrl =
          supabaseUrl.replace(/\/$/, "");

        const downstreamHeaders = {
          Authorization:
            authorization,

          apikey:
            anonKey,

          "Content-Type":
            "application/json",
        };

        // ============================================================
        // 5. SEMANTIC DECISION
        // ============================================================

        const semanticResponse =
          await fetch(
            `${baseUrl}/functions/v1/atlas-internal-semantic-decision`,
            {
              method: "POST",
              headers:
                downstreamHeaders,
              body: JSON.stringify({
                empresa_id,
                conversation_id,
              }),
            },
          );

        const semanticBody =
          await readJsonResponse(
            semanticResponse,
          );

        if (
          !semanticResponse.ok ||
          !isObject(semanticBody)
        ) {
          return errorResponse(
            "SEMANTIC_STAGE_FAILED",
            "Semantic decision stage failed",
            502,
            "SEMANTIC_DECISION",
          );
        }

        const validatedDecision =
          semanticBody
            .validated_decision;

        const nextAction =
          semanticBody
            .next_action;

        if (
          !isObject(validatedDecision)
        ) {
          return errorResponse(
            "INVALID_SEMANTIC_CONTRACT",
            "validated_decision missing from semantic response",
            502,
            "SEMANTIC_DECISION",
          );
        }

        const decisionId =
          validatedDecision
            .decision_id;

        if (
          typeof decisionId !== "string" ||
          !UUID_REGEX.test(decisionId)
        ) {
          return errorResponse(
            "INVALID_SEMANTIC_CONTRACT",
            "validated_decision.decision_id must be a valid UUID",
            502,
            "SEMANTIC_DECISION",
          );
        }

        if (
          typeof nextAction !== "string"
        ) {
          return errorResponse(
            "INVALID_SEMANTIC_CONTRACT",
            "next_action missing from semantic response",
            502,
            "SEMANTIC_DECISION",
          );
        }

        // ============================================================
        // 6. OPTIONAL TOOL EXECUTION
        // ============================================================

        let toolExecution:
          unknown = null;

        if (
          nextAction ===
            "EXECUTE_TOOL"
        ) {
          const toolResponse =
            await fetch(
              `${baseUrl}/rest/v1/rpc/atlas_internal_execute_tool`,
              {
                method: "POST",
                headers:
                  downstreamHeaders,
                body: JSON.stringify({
                  p_decision_id:
                    decisionId,
                }),
              },
            );

          toolExecution =
            await readJsonResponse(
              toolResponse,
            );

          if (!toolResponse.ok) {
            return errorResponse(
              "TOOL_STAGE_FAILED",
              "Canonical tool executor request failed",
              502,
              "TOOL_EXECUTOR",
            );
          }

          if (!isObject(toolExecution)) {
            return errorResponse(
              "INVALID_TOOL_CONTRACT",
              "Tool executor returned an invalid response",
              502,
              "TOOL_EXECUTOR",
            );
          }

          const toolDecisionId =
            toolExecution
              .decision_id;

          if (
            typeof toolDecisionId !==
              "string" ||
            toolDecisionId !==
              decisionId
          ) {
            return errorResponse(
              "INVALID_TOOL_CONTRACT",
              "Tool executor decision mismatch",
              502,
              "TOOL_EXECUTOR",
            );
          }
        }

        // ============================================================
        // 7. FINAL RESPONSE
        //
        // Always call Final Response after Semantic.
        //
        // Final Response already owns:
        // - FINAL
        // - CLARIFICATION
        // - SAFE_STOP
        // - tool success/failure interpretation
        // ============================================================

        const finalResponse =
          await fetch(
            `${baseUrl}/functions/v1/atlas-internal-final-response`,
            {
              method: "POST",
              headers:
                downstreamHeaders,
              body: JSON.stringify({
                decision_id:
                  decisionId,
              }),
            },
          );

        const finalBody =
          await readJsonResponse(
            finalResponse,
          );

        if (
          !finalResponse.ok ||
          !isObject(finalBody)
        ) {
          return errorResponse(
            "FINAL_STAGE_FAILED",
            "Final response stage failed",
            502,
            "FINAL_RESPONSE",
          );
        }

        const canonicalFinalDecisionId =
          finalBody
            .decision_id;

        if (
          canonicalFinalDecisionId !==
            decisionId
        ) {
          return errorResponse(
            "INVALID_FINAL_CONTRACT",
            "Final response decision mismatch",
            502,
            "FINAL_RESPONSE",
          );
        }

        // ============================================================
        // 8. SUCCESS
        // ============================================================

        return jsonResponse({
          runtime_version:
            "INTERNAL_ORCHESTRATOR_V1",

          empresa_id,

          conversation_id,

          decision_id:
            decisionId,

          next_action:
            nextAction,

          tool_executed:
            nextAction ===
              "EXECUTE_TOOL",

          tool_execution:
            toolExecution,

          semantic: {
            validated_decision:
              validatedDecision,

            next_action:
              nextAction,
          },

          final:
            finalBody,
        });
      } catch {
        // Never expose stack traces,
        // provider payloads,
        // JWTs or raw database errors.

        return errorResponse(
          "INTERNAL_ORCHESTRATOR_ERROR",
          "Internal orchestrator runtime error",
          500,
        );
      }
    },
  ),
};