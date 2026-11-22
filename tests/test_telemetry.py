import asyncio
import logging

from mcp_glimpse import telemetry


def test_client_ip_prefers_cloudflare_then_first_forwarded_hop():
    assert telemetry.client_ip({"cf-connecting-ip": "203.0.113.7", "x-forwarded-for": "198.51.100.1"}) == "203.0.113.7"
    assert telemetry.client_ip({"x-forwarded-for": "198.51.100.1, 10.0.0.1"}) == "198.51.100.1"
    assert telemetry.client_ip({"x-forwarded-for": "2001:db8::1"}) == "2001:db8::1"


def test_client_ip_rejects_garbage():
    assert telemetry.client_ip({"cf-connecting-ip": "not-an-ip"}) is None
    assert telemetry.client_ip({}) is None


def test_ua_product_keeps_only_the_product_token():
    assert telemetry.ua_product("openai-mcp/1.0.0 (linux; x)") == "openai-mcp"
    assert telemetry.ua_product("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)") == "Mozilla"
    assert telemetry.ua_product("") is None
    assert telemetry.ua_product(None) is None


def test_rpc_method_from_full_or_truncated_body():
    assert telemetry.rpc_method(b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}') == "tools/list"
    assert telemetry.rpc_method(b'[{"method":"ping"},{"method":"tools/list"}]') == "ping,tools/list"
    assert telemetry.rpc_method(b'{"jsonrpc":"2.0","method":"tools/call","params":{"snapsh') == "tools/call"
    assert telemetry.rpc_method(b"garbage") == "-"


def test_rpc_method_never_echoes_client_text():
    # A snapshot nested before "method" in a >16KB body must not leak via the regex fallback.
    big = (b'{"params":{"arguments":{"snapshot_json":{"method":"SNAPSHOT TEXT","pad":"'
           + b"x" * 20000 + b'"}}},"method":"tools/call"}')
    assert telemetry.rpc_method(big[: 16 * 1024]) == "other"
    assert telemetry.rpc_method(b'{"method":{"tools":["secret_tool"]}}') == "other"
    assert telemetry.rpc_method(b'{"method":"x\\nFORGED LINE"}') == "other"
    assert telemetry.rpc_method(b"[" * 12000) == "-"  # RecursionError is contained


def test_error_reason_is_a_fixed_label():
    body = b'{"jsonrpc":"2.0","id":"server-error","error":{"code":-32600,"message":"Bad Request: Missing session ID"}}'
    assert telemetry.error_reason(body) == "Bad Request: Missing session ID"
    leaky = b'{"error":{"message":"Validation error: 1 validation error input_value={\'secret\': 1}"}}'
    assert telemetry.error_reason(leaky) == "Validation error"
    assert telemetry.error_reason(b"plain text") == "other"


def test_protocol_version_is_shape_checked():
    assert telemetry.protocol_version("2025-11-25") == "2025-11-25"
    assert telemetry.protocol_version("x" * 3000) == "invalid"
    assert telemetry.protocol_version(None) == "-"


def test_client_ip_refuses_ipv6_zone_ids():
    assert telemetry.client_ip({"x-forwarded-for": "fe80::1%any free text"}) is None


def test_redact_strips_pydantic_input_values():
    line = ("Failed to validate request: 1 validation error\n  Input should be a valid dict "
            "[type=dict_type, input_value='SNAPMARK private snapshot...', input_type=str]")
    out = telemetry.redact(line)
    assert "SNAPMARK" not in out and "input_value=<redacted>, input_type=str" in out
    assert telemetry.redact("input_value={'a': 1, 'b': [2, 3]}") == "input_value=<redacted>"
    assert telemetry.redact("nothing to see") == "nothing to see"


def test_redacting_formatter_covers_tracebacks():
    fmt = telemetry.RedactingFormatter(logging.Formatter("%(message)s"))
    try:
        raise ValueError("bad [type=x, input_value='SECRET', input_type=str]")
    except ValueError:
        import sys
        rec = logging.LogRecord("x", logging.ERROR, "", 0, "boom input_value='SECRET2', input_type=str", None, sys.exc_info())
    out = fmt.format(rec)
    assert "SECRET" not in out and "boom" in out


class _Span:
    def __init__(self, attrs):
        self.attributes = dict(attrs)

    def is_recording(self):
        return True

    def set_attribute(self, key, value):
        self.attributes[key] = value


