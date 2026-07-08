import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_pyproject_version_matches_version_file():
    version_file = (ROOT / "VERSION").read_text().strip()
    pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text())
    assert pyproject["project"]["version"] == version_file


def test_package_exposes_version():
    import mcp_glimpse

    assert mcp_glimpse.__version__ == (ROOT / "VERSION").read_text().strip()
