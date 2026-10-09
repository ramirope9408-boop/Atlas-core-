export const ATLAS_AGENT_TOOLS = [
  {
    type: "function",
    name: "get_commercial_context",
    description: "Read the tenant-scoped canonical commercial context for the current customer/conversation/opportunity.",
    parameters: { type:"object", properties:{}, additionalProperties:false }
  },
  {
    type: "function",
    name: "get_company_policy",
    description: "Read canonical company commercial policy when the customer asks about service scope, minimums, deposits, waiters, decoration, delivery or other business rules. Never invent policy from general knowledge.",
    parameters: { type:"object", properties:{ topic:{type:"string"} }, additionalProperties:false }
  },
  {
    type: "function",
    name: "list_opportunities",
    description: "List tenant-scoped opportunities for the current customer conversation so references such as 'the baptism' or 'the other event' can be grounded before resuming one.",
    parameters: { type:"object", properties:{}, additionalProperties:false }
  },
  {
    type: "function",
    name: "resume_opportunity",
    description: "Resume one existing opportunity only after its exact work_state_id has been grounded from list_opportunities or canonical context. Never guess an opportunity ID.",
    parameters: { type:"object", properties:{ work_state_id:{type:"string"} }, required:["work_state_id"], additionalProperties:false }
  },
  {
    type: "function",
    name: "open_opportunity",
    description: "Open a clean opportunity/event when the customer is clearly starting another commercial event. Never copy event-specific fields from another opportunity.",
    parameters: { type:"object", properties:{ reason:{type:"string"} }, required:["reason"], additionalProperties:false }
  },
  {
    type: "function",
    name: "update_event",
    description: "Patch explicit mutable event facts supplied or confirmed by the customer. If the customer explicitly retracts certainty about a mutable Work State fact and gives no replacement, set that specific field to null so ATLAS no longer treats it as known. Never use this to clear formal quote, acceptance, payment, or reservation truth.",
    parameters: { type:"object", properties:{ patch:{ type:"object", properties:{ event_patch:{type:"object"}, requirements:{type:"object"} }, additionalProperties:false } }, required:["patch"], additionalProperties:false }
  },
  {
    type: "function",
    name: "search_catalog",
    description: "Find canonical company products through ATLAS hybrid retrieval (lexical + fuzzy + structured context + vector similarity). Send the shortest query that preserves the customer's useful intent. A product/category term is enough for exact searches; a compact natural phrase such as 'opciones ligeras para bautizo' is appropriate when context, preference, budget or subcategory matters. Use multiple searches only when the customer expresses genuinely different product intents. Never invent recommendations.",
    parameters: { type:"object", properties:{ query:{type:"string"}, exclude_product_ids:{type:"array",items:{type:"string"}} }, required:["query"], additionalProperties:false }
  },
  {
    type: "function",
    name: "select_products",
    description: "Select canonical products for the active opportunity. Pass explicit quantities when the customer supplies them. When quantity is omitted, ATLAS preserves an existing recommended quantity when available.",
    parameters: {
      type:"object",
      properties:{
        product_ids:{type:"array",items:{type:"string"}},
        items:{
          type:"array",
          items:{
            type:"object",
            properties:{product_id:{type:"string"},quantity:{type:"integer",minimum:1}},
            required:["product_id"],
            additionalProperties:false
          }
        }
      },
      additionalProperties:false
    }
  },
  {
    type: "function",
    name: "show_products",
    description: "Request canonical product visuals or a paginated canonical catalog page. For REFERENCE pass product_ids. For CATALOG_PAGE product_ids may be omitted and page selects the catalog page.",
    parameters: { type:"object", properties:{ product_ids:{type:"array",items:{type:"string"}}, scope:{type:"string",enum:["REFERENCE","CATALOG_PAGE"]}, page:{type:"integer",minimum:1} }, additionalProperties:false }
  },
  {
    type: "function",
    name: "get_transaction_state",
    description: "Read the current accepted-quote, payment-evidence and reservation state for this conversation. Use this before telling the customer that payment or reservation is confirmed.",
    parameters: { type:"object", properties:{}, additionalProperties:false }
  },
  {
    type: "function",
    name: "register_payment_evidence",
    description: "Register that the customer sent payment evidence. This NEVER confirms payment or reservation. Use only when the current customer message actually contains or claims a payment receipt/evidence.",
    parameters: {
      type:"object",
      properties:{
        claimed_amount:{type:["number","null"]},
        provider_reference:{type:["string","null"]},
        note:{type:["string","null"]}
      },
      additionalProperties:false
    }
  },
  {
    type: "function",
    name: "request_commercial_exception",
    description: "Create a governed exception request when the customer asks for something outside normal company policy, such as holding a date without confirmed payment. This does not approve the exception; it sends the case to human review.",
    parameters: {
      type:"object",
      properties:{
        exception_type:{type:"string"},
        customer_reason:{type:["string","null"]}
      },
      required:["exception_type"],
      additionalProperties:false
    }
  },
  {
    type: "function",
    name: "request_cancellation",
    description: "Handle a customer's decision to withdraw/cancel. ATLAS will complete a pre-payment withdrawal when safe, but after confirmed payment or reservation it only creates a human-reviewed cancellation request and does not cancel automatically.",
    parameters: {
      type:"object",
      properties:{
        customer_reason:{type:["string","null"]}
      },
      additionalProperties:false
    }
  },
  {
    type: "function",
    name: "request_handoff",
    description: "Request a human operator when the customer asks for a person or the situation requires authority/capability outside the agent. This creates a governed pending handoff only; it does not grant human control by itself.",
    parameters: {
      type:"object",
      properties:{
        reason_code:{type:"string"},
        reason_detail:{type:["string","null"]},
        priority:{type:"string",enum:["LOW","NORMAL","HIGH","URGENT"]}
      },
      required:["reason_code"],
      additionalProperties:false
    }
  },
  {
    type: "function",
    name: "create_quote",
    description: "Request a canonical quote only when the active opportunity satisfies company requirements.",
    parameters: { type:"object", properties:{}, additionalProperties:false }
  },
  {
    type: "function",
    name: "quote_action",
    description: "Read, resend, modify, accept or request payment for the current canonical quote. For MODIFY provide a structured interpretation/patch grounded in the customer's message.",
    parameters: {
      type:"object",
      properties:{
        action:{type:"string",enum:["GET","RESEND","MODIFY","ACCEPT","PAYMENT"]},
        interpretation:{
          type:"object",
          properties:{
            primary_intent:{type:"string"},
            intent_confidence:{type:"number",minimum:0,maximum:1},
            ambiguities:{type:"array",items:{type:"string"}},
            patch:{
              type:"object",
              properties:{
                people_count:{type:"integer",minimum:1},
                event_date:{type:"string"},
                event_location:{type:"string"},
                products:{
                  type:"array",
                  items:{
                    type:"object",
                    properties:{
                      op:{type:"string",enum:["ADD","SET","REMOVE"]},
                      product_id:{type:"string"},
                      quantity:{type:"number"}
                    },
                    required:["op","product_id"],
                    additionalProperties:false
                  }
                },
                services:{
                  type:"array",
                  items:{
                    type:"object",
                    properties:{
                      op:{type:"string",enum:["REMOVE","SET_QUANTITY"]},
                      service_item_id:{type:"string"},
                      quantity:{type:"number"}
                    },
                    required:["op","service_item_id"],
                    additionalProperties:false
                  }
                }
              },
              additionalProperties:false
            }
          },
          additionalProperties:false
        }
      },
      required:["action"],
      additionalProperties:false
    }
  }
] as const;
