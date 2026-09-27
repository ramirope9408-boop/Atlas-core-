import "@supabase/functions-js/edge-runtime.d.ts";
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

// ATLAS B2 - CONVERSATION CERTIFICATION SEMANTIC EVALUATOR V1
// Evidence-bounded evaluator for assertions that cannot be proven mechanically.
// It may fail an assertion for insufficient evidence, but may never invent facts.

type JsonObject = Record<string, unknown>;
type RequestBody = {
  scenario_instance_id?: string;
  runtime_evidence?: JsonObject;
  prior_assertion_results?: JsonObject[];
};

const UUID_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

function isObject(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function errorResponse(code: string, message: string, status = 400) {
  return jsonResponse({ error: code, message }, status);
}

function parseJson(content: string): unknown {
  const fenced = content.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return JSON.parse((fenced ? fenced[1] : content).trim());
}

export default {
  fetch: withSupabase(
    { auth: "user" },
    async (req, ctx) => {
      if (req.method !== "POST") {
        return errorResponse("METHOD_NOT_ALLOWED", "Method not allowed", 405);
      }

      if (ctx.authMode !== "user" || !ctx.userClaims || !ctx.userClaims.id || !ctx.supabase) {
        return errorResponse("AUTH_REQUIRED", "Authentication required", 401);
      }

      let body: RequestBody;
      try {
        body = await req.json();
      } catch {
        return errorResponse("INVALID_INPUT", "Invalid JSON body", 400);
      }

      const instanceId = body.scenario_instance_id;
      if (
        typeof instanceId !== "string" ||
        !UUID_REGEX.test(instanceId) ||
        !isObject(body.runtime_evidence) ||
        !Array.isArray(body.prior_assertion_results)
      ) {
        return errorResponse(
          "INVALID_INPUT",
          "scenario_instance_id, runtime_evidence and prior_assertion_results are required",
          400,
        );
      }

      const renderRes = await ctx.supabase.rpc(
        "atlas_render_conversation_scenario_payload_for_operator_v1",
        { p_scenario_instance_id: instanceId },
      );

      if (renderRes.error || !isObject(renderRes.data)) {
        return errorResponse("SCENARIO_RENDER_FAILED", "Unable to load scenario contract", 502);
      }

      const rendered = renderRes.data;
      if (rendered.ready !== true || !isObject(rendered.payload)) {
        return errorResponse("SCENARIO_NOT_READY", "Scenario is not ready", 409);
      }

      const payload = rendered.payload;
      const expectedCodes = Array.isArray(payload.expected_assertion_codes)
        ? payload.expected_assertion_codes.filter((v) => typeof v === "string") as string[]
        : [];

      const priorByCode = new Map<string, JsonObject>();
      for (const item of body.prior_assertion_results) {
        if (isObject(item) && typeof item.assertion_code === "string") {
          priorByCode.set(item.assertion_code, item);
        }
      }

      const semanticCodes = expectedCodes.filter((code) => {
        const prior = priorByCode.get(code);
        return !prior || prior.evaluation === "REQUIRES_SEMANTIC_EVALUATOR";
      });

      if (semanticCodes.length === 0) {
        const merged = expectedCodes.map((code) => priorByCode.get(code));
        const pass = merged.every((item) => isObject(item) && item.passed === true);
        return jsonResponse({
          runtime_version: "B2_CONVERSATION_CERT_SEMANTIC_EVALUATOR_V1",
          ok: true,
          scenario_instance_id: instanceId,
          assertion_results: merged,
          outcome: pass ? "PASSED" : "FAILED",
          semantic_evaluator_used: false,
        });
      }

      const apiKey = Deno.env.get("OPENAI_API_KEY");
      const model =
        Deno.env.get("B2_CERT_EVALUATOR_MODEL") ||
        Deno.env.get("OPENAI_MODEL");
      if (!apiKey || !model) {
        return errorResponse(
          "EVALUATOR_CONFIG_ERROR",
          "Semantic evaluator configuration unavailable",
          500,
        );
      }

      const evaluatorInput = {
        contract_version: "B2_CONVERSATION_SEMANTIC_EVALUATOR_V1",
        scenario_instance_id: instanceId,
        scenario_code: payload.scenario_code,
        rendered_prompt: payload.rendered_prompt,
        assertion_codes: semanticCodes,
        runtime_evidence: body.runtime_evidence,
        rules: [
          "Judge only from supplied runtime evidence.",
          "Do not use outside knowledge.",
          "Do not infer missing business facts.",
          "If evidence is insufficient, passed must be false.",
          "Return JSON only.",
        ],
      };

      const providerRes = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: "Bearer " + apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          temperature: 0,
          messages: [
            {
              role: "system",
              content: "You are an evidence-bounded certification evaluator. Never invent missing evidence.",
            },
            { role: "user", content: JSON.stringify(evaluatorInput) },
          ],
        }),
      });

      let providerBody: unknown = null;
      try {
        providerBody = await providerRes.json();
      } catch {
        providerBody = null;
      }

      if (!providerRes.ok || !isObject(providerBody)) {
        return errorResponse("SEMANTIC_EVALUATOR_REQUEST_FAILED", "Semantic evaluator request failed", 502);
      }

      const choices = Array.isArray(providerBody.choices) ? providerBody.choices : [];
      const first = choices.length > 0 && isObject(choices[0]) ? choices[0] : null;
      const message = first && isObject(first.message) ? first.message : null;
      const providerText = message && typeof message.content === "string" ? message.content : null;
      if (!providerText) {
        return errorResponse("SEMANTIC_EVALUATOR_EMPTY_OUTPUT", "Semantic evaluator returned empty output", 502);
      }

      let parsed: unknown;
      try {
        parsed = parseJson(providerText);
      } catch {
        return errorResponse("SEMANTIC_EVALUATOR_INVALID_JSON", "Semantic evaluator returned invalid JSON", 502);
      }

      if (!isObject(parsed) || !Array.isArray(parsed.assertion_results)) {
        return errorResponse("SEMANTIC_EVALUATOR_INVALID_CONTRACT", "Semantic evaluator output invalid", 502);
      }

      const semanticResults: JsonObject[] = [];
      const seen = new Set<string>();
      for (const item of parsed.assertion_results) {
        if (!isObject(item)) {
          return errorResponse("SEMANTIC_EVALUATOR_INVALID_CONTRACT", "Assertion item invalid", 502);
        }
        const code = item.assertion_code;
        const passed = item.passed;
        const reason = item.reason;
        if (
          typeof code !== "string" ||
          semanticCodes.indexOf(code) < 0 ||
          seen.has(code) ||
          typeof passed !== "boolean" ||
          typeof reason !== "string" ||
          reason.trim() === ""
        ) {
          return errorResponse("SEMANTIC_EVALUATOR_INVALID_CONTRACT", "Assertion outside expected contract", 502);
        }
        seen.add(code);
        semanticResults.push({
          assertion_code: code,
          passed,
          evaluation: "SEMANTIC_EVIDENCE_EVALUATOR",
          reason,
        });
      }

      if (seen.size !== semanticCodes.length) {
        return errorResponse("SEMANTIC_EVALUATOR_INCOMPLETE", "Not all assertions were evaluated", 502);
      }

      const merged = expectedCodes.map((code) => {
        const prior = priorByCode.get(code);
        if (prior && prior.evaluation !== "REQUIRES_SEMANTIC_EVALUATOR") {
          return prior;
        }
        return semanticResults.find((item) => item.assertion_code === code);
      });

      const validateRes = await ctx.supabase.rpc(
        "atlas_validate_conversation_semantic_evaluation_for_operator_v1",
        {
          p_scenario_instance_id: instanceId,
          p_assertion_results: merged,
          p_outcome: merged.some((item) =>
            isObject(item) &&
            typeof item.reason === "string" &&
            item.reason.trim().toUpperCase() === "INSUFFICIENT_EVIDENCE"
          )
            ? "BLOCKED"
            : (merged.every((item) => isObject(item) && item.passed === true)
              ? "PASSED"
              : "FAILED"),
        },
      );

      if (validateRes.error || !isObject(validateRes.data) || validateRes.data.valid !== true) {
        return errorResponse("SEMANTIC_EVALUATION_GATE_REJECTED", "Semantic evaluation failed contract validation", 502);
      }

      const hasInsufficientEvidence = merged.some((item) =>
        isObject(item) &&
        typeof item.reason === "string" &&
        item.reason.trim().toUpperCase() === "INSUFFICIENT_EVIDENCE"
      );

      const outcome = hasInsufficientEvidence
        ? "BLOCKED"
        : (merged.every((item) => isObject(item) && item.passed === true)
          ? "PASSED"
          : "FAILED");

      return jsonResponse({
        runtime_version: "B2_CONVERSATION_CERT_SEMANTIC_EVALUATOR_V1",
        ok: true,
        scenario_instance_id: instanceId,
        assertion_results: merged,
        outcome,
        semantic_evaluator_used: true,
      });
    },
  ),
};