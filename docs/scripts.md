# Scripts

Repo-local automation lives in `./scripts/`. Every script in there is a small,
predictable CLI that follows one shape. The `scripts-convention` skill enforces it.

## Conventions

- **`-h` / `--help`.** Every script supports both and prints a usage block: what it
  does, its options, and an example. Help must work without side effects.
- **Fail-fast.** `set -euo pipefail` at the top. Validate inputs and required tools
  up front; exit non-zero on the first problem with a clear message — never limp on
  with a half-done run.
- **Coherent naming.** Scripts read as a family: verb-first, kebab-case, consistent
  option flags across siblings (e.g. `bump-version.sh`, `check.sh`). A flag means
  the same thing in every script that has it.
- **macOS bash 3.2 compatible.** The default macOS `/bin/bash` is 3.2 — no
  associative arrays, no `mapfile`/`readarray`, no `${var^^}`. Write to that floor
  so scripts run everywhere without a newer bash on PATH.
- **Quote pathspecs; verify a clean tree after committing.** Astro dynamic
  routes are named with literal brackets (`[spdx].astro`), which the shell
  treats as a **glob**: an unquoted `git add apps/web/src/pages/[spdx].astro`
  matches nothing, exits 0, and silently leaves the file uncommitted (fleet
  finding, [backlog.md](../backlog.md) §14). Always quote and `--`-terminate
  (`git add -- 'apps/web/src/pages/[spdx].astro'`). And after any scripted/agent
  commit, assert the tree is clean — `git status --porcelain` empty — before
  declaring success; that check is what actually catches a silently-dropped file.

## The verify harness

`./scripts/check.sh` is the canonical verify harness: lint, format, build, tests,
markdownlint, and the JS-disabled view-source assertion. Green `check.sh` is part of
the agent definition of done. It is a `scripts/` script and follows every
convention above.

```text
./scripts/check.sh        # full local verify
./scripts/check.sh -h     # usage
```

## Use the scripts-convention skill

Do not hand-write the boilerplate or eyeball portability. The **scripts-convention**
skill creates, updates, validates, and reviews `./scripts/` shell tools — it wires
the `-h`/`--help` block, the fail-fast preamble, coherent naming across the family,
and runs `bash -n` / `shellcheck` / bash-3.2 portability checks. Invoke it whenever
you add, change, or review a script.
