from mcp_glimpse.model import ContextWindow, GlimpseSnapshot, ModelInfo, ToolRef
from mcp_glimpse.tokenizer import _family, estimate


def test_family_detection():
    assert _family("claude-opus-4-8") == "anthropic"
    assert _family("gpt-4o") == "openai"
    assert _family("gemini-2.5-pro") == "google"
    assert _family("llama-3.1-70b") == "meta"
    assert _family("something-else") == "unknown"


def test_estimate_none_when_no_tools():
    assert estimate(None) is None
    assert estimate(GlimpseSnapshot()) is None


def test_estimate_produces_range_and_per_server_and_window():
    snap = GlimpseSnapshot(
        model=ModelInfo(id="claude-opus-4-8"),
        context_window=ContextWindow(total_tokens=200000),
        tools=[
            ToolRef(name="read_file", server="fs", description="Read a file and return its contents."),
            ToolRef(name="write_file", server="fs", description="Write text to a file on disk."),
            ToolRef(name="search", server="web", description="Search the web for a query string."),
        ],
    )
    cost = estimate(snap)
    assert cost is not None
    assert cost.estimated_tokens_low > 0
    assert cost.estimated_tokens_high >= cost.estimated_tokens_low
    assert cost.window_total_tokens == 200000
    assert cost.model_family == "anthropic"
    assert {s.name for s in cost.per_server} == {"fs", "web"}
    # fs has two tools, so it should cost more than web's one tool.
    by_name = {s.name: s.estimated_tokens for s in cost.per_server}
    assert by_name["fs"] > by_name["web"]
    assert "tiktoken" in cost.method or "heuristic" in cost.method
