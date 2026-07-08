"""Pydantic v2 wire models for mcp-glimpse.

The wire contract is camelCase and pinned. Two rules are load-bearing (proven the hard
way in the mcp-lens builds):

1. Serialize with by_alias=True so field names go out camelCase. FastMCP's unstructured
   text conversion serializes by field name (snake_case) and IGNORES by_alias, so tools
   must return `to_wire_json()` (a JSON *string*) with structured_output=False, not a model.
2. Serialize with exclude_none=True so an undeclared annotation hint is OMITTED (the TS
   view then sees `undefined`), never `null`. The view keys "annotated?" off `!== undefined`.
"""
from __future__ import annotations

from pydantic import BaseModel, ConfigDict
from pydantic.alias_generators import to_camel


class CamelModel(BaseModel):
    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True,
        extra="ignore",
    )


class ModelInfo(CamelModel):
    id: str | None = None
    display_name: str | None = None
    provider: str | None = None


class HostInfo(CamelModel):
    name: str | None = None
    version: str | None = None


class ClientCapabilities(CamelModel):
    sampling: bool | None = None
    elicitation: bool | None = None
    roots: bool | None = None
    root_paths: list[str] | None = None


class ServerRef(CamelModel):
    name: str
    title: str | None = None
    offers_prompts: bool | None = None
    offers_resources: bool | None = None


class ToolRef(CamelModel):
    name: str
    server: str | None = None
    description: str | None = None
    read_only_hint: bool | None = None
    destructive_hint: bool | None = None
    idempotent_hint: bool | None = None
    open_world_hint: bool | None = None
    title: str | None = None

    @property
    def has_annotations(self) -> bool:
        return any(
            v is not None
            for v in (
                self.read_only_hint,
                self.destructive_hint,
                self.idempotent_hint,
                self.open_world_hint,
                self.title,
            )
        )

    @property
    def is_dangerous(self) -> bool:
        return self.destructive_hint is True or self.open_world_hint is True


class ContextWindow(CamelModel):
    used_tokens: int | None = None
    total_tokens: int | None = None


class EnvInfo(CamelModel):
    cwd: str | None = None
    date: str | None = None
    platform: str | None = None
    os_version: str | None = None


class Persona(CamelModel):
    name: str | None = None
    notes: str | None = None


class GlimpseSnapshot(CamelModel):
    model: ModelInfo | None = None
    host: HostInfo | None = None
    client_capabilities: ClientCapabilities | None = None
    servers: list[ServerRef] = []
    tools: list[ToolRef] = []
    context_window: ContextWindow | None = None
    environment: EnvInfo | None = None
    persona: Persona | None = None
    skills: list[str] = []
    notes: str | None = None


class ConnectionFacts(CamelModel):
    protocol_version: str | None = None
    client_name: str | None = None
    client_version: str | None = None
    transport: str | None = None
    session_id: str | None = None
    server_name: str = "mcp-glimpse"
    server_version: str = "0.0.0"
    server_edition: str | None = None
    server_instance: str | None = None
    server_started_utc: str | None = None
    server_tools: list[str] = []
    server_prompts: list[str] = []
    server_resources: list[str] = []
    roots: list[str] = []


class LargestServer(CamelModel):
    name: str | None = None
    tool_count: int = 0


class VantageGap(CamelModel):
    server_sees: int = 0
    agent_sees: int = 0


class ServerCost(CamelModel):
    name: str | None = None
    estimated_tokens: int = 0


class ContextCost(CamelModel):
    estimated_tokens_low: int = 0
    estimated_tokens_high: int = 0
    window_total_tokens: int | None = None
    per_server: list[ServerCost] = []
    model_family: str | None = None
    method: str | None = None


class PoisoningFinding(CamelModel):
    tool: str
    category: str
    detail: str


class Analysis(CamelModel):
    total_tools: int = 0
    total_servers: int = 0
    largest_server: LargestServer | None = None
    servers_offering_prompts: int = 0
    servers_offering_resources: int = 0
    duplicate_tool_names: list[str] = []
    dangerous_tool_count: int = 0
    annotated_tool_count: int = 0
    unannotated_tool_count: int = 0
    inconsistencies: list[str] = []
    vantage_gap: VantageGap | None = None
    context_cost: ContextCost | None = None
    tool_poisoning: list[PoisoningFinding] = []


class GlimpseReport(CamelModel):
    source: str
    snapshot: GlimpseSnapshot | None = None
    connection: ConnectionFacts
    analysis: Analysis
    warnings: list[str] = []
    narrative: str | None = None  # sampling demonstrator: "your environment, in prose"

    def to_wire_json(self) -> str:
        return self.model_dump_json(by_alias=True, exclude_none=True)
