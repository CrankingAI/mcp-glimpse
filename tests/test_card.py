from mcp_glimpse.analyzer import analyze
from mcp_glimpse.card import (
    Card,
    LocalCardStore,
    aggregate,
    aggregates_from_snapshot_json,
    render_og_png,
)
from mcp_glimpse.model import (
    ClientCapabilities,
    ConnectionFacts,
    GlimpseSnapshot,
    ModelInfo,
    ToolRef,
)


def test_aggregate_is_counts_only_no_tool_names_leak():
    snap = GlimpseSnapshot(
        model=ModelInfo(id="claude-opus-4-8"),
        client_capabilities=ClientCapabilities(sampling=True, elicitation=True),
        tools=[
            ToolRef(name="secret_tool", server="s1", destructive_hint=True),
            ToolRef(name="another", server="s2", read_only_hint=True),
        ],
    )
    agg = aggregate(analyze(snap, ConnectionFacts()), snap)
    assert agg["tools"] == 2
    assert agg["destructive"] == 1
    assert agg["sampling"] is True
    assert agg["roots"] is False
    assert "secret_tool" not in str(agg)  # data minimization: no names leak


def test_card_store_put_get_and_persistence(tmp_path):
    path = tmp_path / "cards.jsonl"
    store = LocalCardStore(path)
    card = store.put({"servers": 3, "tools": 15})
    assert card.id and store.get(card.id).tools == 15
    # a fresh store reloads from disk
    assert LocalCardStore(path).get(card.id) is not None


def test_render_og_png_is_a_valid_png():
    card = Card(
        id="abc123def456", servers=3, tools=15, destructive=2, annotation_coverage_pct=20,
        sampling=True, elicitation=True, cost_low=38000, cost_high=46000, window=200000,
    )
    png = render_og_png(card)
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    assert len(png) > 2000


def test_aggregates_from_snapshot_json():
    agg = aggregates_from_snapshot_json('{"tools": [{"name": "x", "server": "s"}]}')
    assert agg["tools"] == 1
    assert agg["servers"] == 1
