/**
 * C1 Smoke Test - Valid Decision Without Tool
 * LOCAL AUTHENTICATED TEST ONLY
 *
 * This test verifies:
 * - atlas_internal_prepare_final_response_context RPC works with valid decision
 * - tool_required=false → tool_result_used=false, safe_to_generate=true
 * - decision_state=VALID, all context resolved canonically
 *
 * Usage:
 * 1. Run C1 fixture SQL first (supabase/tests/atlas_internal_prepare_final_response_context_v1_smoke.sql - C1 section)
 * 2. Set environment variables:
 *    SUPABASE_URL=<your-project>.supabase.co
 *    SUPABASE_ANON_KEY=<anon-key>
 *    OWNER_EMAIL=<owner-email>
 *    OWNER_PASSWORD=<owner-password>
 * 3. Run this script:
 *    deno run --allow-env --allow-net scripts/smoke-c1-context-builder.ts
 *
 * IMPORTANT: This test REQUIRES authenticated OWNER session
 * SQL Editor cannot run this RPC because auth.uid() returns NULL
 */

const EMPRESA_ID = "bf55a6aa-2e3f-4749-b2b8-135537a7c7bf";
const CONVERSATION_ID = "b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de";
const C1_DECISION_ID = "c1000000-0000-0000-0000-000000000001"; // From fixture

function getEnv(name: string): string | null {
  const v = Deno.env.get(name);
  return v ?? null;
}

async function signIn(supabaseUrl: string, anonKey: string, email: string, password: string) {
  console.log("[C1] Authenticating OWNER...");
  const resp = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  if (!resp.ok) {
    throw new Error(`Auth failed: ${resp.status}`);
  }
  const json = await resp.json();
  return { accessToken: json.access_token, user: json.user };
}

async function callRPC(supabaseUrl: string, rpcName: string, params: Record<string, unknown>, accessToken: string) {
  const resp = await fetch(`${supabaseUrl}/rest/v1/rpc/${rpcName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify(params),
  });
  if (!resp.ok) {
    const errorText = await resp.text();
    throw new Error(`RPC failed: ${resp.status} - ${errorText}`);
  }
  return await resp.json();
}

async function main() {
  try {
    console.log("[C1] Starting C1 smoke test for context builder...");

    const supabaseUrl = getEnv("SUPABASE_URL");
    const anonKey = getEnv("SUPABASE_ANON_KEY");
    const ownerEmail = getEnv("OWNER_EMAIL") || prompt("Enter OWNER_EMAIL: ");
    const ownerPassword = getEnv("OWNER_PASSWORD") || prompt("Enter OWNER_PASSWORD: ");

    if (!supabaseUrl || !anonKey) {
      throw new Error("[C1] SUPABASE_URL and SUPABASE_ANON_KEY required");
    }
    if (!ownerEmail || !ownerPassword) {
      throw new Error("[C1] OWNER_EMAIL and OWNER_PASSWORD required");
    }

    // Sign in as OWNER
    const { accessToken, user } = await signIn(supabaseUrl, anonKey, ownerEmail, ownerPassword);
    console.log(`[C1] Authentication OK - user: ${user.email}`);

    // Call context builder RPC with C1 decision
    console.log(`[C1] Calling atlas_internal_prepare_final_response_context with decision_id=${C1_DECISION_ID}...`);
    const result = await callRPC(supabaseUrl, "atlas_internal_prepare_final_response_context", {
      p_decision_id: C1_DECISION_ID,
    }, accessToken);

    // Display result
    console.log("[C1] RPC Response:");
    console.log(JSON.stringify(result, null, 2));

    // Validate C1 expectations
    console.log("\n[C1] Validation:");
    if (result.error) {
      console.error(`✗ FAILED: RPC returned error: ${result.error}`);
      Deno.exit(1);
    }

    const checks = [
      ["context_version", "INTERNAL_FINAL_RESPONSE_CONTEXT_V1", result.context_version],
      ["empresa_id", EMPRESA_ID, result.empresa_id],
      ["conversation_id", CONVERSATION_ID, result.conversation_id],
      ["decision_id", C1_DECISION_ID, result.decision_id],
      ["decision_state", "VALID", result.decision_state],
      ["safe_to_generate", true, result.safe_to_generate],
      ["tool_result_used", false, result.tool_result_used],
      ["canonical_tool_result", null, result.canonical_tool_result],
    ];

    let passed = 0;
    let failed = 0;
    for (const [field, expected, actual] of checks) {
      if (JSON.stringify(actual) === JSON.stringify(expected)) {
        console.log(`✓ ${field}: ${JSON.stringify(actual)}`);
        passed++;
      } else {
        console.log(`✗ ${field}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
        failed++;
      }
    }

    console.log(`\n[C1] Checks: ${passed} passed, ${failed} failed`);
    if (failed > 0) {
      Deno.exit(1);
    }

    console.log("\n[C1] C1 SMOKE TEST PASSED ✓");
  } catch (err) {
    console.error("[C1] Error:", err instanceof Error ? err.message : String(err));
    Deno.exit(1);
  }
}

async function prompt(question: string): Promise<string> {
  await Deno.stdout.write(new TextEncoder().encode(question));
  const buf = new Uint8Array(1024);
  const n = <number>await Deno.stdin.read(buf);
  if (!n) return "";
  return new TextDecoder().decode(buf.subarray(0, n)).trim();
}

if (import.meta.main) {
  main().catch(err => {
    console.error("[C1] Fatal:", err);
    Deno.exit(1);
  });
}
