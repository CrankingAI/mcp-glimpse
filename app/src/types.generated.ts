// GENERATED from src/mcp_glimpse/model.py by scripts/gen_app_types.py — do not edit.
// Regenerate: uv run python scripts/gen_app_types.py (drift-gated by tests/test_app_types.py).

export interface ModelInfo {
  id?: string;
  displayName?: string;
  provider?: string;
}

export interface HostInfo {
  name?: string;
  version?: string;
}

export interface ClientCapabilities {
  sampling?: boolean;
  elicitation?: boolean;
  roots?: boolean;
  rootPaths?: string[];
}

export interface ServerRef {
  name: string;
  title?: string;
  offersPrompts?: boolean;
  offersResources?: boolean;
}

export interface ToolRef {
  name: string;
  server?: string;
  description?: string;
  readOnlyHint?: boolean;
  destructiveHint?: boolean;
  idempotentHint?: boolean;
  openWorldHint?: boolean;
  title?: string;
}

export interface ContextWindow {
  usedTokens?: number;
  totalTokens?: number;
}

export interface EnvInfo {
  cwd?: string;
  date?: string;
  platform?: string;
  osVersion?: string;
}

export interface Persona {
  name?: string;
  notes?: string;
}

export interface GlimpseSnapshot {
  model?: ModelInfo;
  host?: HostInfo;
  clientCapabilities?: ClientCapabilities;
  servers?: ServerRef[];
  tools?: ToolRef[];
  contextWindow?: ContextWindow;
  environment?: EnvInfo;
  persona?: Persona;
  skills?: string[];
  notes?: string;
}

export interface ConnectionFacts {
  protocolVersion?: string;
  clientName?: string;
  clientVersion?: string;
  transport?: string;
  sessionId?: string;
  serverName?: string;
  serverVersion?: string;
  serverEdition?: string;
  serverInstance?: string;
  serverStartedUtc?: string;
  serverTools?: string[];
  serverPrompts?: string[];
  serverResources?: string[];
  roots?: string[];
}

export interface LargestServer {
  name?: string;
  toolCount?: number;
}

export interface VantageGap {
  serverSees?: number;
  agentSees?: number;
}

export interface ServerCost {
  name?: string;
  estimatedTokens?: number;
}

export interface ContextCost {
  estimatedTokensLow?: number;
  estimatedTokensHigh?: number;
  windowTotalTokens?: number;
  perServer?: ServerCost[];
  modelFamily?: string;
  method?: string;
}

export interface PoisoningFinding {
  tool: string;
  category: string;
  detail: string;
}

export interface AnnotationVisibility {
  ownToolsInSnapshot?: number;
  ownToolsDeclared?: number;
  ownToolsEchoed?: number;
  verdict: string;
  detail: string;
}

export interface Analysis {
  totalTools?: number;
  totalServers?: number;
  largestServer?: LargestServer;
  serversOfferingPrompts?: number;
  serversOfferingResources?: number;
  duplicateToolNames?: string[];
  dangerousToolCount?: number;
  annotatedToolCount?: number;
  unannotatedToolCount?: number;
  annotationVisibility?: AnnotationVisibility;
  inconsistencies?: string[];
  vantageGap?: VantageGap;
  contextCost?: ContextCost;
  toolPoisoning?: PoisoningFinding[];
}

export interface GlimpseReport {
  source: string;
  snapshot?: GlimpseSnapshot;
  connection: ConnectionFacts;
  analysis: Analysis;
  warnings?: string[];
  narrative?: string;
}
