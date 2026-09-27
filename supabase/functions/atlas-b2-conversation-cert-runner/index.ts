import { createClient } from "jsr:@supabase/supabase-js@2";

type AtlasSupabaseContext = {
  authMode: "user" | "anonymous";
  userClaims: { id: string } | null;
  supabase: ReturnType<typeof createClient> | null;
};

function withSupabase(
  _options: { auth: "user" },
  handler: (req: Request, ctx: AtlasSupabaseContext) => Promise<Response>,
) {
  return async (req: Request): Promise<Response> => {
    const authorization = req.headers.get("Authorization");
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

    if (!authorization?.startsWith("Bearer ") || !supabaseUrl || !anonKey) {
      return handler(req, {
        authMode: "anonymous",
        userClaims: null,
        supabase: null,
      });
    }

    const supabase = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const token = authorization.slice("Bearer ".length);
    const { data, error } = await supabase.auth.getUser(token);

    if (error || !data.user) {
      return handler(req, {
        authMode: "anonymous",
        userClaims: null,
        supabase: null,
      });
    }

    return handler(req, {
      authMode: "user",
      userClaims: { id: data.user.id },
      supabase,
    });
  };
}

// ATLAS B2 - CONVERSATION CERTIFICATION RUNNER V1.1
// Executes explicit multi-turn certification scenarios against the installed
// Valentina runtime inside an isolated INTERNAL_OPERATOR conversation.
// A scenario never receives PASS from evidence that was not actually observed.

const UUID_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

type RequestBody = { scenario_instance_id?: string; };
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
  try { return await response.json(); } catch { return null; }
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function assertion(code: string, passed: boolean, evaluation: string) {
  return { assertion_code: code, passed, evaluation };
}

