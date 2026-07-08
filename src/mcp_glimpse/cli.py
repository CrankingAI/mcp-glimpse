"""mcp-glimpse entry point — dual transport.

  uvx mcp-glimpse                 # stdio (default) — every local MCP host
  mcp-glimpse --http [--port N]   # stateful Streamable HTTP at /mcp (hosted mode)
"""
from __future__ import annotations

import argparse
import logging
import os

from .server import build_server


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="mcp-glimpse", description="Point your agent at itself.")
    parser.add_argument("--http", action="store_true", help="Run stateful Streamable HTTP instead of stdio.")
    parser.add_argument("--port", type=int, default=None, help="HTTP port (default $PORT or 8000).")
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    mcp = build_server()
    if args.http:
        mcp.settings.host = os.environ.get("HOST", "0.0.0.0")
        mcp.settings.port = args.port or int(os.environ.get("PORT", "8000"))
        logging.getLogger("mcp_glimpse").info(
            "mcp-glimpse HTTP on http://%s:%s%s",
            mcp.settings.host, mcp.settings.port, mcp.settings.streamable_http_path,
        )
        mcp.run(transport="streamable-http")
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
