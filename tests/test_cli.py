from mcp_glimpse import cli


def test_parse_args_defaults_to_stdio():
    args = cli.parse_args([])
    assert args.http is False


def test_parse_args_http_with_port():
    args = cli.parse_args(["--http", "--port", "9000"])
    assert args.http is True
    assert args.port == 9000


def test_build_server_smoke():
    from mcp_glimpse.server import build_server

    assert build_server() is not None
