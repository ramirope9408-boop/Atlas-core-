/**
 * ATLAS — SEMANTIC_LLM_EXECUTION V1
 * Smoke Test A
 *
 * Local-only authenticated smoke test.
 *
 * Required env vars:
 * - SUPABASE_URL
 * - SUPABASE_FUNCTIONS_URL
 * - SUPABASE_ANON_KEY
 * - OWNER_EMAIL
 * - OWNER_PASSWORD
 *
 * SECURITY:
 * - Never logs passwords.
 * - Never logs access_token or refresh_token.
 * - Never logs API keys.
 * - Never logs Authorization headers.
 * - Tokens remain in memory only.
 */

const EXPECTED_MESSAGE = "Vale, ¿cómo vamos o ya quebramos? 😂";

const EMPRESA_ID = "bf55a6aa-2e3f-4749-b2b8-135537a7c7bf";
const CONVERSATION_ID = "b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de";

type JsonObject = Record<string, unknown>;

function getEnv(name: string): string | null {
  const value = Deno.env.get(name);

  if (!value) {
    return null;
  }

  const trimmed = value.trim();

  return trimmed.length > 0 ? trimmed : null;
}

function safeString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function safeBoolean(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function safeNumber(value: unknown): number | null {
  return typeof value === "number" ? value : null;
}

async function signInWithPassword(
  supabaseUrl: string,
  anonKey: string,
  email: string,
  password: string,
): Promise<string> {
  const baseUrl = supabaseUrl.replace(/\/$/, "");

  const url =
    `${baseUrl}/auth/v1/token?grant_type=password`;

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
    let errorCode = "AUTH_FAILED";
    let safeMessage =
      "Supabase Auth rejected the OWNER login.";

    try {
      const parsed = await response.json();

      if (
        parsed &&
        typeof parsed === "object"
      ) {
        const body = parsed as JsonObject;

        if (
          typeof body.error_code === "string"
        ) {
          errorCode = body.error_code;
        }

        if (typeof body.msg === "string") {
          safeMessage = body.msg;
        } else if (
          typeof body.message === "string"
        ) {
          safeMessage = body.message;
        }
      }
    } catch {
      // Never expose raw auth response.
    }

    throw new Error(
      `AUTH_HTTP_${response.status}|${errorCode}|${safeMessage}`,
    );
  }

  const json = await response.json();

  if (
    !json ||
    typeof json !== "object" ||
    typeof (json as JsonObject).access_token !== "string"
  ) {
    throw new Error(
      "AUTH_RESPONSE_INVALID|AUTH_TOKEN_MISSING|Authentication succeeded but no access token was returned.",
    );
  }

  return (json as JsonObject).access_token as string;
}

async function callPrepareContext(
  supabaseUrl: string,
  anonKey: string,
  accessToken: string,
): Promise<JsonObject> {
  const baseUrl = supabaseUrl.replace(/\/$/, "");

  const url =
    `${baseUrl}/rest/v1/rpc/atlas_internal_prepare_decision_context`;

  const response = await fetch(url, {
    method: "POST",

    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },

    body: JSON.stringify({
      p_empresa_id: EMPRESA_ID,
      p_conversation_id: CONVERSATION_ID,
      p_memory_limit: 30,
    }),
  });

  if (!response.ok) {
    throw new Error(
      `CONTEXT_HTTP_${response.status}|DECISION_CONTEXT_FAILED|Decision context request failed.`,
    );
  }

  const json = await response.json();

  if (
    !json ||
    typeof json !== "object"
  ) {
    throw new Error(
      "CONTEXT_RESPONSE_INVALID|DECISION_CONTEXT_FAILED|Decision context response was invalid.",
    );
  }

  return json as JsonObject;
}

