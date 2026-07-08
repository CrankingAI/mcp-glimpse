"""End-to-end smoke: every MCP primitive exercised over an in-memory client<->server session.

This is the acceptance test for the brief's "every primitive, demonstrably exercised" bar:
tools, prompts, resources, elicitation, sampling, roots, logging, progress, completions.
"""
import asyncio
import json

from mcp import types
from mcp.shared.memory import create_connected_server_and_client_session

from mcp_glimpse.feedback import LocalFeedbackStore
from mcp_glimpse.server import build_server

_NARRATIVE = "Your environment has a handful of tools across a couple of servers."


async def _run(elicit_action: str, confirm_value: bool):
    store = LocalFeedbackStore()
    server = build_server(feedback=store)
    logs: list = []
    progress: list = []

    async def sampling_cb(context, params):
        return types.CreateMessageResult(
            role="assistant",
            content=types.TextContent(type="text", text=_NARRATIVE),
            model="test-model",
            stopReason="endTurn",
        )

    async def roots_cb(context):
        return types.ListRootsResult(roots=[types.Root(uri="file:///workspace", name="ws")])

    async def elicit_cb(context, params):
        return types.ElicitResult(action=elicit_action, content={"confirm": confirm_value})

    async def logging_cb(params):
        logs.append(params)

    async def progress_cb(prog, total, message):
        progress.append((prog, message))

    async with create_connected_server_and_client_session(
        server,
        sampling_callback=sampling_cb,
        list_roots_callback=roots_cb,
        elicitation_callback=elicit_cb,
        logging_callback=logging_cb,
        client_info=types.Implementation(name="smoke", version="0"),
    ) as client:
        await client.initialize()

        tools = await client.list_tools()
        prompts = await client.list_prompts()
        resources = await client.list_resources()
        prompt = await client.get_prompt("deep_tool_audit", {"focus": "danger"})
        resource = await client.read_resource("glimpse://primitives")
        completion = await client.complete(
            types.PromptReference(type="ref/prompt", name="deep_tool_audit"),
            {"name": "focus", "value": "inj"},
        )

        snapshot = json.dumps({"model": {"id": "claude-opus-4-8"}, "tools": [{"name": "t", "server": "s"}]})
        introspect = await client.call_tool(
            "introspect_mcp_context", {"snapshot_json": snapshot}, progress_callback=progress_cb
        )
        feedback = await client.call_tool("submit_feedback", {"kind": "bug", "summary": "it broke"})

        return {
            "tool_names": {t.name for t in tools.tools},
            "prompt_count": len(prompts.prompts),
            "resource_uris": {str(r.uri) for r in resources.resources},
            "prompt_messages": prompt.messages,
            "resource_contents": resource.contents,
            "completion_values": completion.completion.values,
            "introspect_wire": json.loads(introspect.content[0].text),
            "feedback_text": feedback.content[0].text,
            "store": store,
            "logs": logs,
            "progress": progress,
        }


def test_all_primitives_exercised_with_elicitation_accept():
    r = asyncio.run(_run("accept", True))
    # tools / prompts / resources
    assert r["tool_names"] == {"introspect_mcp_context", "submit_feedback", "share_context_card"}
    assert r["prompt_count"] == 4
    assert "glimpse://snapshot-schema" in r["resource_uris"]
    assert r["prompt_messages"]
    assert r["resource_contents"]
    # completions
    assert "injection" in r["completion_values"]
    # sampling (narrative) + roots surfaced in the report
    assert r["introspect_wire"]["narrative"] == _NARRATIVE
    assert r["introspect_wire"]["connection"]["roots"] == ["file:///workspace"]
    # logging + progress fired
    assert r["logs"]
    assert r["progress"] and r["progress"][-1][0] == 1.0
    # elicitation accepted -> feedback recorded
    assert r["store"].records and r["store"].records[0]["kind"] == "bug"
    assert "confirmed" in r["feedback_text"]


def test_elicitation_decline_does_not_record():
    r = asyncio.run(_run("decline", False))
    assert r["store"].records == []
    assert "not recorded" in r["feedback_text"]
