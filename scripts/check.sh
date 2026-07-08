#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# check.sh — the verify harness the agent "definition of done" hangs on.
#
# Usage:
#   ./scripts/check.sh
#   ./scripts/check.sh --url http://localhost:4321/
#   ./scripts/check.sh --skip-view-source
#
# Runs every toolchain gate that is present in this repo and exits non-zero
# on the first failure (each gate runs; the overall result is the OR of all
# failures). A toolchain that is absent (no .NET solution, no pnpm workspace,
# etc.) is skipped cleanly — this is the same harness whether the repo is
# pure-backend, pure-web, or full-stack.
#
# Gates, in order (each skipped if its inputs are absent):
#   .NET   : dotnet format --verify-no-changes, dotnet build, dotnet test
#   Web    : pnpm -r lint, typecheck, build, --if-present test
#   Infra  : az bicep build (template compiles; AVM restore needs network)
#   Docs   : markdownlint (via the markdown skill's config)
#   SEO    : JS-disabled view-source assertion on a public URL — the full
#            first-GET contract (JSON-LD validity, og: + twitter:, exactly
#            one <h1>, landmarks) via lib/seed-gates.sh's shared assertion
#
# Honors docs/scripts.md conventions: -h/--help, fail-fast, macOS bash 3.2.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Gate functions live in a sourceable library so they can be unit-tested.
# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/lib/seed-gates.sh" ]] && source "$SCRIPT_DIR/lib/seed-gates.sh"

VIEW_SOURCE_URL=""
SKIP_VIEW_SOURCE=false

usage() {
  cat <<'EOF'
Usage: check.sh [options]

Runnable verify harness: the agent definition of done. Runs every toolchain
gate present in this repo (skipping any whose inputs are absent) and exits
non-zero if any gate fails.

Options:
  --url <url>           Public page URL for the JS-disabled view-source
                        assertion (e.g. a local dev server or a deployed shell).
                        If omitted, the view-source gate is skipped.
  --skip-view-source    Force-skip the view-source assertion even if --url given.
  -h, --help            Show this help

Gates (each skipped when its inputs are absent):
  .NET   dotnet format --verify-no-changes; dotnet build; dotnet test
  Web    pnpm -r lint; pnpm -r typecheck; pnpm -r build; pnpm -r --if-present test
  Infra  az bicep build infra/main.bicep (AVM restore needs network)
  Docs   markdownlint over the repo
  SEO    view-source assertion: full first-GET contract — JSON-LD, og: +
         twitter:, exactly one <h1>, landmarks (needs --url)

Environment variables:
  CHECK_URL             Default for --url when the flag is not passed.

Examples:
  check.sh
  check.sh --url http://localhost:4321/
  CHECK_URL=https://example.com check.sh
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help)     usage ;;
    --url)              VIEW_SOURCE_URL="${2:-}"; shift 2 ;;
    --skip-view-source) SKIP_VIEW_SOURCE=true; shift ;;
    *)                  echo "Unknown option: $1" >&2; usage ;;
  esac
done

VIEW_SOURCE_URL="${VIEW_SOURCE_URL:-${CHECK_URL:-}}"

START_TIME=$(date +%s)
echo "🚀 clock started ($(date '+%H:%M:%S'))"

FAILED=0
RAN=()
SKIPPED=()

note_ran()     { RAN+=("$1"); }
note_skipped() { SKIPPED+=("$1: $2"); echo "    skip: $1 ($2)"; }
fail()         { FAILED=1; echo "    FAIL: $1" >&2; }

# Run a gate command; record pass/fail but never abort the harness early
# (we want the full report). `set -e` is sidestepped via the `if` guard.
run_gate() {
  local label="$1"; shift
  echo "==> $label"
  if ( cd "$REPO_ROOT" && "$@" ); then
    note_ran "$label"
  else
    note_ran "$label"
    fail "$label"
  fi
}

# --- .NET -----------------------------------------------------------------
DOTNET_SLN="$(find "$REPO_ROOT" -maxdepth 1 \( -name '*.sln' -o -name '*.slnx' \) -print 2>/dev/null | head -1 || true)"
if command -v dotnet >/dev/null 2>&1 && [[ -n "$DOTNET_SLN" ]]; then
  run_gate ".NET format" dotnet format --verify-no-changes
  run_gate ".NET build"  dotnet build --nologo
  run_gate ".NET test"   dotnet test --nologo
