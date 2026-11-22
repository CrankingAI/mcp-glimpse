"""Hosted-mode (HTTP) observability. Every piece is best-effort and never fatal.

* **OTel -> App Insights** when ``APPLICATIONINSIGHTS_CONNECTION_STRING`` is set and the ``azure``
  extra is installed: request spans for the MCP endpoint (health probes excluded), this package's
  logs (``mcp_glimpse.*``), and outbound Azure SDK calls.
* **Client IP -> geo only.** Behind Cloudflare -> ACA ingress the socket peer is an internal envoy
  address, so the request hook stamps the real caller IP (``CF-Connecting-IP``, else the first
  ``X-Forwarded-For`` hop) as ``client.address`` purely so Azure Monitor can geo-resolve it; App
  Insights then masks the stored IP to 0.0.0.0 (docs/observability.md). The user agent is reduced
  to its product token. Neither is ever logged.
* **MCP rejection diagnostics.** The MCP SDK rejects some requests (e.g. ``400 Missing session
  ID`` on a non-initialize POST that opens a fresh transport) without logging why. This logs the
  status, the JSON-RPC method, whether a session header was sent, and the SDK's rejection label.
  Every logged value is shape-checked or allow-listed — never free client text, so no snapshot
  fragment can reach a log (README privacy promise).
* **Redaction.** Console logs are retained (Log Analytics), and the SDK's own validation warnings
  quote request fragments as pydantic ``input_value=...``; a redacting formatter strips them.
* **Quiet probes.** Successful ``/livez`` + ``/readyz`` lines are dropped from uvicorn's access log
  (the readiness probe polls every 2s); failures still log.
"""
from __future__ import annotations

import ipaddress
import json
import logging
import os
import re
from typing import Any

from . import manifest

logger = logging.getLogger("mcp_glimpse.http")

_HEALTH_PATHS = frozenset({"/livez", "/readyz"})
_MCP_PATH = "/mcp"
_BODY_PREFIX_BYTES = 16 * 1024   # enough to find the JSON-RPC "method" without buffering snapshots
_ERROR_BODY_BYTES = 1024
_METHOD_RE = re.compile(rb'"method"\s*:\s*"([^"]{1,80})"')
_UA_PRODUCT_RE = re.compile(r"^[A-Za-z0-9._-]{1,40}")
_PROTOCOL_VERSION_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_INPUT_VALUE_RE = re.compile(r"input_value=.*?(?=, input_type=)|input_value=[^\n]*", re.DOTALL)

# The only JSON-RPC methods worth naming in a log; anything else is "other" (never echoed).
_KNOWN_RPC_METHODS = frozenset({
    "initialize", "ping", "tools/list", "tools/call", "resources/list", "resources/read",
    "resources/templates/list", "resources/subscribe", "resources/unsubscribe", "prompts/list",
    "prompts/get", "completion/complete", "logging/setLevel", "notifications/initialized",
    "notifications/cancelled", "notifications/progress", "notifications/roots/list_changed",
})

# The SDK's rejection messages, by stable prefix. Only the label is logged — never the detail
# (which for validation errors embeds request fragments).
_REJECTION_LABELS = (
    "Bad Request: Missing session ID",
    "Not Found: Invalid or expired session ID",
    "Bad Request: Unsupported protocol version",
    "Session not found",
    "Parse error",
    "Validation error",
    "Not Acceptable",
    "Unsupported Media Type",
    "Method Not Allowed",
    "Invalid Host header",
    "Invalid Origin header",
    "Invalid Content-Type header",
)


# --- pure helpers (unit-tested) ------------------------------------------------------------------

def client_ip(headers: dict[str, str]) -> str | None:
    """The real caller IP from proxy headers (lower-cased keys), or None. Validated as an IP."""
    candidates = [headers.get("cf-connecting-ip", "")]
    candidates.append(headers.get("x-forwarded-for", "").split(",")[0])
    for raw in candidates:
        value = raw.strip()
        if not value:
            continue
        try:
            ip = ipaddress.ip_address(value)
        except ValueError:
            continue
        if getattr(ip, "scope_id", None):  # "fe80::1%<free text>" is valid syntax — refuse it
            continue
        return str(ip)
    return None


