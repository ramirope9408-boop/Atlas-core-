/**
 * ATLAS — INTERNAL_FINAL_RESPONSE V1
 * Authenticated smoke runner.
 *
 * Required env:
 * SUPABASE_URL
 * SUPABASE_FUNCTIONS_URL
 * SUPABASE_ANON_KEY
 * OWNER_EMAIL
 * OWNER_PASSWORD
 * FINAL_RESPONSE_DECISION_ID
 *
 * Never logs credentials or JWTs.
 */

type JsonObject = Record<string, unknown>;

function getEnv(name: string): string | null {
  const value = Deno.env.get(name);

  if (!value) {
    return null;
  }

  const trimmed = value.trim();

  return trimmed.length > 0
    ? trimmed
    : null;
}

function safeString(value: unknown): string | null {
  return typeof value === "string"
    ? value
    : null;
}

function safeBoolean(value: unknown): boolean | null {
  return typeof value === "boolean"
    ? value
    : null;
}

async function signIn(
  supabaseUrl: string,
  anonKey: string,
  email: string,
  password: string,
): Promise<string> {
  const url =
    `${supabaseUrl.replace(/\/$/, "")}/auth/v1/token?grant_type=password`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      apikey: anonKey,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      email,
      password,
    }),
  });

  if (!response.ok) {
    throw new Error(
      `AUTH_HTTP_${response.status}|AUTH_FAILED|OWNER authentication failed.`,
    );
  }

  const json = await response.json();

  if (
    !json ||
    typeof json !== "object" ||
    typeof (json as JsonObject).access_token !== "string"
  ) {
    throw new Error(
      "AUTH_RESPONSE_INVALID|AUTH_TOKEN_MISSING|No access token returned.",
    );
  }

  return (json as JsonObject).access_token as string;
}

async function callFinalResponse(
  functionsUrl: string,
  anonKey: string,
  accessToken: string,
  decisionId: string,
): Promise<{
  status: number;
  body: JsonObject;
}> {
  const url =
    `${functionsUrl.replace(/\/$/, "")}/atlas-internal-final-response`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      apikey: anonKey,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      decision_id: decisionId,
    }),
  });

  let body: JsonObject = {};

  try {
    const parsed = await response.json();

    if (
      parsed &&
      typeof parsed === "object"
    ) {
      body = parsed as JsonObject;
    }
  } catch {
    body = {};
  }

  return {
    status: response.status,
    body,
  };
}

function printSafeResult(
  status: number,
  body: JsonObject,
): void {
  console.log("");
  console.log(
    "========== ATLAS FINAL RESPONSE SMOKE ==========",
  );

  console.log(
    "status =",
    status,
  );

  if (
    typeof body.error === "string"
  ) {
    console.log(
      "error =",
      body.error,
    );
  }

  if (
    typeof body.message === "string"
  ) {
    console.log(
      "message =",
      body.message,
    );
  }

  console.log(
    "runtime_version =",
    safeString(
      body.runtime_version,
    ),
  );

  console.log(
    "decision_id =",
    safeString(
      body.decision_id,
    ),
  );

  const response =
    body.response &&
      typeof body.response === "object"
      ? body.response as JsonObject
      : {};

  console.log("");
  console.log(
    "--- response ---",
  );

  console.log(
    "response_type =",
    safeString(
      response.response_type,
    ),
  );

  console.log(
    "response_mode =",
    safeString(
      response.response_mode,
    ),
  );

  console.log(
    "tool_result_used =",
    safeBoolean(
      response.tool_result_used,
    ),
  );

  console.log(
    "humor_used =",
    safeBoolean(
      response.humor_used,
    ),
  );

  console.log(
    "seriousness_level =",
    safeString(
      response.seriousness_level,
    ),
  );

  console.log(
    "safe_to_continue =",
    safeBoolean(
      response.safe_to_continue,
    ),
  );

  console.log(
    "registered_message_id =",
    safeString(
      body.registered_message_id,
    ),
  );

  console.log(
    "audit_id =",
    safeString(
      body.audit_id,
    ),
  );

  console.log(
    "prompt_contract_code =",
    safeString(
      body.prompt_contract_code,
    ),
  );

  console.log(
    "prompt_contract_version =",
    safeString(
      body.prompt_contract_version,
    ),
  );

  console.log(
    "================================================",
  );
}

function printSafeError(
  error: unknown,
): void {
  const raw =
    error instanceof Error
      ? error.message
      : String(error);

  const parts =
    raw.split("|");

  if (
    parts.length >= 3
  ) {
    console.error(
      `[FINAL-SMOKE] ERROR: ${parts[0]} - ${parts[1]} - ${
        parts.slice(2).join("|")
      }`,
    );

    return;
  }

  console.error(
    "[FINAL-SMOKE] ERROR: INTERNAL - Smoke failed safely.",
  );
}

async function main() {
  console.log(
    "[FINAL-SMOKE] Starting",
  );

  const SUPABASE_URL =
    getEnv(
      "SUPABASE_URL",
    );

  const SUPABASE_FUNCTIONS_URL =
    getEnv(
      "SUPABASE_FUNCTIONS_URL",
    );

  const SUPABASE_ANON_KEY =
    getEnv(
      "SUPABASE_ANON_KEY",
    );

  const OWNER_EMAIL =
    getEnv(
      "OWNER_EMAIL",
    );

  const OWNER_PASSWORD =
    getEnv(
      "OWNER_PASSWORD",
    );

  const FINAL_RESPONSE_DECISION_ID =
    getEnv(
      "FINAL_RESPONSE_DECISION_ID",
    );

  if (
    !SUPABASE_URL ||
    !SUPABASE_FUNCTIONS_URL ||
    !SUPABASE_ANON_KEY ||
    !OWNER_EMAIL ||
    !OWNER_PASSWORD ||
    !FINAL_RESPONSE_DECISION_ID
  ) {
    console.error(
      "[FINAL-SMOKE] ERROR: MISSING_ENV - Required env vars missing.",
    );

    Deno.exit(1);
  }

  try {
    console.log(
      "[FINAL-SMOKE] Authenticating OWNER",
    );

    const accessToken =
      await signIn(
        SUPABASE_URL,
        SUPABASE_ANON_KEY,
        OWNER_EMAIL,
        OWNER_PASSWORD,
      );

    console.log(
      "[FINAL-SMOKE] Authentication OK",
    );

    console.log(
      "[FINAL-SMOKE] Calling final response function",
    );

    const result =
      await callFinalResponse(
        SUPABASE_FUNCTIONS_URL,
        SUPABASE_ANON_KEY,
        accessToken,
        FINAL_RESPONSE_DECISION_ID,
      );

    console.log(
      "[FINAL-SMOKE] Response received",
    );

    printSafeResult(
      result.status,
      result.body,
    );

    if (
      result.status < 200 ||
      result.status >= 300
    ) {
      Deno.exit(2);
    }

    if (
      safeString(
        result.body.runtime_version,
      ) !==
      "INTERNAL_FINAL_RESPONSE_V1"
    ) {
      console.error(
        "[FINAL-SMOKE] FAIL - Unexpected runtime version",
      );

      Deno.exit(3);
    }

    console.log("");
    console.log(
      "[FINAL-SMOKE] PASS",
    );

    Deno.exit(0);
  } catch (error) {
    printSafeError(
      error,
    );

    Deno.exit(1);
  }
}

if (import.meta.main) {
  await main();
}