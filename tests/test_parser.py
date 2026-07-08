import pytest

from mcp_glimpse.parser import SnapshotParseResult, parse


@pytest.mark.parametrize("bad", [None, "", "   ", "not json", "[1, 2, 3]", "42", '"a string"'])
def test_unusable_input_yields_empty_without_warnings(bad):
    result = parse(bad)
    assert isinstance(result, SnapshotParseResult)
    assert result.snapshot is None
    assert result.warnings == []


def test_full_snapshot_parses():
    result = parse(
        """
        {
          "model": {"id": "claude-opus-4-8", "provider": "anthropic"},
          "servers": [{"name": "files", "offersPrompts": true}],
          "tools": [{"name": "read_file", "server": "files", "readOnlyHint": true}]
        }
        """
    )
    snap = result.snapshot
    assert snap is not None
    assert snap.model.id == "claude-opus-4-8"
    assert snap.servers[0].name == "files"
    assert snap.tools[0].read_only_hint is True
    assert result.warnings == []


def test_keys_are_case_insensitive_at_every_level():
    result = parse('{"Model": {"ID": "m1"}, "Tools": [{"Name": "t", "ReadOnlyHint": true}]}')
    assert result.snapshot.model.id == "m1"
    assert result.snapshot.tools[0].name == "t"
    assert result.snapshot.tools[0].read_only_hint is True


def test_short_alias_is_accepted_and_triggers_stale_client_advisory():
    result = parse('{"tools": [{"name": "t", "readOnly": true}]}')
    assert result.snapshot.tools[0].read_only_hint is True
    assert any("cached" in w.lower() for w in result.warnings)


def test_non_boolean_hint_is_ignored_with_warning():
    result = parse('{"tools": [{"name": "t", "readOnlyHint": "yes"}]}')
    assert result.snapshot.tools[0].read_only_hint is None
    assert any("boolean" in w.lower() for w in result.warnings)


def test_conflicting_alias_and_canonical_prefers_canonical_with_warning():
    result = parse('{"tools": [{"name": "t", "readOnlyHint": false, "readOnly": true}]}')
    assert result.snapshot.tools[0].read_only_hint is False
    assert any("conflict" in w.lower() for w in result.warnings)


def test_unrecognized_tool_field_is_kept_and_warned():
    result = parse('{"tools": [{"name": "t", "frobnicate": 1}]}')
    assert result.snapshot.tools[0].name == "t"
    assert any("frobnicate" in w for w in result.warnings)


def test_tool_with_no_name_is_skipped_with_warning():
    result = parse('{"tools": [{"description": "no name"}, {"name": "ok"}]}')
    names = [t.name for t in result.snapshot.tools]
    assert names == ["ok"]
    assert any("no name" in w.lower() for w in result.warnings)


def test_undeclared_server_is_warned():
    result = parse('{"servers": [{"name": "a"}], "tools": [{"name": "t", "server": "ghost"}]}')
    assert any("ghost" in w for w in result.warnings)


def test_malformed_tool_does_not_nuke_the_snapshot():
    result = parse('{"model": {"id": "m1"}, "tools": ["not an object", {"name": "ok"}]}')
    assert result.snapshot.model.id == "m1"
    assert [t.name for t in result.snapshot.tools] == ["ok"]


def test_scalar_servers_and_skills_degrade_without_crashing():
    result = parse('{"servers": "oops", "skills": 5, "tools": [{"name": "t"}]}')
    assert result.snapshot.servers == []
    assert result.snapshot.skills == []
    assert result.snapshot.tools[0].name == "t"