elif [[ -n "$DOTNET_SLN" ]]; then
  note_skipped ".NET" "dotnet not installed"
else
  note_skipped ".NET" "no .sln/.slnx in repo root"
fi

# --- Web (pnpm workspace) -------------------------------------------------
if command -v pnpm >/dev/null 2>&1 && [[ -f "$REPO_ROOT/pnpm-workspace.yaml" ]]; then
  run_gate "Web lint"     pnpm -r lint
  run_gate "Web typecheck" pnpm -r typecheck
  run_gate "Web build"    pnpm -r build
  # Tests run AFTER build — build-output guard tests read dist/ (fleet finding,
  # docs/backlog.md §14: the harness ran lint/typecheck/build but never test, so
  # a repo's Vitest suite silently never ran here). --if-present skips packages
  # with no test script (unscaffolded placeholder slots).
  run_gate "Web test"     pnpm -r --if-present test
elif [[ -f "$REPO_ROOT/pnpm-workspace.yaml" ]]; then
  note_skipped "Web" "pnpm not installed"
else
  note_skipped "Web" "no pnpm-workspace.yaml"
fi

# --- Infra (Bicep) --------------------------------------------------------
# `az bicep build` compiles the template (restoring AVM modules from the public
# registry — needs network on first run) and fails on template errors. Without
# this gate, bicep correctness rested entirely on discipline (fleet finding,
# docs/backlog.md §12). Stdout is the compiled ARM JSON — discard it; a non-zero
# exit is the signal. Warnings (AVM linter) go to stderr and do not fail.
bicep_build_gate() { az bicep build --file "$1" --stdout > /dev/null; }
INFRA_MAIN="$REPO_ROOT/infra/main.bicep"
if command -v az >/dev/null 2>&1 && [[ -f "$INFRA_MAIN" ]]; then
  run_gate "Infra bicep build" bicep_build_gate "$INFRA_MAIN"
elif [[ -f "$INFRA_MAIN" ]]; then
  note_skipped "Infra" "az CLI not installed"
else
  note_skipped "Infra" "no infra/main.bicep"
fi

# --- Markdown -------------------------------------------------------------
# Prefer a locally installed markdownlint-cli2/markdownlint; fall back to npx
# if a network-capable npx is available. Config is the kit's .markdownlint.jsonc.
md_lint() {
  if command -v markdownlint-cli2 >/dev/null 2>&1; then
    markdownlint-cli2 "**/*.md" "!**/node_modules/**" "!**/dist/**"
  elif command -v markdownlint >/dev/null 2>&1; then
    markdownlint . --ignore node_modules --ignore "**/dist/**"
  elif command -v npx >/dev/null 2>&1; then
    npx -y markdownlint-cli2 "**/*.md" "!**/node_modules/**" "!**/dist/**"
  else
    return 127
  fi
}
if [[ -f "$REPO_ROOT/.markdownlint.jsonc" ]]; then
  if command -v markdownlint-cli2 >/dev/null 2>&1 \
     || command -v markdownlint >/dev/null 2>&1 \
     || command -v npx >/dev/null 2>&1; then
    run_gate "Markdown lint" md_lint
  else
    note_skipped "Markdown" "markdownlint not installed (see markdown skill)"
  fi
else
  note_skipped "Markdown" "no .markdownlint.jsonc"
fi

