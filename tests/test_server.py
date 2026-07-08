import asyncio
import json

from mcp_glimpse import manifest
from mcp_glimpse.feedback import LocalFeedbackStore
from mcp_glimpse.server import build_server


def _mcp():
    return build_server(feedback=LocalFeedbackStore())


def _extract_text(result):
    # FastMCP.call_tool returns a list[TextContent] (or a (content, structured) tuple in some
    # minors); normalize to the first text payload.
    content = result[0] if isinstance(result, tuple) else result
    block = content[0]
    return getattr(block, "text", block)


def test_registered_tool_names_match_manifest():
    tools = asyncio.run(_mcp().list_tools())
    assert [t.name for t in tools] == manifest.TOOLS


def test_every_tool_is_annotated():
    tools = {t.name: t for t in asyncio.run(_mcp().list_tools())}
    intro = tools["introspect_mcp_context"].annotations
    assert intro.readOnlyHint is True
    assert intro.idempotentHint is True
    assert intro.openWorldHint is False
    assert intro.title == "Introspect MCP / agent context"
    fb = tools["submit_feedback"].annotations
    assert fb.readOnlyHint is False and fb.destructiveHint is False
    assert fb.title == "Submit feedback / feature request / bug"


def test_introspect_input_schema_hides_ctx_and_exposes_snapshot_json():
    tools = {t.name: t for t in asyncio.run(_mcp().list_tools())}
    props = tools["introspect_mcp_context"].inputSchema.get("properties", {})
    assert "snapshot_json" in props
    assert "ctx" not in props and "self" not in props


def test_introspect_meta_links_ui_resource():
    tools = {t.name: t for t in asyncio.run(_mcp().list_tools())}
    assert tools["introspect_mcp_context"].meta["ui"]["resourceUri"] == manifest.UI_RESOURCE_URI


def test_prompt_and_resource_counts_match_manifest():
    mcp = _mcp()
    assert [p.name for p in asyncio.run(mcp.list_prompts())] == manifest.PROMPTS
    uris = {str(r.uri) for r in asyncio.run(mcp.list_resources())}
    assert "glimpse://snapshot-schema" in uris


def test_introspect_call_returns_camelcase_wire_json():
    mcp = _mcp()
    result = asyncio.run(mcp.call_tool("introspect_mcp_context", {}))
    wire = json.loads(_extract_text(result))
    assert wire["source"] == "introspect_mcp_context"
    assert wire["connection"]["serverName"] == "mcp-glimpse"
    assert "totalTools" in wire["analysis"]


def test_submit_feedback_call_records():
    store = LocalFeedbackStore()
    mcp = build_server(feedback=store)
    asyncio.run(mcp.call_tool("submit_feedback", {"kind": "bug", "summary": "x"}))
    assert store.records and store.records[0]["kind"] == "bug"
