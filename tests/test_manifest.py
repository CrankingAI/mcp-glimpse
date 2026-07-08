from pathlib import Path

from mcp_glimpse import manifest


def test_tool_prompt_resource_name_lists():
    assert manifest.TOOLS == ["introspect_mcp_context", "submit_feedback"]
    assert manifest.PROMPTS == [
        "suggest_explorations", "full_context_dump",
        "compare_vantage_points", "deep_tool_audit",
    ]
    assert manifest.UI_RESOURCE_URI == "ui://glimpse/index.html"
    assert manifest.RESOURCES == [
        "glimpse://snapshot-schema", "glimpse://explorations", "glimpse://primitives",
        "glimpse://what-servers-can-see", "glimpse://capabilities",
        "glimpse://protocol-versions", manifest.UI_RESOURCE_URI,
    ]


def test_version_reads_version_file():
    assert manifest.version() == (Path(manifest.__file__).resolve().parents[2] / "VERSION").read_text().strip()


def test_resource_files_exist_and_are_renamed():
    for f in ("snapshot-schema.json", "explorations.md", "primitives.md",
              "what-servers-can-see.md", "capabilities.md", "protocol-versions.md"):
        text = (manifest.RESOURCES_DIR / f).read_text()
        assert "lens://" not in text
        assert "mcp-lens" not in text
