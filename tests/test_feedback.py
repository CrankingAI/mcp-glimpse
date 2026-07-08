import json

from mcp_glimpse.feedback import MAX_SUMMARY, LocalFeedbackStore


def test_empty_summary_rejected_and_nothing_persisted():
    store = LocalFeedbackStore()
    result = store.record("bug", "   ")
    assert result["id"] == ""
    assert "required" in result["status"]
    assert store.records == []


def test_valid_feedback_recorded():
    store = LocalFeedbackStore()
    result = store.record("bug", "it broke", detail="stack", context="ctx")
    assert result["status"] == "recorded"
    assert result["id"]
    assert store.records[0]["kind"] == "bug"


def test_unknown_kind_is_sanitized():
    store = LocalFeedbackStore()
    store.record("PRAISE", "nice")
    assert store.records[0]["kind"] == "praise"
    store.record("banana", "x")
    assert store.records[1]["kind"] == "feedback"


def test_oversized_summary_truncated_with_marker():
    store = LocalFeedbackStore()
    store.record("feedback", "x" * (MAX_SUMMARY + 50))
    assert store.records[0]["summary"].endswith("…[truncated]")


def test_file_backend_persists(tmp_path):
    path = tmp_path / "fb.jsonl"
    LocalFeedbackStore(path).record("feedback", "hi")
    line = json.loads(path.read_text().splitlines()[0])
    assert line["summary"] == "hi"
