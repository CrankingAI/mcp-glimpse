#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# cf-zone-init.sh — idempotent Cloudflare zone posture for this repo's edge
# (docs/edge.md): SSL Full (strict), min TLS 1.2, Always Use HTTPS, proxied
# CNAMEs (apex + www), cache-bypass on the watched paths, www→apex redirect,
# verified-bot transform rule (x-kit-verified-bot[-category] headers).
#
# Modes:
#   default        apply the zone posture (requires CF_API_TOKEN with
#                  DNS Write + Zone Settings Write + Cache Settings Write +
#                  Dynamic URL Redirects Write + Zone Transform Rules Write)
#   --mint-tokens  bootstrap: mint the two least-privilege tokens from a
#                  broader bootstrap token (needs "API Tokens: Edit"; e.g. the
#                  one OAuth-approved session's token) and store them via
#                  `gh secret set`. The only human steps before this are:
#                  create account, add zone, delegate nameservers.
#
# Idempotent: every step GETs current state and PATCHes only on drift.
# Conventions: docs/scripts.md (-h/--help, fail-fast, macOS bash 3.2).
# ---------------------------------------------------------------------------

API="https://api.cloudflare.com/client/v4"
ZONE_ID="" DOMAIN="" ORIGIN="" MINT_TOKENS=false

usage() {
  cat <<'EOF'
Usage:
  CF_API_TOKEN=... cf-zone-init.sh --zone-id <id> --domain <apex> --origin <host>
  CF_API_TOKEN=<bootstrap-token> cf-zone-init.sh --mint-tokens --zone-id <id> --domain <apex>

Applies the kit's Cloudflare zone posture (docs/edge.md), idempotently:
  SSL Full (strict) · min TLS 1.2 · Always Use HTTPS · proxied CNAME apex+www
  → origin · cache-bypass ruleset on watched paths · www→apex 301 redirect ·
  verified-bot transform rule (x-kit-verified-bot[-category] headers).

Options:
  --zone-id <id>    Cloudflare zone ID (dashboard → zone → Overview)
  --domain <apex>   Apex domain, e.g. example.com
  --origin <host>   Origin hostname (SWA default hostname or ACA FQDN)
  --mint-tokens     Mint the least-privilege zone-config + worker-deploy
                    tokens (bootstrap token in CF_API_TOKEN) and store them
                    with `gh secret set CF_API_TOKEN / CF_WORKER_DEPLOY_TOKEN`
  -h, --help        Show this help

Environment:
  CF_API_TOKEN      Required. Zone-config token (default mode) or a bootstrap
                    token holding "API Tokens: Edit" (--mint-tokens).
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help) usage ;;
    --zone-id)      ZONE_ID="${2:-}"; shift 2 ;;
    --domain)       DOMAIN="${2:-}"; shift 2 ;;
    --origin)       ORIGIN="${2:-}"; shift 2 ;;
    --mint-tokens)  MINT_TOKENS=true; shift ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "${CF_API_TOKEN:-}" ]] || { echo "Error: CF_API_TOKEN not set" >&2; exit 1; }
[[ -n "$ZONE_ID" && -n "$DOMAIN" ]] || { echo "Error: --zone-id and --domain are required" >&2; exit 1; }
command -v curl >/dev/null || { echo "Error: curl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Error: python3 needed for JSON parsing" >&2; exit 1; }