def test_request_hook_stamps_ip_and_reduces_every_user_agent():
    span = _Span({"http.user_agent": "glimpse-review/9.9.9 (MarkerOS 42; SECRETUAMARKER)"})
    scope = {"headers": [
        (b"user-agent", b"glimpse-review/9.9.9 (MarkerOS 42; SECRETUAMARKER)"),
        (b"user-agent", b""),  # duplicate, last one empty: must still overwrite
        (b"cf-connecting-ip", b"203.0.113.7"),
    ]}
    telemetry.server_request_hook(span, scope)
    assert span.attributes["client.address"] == "203.0.113.7"
    assert span.attributes["http.user_agent"] == "glimpse-review"
    assert span.attributes["user_agent.original"] == "glimpse-review"
    assert not any("SECRETUAMARKER" in str(v) for v in span.attributes.values())


def test_wrap_without_otel_still_installs_rejection_logger():
    async def app(scope, receive, send):
        pass

    assert isinstance(telemetry.wrap(app, tracing=False), telemetry.McpRejectionLogger)


def _record(path: str, status: int) -> logging.LogRecord:
    return logging.LogRecord("uvicorn.access", logging.INFO, "", 0, '%s - "%s %s HTTP/%s" %d',
                             ("100.100.0.1:1", "GET", path, "1.1", status), None)


def test_health_probe_filter_drops_only_successful_probes():
    f = telemetry.HealthProbeAccessFilter()
    assert f.filter(_record("/readyz", 200)) is False
    assert f.filter(_record("/livez", 200)) is False
    assert f.filter(_record("/readyz", 503)) is True
    assert f.filter(_record("/mcp", 200)) is True


def _run_asgi(app, method: str, path: str, body: bytes, headers: list[tuple[bytes, bytes]]):
    sent: list[dict] = []
    chunks = [{"type": "http.request", "body": body, "more_body": False}]

    async def receive():
        return chunks.pop(0) if chunks else {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "method": method, "path": path, "headers": headers}
    asyncio.run(app(scope, receive, send))
    return sent


def test_rejection_logger_logs_reason_and_passes_everything_through(caplog):
    async def app(scope, receive, send):
        await receive()
        await send({"type": "http.response.start", "status": 400, "headers": []})
        await send({"type": "http.response.body",
                    "body": b'{"error":{"code":-32600,"message":"Bad Request: Missing session ID"}}'})

    with caplog.at_level(logging.WARNING, logger="mcp_glimpse.http"):
        sent = _run_asgi(
            telemetry.McpRejectionLogger(app), "POST", "/mcp",
            b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
            [(b"user-agent", b"openai-mcp/1.0.0"), (b"x-forwarded-for", b"203.0.113.7")],
        )
    assert [m["type"] for m in sent] == ["http.response.start", "http.response.body"]
    line = caplog.records[-1].getMessage()
    assert "status=400" in line and "rpc=tools/list" in line and "session=no" in line
    assert "client=openai-mcp" in line and "reason=Bad Request: Missing session ID" in line
    assert "protocolVersion=-" in line
    assert "203.0.113.7" not in line  # never the IP


def test_rejection_logger_is_silent_on_success_and_off_path(caplog):
    async def ok(scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"{}"})

    with caplog.at_level(logging.WARNING, logger="mcp_glimpse.http"):
        _run_asgi(telemetry.McpRejectionLogger(ok), "POST", "/mcp", b"{}", [])
        _run_asgi(telemetry.McpRejectionLogger(ok), "GET", "/readyz", b"", [])
    assert not [r for r in caplog.records if r.name == "mcp_glimpse.http"]


def test_rejection_logger_against_the_real_sdk_missing_session_400(caplog):
    # Reproduces the production pattern: a non-initialize POST with no session header opens a fresh
    # transport and the SDK answers 400 — now with the reason logged.
    from starlette.testclient import TestClient

    from mcp_glimpse.server import build_server

    mcp = build_server()
    app = telemetry.wrap(mcp.streamable_http_app(), tracing=False)
    with caplog.at_level(logging.WARNING, logger="mcp_glimpse.http"), TestClient(app, base_url="http://127.0.0.1:8000") as client:
        resp = client.post(
            "/mcp",
            json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            headers={"accept": "application/json, text/event-stream"},
        )
    assert resp.status_code == 400
    line = caplog.records[-1].getMessage()
    assert "rpc=tools/list" in line and "session=no" in line and "Missing session ID" in line


def test_configure_is_off_without_connection_string(monkeypatch):
    monkeypatch.delenv("APPLICATIONINSIGHTS_CONNECTION_STRING", raising=False)
    assert telemetry.configure() is False
