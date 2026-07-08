"""mcp-glimpse — point your agent at itself."""
from pathlib import Path

__all__ = ["__version__"]

__version__ = (Path(__file__).resolve().parents[2] / "VERSION").read_text().strip()
