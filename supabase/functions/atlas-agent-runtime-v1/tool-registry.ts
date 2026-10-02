export const ATLAS_AGENT_TOOLS = [
  {
    type: "function",
    name: "get_commercial_context",
    description: "Read the tenant-scoped canonical commercial context for the current customer/conversation/opportunity.",
    parameters: { type:"object", properties:{}, additionalProperties:false }
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
    description: "Find canonical company products relevant to the customer's request. Use this instead of inventing recommendations.",
    parameters: { type:"object", properties:{ query:{type:"string"}, exclude_product_ids:{type:"array",items:{type:"string"}} }, required:["query"], additionalProperties:false }
  },
  {
    type: "function",
    name: "select_products",
    description: "Select canonical products for the active opportunity.",
    parameters: { type:"object", properties:{ product_ids:{type:"array",items:{type:"string"}} }, required:["product_ids"], additionalProperties:false }
  },
  {
    type: "function",
    name: "show_products",
    description: "Request canonical product visuals. Prefer referenced/relevant products; do not flood the customer with the entire catalog.",
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
    description: "Read, modify, accept or request payment for the current canonical quote.",
    parameters: { type:"object", properties:{ action:{type:"string",enum:["GET","MODIFY","ACCEPT","PAYMENT"]} }, required:["action"], additionalProperties:false }
  }
] as const;
