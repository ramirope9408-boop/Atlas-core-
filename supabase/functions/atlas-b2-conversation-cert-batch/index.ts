import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

// ATLAS B2 - CONVERSATION CERTIFICATION BATCH EXECUTOR V1
// Executes pending applicable scenarios sequentially to preserve deterministic order.

type JsonObject = Record<string, unknown>;
type RequestBody = { scenario_plan_id?: string; limit?: number; };

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

      const scenarioPlanId = body.scenario_plan_id;
      const limit = Number.isInteger(body.limit) ? Number(body.limit) : 20;
      if (
        typeof scenarioPlanId !== "string" ||
        !UUID_REGEX.test(scenarioPlanId) ||
        limit < 1 ||
        limit > 100
      ) {
        return jsonResponse({ error: "INVALID_INPUT" }, 400);
      }

      const nextRes = await ctx.supabase.rpc(
        "atlas_get_next_conversation_certification_scenarios_v1",
        {
          p_scenario_plan_id: scenarioPlanId,
          p_limit: limit,
        },
      );

      if (nextRes.error || !isObject(nextRes.data)) {
        return jsonResponse({ error: "BATCH_PLAN_LOAD_FAILED" }, 502);
      }

      const items = Array.isArray(nextRes.data.items) ? nextRes.data.items : [];
      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
      if (!supabaseUrl || !anonKey) {
        return jsonResponse({ error: "BATCH_EXECUTOR_CONFIG_ERROR" }, 500);
      }

      const baseUrl = supabaseUrl.replace(/\/$/, "");
      const headers = {
        Authorization: authorization,
        apikey: anonKey,
        "Content-Type": "application/json",
      };

      const results: JsonObject[] = [];
      for (const item of items) {
        if (!isObject(item) || typeof item.scenario_instance_id !== "string") continue;

        const response = await fetch(
          baseUrl + "/functions/v1/atlas-b2-conversation-cert-executor",
          {
            method: "POST",
            headers,
            body: JSON.stringify({
              scenario_instance_id: item.scenario_instance_id,
            }),
          },
        );
        const resultBody = await readJson(response);

        results.push({
          scenario_instance_id: item.scenario_instance_id,
          scenario_code: item.scenario_code || null,
          http_status: response.status,
          ok: response.ok && isObject(resultBody) && resultBody.ok === true,
          result: isObject(resultBody) ? resultBody : null,
        });
      }

      const summaryRes = await ctx.supabase.rpc(
        "atlas_compute_conversation_certification_batch_summary_v1",
        { p_scenario_plan_id: scenarioPlanId },
      );

      return jsonResponse({
        runtime_version: "B2_CONVERSATION_CERT_BATCH_EXECUTOR_V1",
        ok: !summaryRes.error,
        scenario_plan_id: scenarioPlanId,
        executed_count: results.length,
        execution_results: results,
        summary: summaryRes.error ? null : summaryRes.data,
        next_action: summaryRes.error
          ? "REVIEW_BATCH_SUMMARY_ERROR"
          : (isObject(summaryRes.data) && summaryRes.data.ready === true
            ? "COMPUTE_G03_V21_READINESS"
            : "REMEDIATE_AND_RETRY_FAILED_SCENARIOS"),
      });
    },
  ),
};