import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

// ATLAS B2 — CONVERSATION CERTIFICATION RUNNER V1
//
// Authenticated implementation operator
// -> render canonical scenario payload
// -> open isolated INTERNAL_OPERATOR conversation
// -> register synthetic customer message
// -> execute installed Valentina runtime through INTERNAL_ORCHESTRATOR_V2
// -> apply deterministic assertions when the contract can be proven mechanically
// -> return evidence package for registration/evaluation
//
// This runner never marks a semantic assertion PASSED when the available
// runtime evidence is insufficient. Such assertions are returned as
// REQUIRES_SEMANTIC_EVALUATOR.

const UUID_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

type RequestBody = {
  scenario_instance_id?: string;
};

type JsonObject = Record<string, unknown>;

function isObject(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function readJson(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return null;
  }
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function assertion(
  code: string,
  passed: boolean,
  evaluation: string,
) {
  return {
    assertion_code: code,
    passed,
    evaluation,
  };
}

export default {
  fetch: withSupabase(
    { auth: "user" },

    async (req, ctx) => {
      if (req.method !== "POST") {
        return jsonResponse(
          { error: "METHOD_NOT_ALLOWED", message: "Method not allowed" },
          405,
        );
      }

      if (
        ctx.authMode !== "user" ||
        !ctx.userClaims?.id ||
        !ctx.supabase
      ) {
        return jsonResponse(
          { error: "AUTH_REQUIRED", message: "Authentication required" },
          401,
        );
      }

      const authorization = req.headers.get("Authorization");
      if (!authorization?.startsWith("Bearer ")) {
        return jsonResponse(
          { error: "AUTH_REQUIRED", message: "Bearer token required" },
          401,
        );
      }

      let body: RequestBody;
      try {
        body = await req.json();
      } catch {
        return jsonResponse(
          { error: "INVALID_INPUT", message: "Invalid JSON body" },
          400,
        );
      }

      const scenarioInstanceId = body?.scenario_instance_id;
      if (
        typeof scenarioInstanceId !== "string" ||
        !UUID_REGEX.test(scenarioInstanceId)
      ) {
        return jsonResponse(
          {
            error: "INVALID_INPUT",
            message: "scenario_instance_id must be a valid UUID",
          },
          400,
        );
      }

      const supabase = ctx.supabase;

      // 1. Render the execution input from the canonical company installation.
      const renderRes = await supabase.rpc(
        "atlas_render_conversation_scenario_payload_for_operator_v1",
        { p_scenario_instance_id: scenarioInstanceId },
      );

      if (renderRes.error || !isObject(renderRes.data)) {
        return jsonResponse(
          {
            error: "SCENARIO_RENDER_FAILED",
            message: "Unable to render canonical scenario payload",
          },
          502,
        );
      }

      const rendered = renderRes.data as JsonObject;
      if (rendered.ready !== true || !isObject(rendered.payload)) {
        return jsonResponse(
          {
            error: "SCENARIO_NOT_READY",
            scenario_instance_id: scenarioInstanceId,
            render: rendered,
          },
          409,
        );
      }

      const payload = rendered.payload as JsonObject;
      const empresaId = payload.empresa_id;
      const scenarioCode = payload.scenario_code;
      const renderedPrompt = payload.rendered_prompt;
      const expectedAssertionCodes = Array.isArray(
        payload.expected_assertion_codes,
      )
        ? payload.expected_assertion_codes.filter(
          (v): v is string => typeof v === "string",
        )
        : [];

      if (
        typeof empresaId !== "string" ||
        !UUID_REGEX.test(empresaId) ||
        typeof scenarioCode !== "string" ||
        typeof renderedPrompt !== "string" ||
        renderedPrompt.trim() === "" ||
        expectedAssertionCodes.length === 0
      ) {
        return jsonResponse(
          {
            error: "INVALID_RENDER_CONTRACT",
            message: "Rendered scenario contract is incomplete",
          },
          502,
        );
      }

      // 2. Open an isolated internal conversation owned by the authenticated
      // implementation operator. This avoids touching customer conversations.
      const openRes = await supabase.rpc(
        "atlas_web_open_internal_conversation",
        {
          p_empresa_id: empresaId,
          p_title: `B2 CERT ${scenarioCode}`,
        },
      );

      if (openRes.error || !isObject(openRes.data)) {
        return jsonResponse(
          {
            error: "CERT_CONVERSATION_OPEN_FAILED",
            message: "Unable to open isolated certification conversation",
          },
          502,
        );
      }

      const conversationId = openRes.data.conversation_id;
      if (
        typeof conversationId !== "string" ||
        !UUID_REGEX.test(conversationId)
      ) {
        return jsonResponse(
          {
            error: "INVALID_CONVERSATION_CONTRACT",
            message: "Certification conversation id missing",
          },
          502,
        );
      }

      // 3. Register the synthetic inbound text exactly as the current internal
      // chat runtime would receive it.
      const messageRes = await supabase.rpc(
        "atlas_web_register_internal_text_message",
        {
          p_conversation_id: conversationId,
          p_text_content: renderedPrompt,
        },
      );

      if (messageRes.error || !isObject(messageRes.data)) {
        return jsonResponse(
          {
            error: "CERT_MESSAGE_REGISTRATION_FAILED",
            message: "Unable to register certification message",
          },
          502,
        );
      }

      // 4. Execute the installed runtime, forwarding the caller JWT.
      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

      if (!supabaseUrl || !anonKey) {
        return jsonResponse(
          {
            error: "RUNNER_CONFIG_ERROR",
            message: "Runtime configuration unavailable",
          },
          500,
        );
      }

      const orchestratorResponse = await fetch(
        `${supabaseUrl.replace(/\/$/, "")}/functions/v1/atlas-internal-orchestrator`,
        {
          method: "POST",
          headers: {
            Authorization: authorization,
            apikey: anonKey,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            empresa_id: empresaId,
            conversation_id: conversationId,
          }),
        },
      );

      const orchestratorBody = await readJson(orchestratorResponse);

      if (!orchestratorResponse.ok || !isObject(orchestratorBody)) {
        return jsonResponse(
          {
            error: "INSTALLED_RUNTIME_EXECUTION_FAILED",
            message: "Certification scenario could not execute installed runtime",
            scenario_instance_id: scenarioInstanceId,
            conversation_id: conversationId,
          },
          502,
        );
      }

      const nextAction =
        typeof orchestratorBody.next_action === "string"
          ? orchestratorBody.next_action
          : null;
      const toolExecuted = orchestratorBody.tool_executed === true;

      const finalStage = isObject(orchestratorBody.final)
        ? orchestratorBody.final
        : null;
      const finalResponse = finalStage && isObject(finalStage.response)
        ? finalStage.response
        : null;
      const textResponse =
        finalResponse && typeof finalResponse.text_response === "string"
          ? finalResponse.text_response
          : null;
      const responseType =
        finalResponse && typeof finalResponse.response_type === "string"
          ? finalResponse.response_type
          : null;

      const validatedDecision =
        isObject(orchestratorBody.semantic) &&
          isObject(orchestratorBody.semantic.validated_decision)
          ? orchestratorBody.semantic.validated_decision
          : null;

      // 5. Deterministic evaluator. Only assertions that can be proven from
      // canonical runtime state are auto-evaluated. The rest remain blocked
      // for the semantic evaluator; this prevents false certification.
      const deterministic: Record<string, boolean> = {};

      if (
        scenarioCode === "ACKNOWLEDGEMENT_NO_RETRIGGER" ||
        scenarioCode === "POST_MODIFICATION_ACK_NO_LOOP" ||
        scenarioCode === "NON_ACCEPTANCE_ACK_BLOCKED" ||
        scenarioCode === "PAYMENT_BEFORE_ACCEPTANCE_BLOCKED"
      ) {
        deterministic.ACKNOWLEDGEMENT_NO_ACTION_RETRIGGER =
          !toolExecuted && nextAction !== "EXECUTE_TOOL";
        deterministic.ACTION_INTENT_GATING =
          !toolExecuted && nextAction !== "EXECUTE_TOOL";
        deterministic.EXPLICIT_ACCEPTANCE_GATING =
          !toolExecuted && nextAction !== "EXECUTE_TOOL";
        deterministic.CONTEXTUAL_MODIFICATION_NO_LOOP =
          !toolExecuted && nextAction !== "EXECUTE_TOOL";
      }

      const assertionResults = expectedAssertionCodes.map((code) => {
        if (Object.prototype.hasOwnProperty.call(deterministic, code)) {
          return assertion(
            code,
            deterministic[code],
            "DETERMINISTIC_RUNTIME_EVIDENCE",
          );
        }
        return assertion(
          code,
          false,
          "REQUIRES_SEMANTIC_EVALUATOR",
        );
      });

      const fullyDeterministic = assertionResults.every(
        (r) => r.evaluation === "DETERMINISTIC_RUNTIME_EVIDENCE",
      );

      const allDeterministicPassed =
        fullyDeterministic &&
        assertionResults.every((r) => r.passed === true);

      const renderedInputSha256 = await sha256Hex(
        JSON.stringify(payload),
      );
      const runtimeEvidence = {
        scenario_instance_id: scenarioInstanceId,
        scenario_code: scenarioCode,
        conversation_id: conversationId,
        decision_id:
          typeof orchestratorBody.decision_id === "string"
            ? orchestratorBody.decision_id
            : null,
        next_action: nextAction,
        tool_executed: toolExecuted,
        response_type: responseType,
        text_response: textResponse,
        validated_decision: validatedDecision,
        runtime_version:
          typeof orchestratorBody.runtime_version === "string"
            ? orchestratorBody.runtime_version
            : null,
      };

      const responseSha256 = await sha256Hex(
        JSON.stringify(runtimeEvidence),
      );

      return jsonResponse({
        runtime_version: "B2_CONVERSATION_CERT_RUNNER_V1",
        ok: true,
        scenario_instance_id: scenarioInstanceId,
        scenario_code: scenarioCode,
        empresa_id: empresaId,
        conversation_id: conversationId,
        rendered_input_sha256: renderedInputSha256,
        response_sha256: responseSha256,
        assertion_results: assertionResults,
        provisional_outcome: fullyDeterministic
          ? (allDeterministicPassed ? "PASSED" : "FAILED")
          : "BLOCKED",
        semantic_evaluator_required: !fullyDeterministic,
        runtime_evidence: runtimeEvidence,
        next_action: fullyDeterministic
          ? "REGISTER_SCENARIO_RESULT"
          : "RUN_SEMANTIC_EVALUATOR",
      });
    },
  ),
};
