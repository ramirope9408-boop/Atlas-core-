# ATLAS Agent Runtime V1 — Regression Gate

This gate must pass before any production WhatsApp cutover.

## Isolation
- Production atlas-commercial-turn V11 remains untouched.
- atlas-agent-runtime-v1 is invoked only by an isolated test route.
- No outbound delivery is enabled during regression.

## Canonical authority
- Company/agent profile comes from empresa_id installation data, never request overrides.
- Catalog products must resolve to canonical tenant-scoped IDs.
- Quote/payment actions execute through ATLAS canonical commercial authority.
- Commercial actions are grounded in the real source_message_id text.
- No arbitrary SQL or model-selected endpoint is available.

## Required scenario
1. Start a bautizo for 25 people and request Finger Table recommendations.
2. Supply date and location.
3. Ask for different/more alternatives.
4. Ask to see those products.
5. Select referenced products and also request more catalog options in the same turn.
6. Supply duration, decoration preference and waiter requirement.
7. Request quote.
8. Accept the delivered current quote.
9. Request payment.
10. Start a second event in the same WhatsApp conversation.
11. Return to the first opportunity without contaminating either event.

## Regression families
R1 recommendation novelty: MORE must exclude already shown products when alternatives exist.
R2 opportunity isolation: new event must not inherit event date/location/service/selection/reference.
R3 compound intent: selection + visual/catalog request must both survive one customer turn.
R4 event schema: service duration, decoration and waiters remain explicit canonical requirements.
R5 simple event facts: date/location/people updates must not be rejected by phrase matching.
R6 service correction: explicit service changes update canonical state without regex classification.
R7 plural reference: visuals/selections can preserve a group of canonical product IDs.
R8 post-acceptance idempotency: repeated acceptance is acknowledgement, never duplicate acceptance.
R9 payment authority: payment data is available only for the accepted/current canonical quote.
R10 tenant isolation: every read/write is constrained by empresa_id.
R11 relationship safety: NO_ACTION/WAIT is allowed; no forced follow-up.

## Cutover rule
Do not route production WhatsApp until all required scenarios are evidenced. A model-generated answer alone is not PASS; canonical database state and tool trace must agree.
