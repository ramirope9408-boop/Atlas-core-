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

// ATLAS B2 - CONVERSATION CERTIFICATION EXECUTOR V1
// Orchestrates runner -> semantic evaluator when needed -> canonical result ledger.

type JsonObject = Record<string, unknown>;
type RequestBody = { scenario_instance_id?: string; };

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

async function readJson(response: Response): Promise<unknown> {
  try { return await response.json(); } catch { return null; }
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export default {
  fetch: withSupabase(
    { auth: "user" },
    async (req, ctx) => {
      const startedAt = new Date().toISOString();

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

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
      if (!supabaseUrl || !anonKey) {
        return jsonResponse({ error: "EXECUTOR_CONFIG_ERROR" }, 500);
      }

      const baseUrl = supabaseUrl.replace(/\/$/, "");
      const headers = {
        Authorization: authorization,
        apikey: anonKey,
        "Content-Type": "application/json",
      };

      const runnerResponse = await fetch(
        baseUrl + "/functions/v1/atlas-b2-conversation-cert-runner",
        {
          method: "POST",
          headers,
          body: JSON.stringify({ scenario_instance_id: instanceId }),
        },
      );
      const runnerBody = await readJson(runnerResponse);

      if (!runnerResponse.ok || !isObject(runnerBody) || runnerBody.ok !== true) {
        return jsonResponse({
          error: "CERT_RUNNER_FAILED",
          scenario_instance_id: instanceId,
        }, 502);
      }

      let finalAssertionResults = Array.isArray(runnerBody.assertion_results)
        ? runnerBody.assertion_results
        : [];
      let finalOutcome = typeof runnerBody.provisional_outcome === "string"
        ? runnerBody.provisional_outcome
        : "BLOCKED";
      let semanticEvaluatorUsed = false;

      if (runnerBody.semantic_evaluator_required === true) {
        const evaluatorResponse = await fetch(
          baseUrl + "/functions/v1/atlas-b2-conversation-cert-evaluator",
          {
            method: "POST",
            headers,
            body: JSON.stringify({
              scenario_instance_id: instanceId,
              runtime_evidence: runnerBody.runtime_evidence,
              prior_assertion_results: finalAssertionResults,
            }),
          },
        );
        const evaluatorBody = await readJson(evaluatorResponse);

        if (!evaluatorResponse.ok || !isObject(evaluatorBody) || evaluatorBody.ok !== true) {
          return jsonResponse({
            error: "CERT_SEMANTIC_EVALUATOR_FAILED",
            scenario_instance_id: instanceId,
          }, 502);
        }

        finalAssertionResults = Array.isArray(evaluatorBody.assertion_results)
          ? evaluatorBody.assertion_results
          : [];
        finalOutcome = typeof evaluatorBody.outcome === "string"
          ? evaluatorBody.outcome
          : "BLOCKED";
        semanticEvaluatorUsed = evaluatorBody.semantic_evaluator_used === true;
      }

      if (finalOutcome !== "PASSED" && finalOutcome !== "FAILED" && finalOutcome !== "BLOCKED") {
        finalOutcome = "BLOCKED";
      }

      const completedAt = new Date().toISOString();
      const evidence = {
        runner_runtime_version: runnerBody.runtime_version || null,
        scenario_code: runnerBody.scenario_code || null,
        conversation_id: runnerBody.conversation_id || null,
        runtime_evidence: runnerBody.runtime_evidence || null,
        semantic_evaluator_used: semanticEvaluatorUsed,
        assertion_results: finalAssertionResults,
        outcome: finalOutcome,
      };

      const evidenceSha256 = await sha256Hex(JSON.stringify(evidence));
      const requestId = crypto.randomUUID();
      const evidenceReference = "test-evidence://b2-conversation/" + instanceId + "/" + requestId;

      const registerRes = await ctx.supabase.rpc(
        "atlas_register_conversation_scenario_result_for_operator_v1",
        {
          p_scenario_instance_id: instanceId,
          p_outcome: finalOutcome,
          p_executor_code: "B2_CONVERSATION_CERT_EXECUTOR_V1",
          p_request_id: requestId,
          p_rendered_input_sha256: runnerBody.rendered_input_sha256,
          p_response_sha256: runnerBody.response_sha256,
          p_assertion_results: finalAssertionResults,
          p_evidence_reference: evidenceReference,
          p_evidence_sha256: evidenceSha256,
          p_error_code: finalOutcome === "PASSED" ? null : "CONVERSATION_CERTIFICATION_NOT_PASSED",
          p_redacted_error_summary: finalOutcome === "PASSED" ? null : "One or more required assertions did not pass.",
          p_started_at: startedAt,
          p_completed_at: completedAt,
          p_metadata: {
            runtime: "B2_CONVERSATION_CERT_EXECUTOR_V1",
            semantic_evaluator_used: semanticEvaluatorUsed,
            conversation_id: runnerBody.conversation_id || null,
          },
        },
      );

      if (registerRes.error || !isObject(registerRes.data)) {
        return jsonResponse({
          error: "CERT_RESULT_REGISTRATION_FAILED",
          scenario_instance_id: instanceId,
          outcome: finalOutcome,
        }, 502);
      }

      return jsonResponse({
        runtime_version: "B2_CONVERSATION_CERT_EXECUTOR_V1",
        ok: true,
        scenario_instance_id: instanceId,
        outcome: finalOutcome,
        semantic_evaluator_used: semanticEvaluatorUsed,
        evidence_reference: evidenceReference,
        evidence_sha256: evidenceSha256,
        registration: registerRes.data,
        next_action: "RECOMPUTE_CONVERSATION_AND_G03_READINESS",
      });
    },
  ),
};