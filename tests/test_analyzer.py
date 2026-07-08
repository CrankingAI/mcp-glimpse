from mcp_glimpse.analyzer import analyze
from mcp_glimpse.model import ConnectionFacts, GlimpseSnapshot, ServerRef, ToolRef


def conn(*server_tools: str) -> ConnectionFacts:
    return ConnectionFacts(server_tools=list(server_tools))


def test_counts_tools_and_servers():
    snap = GlimpseSnapshot(
        servers=[ServerRef(name="a"), ServerRef(name="b")],
        tools=[ToolRef(name="t1", server="a"), ToolRef(name="t2", server="a"), ToolRef(name="t3", server="b")],
    )
    result = analyze(snap, conn())
    assert result.total_tools == 3
    assert result.total_servers == 2


def test_largest_server():
    snap = GlimpseSnapshot(
        tools=[ToolRef(name="t1", server="a"), ToolRef(name="t2", server="a"), ToolRef(name="t3", server="b")],
    )
    result = analyze(snap, conn())
    assert result.largest_server is not None
    assert result.largest_server.name == "a"
    assert result.largest_server.tool_count == 2


def test_total_servers_falls_back_to_distinct_tool_servers_when_servers_omitted():
    snap = GlimpseSnapshot(
        tools=[ToolRef(name="t1", server="a"), ToolRef(name="t2", server="b")],
    )
    result = analyze(snap, conn())
    assert result.total_servers == 2


def test_cross_server_duplicate_tool_names():
    snap = GlimpseSnapshot(
        tools=[ToolRef(name="search", server="a"), ToolRef(name="search", server="b"), ToolRef(name="unique", server="a")],
    )
    result = analyze(snap, conn())
    assert result.duplicate_tool_names == ["search"]


def test_dangerous_counts_destructive_and_open_world():
    snap = GlimpseSnapshot(
        tools=[
            ToolRef(name="a", destructive_hint=True),
            ToolRef(name="b", open_world_hint=True),
            ToolRef(name="c", read_only_hint=True),
        ],
    )
    assert analyze(snap, conn()).dangerous_tool_count == 2


def test_annotated_and_unannotated_counts():
    snap = GlimpseSnapshot(
        tools=[
            ToolRef(name="a", read_only_hint=True),
            ToolRef(name="b", title="B"),
            ToolRef(name="c"),
        ],
    )
    result = analyze(snap, conn())
    assert result.annotated_tool_count == 2
    assert result.unannotated_tool_count == 1


def test_servers_offering_prompts_and_resources():
    snap = GlimpseSnapshot(
        servers=[
            ServerRef(name="a", offers_prompts=True, offers_resources=True),
            ServerRef(name="b", offers_prompts=True),
            ServerRef(name="c"),
        ],
    )
    result = analyze(snap, conn())
    assert result.servers_offering_prompts == 2
    assert result.servers_offering_resources == 1


def test_vantage_gap_compares_server_view_to_agent_view():
    snap = GlimpseSnapshot(tools=[ToolRef(name="t1"), ToolRef(name="t2"), ToolRef(name="t3")])
    result = analyze(snap, conn("own_tool_a", "own_tool_b"))
    assert result.vantage_gap is not None
    assert result.vantage_gap.server_sees == 2
    assert result.vantage_gap.agent_sees == 3


def test_null_snapshot_zeroes_agent_view_but_keeps_server_view():
    result = analyze(None, conn("own_tool_a", "own_tool_b"))
    assert result.total_tools == 0
    assert result.total_servers == 0
    assert result.dangerous_tool_count == 0
    assert result.largest_server is None
    assert result.vantage_gap is not None
    assert result.vantage_gap.server_sees == 2
    assert result.vantage_gap.agent_sees == 0


def test_inconsistencies_are_surfaced():
    snap = GlimpseSnapshot(tools=[ToolRef(name="delete_it", read_only_hint=True)])
    result = analyze(snap, conn())
    assert len(result.inconsistencies) == 1
    assert "delete_it" in result.inconsistencies[0]
