#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# cf-domain-bind.sh — the orange-proxy dance, end to end (docs/edge.md):
#
#   1. Upsert the CNAME in Cloudflare **grey-clouded** (DNS-only) so Azure
#      managed-cert validation resolves directly (the proxy blocks DigiCert).
#      For ACA, also upsert the asuid.<sub> ownership TXT.
#   2. Drive the Azure-side bind:
#        swa: az staticwebapp hostname set (TXT validation) and poll status
#        aca: az containerapp env certificate create (managed cert) and poll
#             hostname bindingType — the hostname itself must be DECLARED IN
#             THE APPLIED IaC (ingress.customDomains, bindingType 'Auto');
#             this script is one-time bootstrap + break-glass, never a
#             pipeline dependency (rules/backend-container-apps.md).
#   3. Flip the CNAME to **proxied** (orange cloud).
#
# Resumable: every step checks current state first; re-run after a timeout.
# Conventions: docs/scripts.md (-h/--help, fail-fast, macOS bash 3.2).
# ---------------------------------------------------------------------------

API="https://api.cloudflare.com/client/v4"
ZONE_ID="" FQDN="" ORIGIN="" KIND="" RG="" APP="" ACA_ENV="" TIMEOUT=900
VALIDATION_METHOD="CNAME"

usage() {
  cat <<'EOF'
Usage:
  CF_API_TOKEN=... cf-domain-bind.sh --zone-id <id> --fqdn <host> \
    --origin <azure-hostname> --kind swa --resource-group <rg> --app <name>
  CF_API_TOKEN=... cf-domain-bind.sh --zone-id <id> --fqdn <host> \
    --origin <azure-hostname> --kind aca --resource-group <rg> --app <name> \
    --aca-env <managed-env-name>

Options:
  --zone-id <id>          Cloudflare zone ID
  --fqdn <host>           Hostname to bind (apex or subdomain)
  --origin <host>         Azure default hostname (SWA *.azurestaticapps.net /
                          ACA FQDN)
  --kind <swa|aca>        Which origin flavor drives validation
  --resource-group <rg>   Azure resource group
  --app <name>            SWA name / Container App name
  --aca-env <name>        ACA managed environment (kind=aca only)
  --validation-method <CNAME|TXT|HTTP>
                          Azure managed-cert validation method, kind=aca only
                          (default CNAME). THE RULE: CNAME = subdomain (default,
                          ~2.5 min); TXT = apex ONLY — the escape hatch for when
                          a flattening DNS proxy (e.g. Cloudflare on the apex)
                          makes CNAME validation unreachable. Do NOT use TXT on a
                          subdomain: it is CLI-accepted, sits `Pending` ~80 min,
                          then `Failed` — and a Pending cert 500s on delete until
                          it goes terminal, so there is no fast abort.
  --timeout <seconds>     Max wait for cert issuance (default 900)
  -h, --help              Show this help

Requires: CF_API_TOKEN (DNS Write), az CLI logged in, python3, curl.
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help)    usage ;;
    --zone-id)         ZONE_ID="${2:-}"; shift 2 ;;
    --fqdn)            FQDN="${2:-}"; shift 2 ;;
    --origin)          ORIGIN="${2:-}"; shift 2 ;;
    --kind)            KIND="${2:-}"; shift 2 ;;
    --resource-group)  RG="${2:-}"; shift 2 ;;
    --app)             APP="${2:-}"; shift 2 ;;
    --aca-env)         ACA_ENV="${2:-}"; shift 2 ;;
    --validation-method) VALIDATION_METHOD="${2:-}"; shift 2 ;;
    --timeout)         TIMEOUT="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -n "${CF_API_TOKEN:-}" ]] || { echo "Error: CF_API_TOKEN not set" >&2; exit 1; }
# Explicit var→flag pairs (bash 3.2: no assoc arrays) so errors name real flags.
for pair in "ZONE_ID:--zone-id" "FQDN:--fqdn" "ORIGIN:--origin" \
            "KIND:--kind" "RG:--resource-group" "APP:--app"; do
  v="${pair%%:*}" flag="${pair#*:}"
  eval "val=\${$v}"
  [[ -n "$val" ]] || { echo "Error: $flag is required" >&2; exit 1; }
done
case "$KIND" in
  swa) : ;;
  aca) [[ -n "$ACA_ENV" ]] || { echo "Error: --aca-env required for kind=aca" >&2; exit 1; } ;;
  *)   echo "Error: --kind must be swa or aca" >&2; exit 1 ;;
esac
case "$TIMEOUT" in # non-empty, all digits, no leading zero (avoids octal $(( )))
  ''|*[!0-9]*|0*) echo "Error: --timeout must be a positive integer" >&2; exit 1 ;;
esac
case "$VALIDATION_METHOD" in
  CNAME|TXT|HTTP) : ;;
  *) echo "Error: --validation-method must be CNAME, TXT, or HTTP" >&2; exit 1 ;;
esac
command -v curl >/dev/null || { echo "Error: curl not found" >&2; exit 1; }
command -v az >/dev/null || { echo "Error: az CLI not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Error: python3 not found" >&2; exit 1; }