# --- SEO: JS-disabled view-source assertion -------------------------------
# First-GET-without-JS / view-source acceptance test (docs/seo-discoverability.md).
# We fetch raw HTML (no JS execution — curl never runs JS, which is exactly the
# GPTBot/ClaudeBot worst case) and assert the FULL first-GET contract via the
# shared assertion in lib/seed-gates.sh (JSON-LD validity, og: + twitter:,
# exactly one <h1>, landmarks, no inline executable scripts) — one assertion
# implementation for both the URL gate and the built-HTML gate, so the harness
# cannot drift from the spec. A weaker inline fallback covers a tree where
# lib/seed-gates.sh is absent.
view_source_assert() {
  local url="$1" html tmp rc=0 h1count lm
  if ! command -v curl >/dev/null 2>&1; then
    return 127
  fi
  html="$(curl -fsSL "$url")" || { echo "    could not fetch $url" >&2; return 1; }

  if declare -f assert_view_source_html >/dev/null 2>&1; then
    tmp="$(mktemp)" || return 1
    printf '%s' "$html" > "$tmp"
    assert_view_source_html "$tmp"
    rc=$?
    rm -f "$tmp"
    [[ "$rc" -eq 0 ]] && echo "    first-GET contract ✓ (shared assertion)"
    return "$rc"
  fi

  # Fallback (lib/seed-gates.sh absent): presence checks only — weaker than the
  # shared assertion (no JSON-LD parse, no inline-script ban). Restore the lib
  # for the full contract.
  printf '%s' "$html" | grep -qi 'application/ld+json' \
    || { echo "    missing <script type=application/ld+json>" >&2; rc=1; }
  printf '%s' "$html" | grep -qiE "property=[\"']og:" \
    || { echo "    missing og: meta tags" >&2; rc=1; }
  printf '%s' "$html" | grep -qiE "name=[\"']twitter:" \
    || { echo "    missing twitter: meta tags" >&2; rc=1; }
  h1count="$(printf '%s' "$html" | grep -oi '<h1[ >]' | wc -l | tr -d ' ')"
  [[ "$h1count" == "1" ]] \
    || { echo "    expected exactly one <h1>, found $h1count" >&2; rc=1; }
  for lm in header nav main footer; do
    printf '%s' "$html" | grep -qi "<${lm}[ >/]" \
      || { echo "    missing <$lm> landmark" >&2; rc=1; }
  done
  [[ "$rc" -eq 0 ]] && echo "    ld+json ✓  og: ✓  twitter: ✓  single <h1> ✓  landmarks ✓"
  return "$rc"
}
if [[ "$SKIP_VIEW_SOURCE" == true ]]; then
  note_skipped "view-source" "--skip-view-source"
elif [[ -z "$VIEW_SOURCE_URL" ]]; then
  note_skipped "view-source" "no --url / CHECK_URL"
elif ! command -v curl >/dev/null 2>&1; then
  note_skipped "view-source" "curl not installed"
else
  run_gate "view-source ($VIEW_SOURCE_URL)" view_source_assert "$VIEW_SOURCE_URL"
fi

# --- Scaffold-completeness gate -------------------------------------------
if declare -f gate_placeholder_slots >/dev/null 2>&1; then
  run_gate "Placeholder slots" gate_placeholder_slots "$REPO_ROOT"
else
  note_skipped "Placeholder slots" "seed-gates.sh not present"
fi

# --- Token-drift gate -----------------------------------------------------
if declare -f gate_token_drift >/dev/null 2>&1 \
   && { [[ -d "$REPO_ROOT/apps/web" ]] || [[ -d "$REPO_ROOT/apps/app" ]]; }; then
  run_gate "Token drift" gate_token_drift "$REPO_ROOT"
else
  note_skipped "Token drift" "no app slots / seed-gates.sh absent"
fi

# --- First-GET / SEO over built HTML --------------------------------------
# Runs only when apps/web is scaffolded (sentinel removed) and a build exists.
if declare -f gate_view_source_dir >/dev/null 2>&1 \
   && [[ -d "$REPO_ROOT/apps/web" ]] \
   && ! slot_is_placeholder "$REPO_ROOT" web; then
  WEB_DIST=""
  for cand in "$REPO_ROOT/apps/web/dist" "$REPO_ROOT/apps/web/build"; do
    [[ -d "$cand" ]] && WEB_DIST="$cand" && break
  done
  if [[ -n "$WEB_DIST" ]]; then
    run_gate "First-GET (apps/web/dist)" gate_view_source_dir "$WEB_DIST"
  else
    note_skipped "First-GET" "apps/web scaffolded but no dist/ build found (run the web build first)"
  fi
else
  note_skipped "First-GET" "apps/web is a placeholder or seed-gates.sh absent"
fi

# --- Report ---------------------------------------------------------------
echo ""
echo "==> Summary"
if [[ ${#RAN[@]} -gt 0 ]]; then
  for g in "${RAN[@]}"; do echo "    ran:  $g"; done
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  for g in "${SKIPPED[@]}"; do echo "    $g"; done
fi

DURATION=$(( $(date +%s) - START_TIME ))
if [[ "$FAILED" -ne 0 ]]; then
  echo "🏁 clock stopped (took ${DURATION}s, ended $(date '+%H:%M:%S'))"
  echo "FAILED — at least one gate did not pass." >&2
  exit 1
fi
echo "🏁 clock stopped (took ${DURATION}s, ended $(date '+%H:%M:%S'))"
echo "OK — all present gates passed."
exit 0