cf() { # cf <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" --data "$body"
  else
    curl -sS -X "$method" "$API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}

jget() { # jget <json> <python-expr over d>
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2" <<<"$1"
}

require_ok() { # require_ok <json> <what>
  [[ "$(jget "$1" 'd["success"]')" == "True" ]] \
    || { echo "Error: $2 failed: $(jget "$1" 'json.dumps(d["errors"])')" >&2; exit 1; }
}

# --- Bootstrap: mint least-privilege tokens --------------------------------
if [[ "$MINT_TOKENS" == true ]]; then
  command -v gh >/dev/null || { echo "Error: gh CLI needed for secret storage" >&2; exit 1; }
  echo "==> Looking up permission groups"
  pgs="$(cf GET "/user/tokens/permission_groups")"
  require_ok "$pgs" "permission-group lookup"
  pg_id() { # pg_id <name> -> id, or a clean fatal error (never a raw IndexError)
    local id
    id="$(jget "$pgs" "([g['id'] for g in d['result'] if g['name']=='$1'] or [''])[0]")"
    [[ -n "$id" ]] \
      || { echo "Error: permission group '$1' not found — check /user/tokens/permission_groups" >&2; exit 1; }
    echo "$id"
  }
  DNS_W="$(pg_id 'DNS Write')"
  READ_Z="$(pg_id 'Zone Read')"                   # for the account-id self-lookup below
  SET_W="$(pg_id 'Zone Settings Write')"
  CACHE_W="$(pg_id 'Cache Settings Write')"       # NB: dashboard says "Cache Rules"; the API group is "Cache Settings Write"
  REDIRECT_W="$(pg_id 'Dynamic URL Redirects Write')"
  TRANSFORM_W="$(pg_id 'Zone Transform Rules Write')" # NB: plain "Transform Rules Write" exists but is ACCOUNT-scoped
  WORKERS_W="$(pg_id 'Workers Scripts Write')"
  ROUTES_W="$(pg_id 'Workers Routes Write')"

  echo "==> Minting zone-config token (zone-scoped)"
  # Zone Read is included so THIS token can do the account-id self-lookup below.
  # The bootstrap ("Create Additional Tokens") token is User-scoped only and
  # 9109s on any zone read — so the lookup must use the minted token, not it.
  zc="$(cf POST "/user/tokens" "$(cat <<JSON
{"name":"$DOMAIN zone-config (seed kit)","policies":[{"effect":"allow",
"resources":{"com.cloudflare.api.account.zone.$ZONE_ID":"*"},
"permission_groups":[{"id":"$DNS_W"},{"id":"$READ_Z"},{"id":"$SET_W"},{"id":"$CACHE_W"},
{"id":"$REDIRECT_W"},{"id":"$TRANSFORM_W"}]}]}
JSON
)")"
  require_ok "$zc" "zone-config token mint"
  ZC_TOKEN="$(jget "$zc" 'd["result"]["value"]')"
  # Accepted trade-off (recorded decision): the token value passes via argv
  # (visible in ps momentarily) — one-time bootstrap on an operator machine.
  gh secret set CF_API_TOKEN --body "$ZC_TOKEN"

  echo "==> Minting worker-deploy token (account-scoped)"
  # Account-id self-lookup uses the just-minted zone-config token (it has Zone
  # Read), NOT the bootstrap token in CF_API_TOKEN, which cannot read zones.
  acct="$(curl -sS --max-time 20 -H "Authorization: Bearer $ZC_TOKEN" "$API/zones/$ZONE_ID")"
  require_ok "$acct" "zone lookup"
  ACCOUNT_ID="$(jget "$acct" 'd["result"]["account"]["id"]')"
  wd="$(cf POST "/user/tokens" "$(cat <<JSON
{"name":"$DOMAIN worker-deploy (seed kit)","policies":[{"effect":"allow",
"resources":{"com.cloudflare.api.account.$ACCOUNT_ID":"*"},
"permission_groups":[{"id":"$WORKERS_W"},{"id":"$ROUTES_W"}]}]}
JSON
)")"
  require_ok "$wd" "worker-deploy token mint"
  gh secret set CF_WORKER_DEPLOY_TOKEN --body "$(jget "$wd" 'd["result"]["value"]')"
  # Account/zone IDs are NOT secrets — store as GH Actions VARIABLES, named to
  # match what the deploy workflow reads (vars.CF_ACCOUNT_ID / vars.CF_ZONE_ID).
  gh variable set CF_ACCOUNT_ID --body "$ACCOUNT_ID"
  gh variable set CF_ZONE_ID --body "$ZONE_ID"
  echo "Done. Tokens are GH secrets; account/zone IDs are GH variables; the bootstrap token can now be revoked."
  exit 0
fi

[[ -n "$ORIGIN" ]] || { echo "Error: --origin is required (SWA/ACA hostname)" >&2; exit 1; }

# --- Zone settings ----------------------------------------------------------
ensure_setting() { # ensure_setting <id> <value>
  local cur resp body
  resp="$(cf GET "/zones/$ZONE_ID/settings/$1")"
  require_ok "$resp" "read $1"
  cur="$(jget "$resp" 'd["result"]["value"]')"
  if [[ "$cur" == "$2" ]]; then
    echo "    ok: $1 = $2"
  else
    # JSON bodies are built OUTSIDE the $() call: macOS bash 3.2 mis-parses
    # \" inside command substitution (args split, body mangled -> API 9207).
    body="{\"value\":\"$2\"}"
    require_ok "$(cf PATCH "/zones/$ZONE_ID/settings/$1" "$body")" "$1"
    echo "    set: $1 $cur -> $2"
  fi
}
echo "==> Zone settings"
ensure_setting ssl strict
ensure_setting min_tls_version "1.2"
ensure_setting always_use_https on

# --- Proxied CNAMEs (apex + www) → origin ------------------------------------
ensure_cname() { # ensure_cname <name>
  local name="$1" rec rec_id cur_content cur_proxied body
  rec="$(cf GET "/zones/$ZONE_ID/dns_records?type=CNAME&name=$name")"
  require_ok "$rec" "DNS lookup $name"
  if [[ "$(jget "$rec" 'len(d["result"])')" == "0" ]]; then
    # body built outside $() — bash 3.2 \"-in-command-substitution bug.
    body="{\"type\":\"CNAME\",\"name\":\"$name\",\"content\":\"$ORIGIN\",\"proxied\":true,\"ttl\":1}"
    require_ok "$(cf POST "/zones/$ZONE_ID/dns_records" "$body")" "DNS create $name"
    echo "    create: $name -> $ORIGIN (proxied)"
  else
    rec_id="$(jget "$rec" 'd["result"][0]["id"]')"
    cur_content="$(jget "$rec" 'd["result"][0]["content"]')"
    cur_proxied="$(jget "$rec" 'd["result"][0]["proxied"]')"
    if [[ "$cur_content" == "$ORIGIN" && "$cur_proxied" == "True" ]]; then
      echo "    ok: $name -> $ORIGIN (proxied)"
    else
      body="{\"content\":\"$ORIGIN\",\"proxied\":true}"
      require_ok "$(cf PATCH "/zones/$ZONE_ID/dns_records/$rec_id" "$body")" "DNS update $name"
      echo "    update: $name -> $ORIGIN (proxied)"
    fi
  fi
}
echo "==> DNS"
ensure_cname "$DOMAIN"
ensure_cname "www.$DOMAIN"

# --- Rulesets: cache bypass on watched paths + www→apex redirect -------------
# PUT on the zone entrypoint replaces the kit-owned phase wholesale — that is
# the idempotency mechanism (re-runs converge, hand edits are reconciled).
put_entrypoint() { # put_entrypoint <phase> <rules-json> <what>
  # body built outside $() — bash 3.2 \"-in-command-substitution bug.
  local body="{\"rules\":$2}"
  require_ok "$(cf PUT "/zones/$ZONE_ID/rulesets/phases/$1/entrypoint" "$body")" "$3"
  echo "    set: $3"
}
echo "==> Rulesets"
WATCHED_EXPR='(http.request.uri.path in {"/sitemap.xml" "/llms.txt" "/llms-full.txt" "/robots.txt" "/security.txt"} or starts_with(http.request.uri.path, "/.well-known/"))'
put_entrypoint http_request_cache_settings "[
  {\"action\":\"set_cache_settings\",
   \"action_parameters\":{\"cache\":false},
   \"expression\":\"${WATCHED_EXPR//\"/\\\"}\",
   \"description\":\"bypass cache on watched paths (docs/edge.md)\",
   \"enabled\":true}]" "cache bypass on watched paths"
put_entrypoint http_request_dynamic_redirect "[
  {\"action\":\"redirect\",
   \"action_parameters\":{\"from_value\":{\"status_code\":301,
     \"target_url\":{\"expression\":\"concat(\\\"https://$DOMAIN\\\", http.request.uri.path)\"},
     \"preserve_query_string\":true}},
   \"expression\":\"(http.host eq \\\"www.$DOMAIN\\\")\",
   \"description\":\"www to apex (docs/site-conventions.md)\",
   \"enabled\":true}]" "www -> apex redirect"
# cf.client.bot / cf.verified_bot_category are ruleset fields on every plan;
# request.cf.botManagement in the Worker is Enterprise-only. This rule stamps
# both as headers, unconditionally, on every request — the unconditional SET
# is what makes it anti-spoofing (client-supplied values are always
# overwritten at the edge before the Worker ever sees the request).
put_entrypoint http_request_late_transform "[
  {\"action\":\"rewrite\",
   \"action_parameters\":{\"headers\":{
     \"x-kit-verified-bot\":{\"operation\":\"set\",\"expression\":\"to_string(cf.client.bot)\"},
     \"x-kit-verified-bot-category\":{\"operation\":\"set\",\"expression\":\"cf.verified_bot_category\"}}},
   \"expression\":\"true\",
   \"description\":\"verified-bot header for the edge Worker (docs/edge.md)\",
   \"enabled\":true}]" "verified-bot header rule"

echo "Done. Next: scripts/cf-domain-bind.sh (origin cert dance), then wrangler deploy in apps/edge/."
exit 0
