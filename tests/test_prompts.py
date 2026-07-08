from mcp_glimpse import prompts


def test_all_four_prompts_return_nonempty_text():
    assert "introspect_mcp_context" in prompts.suggest_explorations()
    assert "snapshot_json" in prompts.full_context_dump()
    assert "vantageGap" in prompts.compare_vantage_points()
    assert prompts.deep_tool_audit()


def test_deep_tool_audit_threads_focus():
    assert "network egress" in prompts.deep_tool_audit("network egress")


def test_prompts_have_no_lens_branding():
    for text in (prompts.suggest_explorations(), prompts.compare_vantage_points()):
        assert "mcp-lens" not in text
        assert "lens://" not in text
