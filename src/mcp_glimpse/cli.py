"""mcp-glimpse entry point — dual transport.

  uvx mcp-glimpse                 # stdio (default) — every local MCP host
  mcp-glimpse --http [--port N]   # stateful Streamable HTTP at /mcp (hosted mode)
"""
from __future__ import annotations

import argparse
import logging
import os
import signal
import sys

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
    if args.http:
        run_http(args.port)
    else:
        build_server().run(transport="stdio")


def run_http(port: int | None) -> None:
    # Mirrors FastMCP.run_streamable_http_async, plus the telemetry wrap (docs/observability.md).
    import uvicorn

    from . import telemetry

    tracing = telemetry.configure()  # before build_server so its loggers export from the start
    mcp = build_server()
    mcp.settings.host = os.environ.get("HOST", "0.0.0.0")
    mcp.settings.port = port or int(os.environ.get("PORT", "8000"))
    app = telemetry.wrap(mcp.streamable_http_app(), tracing=tracing)
    config = uvicorn.Config(
        app,
        host=mcp.settings.host,
        port=mcp.settings.port,
        log_level=mcp.settings.log_level.lower(),
        # Never derive the logged client address from X-Forwarded-For: console logs are retained,
        # and raw caller IPs belong only in the 10-day edge log (docs/edge.md).
        proxy_headers=False,
    )
    telemetry.harden_logging()
    # uvicorn re-raises SIGTERM with the ORIGINAL handler after its graceful shutdown. With the
    # default handler the process dies without atexit, so OTel's batch processors never flush the
    # last few seconds (every revision roll / scale-to-zero). SystemExit runs atexit -> flush.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    logging.getLogger("mcp_glimpse").info(
        "mcp-glimpse HTTP on http://%s:%s%s",
        mcp.settings.host, mcp.settings.port, mcp.settings.streamable_http_path,
    )
    uvicorn.Server(config).run()


if __name__ == "__main__":
    main()