def ua_product(user_agent: str | None) -> str | None:
    """'openai-mcp/1.0.0 (x)' -> 'openai-mcp'. The product token only — never the full UA."""
    if not user_agent:
        return None
    match = _UA_PRODUCT_RE.match(user_agent.strip())
    return match.group(0) if match else None


def _known_method(value: object) -> str:
    return value if isinstance(value, str) and value in _KNOWN_RPC_METHODS else "other"


def rpc_method(body_prefix: bytes) -> str:
    """The JSON-RPC method(s) of a request body: allow-listed names only, else 'other' / '-'.

    A full parse wins. For a truncated prefix the regex fallback may hit a "method" key nested in
    the params (e.g. inside a snapshot) — harmless, because only allow-listed names are returned.
    """
    try:
        parsed = json.loads(body_prefix)
        items = parsed if isinstance(parsed, list) else [parsed]
        methods = [_known_method(i.get("method")) for i in items if isinstance(i, dict) and "method" in i]
        return ",".join(methods[:5]) if methods else "-"
    except (ValueError, UnicodeDecodeError, RecursionError):
        pass
    found = _METHOD_RE.search(body_prefix)
    return _known_method(found.group(1).decode("utf-8", "replace")) if found else "-"


def error_reason(body: bytes) -> str:
    """The SDK's rejection, as a fixed label (see _REJECTION_LABELS), else 'other'."""
    try:
        parsed = json.loads(body)
        message = parsed.get("error", {}).get("message") if isinstance(parsed, dict) else None
    except (ValueError, UnicodeDecodeError, AttributeError, RecursionError):
        message = None
    text = message if isinstance(message, str) else body[:200].decode("utf-8", "replace")
    for label in _REJECTION_LABELS:
        if text.strip().startswith(label):
            return label
    return "other"


def protocol_version(value: str | None) -> str:
    if not value:
        return "-"
    return value if _PROTOCOL_VERSION_RE.match(value) else "invalid"


def redact(text: str) -> str:
    """Strip pydantic ``input_value=...`` request excerpts from a formatted log line."""
    return _INPUT_VALUE_RE.sub("input_value=<redacted>", text) if "input_value=" in text else text


class RedactingFormatter(logging.Formatter):
    """Wraps a handler's formatter; redacts the final text (message AND any traceback)."""

    def __init__(self, inner: logging.Formatter | None) -> None:
        super().__init__()
        self._inner = inner or logging.Formatter()

    def format(self, record: logging.LogRecord) -> str:
        return redact(self._inner.format(record))


class HealthProbeAccessFilter(logging.Filter):
    """Drop successful health-probe lines from uvicorn.access (args: client, method, path, ver, status)."""

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if isinstance(args, tuple) and len(args) >= 5:
            path, status = args[2], args[4]
            if isinstance(path, str) and path.split("?")[0] in _HEALTH_PATHS:
                return not (isinstance(status, int) and status < 400)
        return True


# --- ASGI middleware -----------------------------------------------------------------------------

class McpRejectionLogger:
    """Logs WHY the MCP endpoint rejected a request. Tees the request body prefix as the app reads
    it (no buffering, no behaviour change) and captures the status + error body of 4xx/5xx."""

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope: dict, receive: Any, send: Any) -> None:
        if scope.get("type") != "http" or scope.get("path", "").rstrip("/") != _MCP_PATH:
            await self.app(scope, receive, send)
            return

        body_prefix = bytearray()
        status: list[int] = []
        error_body = bytearray()

        async def tee_receive() -> dict:
            message = await receive()
            if message.get("type") == "http.request" and len(body_prefix) < _BODY_PREFIX_BYTES:
                body_prefix.extend(message.get("body", b"")[: _BODY_PREFIX_BYTES - len(body_prefix)])
            return message

        async def tee_send(message: dict) -> None:
            if message.get("type") == "http.response.start":
                status.append(int(message.get("status", 0)))
            elif (
                message.get("type") == "http.response.body"
                and status and status[0] >= 400
                and len(error_body) < _ERROR_BODY_BYTES
            ):
                error_body.extend(message.get("body", b"")[: _ERROR_BODY_BYTES - len(error_body)])
            await send(message)

        try:
            await self.app(scope, tee_receive, tee_send)
        finally:
            if status and status[0] >= 400:
                try:
                    self._log(scope, status[0], bytes(body_prefix), bytes(error_body))
                except Exception:  # diagnostics must never break the response path
                    logger.warning("mcp rejected: status=%s (diagnostics unavailable)", status[0])

    @staticmethod
    def _log(scope: dict, status: int, body_prefix: bytes, error_body: bytes) -> None:
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
        logger.warning(
            "mcp rejected: status=%s http=%s rpc=%s session=%s protocolVersion=%s client=%s reason=%s",
            status,
            scope.get("method", "-"),
            rpc_method(body_prefix) if body_prefix else "-",
            "yes" if headers.get("mcp-session-id") else "no",
            protocol_version(headers.get("mcp-protocol-version")),
            ua_product(headers.get("user-agent")) or "-",
            error_reason(error_body) if error_body else "-",
        )


