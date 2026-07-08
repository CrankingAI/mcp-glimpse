#!/usr/bin/env bash
set -uo pipefail

# ---------------------------------------------------------------------------
# preflight.sh — exercise the CAPABILITY of each credential/tool a kit
# operation will actually use, before any real work begins.
#
# Shallow "am I logged in?" checks give false greens (fleet finding,
# docs/backlog.md §11b): azd's `auth login --check-status` reported "Logged in"
# and then failed principal resolution 30 minutes into a provision; a Cloudflare
# token passed `user/tokens/verify` ("active") and then could not read the zone
# it needed to edit. Every check here does the real thing instead — issue a
# token, read the target resource, hit the API — and fails fast with the exact
# remediation.
#
# Runs only the checks whose inputs are present (same philosophy as check.sh):
# a tool not installed or a credential not configured is SKIPPED, not failed.
# Exits non-zero if any active check FAILS.
#
# Usage:
#   ./scripts/preflight.sh
#   ./scripts/preflight.sh --zone-id <cf-zone-id>   # also read-probe that CF zone
#
# Conditional checks read from the environment / known dotfiles:
#   CF_API_TOKEN (+ --zone-id)   Cloudflare edge
#   ~/.descope-management-key + ~/.descope-project-id   MCP auth (Descope)
#
# Conventions: docs/scripts.md (-h/--help, fail-fast, macOS bash 3.2).
# ---------------------------------------------------------------------------

ZONE_ID=""

usage() {
  cat <<'EOF'
Usage: preflight.sh [--zone-id <cf-zone-id>] [-h|--help]

Exercises the real capability of each credential/tool in play (not just login
status) so a stuck credential fails in seconds, not mid-deploy. Skips any tool
or credential that is not present. Exits non-zero if any active check fails.

Options:
  --zone-id <id>   Cloudflare zone to read-probe (proves the token's real scope,
                   not just that it verifies). Uses CF_API_TOKEN from the env.
  -h, --help       Show this help
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --zone-id)      ZONE_ID="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

PASS=0; SKIP=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$1"; }
bad()  {
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        fix: %s\n' "$2"
  return 0
}
have() { command -v "$1" >/dev/null 2>&1; }

echo "==> Preflight (capability checks, not login-status)"

# --- az: a token must actually ISSUE for the current subscription ------------
if have az; then
  if az account show >/dev/null 2>&1; then
    if az account get-access-token --query expiresOn -o tsv >/dev/null 2>&1; then
      ok "az: access token issues for '$(az account show --query name -o tsv 2>/dev/null)'"
    else
      bad "az: logged in but cannot issue an access token for the current sub" \
          "az login   (or: az account set --subscription <id>)"
    fi
  else
    bad "az: not logged in" "az login"
  fi
else
  skip "az: not installed"
fi

# --- azd: --check-status is NOT sufficient (it lies); surface the trap -------
if have azd; then
  if azd auth login --check-status >/dev/null 2>&1; then
    ok "azd: authenticated (see note — check-status does not prove principal resolution)"
  else
    bad "azd: not authenticated" "azd auth login   (--tenant-id <sub-tenant> if it stalls)"
  fi
  printf '        note: azd principal resolution can still fail at provision even when\n'
  printf '        check-status is green (docs/backlog.md §11d). If provision fails with\n'
  printf '        "fetching current principal id", use the az fallback path\n'
  printf '        (docs/deployment.md).\n'
else
  skip "azd: not installed"
fi

# --- gh: token + scopes must be real -----------------------------------------
if have gh; then
  if gh api user --jq .login >/dev/null 2>&1; then
    ok "gh: API reachable as '$(gh api user --jq .login 2>/dev/null)'"
  else
    bad "gh: token missing or unauthorized" "gh auth login"
  fi
else
  skip "gh: not installed"
fi

# --- docker: daemon must be UP (before any container build) ------------------
if have docker; then
  if docker info >/dev/null 2>&1; then
    ok "docker: daemon reachable"
  else
    bad "docker: daemon not reachable" "start Docker Desktop / the docker daemon"
  fi
else
  skip "docker: not installed"
fi

# --- node / pnpm: shims must resolve -----------------------------------------
if have node; then
  ok "node: $(node -v 2>/dev/null)"
  if have pnpm; then
    ok "pnpm: $(pnpm -v 2>/dev/null)"
  else
    skip "pnpm: not on PATH (nvm use / corepack enable)"
  fi
else
  skip "node: not installed"
fi

# --- Cloudflare: the token must READ the target zone, not just verify --------
if [ -n "${CF_API_TOKEN:-}" ]; then
  if have curl; then
    vr="$(curl -sS --max-time 15 -H "Authorization: Bearer $CF_API_TOKEN" \
          "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)"
    if printf '%s' "$vr" | grep -q '"status":"active"'; then
      if [ -n "$ZONE_ID" ]; then
        zr="$(curl -sS --max-time 15 -H "Authorization: Bearer $CF_API_TOKEN" \
              "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=1" 2>/dev/null)"
        if printf '%s' "$zr" | grep -q '"success":true'; then
          ok "cloudflare: token READS zone $ZONE_ID (real scope confirmed)"
        else
          bad "cloudflare: token is active but CANNOT read zone $ZONE_ID" \
              "verify passes for a mint-only/wrong-scope token — re-scope with Zone.DNS/Settings/etc (docs/edge.md)"
        fi
      else
        ok "cloudflare: token active (pass --zone-id to confirm real zone scope)"
      fi
    else
      bad "cloudflare: token failed verify" "check CF_API_TOKEN (docs/edge.md)"
    fi
  else
    skip "cloudflare: curl not installed (cannot probe CF_API_TOKEN)"
  fi
else
  skip "cloudflare: CF_API_TOKEN not set"
fi

# --- Descope: management key + project id must be present + non-empty ---------
# (A read-only capability probe against the Management API is deferred until a
#  safe endpoint is confirmed — see docs/backlog.md §11c; presence is the floor.)
if [ -f "$HOME/.descope-management-key" ] || [ -f "$HOME/.descope-project-id" ]; then
  if [ -s "$HOME/.descope-management-key" ] && [ -s "$HOME/.descope-project-id" ]; then
    ok "descope: management-key + project-id dotfiles present (mgmt-call probe: TODO §11c)"
  else
    bad "descope: a credential dotfile is missing or empty" \
        "recreate per ~/.descope-management-key.INSTRUCTIONS.txt"
  fi
else
  skip "descope: management-key / project-id dotfiles not present"
fi

echo ""
printf 'preflight: %d passed, %d skipped, %d failed\n' "$PASS" "$SKIP" "$FAIL"
[ "$FAIL" -eq 0 ]
