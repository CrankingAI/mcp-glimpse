# Markdown

All Markdown in this repo passes the kit's lint baseline. The config is canonical;
the `markdown` skill is the tool that edits and fixes it.

## .markdownlint.jsonc is canonical

`.markdownlint.jsonc` at the repo root is the single source of truth for Markdown
style. Do not fork it per-directory or re-state its rules elsewhere. What it sets:

- **MD013** off — prose wraps freely; no hard column limit.
- **MD036** off — bold lead-ins may stand in for headings.
- **MD060** off — no table column-count strictness.
- **MD024** `siblings_only` — duplicate headings are fine across different
  sections, never as siblings under one parent.
- **MD040** on — **every fenced code block declares a language.**

VS Code reads it automatically with the `DavidAnson.vscode-markdownlint`
extension. From the CLI:

```text
npx markdownlint-cli2 "**/*.md"
```

Markdownlint also runs inside the verify harness (`./scripts/check.sh`), so a lint
failure fails the build — see [scripts](scripts.md).

## Every fenced block carries a language tag

`MD040` is enforced: a bare ```` ``` ```` is a violation. Tag every fence with the
language. When nothing fits — output dumps, trees, plain commands — use `text`:

```text
./scripts/check.sh
```

## Use the markdown skill

Do not hand-tune lint configs or chase violations by hand. The **markdown** skill
owns Markdown editing, linting, and markdownlint-fixing. It enforces consistent
style with minimal-change discipline and reconciles the canonical
`.markdownlint.jsonc` — invoke it for any of:

- writing or editing Markdown,
- fixing markdownlint violations (MD013/MD036/MD040/MD060, no-duplicate-heading,
  fenced-code-language, and friends),
- reconciling duplicate or conflicting lint configs.
