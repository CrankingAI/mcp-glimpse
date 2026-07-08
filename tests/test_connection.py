from types import SimpleNamespace

from mcp_glimpse import connection


def test_observe_none_gives_server_only_facts():
    facts = connection.observe(None)
    assert facts.server_name == "mcp-glimpse"
    assert facts.transport == "stdio"
    assert facts.protocol_version is None
    assert facts.client_name is None
    assert "introspect_mcp_context" in facts.server_tools
    assert facts.server_prompts and facts.server_resources


def test_observe_http_ctx_surfaces_client_and_session():
    ctx = SimpleNamespace(
        session=SimpleNamespace(
            client_params=SimpleNamespace(
                protocolVersion="2025-11-25",
                clientInfo=SimpleNamespace(name="test-host", version="1.2.3"),
            )
        ),
        request_context=SimpleNamespace(
            request=SimpleNamespace(headers={"mcp-session-id": "sess-abc"})
        ),
    )
    facts = connection.observe(ctx)
    assert facts.transport == "streamable-http"
    assert facts.protocol_version == "2025-11-25"
    assert facts.client_name == "test-host"
    assert facts.client_version == "1.2.3"
    assert facts.session_id == "sess-abc"
