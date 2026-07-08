# Contributing to mcp-glimpse

Thanks for your interest. mcp-glimpse is a small, focused server; contributions that keep it that way are
most welcome.

## Ground rules

- **Tool and parameter names are an append-only public contract.** Renaming a tool, prompt, resource, or
  field is a semver-MAJOR breaking change — never slip one into a patch. Add, don't rename; accept aliases.
- **The wire is camelCase, pinned.** Models serialize with `by_alias=True, exclude_none=True`. The
  contract-snapshot test guards it; a rename or field drift fails CI.
- **Don't hand-edit generated artifacts.** `app/src/types.generated.ts` is generated from the Pydantic
  models — run `uv run python scripts/gen_app_types.py` and commit the result; the drift gate enforces it.

## Development loop

```bash
uv sync --dev
uv run pytest          # unit + in-memory end-to-end
./scripts/check.sh     # full verify harness (markdown, bicep, …)
```

For the App view:

```bash
cd app && npm install && npm run build   # -> app/dist/index.html (single file)
```

Open `app/dist/index.html?demo=1` to see the rectangle with fixture data.

## Feedback channels

- In-band: call the `submit_feedback` tool from any connected agent.
- Out-of-band: open a GitHub issue.

## Pull requests

Keep changes focused, add tests, and make sure `uv run pytest` and `./scripts/check.sh` are green. Commit
messages are conventional (`feat:`, `fix:`, `docs:`, `chore:`).