async function callEdgeFunction(
  functionsUrl: string,
  accessToken: string,
  anonKey: string,
): Promise<{
  status: number;
  body: JsonObject;
}> {
  const baseUrl =
    functionsUrl.replace(/\/$/, "");

  const url =
    `${baseUrl}/atlas-internal-semantic-decision`;

  const response = await fetch(url, {
    method: "POST",

    headers: {
      Authorization:
        `Bearer ${accessToken}`,

      apikey:
        anonKey,

      "Content-Type":
        "application/json",

      Accept:
        "application/json",
    },

    body: JSON.stringify({
      empresa_id:
        EMPRESA_ID,

      conversation_id:
        CONVERSATION_ID,
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
  const semanticProposal =
    body.semantic_proposal &&
      typeof body.semantic_proposal === "object"
      ? body.semantic_proposal as JsonObject
      : {};

  const validatedDecision =
    body.validated_decision &&
      typeof body.validated_decision === "object"
      ? body.validated_decision as JsonObject
      : {};

  console.log("");
  console.log(
    "========== ATLAS SEMANTIC SMOKE RESULT ==========",
  );

  console.log(
    "status =",
    status,
  );

  const safeError =
    safeString(body.error);

  const safeMessage =
    safeString(body.message);

  if (safeError) {
    console.log(
      "error =",
      safeError,
    );
  }

  if (safeMessage) {
    console.log(
      "message =",
      safeMessage,
    );
  }

  if (
    body.runtime_version !== undefined
  ) {
    console.log(
      "runtime_version =",
      safeString(body.runtime_version),
    );
  }

  console.log("");
  console.log(
    "--- semantic_proposal ---",
  );

  console.log(
    "intent_code =",
    safeString(
      semanticProposal.intent_code,
    ),
  );

  console.log(
    "confidence =",
    safeNumber(
      semanticProposal.confidence,
    ),
  );

  console.log(
    "tool_required =",
    safeBoolean(
      semanticProposal.tool_required,
    ),
  );

  console.log(
    "selected_tool_code =",
    safeString(
      semanticProposal.selected_tool_code,
    ),
  );

  console.log(
    "seriousness_level =",
    safeString(
      semanticProposal.seriousness_level,
    ),
  );

  console.log(
    "humor_allowed =",
    safeBoolean(
      semanticProposal.humor_allowed,
    ),
  );

  console.log(
    "response_mode =",
    safeString(
      semanticProposal.response_mode,
    ),
  );

  console.log("");
  console.log(
    "--- validated_decision ---",
  );

  console.log(
    "validation_status =",
    safeString(
      validatedDecision.validation_status,
    ),
  );

  console.log(
    "intent_code =",
    safeString(
      validatedDecision.intent_code,
    ),
  );

  console.log(
    "permission_granted =",
    safeBoolean(
      validatedDecision.permission_granted,
    ),
  );

  console.log(
    "tool_allowed =",
    safeBoolean(
      validatedDecision.tool_allowed,
    ),
  );

  console.log(
    "safe_to_execute =",
    safeBoolean(
      validatedDecision.safe_to_execute,
    ),
  );

  console.log(
    "selected_tool_code =",
    safeString(
      validatedDecision.selected_tool_code,
    ),
  );

  console.log(
    "clarification_required =",
    safeBoolean(
      validatedDecision.clarification_required,
    ),
  );

  console.log("");

  console.log(
    "next_action =",
    safeString(body.next_action),
  );

  console.log(
    "==================================================",
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

  if (parts.length >= 3) {
    const internalCode =
      parts[0];

    const safeCode =
      parts[1];

    const safeMessage =
      parts.slice(2).join("|");

    console.error(
      `[SMOKE] ERROR: ${internalCode} - ${safeCode} - ${safeMessage}`,
    );

    return;
  }

  console.error(
    "[SMOKE] ERROR: INTERNAL - Smoke test failed safely.",
  );
}

async function main(): Promise<void> {
  console.log(
    "[SMOKE] Starting",
  );

  const SUPABASE_URL =
    getEnv("SUPABASE_URL");

  const SUPABASE_FUNCTIONS_URL =
    getEnv("SUPABASE_FUNCTIONS_URL");

  const SUPABASE_ANON_KEY =
    getEnv("SUPABASE_ANON_KEY");

  const OWNER_EMAIL =
    getEnv("OWNER_EMAIL");

  const OWNER_PASSWORD =
    getEnv("OWNER_PASSWORD");

  if (
    !SUPABASE_URL ||
    !SUPABASE_FUNCTIONS_URL ||
    !SUPABASE_ANON_KEY ||
    !OWNER_EMAIL ||
    !OWNER_PASSWORD
  ) {
    console.error(
      "[SMOKE] ERROR: MISSING_ENV - One or more required env vars are missing.",
    );

    Deno.exit(1);
  }

  console.log(
    "[SMOKE] Environment present",
  );

  try {
    console.log(
      "[SMOKE] Authenticating OWNER",
    );

    const accessToken =
      await signInWithPassword(
        SUPABASE_URL,
        SUPABASE_ANON_KEY,
        OWNER_EMAIL,
        OWNER_PASSWORD,
      );

    console.log(
      "[SMOKE] Authentication OK",
    );

    console.log(
      "[SMOKE] Loading decision context",
    );

    const context =
      await callPrepareContext(
        SUPABASE_URL,
        SUPABASE_ANON_KEY,
        accessToken,
      );

    const currentMessage =
      context.current_message &&
        typeof context.current_message === "object"
        ? context.current_message as JsonObject
        : {};

    const normalized =
      safeString(
        currentMessage.normalized_content,
      ) ??
      safeString(
        currentMessage.content,
      ) ??
      safeString(
        currentMessage.text_content,
      );

    if (
      normalized !== EXPECTED_MESSAGE
    ) {
      console.error(
        "[SMOKE] ERROR: MESSAGE_MISMATCH - Prepared decision context does not contain the expected Smoke A message.",
      );

      if (normalized) {
        console.error(
          "[SMOKE] Current message (safe) =",
          normalized,
        );
      }

      Deno.exit(2);
    }

    console.log(
      "[SMOKE] Current message verified",
    );

    console.log(
      "[SMOKE] Calling Edge Function",
    );

    const result =
      await callEdgeFunction(
        SUPABASE_FUNCTIONS_URL,
        accessToken,
        SUPABASE_ANON_KEY,
      );

    console.log(
      "[SMOKE] Semantic response received",
    );

    printSafeResult(
      result.status,
      result.body,
    );

    const validatedDecision =
      result.body.validated_decision &&
        typeof result.body.validated_decision === "object"
        ? result.body.validated_decision as JsonObject
        : {};

    const validatedIntent =
      safeString(
        validatedDecision.intent_code,
      );

    if (
      result.status < 200 ||
      result.status >= 300
    ) {
      console.error(
        `[SMOKE] FAIL - Edge Function returned HTTP ${result.status}`,
      );

      Deno.exit(3);
    }

    if (
      validatedIntent !==
        "EXECUTIVE_STATUS"
    ) {
      console.error(
        `[SMOKE] FAIL - Expected EXECUTIVE_STATUS but received ${
          validatedIntent ?? "null"
        }`,
      );

      Deno.exit(4);
    }

    console.log("");

    console.log(
      "[SMOKE] PASS - Smoke A resolved to EXECUTIVE_STATUS",
    );

    // Important:
    // This smoke test NEVER executes next_action.

    Deno.exit(0);
  } catch (error) {
    printSafeError(error);
    Deno.exit(1);
  }
}

if (import.meta.main) {
  await main();
}