def server_request_hook(span: Any, scope: dict) -> None:
    """Stamp the real caller IP (geo only) and reduce every user agent to its product token."""
    if span is None or not span.is_recording():
        return
    raw = [(k.decode("latin-1").lower(), v.decode("latin-1")) for k, v in scope.get("headers", [])]
    ip = client_ip(dict(raw))
    if ip:
        span.set_attribute("client.address", ip)  # geo lookup only; App Insights masks to 0.0.0.0
        span.set_attribute("http.client_ip", ip)
    user_agents = [v for k, v in raw if k == "user-agent"]
    if user_agents:
        # Overwrite whenever ANY user-agent header exists: the instrumentation already copied one
        # (possibly not the one we'd pick) into the span, and the full UA must never be exported.
        product = next((p for p in map(ua_product, user_agents) if p), None) or "-"
        span.set_attribute("user_agent.original", product)
        span.set_attribute("http.user_agent", product)


# --- wiring --------------------------------------------------------------------------------------

def configure() -> bool:
    """Start the Azure Monitor OTel pipeline. False (and a log line) when it's off or unavailable."""
    if not os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
        logger.info("telemetry: APPLICATIONINSIGHTS_CONNECTION_STRING not set; App Insights export off")
        return False
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
        from opentelemetry.sdk.resources import Resource
    except ImportError:
        logger.warning("telemetry: azure extra not installed; App Insights export off")
        return False
    # The exporter's own HTTP calls (and Table Storage's) log every request/response header block
    # at INFO through azure-core — it would drown the console log. Keep their warnings and errors.
    logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)
    # ...and the exporter logs "Transmission succeeded" at INFO on every batch.
    logging.getLogger("azure.monitor.opentelemetry.exporter").setLevel(logging.WARNING)
    try:
        configure_azure_monitor(
            logger_name="mcp_glimpse",
            enable_live_metrics=False,  # no always-on ping loop for a single-replica showcase
            resource=Resource.create(
                {"service.name": "mcp-glimpse", "service.version": manifest.version()}
            ),
        )
    except Exception:
        logger.exception("telemetry: configure_azure_monitor failed; App Insights export off")
        return False
    logger.info("telemetry: App Insights export on")
    return True


def wrap(app: Any, *, tracing: bool) -> Any:
    """Wrap the Starlette app: rejection diagnostics always; request spans when tracing is on."""
    wrapped: Any = McpRejectionLogger(app)
    if tracing:
        try:
            from opentelemetry.instrumentation.asgi import OpenTelemetryMiddleware

            wrapped = OpenTelemetryMiddleware(
                wrapped,
                excluded_urls="livez,readyz",
                server_request_hook=server_request_hook,
                exclude_spans=["receive", "send"],  # no per-chunk InProc rows
            )
        except ImportError:
            logger.warning("telemetry: opentelemetry-instrumentation-asgi missing; no request spans")
    return wrapped


def harden_logging() -> None:
    """Call AFTER uvicorn.Config() — it (re)configures the uvicorn loggers. Quiets successful probes
    and wraps every console handler's formatter in the redactor."""
    logging.getLogger("uvicorn.access").addFilter(HealthProbeAccessFilter())
    for name in ("", "uvicorn", "uvicorn.error", "uvicorn.access"):
        for handler in logging.getLogger(name).handlers:
            if not isinstance(handler.formatter, RedactingFormatter):
                handler.setFormatter(RedactingFormatter(handler.formatter))