cf() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" --data "$body"
  else
    curl -sS -X "$method" "$API$path" -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}
jget() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2" <<<"$1"
}
require_ok() {
  [[ "$(jget "$1" 'd["success"]')" == "True" ]] \
    || { echo "Error: $2 failed: $(jget "$1" 'json.dumps(d["errors"])')" >&2; exit 1; }
}

upsert_record() { # upsert_record <type> <name> <content> <proxied true|false>
  local type="$1" name="$2" content="$3" proxied="$4" rec rec_id body
  rec="$(cf GET "/zones/$ZONE_ID/dns_records?type=$type&name=$name")"
  require_ok "$rec" "DNS lookup $name"
  if [[ "$(jget "$rec" 'len(d["result"])')" == "0" ]]; then
    # JSON bodies are built OUTSIDE the $() call: macOS bash 3.2 mis-parses
    # \" inside command substitution (args split, body mangled -> API 9207).
    body="{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"proxied\":$proxied,\"ttl\":1}"
    require_ok "$(cf POST "/zones/$ZONE_ID/dns_records" "$body")" "DNS create $name"
    echo "    create: $name ($type, proxied=$proxied)"
  else
    rec_id="$(jget "$rec" 'd["result"][0]["id"]')"
    body="{\"content\":\"$content\",\"proxied\":$proxied}"
    require_ok "$(cf PATCH "/zones/$ZONE_ID/dns_records/$rec_id" "$body")" "DNS update $name"
    echo "    update: $name ($type, proxied=$proxied)"
  fi
}

# --- 1. Grey-cloud DNS -------------------------------------------------------
echo "==> Step 1: DNS (grey-cloud for validation)"
upsert_record CNAME "$FQDN" "$ORIGIN" false
if [[ "$KIND" == "aca" ]]; then
  VERIFICATION_ID="$(az containerapp show -g "$RG" -n "$APP" \
    --query "properties.customDomainVerificationId" -o tsv)"
  upsert_record TXT "asuid.$FQDN" "$VERIFICATION_ID" false
fi

# --- 2. Azure-side bind ------------------------------------------------------
echo "==> Step 2: Azure-side bind ($KIND)"
deadline=$(( $(date +%s) + TIMEOUT ))
if [[ "$KIND" == "swa" ]]; then
  az staticwebapp hostname set -g "$RG" -n "$APP" --hostname "$FQDN" \
    --validation-method dns-txt-token --no-wait >/dev/null 2>&1 || true
  # The validation token can lag `hostname set --no-wait`; fetch it inside the
  # poll loop and upsert the _dnsauth TXT once, as soon as a token appears.
  txt_written=false
  while :; do
    if [[ "$txt_written" == false ]]; then
      TXT_TOKEN="$(az staticwebapp hostname show -g "$RG" -n "$APP" \
        --hostname "$FQDN" --query "validationToken" -o tsv 2>/dev/null || true)"
      if [[ -n "$TXT_TOKEN" && "$TXT_TOKEN" != "None" ]]; then
        upsert_record TXT "_dnsauth.$FQDN" "$TXT_TOKEN" false
        txt_written=true
      fi
    fi
    status="$(az staticwebapp hostname show -g "$RG" -n "$APP" \
      --hostname "$FQDN" --query "status" -o tsv 2>/dev/null || echo pending)"
    [[ "$status" == "Ready" ]] && { echo "    hostname Ready"; break; }
    [[ "$(date +%s)" -ge "$deadline" ]] \
      && { echo "Error: timed out waiting for SWA hostname (status: $status). Re-run to resume." >&2; exit 1; }
    echo "    waiting: SWA hostname status=$status"; sleep 20
  done
else
  # Managed cert: created once per hostname per environment; idempotent-ish —
  # an existing cert makes this a no-op error we tolerate.
  az containerapp env certificate create -g "$RG" -n "$ACA_ENV" \
    --hostname "$FQDN" --validation-method "$VALIDATION_METHOD" >/dev/null 2>&1 || true
  # The hostname itself must be declared in the applied IaC
  # (ingress.customDomains, bindingType 'Auto'); poll until 'Auto'/'SniEnabled'.
  while :; do
    binding="$(az containerapp hostname list -g "$RG" -n "$APP" \
      --query "[?name=='$FQDN'].bindingType | [0]" -o tsv 2>/dev/null || echo "")"
    case "$binding" in
      Auto|SniEnabled) echo "    hostname bound ($binding)"; break ;;
    esac
    [[ "$(date +%s)" -ge "$deadline" ]] \
      && { echo "Error: timed out waiting for ACA binding (got: '${binding:-none}')." >&2
           echo "  Is the hostname declared in the applied IaC (ingress.customDomains)?" >&2
           echo "  Break-glass: az containerapp hostname bind -g $RG -n $APP --hostname $FQDN" >&2
           exit 1; }
    echo "    waiting: ACA bindingType='${binding:-none}'"; sleep 20
  done
fi

# --- 3. Flip to proxied ------------------------------------------------------
echo "==> Step 3: orange-cloud"
upsert_record CNAME "$FQDN" "$ORIGIN" true
echo "Done. $FQDN is bound at the origin and proxied at the Cloudflare edge."
exit 0
