export type AgentOperation =
  | { type: "GET_COMMERCIAL_CONTEXT" }
  | { type: "OPEN_OPPORTUNITY"; reason?: string }
  | { type: "PATCH_EVENT"; patch: Record<string, unknown> }
  | { type: "SEARCH_CATALOG"; query: string; exclude_product_ids?: string[] }
  | { type: "SELECT_PRODUCTS"; product_ids: string[] }
  | { type: "SHOW_PRODUCTS"; product_ids?: string[]; scope?: "REFERENCE"|"CATALOG" }
  | { type: "CREATE_QUOTE" }
  | { type: "QUOTE_ACTION"; action: "GET"|"MODIFY"|"ACCEPT"|"PAYMENT" };

export type RelationshipJudgment = {
  observed_style: {
    formality?: "FORMAL"|"NEUTRAL"|"INFORMAL";
    verbosity?: "BRIEF"|"NORMAL"|"DETAILED";
    pace?: "FAST"|"NORMAL"|"DELIBERATE";
    preferred_format?: "TEXT"|"AUDIO"|"MIXED";
  };
  explicit_signals: string[];
  action_posture: "ACT"|"ASK"|"WAIT"|"NO_ACTION"|"HANDOFF";
  rationale: string;
  confidence: number;
};

export type AgentPlan = {
  lifecycle: "CONTINUE"|"OPEN_NEW"|"SWITCH"|"CLARIFY";
  opportunity_id?: string;
  relationship_judgment: RelationshipJudgment;
  operations: AgentOperation[];
  response_goal: string;
  unresolved: string[];
  confidence: number;
};
