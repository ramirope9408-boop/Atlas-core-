# Valentina Agent V1 — POC

Status: experimental, isolated from production routing.

## Goal

Replace the monolithic language-to-decision interpreter with an agent runtime that can reason across multiple commercial actions and call narrow canonical ATLAS tools.

Principle:

> AI understands and plans. ATLAS validates and executes.

## Boundaries

The agent MUST NOT:
- write arbitrary SQL;
- invent products, prices, availability, policies, quote totals or payment status;
- treat customer memory as transactional truth;
- reuse event data merely because it exists in conversation history.

Canonical authorities remain:
- company policy -> business truth;
- catalog -> product/price truth;
- opportunity/work state -> active event truth;
- formal quote -> issued commercial truth;
- accepted quote/payment -> transactional truth;
- CRM -> relationship context only.

## POC tool surface

1. get_commercial_context
2. start_event
3. update_event
4. search_catalog
5. select_products
6. show_products
7. create_quote
8. quote_action

Each tool is tenant-scoped by empresa_id and validates its own arguments.

## Agent behavior

A customer may have several opportunities in the same WhatsApp conversation.
The agent must identify which opportunity is being discussed before mutating state.
A new explicit occasion must not inherit event-specific fields from another opportunity.
One user message may require several tool calls.

Example:
"agrégame esas y muéstrame el catálogo"
=> select_products(current reference group)
=> show_products(catalog scope)
=> one natural response.

## POC acceptance scenario

Conversation:
1. "Hola Vale, quiero organizar un bautizo para unas 25 personas y estaba pensando en una mesa finger. ¿Qué me recomiendas?"
2. Provide date/location naturally.
3. "¿Además de esas tienes otras?"
4. "Muéstramelas."
5. "Agrégame esas pero muéstrame también el catálogo."
6. Provide duration/decoration/waiters.
7. Request quote.
8. Accept quote.
9. Ask how to pay.
10. Start a second event in the same WhatsApp conversation.
11. Return to the first event.

Pass requires:
- no cross-opportunity contamination;
- canonical product IDs only;
- distinct alternatives for MORE when available;
- plural references preserve the complete referenced group;
- compound intents can execute multiple safe tool calls;
- quote/payment truth remains canonical;
- no outbound delivery unless explicitly produced by the agent runtime and accepted by ATLAS.

## Migration strategy

V11/V4 remains production fallback during the POC.
No production WhatsApp routing is changed until the POC passes the controlled scenario.
