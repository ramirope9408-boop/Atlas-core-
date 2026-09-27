# ATLAS B2 V2 — Static Validation Report

Date: 2026-09-27
Branch: audit/b2-generalization-20260927
Deployment status: NOT DEPLOYED
Validation mode: repository/static validation only

## Scope

This report validates the additive B2 conversational certification architecture created from the FingerFood generalization audit.

It does not claim database execution certification. No production Supabase migration has been applied.

## Confirmed fixes during static validation

### 1. Historical test-plan constraint name mismatch — FIXED

The original B2 core creates:

`atlas_test_plans_versions_check`

The first V2 materializer draft attempted to drop a different singular name.

Correction:
- drop the real historical constraint;
- also defensively drop the accidental singular name if present;
- recreate `atlas_test_plans_versions_check` allowing both:
  - B2_INSTALLATION_TEST_PLAN_V1
  - B2_INSTALLATION_TEST_PLAN_V2

Associated smoke test was corrected to inspect the actual constraint name.

### 2. Scenario result composite foreign-key ordering — FIXED

The scenario-result table referenced a composite identity on scenario instances before the composite UNIQUE constraint was created.

Correction:
- create `atlas_conversation_scenario_instance_identity_key` before creating the result table.

This removes a migration-order blocker.

### 3. Authenticated Edge Function → service-role-only RPC mismatch — FIXED

The new certification Edge Functions execute under an authenticated operator JWT.

Several low-level RPCs intentionally remained service-role only, which would have caused runtime permission failures if called directly.

Correction:
- keep low-level resolver/evaluator functions service-role only;
- add permission-checked authenticated wrapper RPCs using:
  - INSTALLATION_TEST_EXECUTE
  - INSTALLATION_TEST_READ
- update certification Edge Functions to call those wrappers.

### 4. Hardcoded evaluator model — FIXED

The semantic certification evaluator no longer hardcodes a model identifier.

Resolution order:
1. B2_CERT_EVALUATOR_MODEL
2. OPENAI_MODEL

If neither exists, execution is blocked with configuration error.

### 5. Single-turn false-state testing — FIXED ARCHITECTURALLY

Several discovered FingerFood failures are stateful:
- acknowledgement after an action;
- acknowledgement after modification;
- acceptance against current proposal;
- payment before acceptance;
- document after modification.

A single synthetic message cannot prove these states.

Correction:
- add explicit multi-turn scenario step definitions;
- execute the steps sequentially in the same isolated certification conversation;
- preserve step-by-step runtime evidence;
- evaluate assertions against the actual assertion-relevant step.

### 6. Synthetic-language placeholders — HARDENED

Literal placeholders such as ACKNOWLEDGEMENT_IN_INSTALLED_LOCALE are no longer used by the multi-turn runner.

Added:
- canonical locale detection from AGENT_PERSONALITY_PROFILE / LOCATION_AND_LOCALE;
- deterministic phrase resolver;
- initial es/en phrase packs for:
  - acknowledgement;
  - explicit acceptance;
  - payment request;
  - document request;
  - canonical lookup;
  - unsupported attribute;
  - visual request;
  - commercial setup;
  - modification;
  - self-correction.

Unsupported/missing locale => BLOCKED, never PASS.

### 7. Insufficient semantic evidence classification — FIXED

Semantic evaluator now distinguishes:
- FAILED: evidence proves the behavior fails;
- BLOCKED: evidence is insufficient to decide;
- PASSED: all required assertions pass.

Insufficient evidence can no longer silently become a normal FAIL or PASS.

## FingerFood leakage scan

Current static scan found FingerFood references only in explanatory comments:
- historical rationale comment;
- “no FingerFood-specific content” comment;
- “without embedding FingerFood-specific assumptions” comment.

No FingerFood product, price, bank, city or catalog value was found in runtime test logic.

No hardcoded OpenAI model identifier remains in the new certification Edge Functions.

## Current architecture after fixes

1. Assertion contract V2.
2. Test Plan materializer V2.
3. G03 readiness V2.
4. Generic scenario registry.
5. Scenario-plan materialization.
6. Scenario result ledger.
7. G03 conversational readiness V2.1.
8. Canonical binding resolver.
9. Scenario renderer.
10. Semantic evaluation contract gate.
11. Batch orchestration.
12. Certification package + explicit UAT handoff.
13. Permission-checked operator RPC wrappers.
14. Multi-turn scenario protocol.
15. Locale/phrase resolver.
16. Installed-runtime certification runner V1.1.
17. Evidence-bounded semantic evaluator.
18. Result executor.
19. Batch executor.

## Remaining blockers before any deployment

### BLOCKER A — Database execution validation

The full migration chain must be applied to a disposable/non-production database or equivalent isolated test environment.

Need to validate:
- SQL parse/DDL;
- FK creation;
- function signatures;
- grants;
- constraint names;
- migration ordering;
- trigger/RLS interactions;
- idempotency expectations.

### BLOCKER B — TypeScript/Deno compile validation

The four certification Edge Functions require compile/type validation against the repository import map/runtime.

### BLOCKER C — Certification conversation authority

The runner currently uses the existing internal-chat conversation/open/register path.

Need to confirm that an ATLAS implementation operator executing B2 certification necessarily has the company-level INTERNAL_CHAT_USE authority required by that path.

If not, create a dedicated B2 certification conversation authority rather than weakening normal internal-chat permissions.

### BLOCKER D — Locale coverage

Current deterministic synthetic phrase packs cover es/en only.

Other locales must be BLOCKED until an approved phrase pack exists.

### BLOCKER E — Stateful commercial setup validity

Multi-turn structure now exists, but each capability must still be proven to create the intended canonical precondition on a real installed runtime:
- visible proposal created;
- modification applied;
- document source version updated;
- payment gate still unaccepted.

The batch runner must not infer that setup succeeded merely because a turn completed.

## Certification rule

Until blockers A–E are resolved:

`NOT_READY_FOR_DEPLOYMENT`

This is not a failure of the architecture. It is the required pre-deployment validation state.

## Safety

- No production migration applied.
- No historical B2 V1 certificate modified.
- No historical V1 test plan rewritten.
- No production Valentina workflow cut over.
- No company-specific FingerFood rule promoted into CORE.
