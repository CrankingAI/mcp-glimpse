"""Regression guards for the Phase 12 correctness-review findings."""
import asyncio
import json

from mcp_glimpse.card import Card, LocalCardStore
from mcp_glimpse.feedback import FeedbackStore
from mcp_glimpse.model import ToolRef
from mcp_glimpse.poisoning import scan
from mcp_glimpse.server import build_server


def _call_text(mcp, name, args):
    res = asyncio.run(mcp.call_tool(name, args))
    content = res[0] if isinstance(res, tuple) else res
    return content[0].text


def test_submit_feedback_survives_backend_write_failure():
    # A backend write failure must degrade to an honest error, never crash the tool or double-write.
    class Failing(FeedbackStore):
        calls = 0

        def _persist(self, entity):
            Failing.calls += 1
            raise RuntimeError("backend down")

    data = json.loads(_call_text(build_server(feedback=Failing()), "submit_feedback",
                                 {"kind": "bug", "summary": "x"}))
    assert "error" in data["status"].lower()
    assert Failing.calls == 1  # not double-attempted


def test_emoji_zwj_not_flagged_as_hidden_unicode():
    findings = scan([ToolRef(name="dev", description="run as a 👨‍💻 helper")])
    assert not any(f.category == "hidden-unicode" for f in findings)


def test_real_bidi_override_still_flagged():
    findings = scan([ToolRef(name="x", description="hi‮ there")])
    assert any(f.category == "hidden-unicode" for f in findings)


def test_local_card_store_skips_corrupt_lines(tmp_path):
    path = tmp_path / "cards.jsonl"
    good = Card(id="good1", tools=5)
    path.write_text("not json\n" + good.model_dump_json() + '\n{"missing":"id"}\n', encoding="utf-8")
    store = LocalCardStore(path)  # must not raise on the corrupt/legacy lines
    assert store.get("good1") is not None


def test_oversized_snapshot_is_rejected_with_warning():
    from mcp_glimpse.parser import MAX_SNAPSHOT_BYTES, parse

    result = parse('{"tools":[]}' + " " * MAX_SNAPSHOT_BYTES)
    assert result.snapshot is None
    assert any("limit" in w for w in result.warnings)