export default {
  fetch: withSupabase(
    { auth: "user" },
    async (req, ctx) => {
      if (req.method !== "POST") {
        return jsonResponse({ error: "METHOD_NOT_ALLOWED" }, 405);
      }

      if (ctx.authMode !== "user" || !ctx.userClaims || !ctx.userClaims.id || !ctx.supabase) {
        return jsonResponse({ error: "AUTH_REQUIRED" }, 401);
      }

      const authorization = req.headers.get("Authorization");
      if (!authorization || !authorization.startsWith("Bearer ")) {
        return jsonResponse({ error: "AUTH_REQUIRED" }, 401);
      }

      let body: RequestBody;
      try { body = await req.json(); } catch {
        return jsonResponse({ error: "INVALID_INPUT" }, 400);
      }

      const instanceId = body.scenario_instance_id;
      if (typeof instanceId !== "string" || !UUID_REGEX.test(instanceId)) {
        return jsonResponse({ error: "INVALID_SCENARIO_INSTANCE_ID" }, 400);
      }

      const supabase = ctx.supabase;

      const renderRes = await supabase.rpc(
        "atlas_render_conversation_scenario_payload_for_operator_v1",
        { p_scenario_instance_id: instanceId },
      );
      if (renderRes.error || !isObject(renderRes.data) || renderRes.data.ready !== true || !isObject(renderRes.data.payload)) {
        return jsonResponse({
          error: "SCENARIO_RENDER_FAILED",
          scenario_instance_id: instanceId,
        }, 409);
      }

      const payload = renderRes.data.payload;
      const empresaId = payload.empresa_id;
      const scenarioCode = payload.scenario_code;
      const expectedCodes = Array.isArray(payload.expected_assertion_codes)
        ? payload.expected_assertion_codes.filter((v) => typeof v === "string") as string[]
        : [];

      if (
        typeof empresaId !== "string" ||
        !UUID_REGEX.test(empresaId) ||
        typeof scenarioCode !== "string" ||
        expectedCodes.length === 0
      ) {
        return jsonResponse({ error: "INVALID_RENDER_CONTRACT" }, 502);
      }

      const stepsRes = await supabase.rpc(
        "atlas_get_conversation_scenario_steps_for_operator_v1",
        { p_scenario_instance_id: instanceId },
      );
      if (stepsRes.error || !isObject(stepsRes.data) || stepsRes.data.ready !== true || !Array.isArray(stepsRes.data.steps)) {
        return jsonResponse({
          error: "SCENARIO_STEPS_NOT_READY",
          scenario_instance_id: instanceId,
          step_contract: stepsRes.error ? null : stepsRes.data,
        }, 409);
      }

      const steps = stepsRes.data.steps;
      if (steps.length === 0) {
        return jsonResponse({ error: "SCENARIO_STEPS_EMPTY" }, 409);
      }

      const openRes = await supabase.rpc(
        "atlas_web_open_internal_conversation",
        {
          p_empresa_id: empresaId,
          p_title: "B2 CERT " + scenarioCode,
        },
      );
      if (openRes.error || !isObject(openRes.data) || typeof openRes.data.conversation_id !== "string") {
        return jsonResponse({ error: "CERT_CONVERSATION_OPEN_FAILED" }, 502);
      }

      const conversationId = openRes.data.conversation_id;
      if (!UUID_REGEX.test(conversationId)) {
        return jsonResponse({ error: "INVALID_CONVERSATION_CONTRACT" }, 502);
      }

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
      if (!supabaseUrl || !anonKey) {
        return jsonResponse({ error: "RUNNER_CONFIG_ERROR" }, 500);
      }

      const baseUrl = supabaseUrl.replace(/\/$/, "");
      const downstreamHeaders = {
        Authorization: authorization,
        apikey: anonKey,
        "Content-Type": "application/json",
      };

      const stepEvidence: JsonObject[] = [];

      for (const rawStep of steps) {
        if (!isObject(rawStep)) {
          return jsonResponse({ error: "INVALID_SCENARIO_STEP_CONTRACT" }, 502);
        }

        const stepType = rawStep.step_type;
        const stepCode = rawStep.step_code;
        const requiredForAssertion = rawStep.required_for_assertion === true;

        if (stepType !== "MESSAGE") {
          continue;
        }

        const message = rawStep.rendered_message;
        if (
          typeof message !== "string" ||
          message.trim() === "" ||
          message.includes("{{") ||
          message.includes("}}")
        ) {
          return jsonResponse({
            error: "UNRESOLVED_SCENARIO_MESSAGE",
            scenario_instance_id: instanceId,
            step_code: stepCode || null,
          }, 409);
        }

        const messageRes = await supabase.rpc(
          "atlas_web_register_internal_text_message",
          {
            p_conversation_id: conversationId,
            p_text_content: message,
          },
        );
        if (messageRes.error || !isObject(messageRes.data)) {
          return jsonResponse({
            error: "CERT_MESSAGE_REGISTRATION_FAILED",
            step_code: stepCode || null,
          }, 502);
        }

        const orchestratorResponse = await fetch(
          baseUrl + "/functions/v1/atlas-internal-orchestrator",
          {
            method: "POST",
            headers: downstreamHeaders,
            body: JSON.stringify({
              empresa_id: empresaId,
              conversation_id: conversationId,
            }),
          },
        );
        const orchestratorBody = await readJson(orchestratorResponse);

        if (!orchestratorResponse.ok || !isObject(orchestratorBody)) {
          return jsonResponse({
            error: "INSTALLED_RUNTIME_EXECUTION_FAILED",
            scenario_instance_id: instanceId,
            conversation_id: conversationId,
            step_code: stepCode || null,
          }, 502);
        }

        const finalStage = isObject(orchestratorBody.final)
          ? orchestratorBody.final
          : null;
        const finalResponse = finalStage && isObject(finalStage.response)
          ? finalStage.response
          : null;
        const semantic = isObject(orchestratorBody.semantic)
          ? orchestratorBody.semantic
          : null;
        const validatedDecision = semantic && isObject(semantic.validated_decision)
          ? semantic.validated_decision
          : null;

        stepEvidence.push({
          step_order: rawStep.step_order || null,
          step_code: stepCode || null,
          required_for_assertion: requiredForAssertion,
          customer_message: message,
          message_id: messageRes.data.message_id || null,
          decision_id: typeof orchestratorBody.decision_id === "string"
            ? orchestratorBody.decision_id
            : null,
          next_action: typeof orchestratorBody.next_action === "string"
            ? orchestratorBody.next_action
            : null,
          tool_executed: orchestratorBody.tool_executed === true,
          validated_decision: validatedDecision,
          response_type: finalResponse && typeof finalResponse.response_type === "string"
            ? finalResponse.response_type
            : null,
          text_response: finalResponse && typeof finalResponse.text_response === "string"
            ? finalResponse.text_response
            : null,
          runtime_version: typeof orchestratorBody.runtime_version === "string"
            ? orchestratorBody.runtime_version
            : null,
        });
      }

      if (stepEvidence.length === 0) {
        return jsonResponse({ error: "NO_EXECUTABLE_SCENARIO_STEPS" }, 409);
      }

      const assertionSteps = stepEvidence.filter((item) => item.required_for_assertion === true);
      const primaryEvidence = assertionSteps.length > 0
        ? assertionSteps[assertionSteps.length - 1]
        : stepEvidence[stepEvidence.length - 1];

      const primaryToolExecuted = primaryEvidence.tool_executed === true;
      const primaryNextAction = typeof primaryEvidence.next_action === "string"
        ? primaryEvidence.next_action
        : null;

      const deterministic: Record<string, boolean> = {};

      if (
        scenarioCode === "ACKNOWLEDGEMENT_NO_RETRIGGER" ||
        scenarioCode === "POST_MODIFICATION_ACK_NO_LOOP" ||
        scenarioCode === "NON_ACCEPTANCE_ACK_BLOCKED" ||
        scenarioCode === "PAYMENT_BEFORE_ACCEPTANCE_BLOCKED"
      ) {
        const noActionRetrigger =
          !primaryToolExecuted && primaryNextAction !== "EXECUTE_TOOL";

        if (expectedCodes.includes("ACKNOWLEDGEMENT_NO_ACTION_RETRIGGER")) {
          deterministic.ACKNOWLEDGEMENT_NO_ACTION_RETRIGGER = noActionRetrigger;
        }
        if (expectedCodes.includes("ACTION_INTENT_GATING")) {
          deterministic.ACTION_INTENT_GATING = noActionRetrigger;
        }
        if (expectedCodes.includes("EXPLICIT_ACCEPTANCE_GATING")) {
          deterministic.EXPLICIT_ACCEPTANCE_GATING = noActionRetrigger;
        }
        if (expectedCodes.includes("CONTEXTUAL_MODIFICATION_NO_LOOP")) {
          deterministic.CONTEXTUAL_MODIFICATION_NO_LOOP = noActionRetrigger;
        }
      }

      const assertionResults = expectedCodes.map((code) => {
        if (Object.prototype.hasOwnProperty.call(deterministic, code)) {
          return assertion(code, deterministic[code], "DETERMINISTIC_RUNTIME_EVIDENCE");
        }
        return assertion(code, false, "REQUIRES_SEMANTIC_EVALUATOR");
      });

      const fullyDeterministic = assertionResults.every(
        (item) => item.evaluation === "DETERMINISTIC_RUNTIME_EVIDENCE",
      );
      const deterministicPass = fullyDeterministic && assertionResults.every(
        (item) => item.passed === true,
      );

      const renderedInputSha256 = await sha256Hex(
        JSON.stringify({ payload, steps }),
      );

      const runtimeEvidence = {
        scenario_instance_id: instanceId,
        scenario_code: scenarioCode,
        conversation_id: conversationId,
        locale: stepsRes.data.locale || null,
        steps: stepEvidence,
        primary_assertion_step: primaryEvidence,
      };
      const responseSha256 = await sha256Hex(JSON.stringify(runtimeEvidence));

      return jsonResponse({
        runtime_version: "B2_CONVERSATION_CERT_RUNNER_V1_1",
        ok: true,
        scenario_instance_id: instanceId,
        scenario_code: scenarioCode,
        empresa_id: empresaId,
        conversation_id: conversationId,
        step_count: stepEvidence.length,
        rendered_input_sha256: renderedInputSha256,
        response_sha256: responseSha256,
        assertion_results: assertionResults,
        provisional_outcome: fullyDeterministic
          ? (deterministicPass ? "PASSED" : "FAILED")
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