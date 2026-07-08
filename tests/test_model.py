import json

from mcp_glimpse.model import (
    Analysis,
    ConnectionFacts,
    GlimpseReport,
    GlimpseSnapshot,
    ToolRef,
    VantageGap,
)


def _report(analysis: Analysis | None = None, snapshot: GlimpseSnapshot | None = None) -> GlimpseReport:
    return GlimpseReport(
        source="test",
        snapshot=snapshot,
        connection=ConnectionFacts(),
        analysis=analysis or Analysis(),
    )


def _wire(report: GlimpseReport) -> dict:
    return json.loads(report.to_wire_json())


def test_wire_keys_are_camelcase():
    report = _report(
        analysis=Analysis(
            total_tools=3,
            total_servers=1,
            dangerous_tool_count=1,
            annotated_tool_count=2,
            unannotated_tool_count=1,
            duplicate_tool_names=["dup"],
            vantage_gap=VantageGap(server_sees=2, agent_sees=3),
        )
    )
    wire = _wire(report)
    a = wire["analysis"]
    assert a["totalTools"] == 3
    assert a["totalServers"] == 1
    assert a["dangerousToolCount"] == 1
    assert a["annotatedToolCount"] == 2
    assert a["unannotatedToolCount"] == 1
    assert a["duplicateToolNames"] == ["dup"]
    assert "total_tools" not in a
    assert a["vantageGap"]["serverSees"] == 2
    assert a["vantageGap"]["agentSees"] == 3
    c = wire["connection"]
    assert c["serverName"] == "mcp-glimpse"
    assert "serverVersion" in c
    assert c["serverTools"] == []


def test_declared_hints_are_camelcase_and_undeclared_hints_are_omitted():
    snap = GlimpseSnapshot(tools=[ToolRef(name="read_thing", read_only_hint=True)])
    tool = _wire(_report(snapshot=snap))["snapshot"]["tools"][0]
    assert tool["readOnlyHint"] is True
    assert "destructiveHint" not in tool
    assert "idempotentHint" not in tool
    assert "openWorldHint" not in tool


def test_camel_alias_and_snake_input_both_accepted():
    assert ToolRef.model_validate({"name": "t", "readOnlyHint": True}).read_only_hint is True
    assert ToolRef.model_validate({"name": "t", "read_only_hint": True}).read_only_hint is True


def test_tool_has_annotations_property():
    assert ToolRef(name="t", read_only_hint=True).has_annotations is True
    assert ToolRef(name="t", title="X").has_annotations is True
    assert ToolRef(name="t").has_annotations is False


def test_tool_is_dangerous_property():
    assert ToolRef(name="t", destructive_hint=True).is_dangerous is True
    assert ToolRef(name="t", open_world_hint=True).is_dangerous is True
    assert ToolRef(name="t", read_only_hint=True).is_dangerous is False
    assert ToolRef(name="t").is_dangerous is False


def test_snapshot_defaults_to_empty_collections():
    snap = GlimpseSnapshot()
    assert snap.servers == []
    assert snap.tools == []
    assert snap.skills == []
    assert snap.model is None
