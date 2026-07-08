from mcp_glimpse.analyzer import _find_inconsistencies, _name_looks_like_write, _tokens
from mcp_glimpse.model import ToolRef


def test_tokenizer_splits_snake_kebab_and_camel():
    assert _tokens("get_settings") == ["get", "settings"]
    assert _tokens("delete-file") == ["delete", "file"]
    assert _tokens("createUser") == ["create", "user"]
    assert _tokens("fs/write.file") == ["fs", "write", "file"]


def test_write_verb_detection_uses_whole_tokens_not_substrings():
    # "set" is a write verb; "get_settings" contains the substring "set" but not the token.
    assert _name_looks_like_write(ToolRef(name="set_value")) is True
    assert _name_looks_like_write(ToolRef(name="get_settings")) is False
    assert _name_looks_like_write(ToolRef(name="read_only")) is False
    assert _name_looks_like_write(ToolRef(name="deleteWidget")) is True


def test_contradictory_readonly_and_destructive_is_flagged():
    tools = [ToolRef(name="wipe", read_only_hint=True, destructive_hint=True)]
    out = _find_inconsistencies(tools)
    assert len(out) == 1
    assert "wipe" in out[0]


def test_readonly_but_write_name_is_flagged():
    out = _find_inconsistencies([ToolRef(name="delete_thing", read_only_hint=True)])
    assert len(out) == 1
    assert "delete_thing" in out[0]


def test_clean_tools_produce_no_inconsistencies():
    tools = [
        ToolRef(name="get_settings", read_only_hint=True),
        ToolRef(name="delete_thing", destructive_hint=True),
        ToolRef(name="list_items"),
    ]
    assert _find_inconsistencies(tools) == []
