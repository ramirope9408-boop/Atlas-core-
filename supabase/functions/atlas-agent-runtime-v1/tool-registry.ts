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
    description: "Patch explicit event facts supplied or confirmed by the customer.",
    parameters: { type:"object", properties:{ patch:{ type:"object", properties:{ event_patch:{type:"object"}, requirements:{type:"object"} }, additionalProperties:false } }, required:["patch"], additionalProperties:false }
  },
  {
    type: "function",
    name: "search_catalog",
    description: "Find canonical company products. Send concise catalog search terms, usually 1-3 product or category words, not a long natural-language sentence. For compound preferences, make multiple searches when useful. Use this instead of inventing recommendations.",
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
    name: "create_quote",
    description: "Request a canonical quote only when the active opportunity satisfies company requirements.",
    parameters: { type:"object", properties:{}, additionalProperties:false }
  },
  {
    type: "function",
    name: "quote_action",
    description: "Read, modify, accept or request payment for the current canonical quote. For MODIFY provide a structured interpretation/patch grounded in the customer's message.",
    parameters: {
      type:"object",
      properties:{
        action:{type:"string",enum:["GET","MODIFY","ACCEPT","PAYMENT"]},
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
