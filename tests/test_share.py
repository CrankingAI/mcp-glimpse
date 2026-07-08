import asyncio
import json

import httpx
from mcp import types
from mcp.shared.memory import create_connected_server_and_client_session

from mcp_glimpse.card import LocalCardStore
from mcp_glimpse.server import build_server


async def _share(action: str, confirm: bool):
    cards = LocalCardStore()
    server = build_server(cards=cards)

    async def elicit_cb(context, params):
        return types.ElicitResult(action=action, content={"confirm": confirm})

    async with create_connected_server_and_client_session(
        server, elicitation_callback=elicit_cb, client_info=types.Implementation(name="s", version="0")
    ) as client:
        await client.initialize()
        snap = json.dumps({"model": {"id": "gpt-4o"}, "tools": [
            {"name": "a", "server": "s1", "destructiveHint": True}, {"name": "b", "server": "s2"}]})
        result = await client.call_tool("share_context_card", {"snapshot_json": snap})
        return result.content[0].text, cards


def test_share_card_published_on_confirm():
    text, cards = asyncio.run(_share("accept", True))
    assert "published" in text and "mcpglimpse.com/c/" in text
    assert len(cards.cards) == 1


def test_share_card_not_published_on_decline():
    text, cards = asyncio.run(_share("decline", False))
    assert "not published" in text
    assert len(cards.cards) == 0


def test_share_tool_is_registered_and_annotated_as_a_write():
    tools = {t.name: t for t in asyncio.run(build_server().list_tools())}
    assert "share_context_card" in tools
    assert tools["share_context_card"].annotations.readOnlyHint is False


def test_og_route_serves_a_png():
    cards = LocalCardStore()
    card = cards.put({"servers": 2, "tools": 10, "destructive": 1, "annotation_coverage_pct": 30})
    app = build_server(cards=cards).streamable_http_app()

    async def go():
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            return await client.get(f"/og/{card.id}")

    resp = asyncio.run(go())
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"
    assert resp.content[:8] == b"\x89PNG\r\n\x1a\n"
