#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# entra-external-id-doctor.sh — best-practice diagnostic for an Entra External
# ID (CIAM) deployment that powers an MCP OAuth2 resource server + a SPA public
# client + a confidential client + a consumer self-service sign-up user flow.
#
# Read-only. Every check is a Graph GET / `az ... show|list` / HTTP probe — safe
# against production. It runs ALL applicable checks (never aborts on a failed
# check) and prints a per-rule line plus a grouped summary. It fails-fast ONLY
# on a missing prerequisite or missing auth.
#
# Rule catalog (the source of truth, with severity / check / pass / fix per
# rule) is seed/docs/entra-external-id-checklist.md. The five sections:
#   1. App registration & credential hygiene
#   2. Scopes, permissions & consent
#   3. External-tenant security & user flow
#   4. MCP / OAuth2 resource server (App Service Easy Auth + PRM) — reference for
#      diagnosing an App Service Easy Auth deployment. App Service is no longer a
#      kit host (AGENTS.md backend topology); the kit's ACA MCP host validates in-app (see
#      seed/rules/backend-mcp.md). Protocol-level checks still apply on ACA.
#   5. Operations, monitoring & secret lifecycle
#
# Conventions (match scripts/check.sh): bash 3.2 (macOS) compatible — no
# associative arrays, no `mapfile`; -h/--help; fail-fast on prereqs only.
# ---------------------------------------------------------------------------

# --- defaults --------------------------------------------------------------
CONFIG_PATH="./infra/external-id.outputs.json"
TENANT_ID=""
API_APP_ID=""
SPA_APP_ID=""
CONFIDENTIAL_APP_ID=""
API_SP_ID=""
MCP_HOST="https://mcp.informhuman.com"
RESOURCE_GROUP=""
WEBAPP=""
STORAGE_ACCOUNT=""
USERFLOW_ID=""
API_SCOPE="Inform.Send"
API_IDENTIFIER_URI=""
SPA_SP_ID=""
CONF_SP_ID=""

ONLY_SECTION=""
OUTPUT_FORMAT="text"
NO_FAIL=false

GRAPH_APPID="00000003-0000-0000-c000-000000000000"   # Microsoft Graph, constant
GRAPH_V1="https://graph.microsoft.com/v1.0"
GRAPH_BETA="https://graph.microsoft.com/beta"

usage() {
  cat <<'EOF'
Usage: entra-external-id-doctor.sh [options]

Read-only best-practice diagnostic for an Entra External ID (CIAM) deployment
(MCP resource server + SPA public client + confidential client + sign-up flow).
Runs every applicable rule from seed/docs/entra-external-id-checklist.md and
prints a grouped report. Safe against production: only GET / show / list.

Inputs (most are derived from --config; flags override):
  --config <path>            Provisioning outputs JSON. Default:
                             ./infra/external-id.outputs.json
                             Derives tenantId, api.appId/spId/scope/identifierUri,
                             portal.appId/spId, mcpClient.appId/spId, userFlow.id.

Overrides (optional unless the config lacks the value):
  --tenant-id <guid>         CIAM tenant id (REQUIRED via config or flag).
  --api-app-id <guid>        API (resource server) application appId.
  --spa-app-id <guid>        SPA public client appId.
  --confidential-app-id <g>  Confidential client appId.
  --api-sp-id <guid>         API service principal objectId.
  --mcp-host <url>           MCP host base URL. Default https://mcp.informhuman.com
  --resource-group <name>    Azure RG for the webapp/storage (ARM checks).
  --webapp <name>            App Service name hosting MCP (Easy Auth checks).
  --storage-account <name>   Storage account name (storage posture checks).

Behavior:
  --section <1..5>           Run only one section.
  --format text|json         Output format (default text). json emits an array of
                             {id,severity,status,reason}.
  --no-fail                  Always exit 0 (default: non-zero if any C/H FAIL).
  -h, --help                 Show this help.

Auth model:
  Graph checks use a token for the CIAM tenant:
    az account get-access-token --tenant <tenantId> --resource https://graph.microsoft.com
  ARM / webapp / storage checks use plain `az` against the signed-in subscription.
  HTTP probes (PRM, 401 challenge) use curl.

Prerequisites (fail-fast if absent): az (logged in), jq, python3, curl.

Examples:
  entra-external-id-doctor.sh --config infra/external-id.outputs.json
  entra-external-id-doctor.sh --section 4 --mcp-host https://mcp.example.com
  entra-external-id-doctor.sh --format json --no-fail > report.json
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help)         usage ;;
    --config)               CONFIG_PATH="${2:-}"; shift 2 ;;
    --tenant-id)            TENANT_ID="${2:-}"; shift 2 ;;
    --api-app-id)           API_APP_ID="${2:-}"; shift 2 ;;
    --spa-app-id)           SPA_APP_ID="${2:-}"; shift 2 ;;
    --confidential-app-id)  CONFIDENTIAL_APP_ID="${2:-}"; shift 2 ;;
    --api-sp-id)            API_SP_ID="${2:-}"; shift 2 ;;
    --mcp-host)             MCP_HOST="${2:-}"; shift 2 ;;
    --resource-group)       RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --webapp)               WEBAPP="${2:-}"; shift 2 ;;
    --storage-account)      STORAGE_ACCOUNT="${2:-}"; shift 2 ;;
    --section)              ONLY_SECTION="${2:-}"; shift 2 ;;
    --format)               OUTPUT_FORMAT="${2:-}"; shift 2 ;;
    --no-fail)              NO_FAIL=true; shift ;;
    *)                      echo "Unknown option: $1" >&2; usage ;;
  esac
done

# --- fail-fast: prerequisites ---------------------------------------------
die() { echo "FATAL: $*" >&2; exit 2; }

command -v jq      >/dev/null 2>&1 || die "jq not installed (brew install jq)."
command -v python3 >/dev/null 2>&1 || die "python3 not installed."
command -v curl    >/dev/null 2>&1 || die "curl not installed."
command -v az      >/dev/null 2>&1 || die "Azure CLI (az) not installed."
az account show >/dev/null 2>&1 || die "Not logged in to Azure CLI. Run: az login"

case "$OUTPUT_FORMAT" in text|json) ;; *) die "--format must be text or json" ;; esac

# --- load config -----------------------------------------------------------
cfg() { # cfg <jq-filter> ; echoes "" when key/file absent
  [ -f "$CONFIG_PATH" ] || { echo ""; return 0; }
  jq -r "$1 // empty" "$CONFIG_PATH" 2>/dev/null || echo ""
}

if [ -f "$CONFIG_PATH" ]; then
  [ -n "$TENANT_ID" ]           || TENANT_ID="$(cfg '.tenantId')"
  [ -n "$API_APP_ID" ]          || API_APP_ID="$(cfg '.api.appId')"
  [ -n "$API_SP_ID" ]           || API_SP_ID="$(cfg '.api.spId')"
  [ -n "$API_IDENTIFIER_URI" ]  || API_IDENTIFIER_URI="$(cfg '.api.identifierUri')"
  [ -n "$SPA_APP_ID" ]          || SPA_APP_ID="$(cfg '.portal.appId')"
  [ -n "$SPA_SP_ID" ]           || SPA_SP_ID="$(cfg '.portal.spId')"
  [ -n "$CONFIDENTIAL_APP_ID" ] || CONFIDENTIAL_APP_ID="$(cfg '.mcpClient.appId')"
  [ -n "$CONF_SP_ID" ]          || CONF_SP_ID="$(cfg '.mcpClient.spId')"
  [ -n "$USERFLOW_ID" ]         || USERFLOW_ID="$(cfg '.userFlow.id')"
  s="$(cfg '.api.scope')";        [ -n "$s" ] && API_SCOPE="$s"
fi
[ -n "$API_IDENTIFIER_URI" ] || { [ -n "$API_APP_ID" ] && API_IDENTIFIER_URI="api://$API_APP_ID"; }

[ -n "$TENANT_ID" ] || die "tenantId not found in --config and not passed via --tenant-id."

# --- acquire a Graph token for the CIAM tenant (fail-fast on auth) ---------
GRAPH_TOKEN="$(az account get-access-token --tenant "$TENANT_ID" \
  --resource https://graph.microsoft.com --query accessToken -o tsv 2>/dev/null || true)"
[ -n "$GRAPH_TOKEN" ] || die "Could not acquire a Graph token for tenant $TENANT_ID. Run: az login --tenant $TENANT_ID"

# ===========================================================================
# Result accumulation (bash 3.2: parallel indexed arrays, no assoc arrays)
# ===========================================================================
R_ID=();   R_SEV=();  R_STATUS=();  R_TITLE=();  R_REASON=();  R_FIX=();  R_SEC=()

CUR_SECTION=0
section() { CUR_SECTION="$1"; }

# record <status> <sev> <id> <title> <reason> <fix>
record() {
  R_STATUS+=("$1"); R_SEV+=("$2"); R_ID+=("$3"); R_TITLE+=("$4")
  R_REASON+=("$5"); R_FIX+=("$6"); R_SEC+=("$CUR_SECTION")
}
pass() { record "PASS" "$1" "$2" "$3" "" ""; }
warn() { record "WARN" "$1" "$2" "$3" "$4" "$5"; }
fail() { record "FAIL" "$1" "$2" "$3" "$4" "$5"; }
skip() { record "SKIP" "$1" "$2" "$3" "$4" ""; }

# Should this section run?
run_section() { [ -z "$ONLY_SECTION" ] || [ "$ONLY_SECTION" = "$1" ]; }

# ===========================================================================
# Graph / az helpers
# ===========================================================================

# graph_get <full-url> -> echoes body (status line stripped)
graph_get() {
  local url="$1" body
  body="$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $GRAPH_TOKEN" "$url" 2>/dev/null || true)"
  printf '%s' "$body" | sed '$d'
}

# graph_app_by_appid <appId> -> full application object JSON (addressed by appId)
graph_app_by_appid() {
  graph_get "$GRAPH_V1/applications(appId='$1')"
}

# is a JSON body a Graph error? echoes the error code or ""
graph_err_code() {
  printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null || echo ""
}

# json bool helper: echo "true"/"false"/"null"
jbool() { printf '%s' "$1" | jq -r "$2 // \"null\"" 2>/dev/null || echo "null"; }

# az json (stdout only — warnings go to stderr); echoes "" on failure
az_json() {
  "$@" -o json 2>/dev/null || echo ""
}

# ===========================================================================
# Pre-fetch the three app-registration objects once (saves round-trips).
# ===========================================================================
APP_API_JSON=""; APP_SPA_JSON=""; APP_CONF_JSON=""
[ -n "$API_APP_ID" ]          && APP_API_JSON="$(graph_app_by_appid "$API_APP_ID")"
[ -n "$SPA_APP_ID" ]          && APP_SPA_JSON="$(graph_app_by_appid "$SPA_APP_ID")"
[ -n "$CONFIDENTIAL_APP_ID" ] && APP_CONF_JSON="$(graph_app_by_appid "$CONFIDENTIAL_APP_ID")"

api_obj_id()  { printf '%s' "$APP_API_JSON"  | jq -r '.id // empty' 2>/dev/null; }
spa_obj_id()  { printf '%s' "$APP_SPA_JSON"  | jq -r '.id // empty' 2>/dev/null; }
conf_obj_id() { printf '%s' "$APP_CONF_JSON" | jq -r '.id // empty' 2>/dev/null; }

# ===========================================================================
# SECTION 1 — App registration & credential hygiene
# ===========================================================================
section_1() {
  section 1 "App registration & credential hygiene"

  # --- SPA platform rules ---
  if [ -n "$APP_SPA_JSON" ] && [ -z "$(graph_err_code "$APP_SPA_JSON")" ]; then
    local spa web pub badspa
    spa="$(printf '%s' "$APP_SPA_JSON" | jq -r '[.spa.redirectUris[]?] | @json')"
    web="$(printf '%s' "$APP_SPA_JSON" | jq -r '[.web.redirectUris[]?] | @json')"
    pub="$(printf '%s' "$APP_SPA_JSON" | jq -r '[.publicClient.redirectUris[]?] | @json')"

    # spa-redirect-https-no-wildcard
    badspa="$(printf '%s' "$APP_SPA_JSON" | jq -r '
      [.spa.redirectUris[]? | select((startswith("https://")|not) and (test("^http://(localhost|127\\.0\\.0\\.1)")|not))] // []
      | (map(select(test("\\*") or startswith("urn:"))) + .) | unique | join(",")')"
    if [ -n "$(printf '%s' "$spa" | jq -r 'if length>0 then "y" else "" end')" ] && [ -z "$badspa" ]; then
      pass H spa-redirect-https-no-wildcard "SPA redirect URIs are https, no wildcard"
    elif [ -n "$badspa" ]; then
      fail H spa-redirect-https-no-wildcard "SPA redirect URIs all https, no wildcard" "non-conforming: $badspa" "use exact https URIs only"
    else
      skip H spa-redirect-https-no-wildcard "SPA redirect URIs all https, no wildcard" "no spa redirect URIs declared"
    fi

    # spa-uris-under-spa-platform
    if [ "$web" = "[]" ] && [ "$pub" = "[]" ]; then
      pass H spa-uris-under-spa-platform "Browser URIs live under the spa platform"
    else
      fail H spa-uris-under-spa-platform "Browser URIs under spa platform only" "URIs also present on web/publicClient platform" "move browser URIs to the spa platform"
    fi

    # spa-no-implicit-access-token / spa-no-implicit-id-token
    local iat iid
    iat="$(jbool "$APP_SPA_JSON" '.web.implicitGrantSettings.enableAccessTokenIssuance')"
    iid="$(jbool "$APP_SPA_JSON" '.web.implicitGrantSettings.enableIdTokenIssuance')"
    if [ "$iat" = "false" ] || [ "$iat" = "null" ]; then
      pass H spa-no-implicit-access-token "Implicit access-token issuance disabled"
    else
      fail H spa-no-implicit-access-token "Implicit access-token issuance disabled" "enableAccessTokenIssuance=true" "disable implicit; use PKCE"
    fi
    if [ "$iid" = "false" ] || [ "$iid" = "null" ]; then
      pass H spa-no-implicit-id-token "Implicit id-token issuance disabled"
    else
      fail H spa-no-implicit-id-token "Implicit id-token issuance disabled" "enableIdTokenIssuance=true" "disable implicit; use PKCE"
    fi

    # spa-no-credentials
    local spw spk
    spw="$(printf '%s' "$APP_SPA_JSON" | jq -r '(.passwordCredentials|length)')"
    spk="$(printf '%s' "$APP_SPA_JSON" | jq -r '(.keyCredentials|length)')"
    if [ "$spw" = "0" ] && [ "$spk" = "0" ]; then
      pass H spa-no-credentials "Public SPA client has no credentials"
    else
      fail H spa-no-credentials "Public SPA client has no credentials" "found $spw password + $spk key credentials" "delete creds from public client"
    fi
  else
    for r in spa-redirect-https-no-wildcard spa-uris-under-spa-platform spa-no-implicit-access-token spa-no-implicit-id-token spa-no-credentials; do
      skip H "$r" "SPA platform rule" "SPA app not resolvable (appId missing or Graph error)"
    done
  fi

  # --- confidential platform rules ---
  if [ -n "$APP_CONF_JSON" ] && [ -z "$(graph_err_code "$APP_CONF_JSON")" ]; then
    local cweb badweb cpw cpk cfic
    cweb="$(printf '%s' "$APP_CONF_JSON" | jq -r '[.web.redirectUris[]?] | @json')"
    badweb="$(printf '%s' "$APP_CONF_JSON" | jq -r '
      [.web.redirectUris[]? | select((startswith("https://")|not) and (test("^http://(localhost|127\\.0\\.0\\.1)")|not) or test("\\*"))] | unique | join(",")')"
    if [ "$cweb" != "[]" ] && [ -z "$badweb" ]; then
      pass H web-redirect-https-no-wildcard "Confidential web redirect URIs https, no wildcard"
    elif [ -n "$badweb" ]; then
      fail H web-redirect-https-no-wildcard "Confidential web redirect URIs https, no wildcard" "non-conforming: $badweb" "use exact https URIs only"
    else
      skip H web-redirect-https-no-wildcard "Confidential web redirect URIs https, no wildcard" "no web redirect URIs declared"
    fi

    cpw="$(printf '%s' "$APP_CONF_JSON" | jq -r '(.passwordCredentials|length)')"
    cpk="$(printf '%s' "$APP_CONF_JSON" | jq -r '(.keyCredentials|length)')"
    cfic="0"
    if [ -n "$(conf_obj_id)" ]; then
      local fj; fj="$(graph_get "$GRAPH_V1/applications/$(conf_obj_id)/federatedIdentityCredentials")"
      cfic="$(printf '%s' "$fj" | jq -r '(.value|length) // 0' 2>/dev/null || echo 0)"
    fi

    # confidential-prefer-cert-or-fic
    if { [ "$cpk" -gt 0 ] 2>/dev/null || [ "$cfic" -gt 0 ] 2>/dev/null; } && [ "$cpw" = "0" ]; then
      pass H confidential-prefer-cert-or-fic "Confidential client uses cert/FIC, no secret"
    else
      fail H confidential-prefer-cert-or-fic "Confidential client uses cert/FIC, no secret" "passwordCredentials=$cpw key=$cpk fic=$cfic" "replace client secret with a certificate or federated identity credential"
    fi

    # secret-bounded-expiry (M): all future and lifetime <=180d
    local secrep
    secrep="$(PYJSON="$APP_CONF_JSON" python3 -c '
import os, json, datetime, re
def pdt(s):
    s=s.strip().replace("Z","")
    m=re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?",s)
    base=m.group(1); frac=(m.group(2) or "")[:7]
    return datetime.datetime.fromisoformat(base+frac).replace(tzinfo=datetime.timezone.utc)
obj=json.loads(os.environ["PYJSON"])
creds=obj.get("passwordCredentials") or []
if not creds:
    print("SKIP|no client secrets"); raise SystemExit
now=datetime.datetime.now(datetime.timezone.utc)
bad=[]
for c in creds:
    try:
        end=pdt(c["endDateTime"]); start=pdt(c["startDateTime"])
    except Exception:
        bad.append("unparseable"); continue
    if end<now: bad.append("expired")
    elif (end-start).days>180: bad.append("lifetime %dd>180d"%(end-start).days)
print(("FAIL|"+", ".join(bad)) if bad else "PASS|")
')"
    case "$secrep" in
      PASS*) pass M secret-bounded-expiry "Client secrets future-dated and <=180d lifetime" ;;
      SKIP*) skip M secret-bounded-expiry "Client secret expiry bounded" "${secrep#SKIP|}" ;;
      *)     fail M secret-bounded-expiry "Client secrets future-dated and <=180d lifetime" "${secrep#FAIL|}" "reissue with <=180d lifetime, rotate via Key Vault" ;;
    esac
  else
    for r in web-redirect-https-no-wildcard confidential-prefer-cert-or-fic secret-bounded-expiry; do
      skip H "$r" "Confidential client rule" "confidential app not resolvable"
    done
  fi

  # --- per-app rules over all resolvable apps (cert expiry, expired creds, count, owners, lock, audience, fallback) ---
  # Build a list "label|json" newline-separated.
  local apps=""
  [ -n "$APP_API_JSON" ]  && [ -z "$(graph_err_code "$APP_API_JSON")" ]  && apps="${apps}api"$'\t'"$(api_obj_id)"$'\n'
  [ -n "$APP_SPA_JSON" ]  && [ -z "$(graph_err_code "$APP_SPA_JSON")" ]  && apps="${apps}spa"$'\t'"$(spa_obj_id)"$'\n'
  [ -n "$APP_CONF_JSON" ] && [ -z "$(graph_err_code "$APP_CONF_JSON")" ] && apps="${apps}confidential"$'\t'"$(conf_obj_id)"$'\n'

  # cert-bounded-expiry (L) — confidential
  if [ -n "$APP_CONF_JSON" ] && [ -z "$(graph_err_code "$APP_CONF_JSON")" ]; then
    local certrep
    certrep="$(PYJSON="$APP_CONF_JSON" python3 -c '
import os,json,datetime,re
def pdt(s):
    s=s.strip().replace("Z","")
    m=re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?",s)
    return datetime.datetime.fromisoformat(m.group(1)+(m.group(2) or "")[:7]).replace(tzinfo=datetime.timezone.utc)
o=json.loads(os.environ["PYJSON"]); keys=o.get("keyCredentials") or []
if not keys: print("SKIP|no certificate credentials"); raise SystemExit
now=datetime.datetime.now(datetime.timezone.utc); bad=[]
for k in keys:
    end=pdt(k["endDateTime"]); start=pdt(k["startDateTime"])
    if end<now: bad.append("expired")
    elif (end-start).days>365: bad.append("lifetime>365d")
print(("FAIL|"+", ".join(bad)) if bad else "PASS|")
')"
    case "$certrep" in
      PASS*) pass L cert-bounded-expiry "Certificates future-dated and <=365d lifetime" ;;
      SKIP*) skip L cert-bounded-expiry "Certificate expiry bounded" "${certrep#SKIP|}" ;;
      *)     fail L cert-bounded-expiry "Certificates future-dated and <=365d lifetime" "${certrep#FAIL|}" "rotate certs to <=1y lifetime" ;;
    esac
  else
    skip L cert-bounded-expiry "Certificate expiry bounded" "confidential app not resolvable"
  fi

  # no-expired-credentials (M, any) + credential-count-minimal (L, confidential)
  local anyexpired=""
  printf '%s' "$apps" | while IFS=$'\t' read -r lbl oid; do : ; done  # noop to keep set -e happy
  # iterate without subshell to preserve flags
  local oldifs="$IFS"; IFS=$'\n'
  for line in $apps; do
    [ -n "$line" ] || continue
    local lbl oid j ne
    lbl="$(printf '%s' "$line" | cut -f1)"
    oid="$(printf '%s' "$line" | cut -f2)"
    case "$lbl" in api) j="$APP_API_JSON" ;; spa) j="$APP_SPA_JSON" ;; *) j="$APP_CONF_JSON" ;; esac
    ne="$(PYJSON="$j" python3 -c '
import os,json,datetime,re
def pdt(s):
    s=s.strip().replace("Z","")
    m=re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?",s)
    return datetime.datetime.fromisoformat(m.group(1)+(m.group(2) or "")[:7]).replace(tzinfo=datetime.timezone.utc)
o=json.loads(os.environ["PYJSON"]); now=datetime.datetime.now(datetime.timezone.utc); n=0
for arr in ("passwordCredentials","keyCredentials"):
    for c in o.get(arr) or []:
        try:
            if pdt(c["endDateTime"])<now: n+=1
        except Exception: pass
print(n)
')"
    [ "$ne" -gt 0 ] 2>/dev/null && anyexpired="${anyexpired}${lbl}:${ne} "
  done
  IFS="$oldifs"
  if [ -z "$anyexpired" ]; then
    pass M no-expired-credentials "No expired credentials on any app"
  else
    fail M no-expired-credentials "No expired credentials on any app" "expired: $anyexpired" "delete expired credentials"
  fi

  if [ -n "$APP_CONF_JSON" ] && [ -z "$(graph_err_code "$APP_CONF_JSON")" ]; then
    local cnt
    cnt="$(printf '%s' "$APP_CONF_JSON" | jq -r '((.passwordCredentials|length)+(.keyCredentials|length))')"
    if [ "$cnt" -le 2 ] 2>/dev/null; then
      pass L credential-count-minimal "Confidential credential count <=2"
    else
      fail L credential-count-minimal "Confidential credential count <=2" "found $cnt credentials" "trim to active + one rollover"
    fi
  else
    skip L credential-count-minimal "Confidential credential count <=2" "confidential app not resolvable"
  fi

  # api-requested-access-token-v2 (H)
  if [ -n "$APP_API_JSON" ] && [ -z "$(graph_err_code "$APP_API_JSON")" ]; then
    local ratv
    ratv="$(printf '%s' "$APP_API_JSON" | jq -r '.api.requestedAccessTokenVersion // "null"')"
    if [ "$ratv" = "2" ]; then
      pass H api-requested-access-token-v2 "API requestedAccessTokenVersion == 2"
    else
      fail H api-requested-access-token-v2 "API requestedAccessTokenVersion == 2" "value is $ratv" "set requestedAccessTokenVersion to 2"
    fi
    # api-identifier-uri-form (M)
    local uriok
    uriok="$(printf '%s' "$APP_API_JSON" | jq -r --arg app "$API_APP_ID" '
      (.identifierUris // []) as $u |
      if ($u|length)==0 then "EMPTY"
      elif ($u|any(test("\\*"))) then "WILDCARD"
      elif ($u|any(endswith("/"))) then "TRAILING_SLASH"
      elif ($u|any(.=="api://"+$app)) then "OK"
      else "NONSTD" end')"
    case "$uriok" in
      OK)            pass M api-identifier-uri-form "App ID URI is api://<appId>" ;;
      EMPTY)         fail M api-identifier-uri-form "App ID URI is api://<appId>" "identifierUris empty" "set App ID URI to api://$API_APP_ID" ;;
      WILDCARD)      fail M api-identifier-uri-form "App ID URI is api://<appId>" "contains wildcard" "set App ID URI to api://$API_APP_ID" ;;
      TRAILING_SLASH) fail M api-identifier-uri-form "App ID URI is api://<appId>" "trailing slash present" "set App ID URI to api://$API_APP_ID" ;;
      *)             warn M api-identifier-uri-form "App ID URI is api://<appId>" "non-standard App ID URI (not api://<appId>)" "prefer api://$API_APP_ID" ;;
    esac
  else
    skip H api-requested-access-token-v2 "API requestedAccessTokenVersion == 2" "API app not resolvable"
    skip M api-identifier-uri-form "App ID URI is api://<appId>" "API app not resolvable"
  fi

  # sign-in-audience-single-tenant (M, any) — over all apps
  local audbad=""
  IFS=$'\n'
  for line in $apps; do
    [ -n "$line" ] || continue
    local lbl j aud
    lbl="$(printf '%s' "$line" | cut -f1)"
    case "$lbl" in api) j="$APP_API_JSON" ;; spa) j="$APP_SPA_JSON" ;; *) j="$APP_CONF_JSON" ;; esac
    aud="$(printf '%s' "$j" | jq -r '.signInAudience // "null"')"
    [ "$aud" = "AzureADMyOrg" ] || audbad="${audbad}${lbl}:${aud} "
  done
  IFS="$oldifs"
  if [ -z "$audbad" ]; then
    pass M sign-in-audience-single-tenant "All apps signInAudience == AzureADMyOrg"
  else
    warn M sign-in-audience-single-tenant "All apps signInAudience == AzureADMyOrg" "non-single-tenant: $audbad" "set AzureADMyOrg unless multitenant is justified"
  fi

  # app-has-owner (H, any) + app-instance-lock-enabled (M) over all apps
  local noowner="" nolock=""
  IFS=$'\n'
  for line in $apps; do
    [ -n "$line" ] || continue
    local lbl oid j ocount
    lbl="$(printf '%s' "$line" | cut -f1)"
    oid="$(printf '%s' "$line" | cut -f2)"
    case "$lbl" in api) j="$APP_API_JSON" ;; spa) j="$APP_SPA_JSON" ;; *) j="$APP_CONF_JSON" ;; esac
    ocount="$(graph_get "$GRAPH_V1/applications/$oid/owners?\$select=id" | jq -r '(.value|length) // 0' 2>/dev/null || echo 0)"
    [ "$ocount" -ge 1 ] 2>/dev/null || noowner="${noowner}${lbl} "
    local le ap
    le="$(printf '%s' "$j" | jq -r '.servicePrincipalLockConfiguration.isEnabled // "null"')"
    ap="$(printf '%s' "$j" | jq -r '.servicePrincipalLockConfiguration.allProperties // "null"')"
    { [ "$le" = "true" ] && [ "$ap" = "true" ]; } || nolock="${nolock}${lbl} "
  done
  IFS="$oldifs"
  if [ -z "$noowner" ]; then
    pass H app-has-owner "Every app registration has >=1 owner"
  else
    fail H app-has-owner "Every app registration has >=1 owner" "no owner: $noowner" "assign a named owner to each app"
  fi
  if [ -z "$nolock" ]; then
    pass M app-instance-lock-enabled "App instance property lock enabled"
  else
    fail M app-instance-lock-enabled "App instance property lock enabled" "lock off: $nolock" "enable app instance property lock (allProperties)"
  fi

  # confidential-not-fallback-public (M)
  if [ -n "$APP_CONF_JSON" ] && [ -z "$(graph_err_code "$APP_CONF_JSON")" ]; then
    local fb
    fb="$(printf '%s' "$APP_CONF_JSON" | jq -r '.isFallbackPublicClient // "null"')"
    if [ "$fb" = "false" ] || [ "$fb" = "null" ]; then
      pass M confidential-not-fallback-public "Confidential client is not a fallback public client"
    else
      fail M confidential-not-fallback-public "Confidential client is not a fallback public client" "isFallbackPublicClient=true" "set 'allow public client flows' to No"
    fi
  else
    skip M confidential-not-fallback-public "Confidential client is not a fallback public client" "confidential app not resolvable"
  fi

  # no-stray-platform-uris (L) — only the app type's platform holds URIs
  local stray=""
  if [ -n "$APP_SPA_JSON" ] && [ -z "$(graph_err_code "$APP_SPA_JSON")" ]; then
    local w p
    w="$(printf '%s' "$APP_SPA_JSON" | jq -r '(.web.redirectUris|length)+( .publicClient.redirectUris|length)')"
    [ "$w" = "0" ] || stray="${stray}spa-has-web/public "
  fi
  if [ -n "$APP_CONF_JSON" ] && [ -z "$(graph_err_code "$APP_CONF_JSON")" ]; then
    local sp pc
    sp="$(printf '%s' "$APP_CONF_JSON" | jq -r '(.spa.redirectUris|length)')"
    pc="$(printf '%s' "$APP_CONF_JSON" | jq -r '(.publicClient.redirectUris|length)')"
    { [ "$sp" = "0" ] && [ "$pc" = "0" ]; } || stray="${stray}conf-has-spa/public "
  fi
  if [ -z "$stray" ]; then
    pass L no-stray-platform-uris "Redirect URIs live only on each app's own platform"
  else
    fail L no-stray-platform-uris "Redirect URIs live only on each app's own platform" "stray: $stray" "remove URIs on unused platforms"
  fi
}

# ===========================================================================
# SECTION 2 — Scopes, permissions & consent
# ===========================================================================
section_2() {
  section 2 "Scopes, permissions & consent"

  local api_ok=0
  [ -n "$APP_API_JSON" ] && [ -z "$(graph_err_code "$APP_API_JSON")" ] && api_ok=1

  if [ "$api_ok" = "1" ]; then
    # api-custom-scope-exists (H)
    local hasScope
    hasScope="$(printf '%s' "$APP_API_JSON" | jq -r --arg s "$API_SCOPE" '[.api.oauth2PermissionScopes[]? | select(.value==$s and .isEnabled==true)] | length')"
    if [ "$hasScope" -ge 1 ] 2>/dev/null; then
      pass H api-custom-scope-exists "API exposes enabled scope $API_SCOPE"
    else
      fail H api-custom-scope-exists "API exposes enabled scope $API_SCOPE" "no enabled scope named $API_SCOPE" "add the delegated scope $API_SCOPE"
    fi
    # api-scope-type-user (M)
    local stype
    stype="$(printf '%s' "$APP_API_JSON" | jq -r --arg s "$API_SCOPE" 'first(.api.oauth2PermissionScopes[]? | select(.value==$s) | .type) // "null"')"
    if [ "$stype" = "User" ]; then
      pass M api-scope-type-user "$API_SCOPE is user-consentable (type User)"
    elif [ "$stype" = "null" ]; then
      skip M api-scope-type-user "$API_SCOPE is user-consentable (type User)" "scope $API_SCOPE not found"
    else
      warn M api-scope-type-user "$API_SCOPE is user-consentable (type User)" "type is $stype (Admin)" "set consent to 'Admins and users'"
    fi
    # api-scope-naming (L)
    local sname
    sname="$(printf '%s' "$APP_API_JSON" | jq -r --arg s "$API_SCOPE" '
      if ($s|test("^[A-Za-z][A-Za-z0-9._-]{0,119}$")) then "OK" else "BAD" end')"
    if [ "$sname" = "OK" ]; then
      pass L api-scope-naming "Scope value is well-formed and granular"
    else
      warn L api-scope-naming "Scope value is well-formed and granular" "scope $API_SCOPE not Resource.Operation form" "rename to granular Resource.Operation"
    fi
    # api-no-unused-app-roles (M)
    local approles
    approles="$(printf '%s' "$APP_API_JSON" | jq -r '[.appRoles[]? | select(.isEnabled==true and (.allowedMemberTypes|index("Application")))] | length')"
    if [ "$approles" = "0" ]; then
      pass M api-no-unused-app-roles "No unused application app-roles on the API"
    else
      warn M api-no-unused-app-roles "No unused application app-roles on the API" "$approles enabled Application app-role(s) present" "remove unused app roles unless a daemon needs them"
    fi
    # api-assignment-required-for-roles (M) — only relevant if app roles exposed
    if [ "$approles" = "0" ]; then
      skip M api-assignment-required-for-roles "API SP assignment required for app roles" "no app roles exposed"
    elif [ -n "$API_SP_ID" ]; then
      local areq
      areq="$(printf '%s' "$(graph_get "$GRAPH_V1/servicePrincipals/$API_SP_ID")" | jq -r '.appRoleAssignmentRequired // "null"')"
      if [ "$areq" = "true" ]; then
        pass M api-assignment-required-for-roles "API SP requires assignment for app roles"
      else
        fail M api-assignment-required-for-roles "API SP requires assignment for app roles" "appRoleAssignmentRequired=$areq" "set 'assignment required' = Yes"
      fi
    else
      skip M api-assignment-required-for-roles "API SP assignment required for app roles" "api spId unknown"
    fi
    # api-preauthorize-trusted-clients (M) + api-preauth-ids-valid (L)
    local preauth scopeId
    scopeId="$(printf '%s' "$APP_API_JSON" | jq -r --arg s "$API_SCOPE" 'first(.api.oauth2PermissionScopes[]? | select(.value==$s) | .id) // empty')"
    preauth="$(printf '%s' "$APP_API_JSON" | jq -r '[.api.preAuthorizedApplications[]?.appId]|@json')"
    local clients=""
    [ -n "$SPA_APP_ID" ] && clients="$clients $SPA_APP_ID"
    [ -n "$CONFIDENTIAL_APP_ID" ] && clients="$clients $CONFIDENTIAL_APP_ID"
    local missingpa=""
    for c in $clients; do
      printf '%s' "$preauth" | jq -e --arg c "$c" 'index($c)' >/dev/null 2>&1 || missingpa="${missingpa}${c} "
    done
    if [ "$preauth" = "[]" ]; then
      warn M api-preauthorize-trusted-clients "First-party clients pre-authorized on the API" "no preAuthorizedApplications configured" "pre-authorize first-party clients for $API_SCOPE (suppresses consent prompt)"
    elif [ -n "$missingpa" ]; then
      warn M api-preauthorize-trusted-clients "First-party clients pre-authorized on the API" "not pre-authorized: $missingpa" "pre-authorize each first-party client"
    else
      pass M api-preauthorize-trusted-clients "First-party clients pre-authorized on the API"
    fi
    # api-preauth-ids-valid (L)
    if [ "$preauth" = "[]" ]; then
      skip L api-preauth-ids-valid "Pre-auth permission ids map to enabled scopes" "no preAuthorizedApplications"
    else
      local pavalid
      pavalid="$(printf '%s' "$APP_API_JSON" | jq -r --arg sid "$scopeId" '
        [.api.preAuthorizedApplications[]? | .delegatedPermissionIds[]? | select(. != $sid)] | length')"
      if [ "$pavalid" = "0" ]; then
        pass L api-preauth-ids-valid "Pre-auth permission ids map to enabled scopes"
      else
        warn L api-preauth-ids-valid "Pre-auth permission ids map to enabled scopes" "$pavalid pre-auth id(s) do not match the $API_SCOPE scope id" "remove stale pre-auth entries"
      fi
    fi
  else
    for r in api-custom-scope-exists api-scope-type-user api-scope-naming api-no-unused-app-roles api-assignment-required-for-roles api-preauthorize-trusted-clients api-preauth-ids-valid; do
      skip M "$r" "API scope rule" "API app not resolvable"
    done
  fi

  # --- client-side resourceAccess rules (spa + confidential) ---
  local scopeId
  scopeId="$(printf '%s' "$APP_API_JSON" | jq -r --arg s "$API_SCOPE" 'first(.api.oauth2PermissionScopes[]? | select(.value==$s) | .id) // empty' 2>/dev/null)"

  # Evaluate each client app against: requests only Inform.Send (Scope, not Role),
  # minimal Graph perms, no Graph app-roles, no mixed types.
  eval_client_rra() { # <label> <json>
    local lbl="$1" j="$2"
    local apiAccess apiTypes graphRoles
    apiAccess="$(printf '%s' "$j" | jq -r --arg api "$API_APP_ID" '[.requiredResourceAccess[]? | select(.resourceAppId==$api) | .resourceAccess[]?]|@json')"
    apiTypes="$(printf '%s' "$j" | jq -r --arg api "$API_APP_ID" '[.requiredResourceAccess[]? | select(.resourceAppId==$api) | .resourceAccess[]?.type]|unique|join(",")')"
    graphRoles="$(printf '%s' "$j" | jq -r --arg g "$GRAPH_APPID" '[.requiredResourceAccess[]? | select(.resourceAppId==$g) | .resourceAccess[]? | select(.type=="Role")]|length')"
    CLIENT_API_ACCESS="$apiAccess"; CLIENT_API_TYPES="$apiTypes"
    CLIENT_GRAPH_ROLES="$graphRoles"
    CLIENT_ALL_TYPES="$(printf '%s' "$j" | jq -r '[.requiredResourceAccess[]?.resourceAccess[]?.type]|unique|join(",")')"
  }

  local bad_only="" bad_typescope="" bad_graphmin="" bad_graphrole="" bad_mixed=""
  for pair in "spa|$APP_SPA_JSON" "confidential|$APP_CONF_JSON"; do
    local lbl j
    lbl="${pair%%|*}"; j="${pair#*|}"
    [ -n "$j" ] && [ -z "$(graph_err_code "$j")" ] || continue
    eval_client_rra "$lbl" "$j"
    # client-requests-only-inform-send: api block == exactly [Inform.Send scope]
    local onlysend
    onlysend="$(printf '%s' "$CLIENT_API_ACCESS" | jq -r --arg sid "$scopeId" '
      if length==1 and .[0].type=="Scope" and (.[0].id==$sid or $sid=="") then "OK" else "BAD" end')"
    [ "$onlysend" = "OK" ] || bad_only="${bad_only}${lbl} "
    # client-resourceaccess-type-scope: api types must be Scope only
    if [ -n "$CLIENT_API_TYPES" ] && [ "$CLIENT_API_TYPES" != "Scope" ]; then
      bad_typescope="${bad_typescope}${lbl}(${CLIENT_API_TYPES}) "
    fi
    # client-minimal-graph-permissions: graph scopes subset of basics
    local graphextra
    graphextra="$(printf '%s' "$j" | jq -r --arg g "$GRAPH_APPID" '
      ["e1fe6dd8-ba31-4d61-89e7-88639da4683d","14dad69e-099b-42c9-810b-d002981feec1","37f7f235-527c-4136-accd-4a02d197296e","7427e0e9-2fba-42fe-b0c0-848c9e6a8182"] as $ok
      | [.requiredResourceAccess[]? | select(.resourceAppId==$g) | .resourceAccess[]? | select(.type=="Scope") | select(.id as $i | ($ok|index($i))|not)] | length')"
    [ "$graphextra" = "0" ] || bad_graphmin="${bad_graphmin}${lbl}:${graphextra} "
    # client-no-graph-app-roles
    [ "$CLIENT_GRAPH_ROLES" = "0" ] || bad_graphrole="${bad_graphrole}${lbl}:${CLIENT_GRAPH_ROLES} "
    # client-no-mixed-permission-types
    case "$CLIENT_ALL_TYPES" in *Scope*Role*|*Role*Scope*) bad_mixed="${bad_mixed}${lbl} " ;; esac
  done

  if [ -z "$bad_only" ]; then
    pass H client-requests-only-inform-send "Each client requests exactly $API_SCOPE (delegated)"
  else
    fail H client-requests-only-inform-send "Each client requests exactly $API_SCOPE (delegated)" "non-minimal API access: $bad_only" "request only $API_SCOPE (Scope) from the API"
  fi
  if [ -z "$bad_typescope" ]; then
    pass H client-resourceaccess-type-scope "Client->API access is delegated (Scope), never Role"
  else
    fail H client-resourceaccess-type-scope "Client->API access is delegated (Scope), never Role" "Role access found: $bad_typescope" "use delegated (Scope), not application (Role) permission"
  fi
  if [ -z "$bad_graphmin" ]; then
    pass H client-minimal-graph-permissions "Client Graph scopes within {openid,profile,offline_access,User.Read}"
  else
    fail H client-minimal-graph-permissions "Client Graph scopes minimal" "extra Graph scopes: $bad_graphmin" "trim Graph delegated permissions to sign-in basics"
  fi
  if [ -z "$bad_graphrole" ]; then
    pass H client-no-graph-app-roles "Clients declare no Graph application (Role) permissions"
  else
    fail H client-no-graph-app-roles "Clients declare no Graph application (Role) permissions" "Graph Roles: $bad_graphrole" "delete Graph app permissions from clients"
  fi
  if [ -z "$bad_mixed" ]; then
    pass M client-no-mixed-permission-types "No client mixes Scope and Role permissions"
  else
    fail M client-no-mixed-permission-types "No client mixes Scope and Role permissions" "mixed: $bad_mixed" "split daemon perms into their own registration"
  fi

  # spa-no-application-permissions (H) — SPA has no Role resourceAccess and no appRoleAssignments
  if [ -n "$APP_SPA_JSON" ] && [ -z "$(graph_err_code "$APP_SPA_JSON")" ]; then
    local spaRoles spaAssign
    spaRoles="$(printf '%s' "$APP_SPA_JSON" | jq -r '[.requiredResourceAccess[]?.resourceAccess[]? | select(.type=="Role")]|length')"
    spaAssign="0"
    [ -n "$SPA_SP_ID" ] && spaAssign="$(graph_get "$GRAPH_V1/servicePrincipals/$SPA_SP_ID/appRoleAssignments" | jq -r '(.value|length)//0' 2>/dev/null || echo 0)"
    if [ "$spaRoles" = "0" ] && [ "$spaAssign" = "0" ]; then
      pass H spa-no-application-permissions "SPA holds no application permissions (delegated only)"
    else
      fail H spa-no-application-permissions "SPA holds no application permissions" "Role access=$spaRoles, appRoleAssignments=$spaAssign" "use delegated permissions only"
    fi
  else
    skip H spa-no-application-permissions "SPA holds no application permissions" "SPA app not resolvable"
  fi

  # client-no-high-priv-graph-granted (H) — SP appRoleAssignments to Graph high-priv roles
  # High-priv Graph app role ids (Directory.ReadWrite.All, Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, RoleManagement.ReadWrite.Directory)
  local HIGH_PRIV='19dbc75e-c2e2-444c-a770-ec69d8559fc7 1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9 06b708a9-e830-4db3-a914-8e69da51d44f 9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8 62a82d76-70ea-41e2-9197-370581804d09'
  local hpbad=""
  for pair in "spa|$SPA_SP_ID" "confidential|$CONF_SP_ID"; do
    local lbl spid
    lbl="${pair%%|*}"; spid="${pair#*|}"
    [ -n "$spid" ] || continue
    local assigns
    assigns="$(graph_get "$GRAPH_V1/servicePrincipals/$spid/appRoleAssignments" | jq -r --arg g "$GRAPH_APPID" '[.value[]?.appRoleId]|@json' 2>/dev/null || echo '[]')"
    for rid in $HIGH_PRIV; do
      printf '%s' "$assigns" | jq -e --arg r "$rid" 'index($r)' >/dev/null 2>&1 && hpbad="${hpbad}${lbl}:${rid} "
    done
  done
  if [ -z "$hpbad" ]; then
    pass H client-no-high-priv-graph-granted "No client SP holds a high-privilege Graph app-role grant"
  else
    fail H client-no-high-priv-graph-granted "No client SP holds a high-privilege Graph app-role grant" "high-priv grants: $hpbad" "revoke the high-privilege Graph app-role assignment"
  fi

  # --- consent grants ---
  # consent-admin-allprincipals (H): one AllPrincipals grant client->API incl. Inform.Send
  local grant_bad="" grant_overbroad="" graph_stray=""
  for pair in "spa|$SPA_SP_ID" "confidential|$CONF_SP_ID"; do
    local lbl spid
    lbl="${pair%%|*}"; spid="${pair#*|}"
    [ -n "$spid" ] || { grant_bad="${grant_bad}${lbl}(no-sp) "; continue; }
    local grants
    grants="$(graph_get "$GRAPH_V1/servicePrincipals/$spid/oauth2PermissionGrants")"
    # client->API grant present, AllPrincipals, scope contains Inform.Send
    local hasapi
    hasapi="$(printf '%s' "$grants" | jq -r --arg rid "$API_SP_ID" --arg s "$API_SCOPE" '
      [.value[]? | select(.resourceId==$rid) | select(.consentType=="AllPrincipals") | select((.scope|split(" "))|index($s))] | length')"
    [ "$hasapi" -ge 1 ] 2>/dev/null || grant_bad="${grant_bad}${lbl} "
    # consent-grant-not-overbroad: client->API grant scopes subset of declared {Inform.Send}
    local over
    over="$(printf '%s' "$grants" | jq -r --arg rid "$API_SP_ID" --arg s "$API_SCOPE" '
      [.value[]? | select(.resourceId==$rid) | .scope | split(" ")[] | select(.!="" and .!=$s)] | length')"
    [ "$over" = "0" ] || grant_overbroad="${grant_overbroad}${lbl}:${over} "
    # consent-no-stray-graph-grants: Graph AllPrincipals grant scopes subset of basics
    local gstray
    gstray="$(printf '%s' "$grants" | jq -r --arg g "$GRAPH_APPID" '
      ["openid","profile","offline_access","email","User.Read"] as $ok
      | [.value[]? | select(.consentType=="AllPrincipals")
         | .scope | split(" ")[] | select(.!="")] as $all
      | [ $all[] | select(["openid","profile","offline_access","email","User.Read","Inform.Send"]|index(.)|not) ] | length' 2>/dev/null || echo 0)"
    [ "$gstray" = "0" ] 2>/dev/null || graph_stray="${graph_stray}${lbl}:${gstray} "
  done
  if [ -z "$grant_bad" ]; then
    pass H consent-admin-allprincipals "Admin (AllPrincipals) consent granted client->API for $API_SCOPE"
  else
    fail H consent-admin-allprincipals "Admin consent granted client->API for $API_SCOPE" "missing/!AllPrincipals: $grant_bad" "grant admin consent (AllPrincipals) for $API_SCOPE"
  fi
  if [ -z "$grant_overbroad" ]; then
    pass M consent-grant-not-overbroad "Consent grants are least-privilege (no extra scopes)"
  else
    warn M consent-grant-not-overbroad "Consent grants are least-privilege" "extra granted scopes: $grant_overbroad" "re-create least-privilege grant"
  fi
  if [ -z "$graph_stray" ]; then
    pass M consent-no-stray-graph-grants "AllPrincipals grants limited to sign-in basics"
  else
    warn M consent-no-stray-graph-grants "AllPrincipals grants limited to sign-in basics" "stray non-basic scopes: $graph_stray" "reduce the Graph admin-consent grant"
  fi
}

# ===========================================================================
# SECTION 3 — External-tenant security & user flow
# ===========================================================================
section_3() {
  section 3 "External-tenant security & user flow"

  # --- Conditional Access policies ---
  local ca caerr
  ca="$(graph_get "$GRAPH_V1/identity/conditionalAccess/policies")"
  caerr="$(graph_err_code "$ca")"
  if [ -n "$caerr" ]; then
    for r in ca-mfa-policy-enabled ca-mfa-not-report-only ca-mfa-breakglass-excluded; do
      skip H "$r" "Conditional Access MFA policy" "CA policies not readable ($caerr)"
    done
  else
    local capolicies
    capolicies="$(printf '%s' "$ca" | jq -r '[.value[]? | select((.grantControls.builtInControls//[])|index("mfa"))]')"
    local mfacount
    mfacount="$(printf '%s' "$capolicies" | jq -r 'length')"
    if [ "$mfacount" = "0" ]; then
      fail H ca-mfa-policy-enabled "An enabled CA policy enforces MFA" "no CA policy with mfa control found" "create an enabled MFA CA policy targeting customers + apps"
      skip H ca-mfa-not-report-only "MFA CA policy is enforced (not report-only)" "no MFA policy exists"
      skip M ca-mfa-breakglass-excluded "MFA policy excludes a break-glass account" "no MFA policy exists"
    else
      local enabledmfa
      enabledmfa="$(printf '%s' "$capolicies" | jq -r '[.[] | select(.state=="enabled")] | length')"
      if [ "$enabledmfa" -ge 1 ] 2>/dev/null; then
        pass H ca-mfa-policy-enabled "An enabled CA policy enforces MFA"
        pass H ca-mfa-not-report-only "MFA CA policy is enforced (not report-only)"
      else
        fail H ca-mfa-policy-enabled "An enabled CA policy enforces MFA" "MFA policy exists but state != enabled" "enable the MFA CA policy"
        fail H ca-mfa-not-report-only "MFA CA policy is enforced (not report-only)" "MFA policy is report-only" "flip report-only -> enabled"
      fi
      local bgexcl
      bgexcl="$(printf '%s' "$capolicies" | jq -r '[.[] | select(((.conditions.users.excludeUsers//[])|length>0) or ((.conditions.users.excludeGroups//[])|length>0))]|length')"
      if [ "$bgexcl" -ge 1 ] 2>/dev/null; then
        pass M ca-mfa-breakglass-excluded "MFA policy excludes a break-glass account/group"
      else
        warn M ca-mfa-breakglass-excluded "MFA policy excludes a break-glass account/group" "no excluded user/group on the MFA policy" "exclude an emergency-access account"
      fi
    fi
  fi

  # --- user flow (beta) ---
  if [ -n "$USERFLOW_ID" ]; then
    local uf uferr
    uf="$(graph_get "$GRAPH_BETA/identity/authenticationEventsFlows/$USERFLOW_ID")"
    uferr="$(graph_err_code "$uf")"
    if [ -n "$uferr" ]; then
      for r in userflow-has-identity-provider userflow-first-factor-intended userflow-attribute-minimization userflow-linked-to-application; do
        skip H "$r" "User-flow rule" "user flow not readable ($uferr)"
      done
    else
      local idpcount idps
      idpcount="$(printf '%s' "$uf" | jq -r '[.onAuthenticationMethodLoadStart.identityProviders[]?]|length')"
      idps="$(printf '%s' "$uf" | jq -r '[.onAuthenticationMethodLoadStart.identityProviders[]?.displayName]|join(",")')"
      if [ "$idpcount" -ge 1 ] 2>/dev/null; then
        pass H userflow-has-identity-provider "User flow has >=1 identity provider"
      else
        fail H userflow-has-identity-provider "User flow has >=1 identity provider" "no identity providers on the flow" "add an IdP (e.g. Email OTP) to the flow"
      fi
      # userflow-first-factor-intended: only Email OTP
      local nonotp
      nonotp="$(printf '%s' "$uf" | jq -r '[.onAuthenticationMethodLoadStart.identityProviders[]? | select((.id // .displayName) | test("Email|OTP|OneTime"; "i")|not)]|length')"
      if [ "$idpcount" -ge 1 ] 2>/dev/null && [ "$nonotp" = "0" ]; then
        pass M userflow-first-factor-intended "First factor is the intended set (Email OTP only)"
      elif [ "$idpcount" = "0" ]; then
        skip M userflow-first-factor-intended "First factor is the intended set (Email OTP only)" "no IdPs on the flow"
      else
        warn M userflow-first-factor-intended "First factor is the intended set (Email OTP only)" "unexpected IdPs present ($idps)" "remove unused IdPs"
      fi
      # userflow-attribute-minimization: collected attrs subset of {email,displayName}
      local extra_attr
      extra_attr="$(printf '%s' "$uf" | jq -r '
        [.onAttributeCollection.attributes[]? | (.id // .displayName // "")
         | ascii_downcase
         | select(test("email|displayname|emailaddress")|not)] | length')"
      if [ "$extra_attr" = "0" ] || [ -z "$extra_attr" ]; then
        pass M userflow-attribute-minimization "Collected attributes minimal (email/displayName)"
      else
        warn M userflow-attribute-minimization "Collected attributes minimal" "$extra_attr attribute(s) beyond email/displayName collected" "trim collected attributes"
      fi
      # userflow-linked-to-application: includeApplications has prod appIds
      local linkedapps missinglink=""
      linkedapps="$(printf '%s' "$uf" | jq -r '[.conditions.applications.includeApplications[]?.appId // .conditions.applications.includeApplications[]?]|@json')"
      for c in $SPA_APP_ID $CONFIDENTIAL_APP_ID; do
        [ -n "$c" ] || continue
        printf '%s' "$linkedapps" | jq -e --arg c "$c" 'index($c)' >/dev/null 2>&1 || missinglink="${missinglink}${c} "
      done
      # FIELD NOTE: the Graph read of includeApplications is UNRELIABLE for External
      # ID user flows — it returns empty even when apps ARE linked. A *positive* read
      # (apps present) is trustworthy; an *empty/partial* read is a known false
      # negative, NOT proof of "not linked". So a negative read is WARN (verify in
      # portal), never FAIL. Likewise, the Graph association *write*
      # (.../includeApplications/$ref) fails with "no addressUrl for Microsoft.CPIM"
      # regardless of identity/CPIM-readiness — associate apps in the PORTAL, not Graph.
      if [ "$linkedapps" = "[]" ]; then
        warn H userflow-linked-to-application "User flow linked to the prod application(s)" "Graph read returned empty — this read is a KNOWN false-negative for External ID flows (returns empty even when linked). Verify authoritatively in the portal (user flow > Applications, or Run user flow)." "associate apps in the Entra portal (the Graph \$ref write fails with 'no addressUrl for Microsoft.CPIM'); a 'Failed' toast can be spurious — re-open the dialog to confirm the persisted state"
      elif [ -n "$missinglink" ]; then
        warn H userflow-linked-to-application "User flow linked to the prod application(s)" "Graph read shows missing: $missinglink — read may be lagging/false-negative; verify in portal" "add the missing app(s) via the portal, then confirm via the 'already linked' dialog (state read), not the operation-result toast"
      else
        pass H userflow-linked-to-application "User flow linked to the prod application(s)"
      fi
    fi
  else
    for r in userflow-has-identity-provider userflow-first-factor-intended userflow-attribute-minimization userflow-linked-to-application; do
      skip H "$r" "User-flow rule" "no userFlow.id in config"
    done
  fi

  # --- authentication methods policy (email OTP / sms) ---
  local emailm
  emailm="$(graph_get "$GRAPH_V1/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/email")"
  local emerr; emerr="$(graph_err_code "$emailm")"
  if [ -n "$emerr" ]; then
    skip H authpolicy-email-otp-enabled "Email OTP enabled for External ID" "auth-methods policy not readable ($emerr) — needs Policy.Read.All"
  else
    local est eext
    est="$(printf '%s' "$emailm" | jq -r '.state // "null"')"
    eext="$(printf '%s' "$emailm" | jq -r '.allowExternalIdToUseEmailOtp // "null"')"
    if [ "$est" = "enabled" ] && { [ "$eext" = "enabled" ] || [ "$eext" = "default" ]; }; then
      pass H authpolicy-email-otp-enabled "Email OTP enabled for External ID"
    else
      fail H authpolicy-email-otp-enabled "Email OTP enabled for External ID" "state=$est allowExternalIdToUseEmailOtp=$eext" "enable Email OTP for external users"
    fi
  fi
  local smsm
  smsm="$(graph_get "$GRAPH_V1/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/sms")"
  local smserr; smserr="$(graph_err_code "$smsm")"
  if [ -n "$smserr" ]; then
    skip M authpolicy-sms-not-unnecessary "SMS second factor disabled unless required" "auth-methods policy not readable ($smserr)"
  else
    local sst; sst="$(printf '%s' "$smsm" | jq -r '.state // "null"')"
    if [ "$sst" = "disabled" ] || [ "$sst" = "null" ]; then
      pass M authpolicy-sms-not-unnecessary "SMS second factor disabled (cost/SIM-swap)"
    else
      warn M authpolicy-sms-not-unnecessary "SMS second factor disabled unless required" "sms state=$sst" "disable SMS unless explicitly required"
    fi
  fi

  # --- authorization policy ---
  local az_pol azerr
  az_pol="$(graph_get "$GRAPH_V1/policies/authorizationPolicy")"
  azerr="$(graph_err_code "$az_pol")"
  if [ -n "$azerr" ]; then
    for r in authzpolicy-signup-intentional authzpolicy-guest-invite-restricted authzpolicy-no-risky-app-consent; do
      skip M "$r" "Authorization policy rule" "authorizationPolicy not readable ($azerr)"
    done
  else
    local joinflag invites risky createapps
    joinflag="$(printf '%s' "$az_pol" | jq -r '.allowEmailVerifiedUsersToJoinOrganization // "null"')"
    invites="$(printf '%s' "$az_pol" | jq -r '.allowInvitesFrom // "null"')"
    risky="$(printf '%s' "$az_pol" | jq -r '.allowUserConsentForRiskyApps // "null"')"
    createapps="$(printf '%s' "$az_pol" | jq -r '.defaultUserRolePermissions.allowedToCreateApps // "null"')"
    # authzpolicy-signup-intentional: allowEmailVerifiedUsersToJoinOrganization should be false
    if [ "$joinflag" = "false" ]; then
      pass M authzpolicy-signup-intentional "Sign-up join posture intentional (no email-verified self-join)"
    else
      warn M authzpolicy-signup-intentional "Sign-up join posture intentional" "allowEmailVerifiedUsersToJoinOrganization=$joinflag" "set allowEmailVerifiedUsersToJoinOrganization=false unless intended"
    fi
    # authzpolicy-guest-invite-restricted (L)
    case "$invites" in
      none|adminsAndGuestInviters) pass L authzpolicy-guest-invite-restricted "Guest invites restricted" ;;
      *) warn L authzpolicy-guest-invite-restricted "Guest invites restricted" "allowInvitesFrom=$invites" "restrict invites to none/adminsAndGuestInviters" ;;
    esac
    # authzpolicy-no-risky-app-consent (L)
    if [ "$risky" = "false" ]; then
      pass L authzpolicy-no-risky-app-consent "Risky-app user consent disabled"
    elif [ "$risky" = "null" ]; then
      skip L authzpolicy-no-risky-app-consent "Risky-app user consent disabled" "allowUserConsentForRiskyApps not set (tenant default)"
    else
      warn L authzpolicy-no-risky-app-consent "Risky-app user consent disabled" "allowUserConsentForRiskyApps=$risky" "disable risky-app consent"
    fi
  fi

  # --- branding ---
  local org orgid branding bferr
  org="$(graph_get "$GRAPH_V1/organization")"
  orgid="$(printf '%s' "$org" | jq -r '.value[0].id // empty' 2>/dev/null)"
  if [ -n "$orgid" ]; then
    branding="$(graph_get "$GRAPH_V1/organization/$orgid/branding")"
    bferr="$(graph_err_code "$branding")"
    if [ -n "$bferr" ]; then
      skip L branding-custom-not-default "Company branding customized" "branding not readable ($bferr)"
    else
      local hasbrand
      hasbrand="$(printf '%s' "$branding" | jq -r '
        if ((.backgroundColor//"")!="" or (.signInPageText//"")!="" or (.bannerLogoRelativeUrl//"")!="" or (.squareLogoRelativeUrl//"")!="") then "Y" else "N" end')"
      if [ "$hasbrand" = "Y" ]; then
        pass L branding-custom-not-default "Company branding customized"
      else
        warn L branding-custom-not-default "Company branding customized" "default branding (no logo/colors/text)" "configure company branding"
      fi
    fi
  else
    skip L branding-custom-not-default "Company branding customized" "organization id not readable"
  fi

  # --- custom-url-domain-branded (M): authority host not <tenant>.ciamlogin.com ---
  local authority
  authority="$(cfg '.authority')"
  if [ -n "$authority" ]; then
    case "$authority" in
      *ciamlogin.com*) warn M custom-url-domain-branded "Sign-in host is a verified custom domain" "authority uses *.ciamlogin.com (default)" "configure a custom URL domain" ;;
      *) pass M custom-url-domain-branded "Sign-in host is a custom domain" ;;
    esac
  else
    skip M custom-url-domain-branded "Sign-in host is a verified custom domain" "no authority in config"
  fi

  # --- token-lifetime-managed (L): CA session control or token-lifetime policy ---
  if [ -n "$caerr" ]; then
    skip L token-lifetime-managed "Session/token lifetime controls set" "CA policies not readable"
  else
    local sess
    sess="$(printf '%s' "$ca" | jq -r '[.value[]? | select((.sessionControls.signInFrequency.isEnabled==true) or (.sessionControls.persistentBrowser.isEnabled==true))]|length' 2>/dev/null || echo 0)"
    if [ "$sess" -ge 1 ] 2>/dev/null; then
      pass L token-lifetime-managed "Session/token lifetime controls set"
    else
      warn L token-lifetime-managed "Session/token lifetime controls set" "no signInFrequency/persistentBrowser session control" "set session controls (signInFrequency/persistentBrowser)"
    fi
  fi

  # --- data-residency-awareness (L) — verify only ---
  local geo
  geo="$(printf '%s' "$org" | jq -r '.value[0].countryLetterCode // .value[0].preferredLanguage // empty' 2>/dev/null)"
  if [ -n "$geo" ]; then
    warn L data-residency-awareness "Tenant geography is intended (immutable)" "tenant country/locale=$geo — verify this is intended (immutable post-creation)" "if wrong, the tenant must be recreated"
  else
    skip L data-residency-awareness "Tenant geography is intended (immutable)" "tenant geo not readable"
  fi

  # --- monitoring-diagnostic-export (L) — Entra diagnostic settings to Log Analytics ---
  diag_check L monitoring-diagnostic-export "Entra logs export to Log Analytics" "SignInLogs AuditLogs"
}

# diag_check <sev> <id> <title> <categories> — Entra ID diagnostic settings via az monitor
diag_check() {
  local sev="$1" id="$2" title="$3" cats="$4"
  local ds
  ds="$(az monitor diagnostic-settings list --resource "/providers/Microsoft.aadiam/diagnosticSettings" -o json 2>/dev/null || echo "")"
  if [ -z "$ds" ]; then
    # try the aad provider path used for Entra diagnostics
    ds="$(az rest --method get --url "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01-preview" -o json 2>/dev/null || echo "")"
  fi
  if [ -z "$ds" ] || [ "$ds" = "null" ]; then
    skip "$sev" "$id" "$title" "Entra diagnostic settings not readable (needs Security Admin / Global Reader on the tenant)"
    return
  fi
  local hasla
  hasla="$(printf '%s' "$ds" | jq -r '[.. | objects | select(.workspaceId? != null and (.logs? != null))] | length' 2>/dev/null || echo 0)"
  if [ "$hasla" -ge 1 ] 2>/dev/null; then
    pass "$sev" "$id" "$title"
  else
    fail "$sev" "$id" "$title" "no diagnostic setting exporting $cats to Log Analytics" "add a diagnostic setting exporting $cats to Log Analytics"
  fi
}

# ===========================================================================
# SECTION 4 — MCP / OAuth2 resource server (App Service Easy Auth + PRM)
# Reference: probes the App Service Easy Auth form. App Service is no longer a kit
# host (AGENTS.md backend topology) — the kit's ACA MCP host validates in-app (backend-mcp.md).
# The protocol-level checks below remain valid against an ACA in-app deployment;
# the `az webapp auth show` platform checks apply only to App Service.
# ===========================================================================
section_4() {
  section 4 "MCP / OAuth2 resource server (Easy Auth + PRM)"

  local base="${MCP_HOST%/}"
  local prm_url="$base/.well-known/oauth-protected-resource"
  local mcp_url="$base/mcp"

  # Probe PRM endpoint
  local prm_status prm_body
  prm_body="$(curl -sS -w $'\n%{http_code}' "$prm_url" 2>/dev/null || true)"
  prm_status="$(printf '%s' "$prm_body" | tail -1)"
  prm_body="$(printf '%s' "$prm_body" | sed '$d')"

  # prm-endpoint-served (C)
  if [ "$prm_status" = "200" ]; then
    pass C prm-endpoint-served "PRM endpoint returns 200 JSON"
  else
    fail C prm-endpoint-served "PRM endpoint returns 200 JSON" "GET $prm_url -> HTTP $prm_status (Easy Auth/PRM not deployed)" "enable Easy Auth + PRM setting"
  fi
  # prm-valid-json (C)
  if [ "$prm_status" = "200" ] && printf '%s' "$prm_body" | jq -e . >/dev/null 2>&1; then
    pass C prm-valid-json "PRM body is valid JSON"
  elif [ "$prm_status" = "200" ]; then
    fail C prm-valid-json "PRM body is valid JSON" "PRM body did not parse as JSON" "rely on the default PRM document"
  else
    skip C prm-valid-json "PRM body is valid JSON" "PRM endpoint not served (HTTP $prm_status)"
  fi
  # prm-resource-field (C)
  if [ "$prm_status" = "200" ] && printf '%s' "$prm_body" | jq -e . >/dev/null 2>&1; then
    local prmres
    prmres="$(printf '%s' "$prm_body" | jq -r '.resource // empty')"
    if [ -n "$prmres" ]; then
      # canonical MCP URI: https, matches base host
      case "$prmres" in
        https://*) pass C prm-resource-field "PRM .resource is the canonical MCP URI" ;;
        *) fail C prm-resource-field "PRM .resource is the canonical MCP URI" ".resource=$prmres (not https)" "reach the app via its real https hostname" ;;
      esac
    else
      fail C prm-resource-field "PRM .resource is the canonical MCP URI" "no .resource in PRM" "set PRM resource to the canonical MCP URI"
    fi
    # prm-auth-servers (C)
    local authsrv
    authsrv="$(printf '%s' "$prm_body" | jq -r '[.authorization_servers[]?]|join(",")')"
    if printf '%s' "$authsrv" | grep -qi 'ciamlogin\|microsoftonline\|'"$TENANT_ID"; then
      pass C prm-auth-servers "PRM authorization_servers point at External ID"
    else
      fail C prm-auth-servers "PRM authorization_servers point at External ID" "authorization_servers=$authsrv" "point OIDC at the External ID authority"
    fi
    # prm-scopes-inform-send (H)
    local prmsc
    prmsc="$(printf '%s' "$prm_body" | jq -r '[.scopes_supported[]?]|join(",")')"
    if printf '%s' "$prmsc" | grep -q "$API_SCOPE"; then
      pass H prm-scopes-inform-send "PRM scopes_supported includes $API_SCOPE"
    else
      fail H prm-scopes-inform-send "PRM scopes_supported includes $API_SCOPE" "scopes_supported=$prmsc" "set the PRM scopes setting to include $API_SCOPE"
    fi
  else
    skip C prm-resource-field "PRM .resource is the canonical MCP URI" "PRM endpoint not served"
    skip C prm-auth-servers "PRM authorization_servers point at External ID" "PRM endpoint not served"
    skip H prm-scopes-inform-send "PRM scopes_supported includes $API_SCOPE" "PRM endpoint not served"
  fi

  # mcp-401-www-authenticate (C)
  local mcp_hdrs mcp_status wwwauth
  mcp_hdrs="$(curl -sS -D - -o /dev/null "$mcp_url" 2>/dev/null || true)"
  mcp_status="$(printf '%s' "$mcp_hdrs" | awk 'NR==1{print $2}')"
  wwwauth="$(printf '%s' "$mcp_hdrs" | tr -d '\r' | awk -F': ' 'tolower($1)=="www-authenticate"{print $2}')"
  if [ "$mcp_status" = "401" ] && printf '%s' "$wwwauth" | grep -qi 'bearer' && printf '%s' "$wwwauth" | grep -qi 'resource_metadata'; then
    pass C mcp-401-www-authenticate "Unauth /mcp -> 401 with Bearer + resource_metadata"
  elif [ "$mcp_status" = "401" ]; then
    fail C mcp-401-www-authenticate "Unauth /mcp -> 401 with Bearer + resource_metadata" "401 but no resource_metadata WWW-Authenticate (got: ${wwwauth:-none — bare 401, interim static-key/pre-Easy-Auth state})" "enable Return401 + PRM resource_metadata challenge"
  else
    fail C mcp-401-www-authenticate "Unauth /mcp -> 401 with Bearer + resource_metadata" "/mcp -> HTTP $mcp_status (expected 401 challenge)" "enable Easy Auth Return401 + PRM"
  fi

  # mcp-no-token-in-query (M)
  local q_status
  q_status="$(curl -sS -o /dev/null -w '%{http_code}' "$mcp_url?access_token=invalid" 2>/dev/null || echo 000)"
  if [ "$q_status" = "401" ]; then
    pass M mcp-no-token-in-query "Token in query string is rejected (401)"
  else
    warn M mcp-no-token-in-query "Token in query string is rejected (401)" "/mcp?access_token=... -> HTTP $q_status (expected 401)" "accept bearer only via the Authorization header"
  fi

  # https-only — both webapp setting and http->https redirect
  if [ -n "$RESOURCE_GROUP" ] && [ -n "$WEBAPP" ]; then
    local httpsonly
    httpsonly="$(az webapp show -g "$RESOURCE_GROUP" -n "$WEBAPP" --query httpsOnly -o tsv 2>/dev/null || echo "")"
    if [ "$httpsonly" = "true" ]; then
      pass H https-only "App Service httpsOnly == true"
    elif [ -n "$httpsonly" ]; then
      fail H https-only "App Service httpsOnly == true" "httpsOnly=$httpsonly" "enable HTTPS-only on the App Service"
    else
      skip H https-only "App Service httpsOnly == true" "webapp $WEBAPP not found in $RESOURCE_GROUP"
    fi
  else
    # fall back to an HTTP redirect probe
    local httpcode
    httpcode="$(curl -sS -o /dev/null -w '%{http_code}' "http://${base#https://}/readyz" 2>/dev/null || echo 000)"
    case "$httpcode" in
      30[0-9]|200) pass H https-only "HTTP request handled over https (redirect/served)" ;;
      *) skip H https-only "App Service httpsOnly == true" "no --resource-group/--webapp; http probe inconclusive ($httpcode)" ;;
    esac
  fi

  # --- Easy Auth (authsettingsV2) checks ---
  local authv2=""
  if [ -n "$RESOURCE_GROUP" ] && [ -n "$WEBAPP" ]; then
    authv2="$(az webapp auth show -g "$RESOURCE_GROUP" -n "$WEBAPP" -o json 2>/dev/null || echo "")"
  fi
  if [ -z "$authv2" ] || [ "$authv2" = "null" ]; then
    for r in auth-enabled auth-return401 oidc-config-externalid auth-audience-matches-appiduri token-validation-full prm-scopes-setting-present health-version-excluded prm-wellknown-excluded no-token-passthrough auth-allowed-clients; do
      skip C "$r" "Easy Auth / PRM config" "Easy Auth (authsettingsV2) not readable — webapp/RG not given or auth not enabled"
    done
    return
  fi

  # Normalize: az authV2 nests under .properties
  local P
  P="$(printf '%s' "$authv2" | jq -r 'if .properties then .properties else . end')"

  local enabled requireAuth unauthAction
  enabled="$(printf '%s' "$P" | jq -r '.platform.enabled // "null"')"
  requireAuth="$(printf '%s' "$P" | jq -r '.globalValidation.requireAuthentication // "null"')"
  unauthAction="$(printf '%s' "$P" | jq -r '.globalValidation.unauthenticatedClientAction // "null"')"

  # auth-enabled (C)
  if [ "$enabled" = "true" ] && [ "$requireAuth" = "true" ]; then
    pass C auth-enabled "Easy Auth enabled and authentication required"
  else
    fail C auth-enabled "Easy Auth enabled and authentication required" "platform.enabled=$enabled requireAuthentication=$requireAuth" "enable Easy Auth and require authentication"
  fi
  # auth-return401 (C)
  if [ "$unauthAction" = "Return401" ]; then
    pass C auth-return401 "Unauthenticated action is Return401"
  else
    fail C auth-return401 "Unauthenticated action is Return401" "unauthenticatedClientAction=$unauthAction" "set unauthenticatedClientAction=Return401 (not RedirectToLoginPage)"
  fi

  # oidc-config-externalid (C) — custom OIDC well-known points at External ID v2.0
  local wellknown clientid
  wellknown="$(printf '%s' "$P" | jq -r '. as $p | ([$p.identityProviders.customOpenIdConnectProviders[]?.openIdConnectConfiguration.wellKnownOpenIdConfiguration] | first) // $p.identityProviders.azureActiveDirectory.registration.openIdIssuer // empty')"
  clientid="$(printf '%s' "$P" | jq -r '. as $p | ([$p.identityProviders.customOpenIdConnectProviders[]?.registration.clientId] | first) // $p.identityProviders.azureActiveDirectory.registration.clientId // empty')"
  if [ -n "$wellknown" ] && printf '%s' "$wellknown" | grep -qi 'ciamlogin\|'"$TENANT_ID"; then
    pass C oidc-config-externalid "Custom OIDC well-known points at External ID discovery"
  elif [ -n "$wellknown" ]; then
    fail C oidc-config-externalid "Custom OIDC well-known points at External ID discovery" "wellKnown=$wellknown (not External ID)" "point the OIDC config at the ciamlogin v2.0 discovery"
  else
    fail C oidc-config-externalid "Custom OIDC well-known points at External ID discovery" "no OIDC provider configured" "configure a custom OIDC provider for External ID"
  fi

  # auth-audience-matches-appiduri (C) — custom OIDC clientId == API App ID URI (==PRM .resource)
  # (Custom OIDC providers have no allowedAudiences; clientId IS the audience gate.)
  if [ -n "$clientid" ]; then
    if [ "$clientid" = "$API_IDENTIFIER_URI" ] || [ "$clientid" = "$API_APP_ID" ]; then
      pass C auth-audience-matches-appiduri "OIDC clientId (audience gate) binds to the API App ID URI"
    else
      fail C auth-audience-matches-appiduri "OIDC clientId binds to the API App ID URI" "clientId=$clientid != $API_IDENTIFIER_URI" "set the OIDC clientId to the API App ID URI (api://<appId>)"
    fi
  else
    skip C auth-audience-matches-appiduri "OIDC clientId binds to the API App ID URI" "no OIDC clientId configured"
  fi

  # token-validation-full (C) — requires live valid/invalid tokens; not automatable read-only
  skip C token-validation-full "Full token validation (iss/aud/sig/scope)" "requires minting valid + tampered tokens; not a read-only signal — verify with an integration test"

  # prm-scopes-setting-present (H) — app setting WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES
  if [ -n "$RESOURCE_GROUP" ] && [ -n "$WEBAPP" ]; then
    local prmsetting
    prmsetting="$(az webapp config appsettings list -g "$RESOURCE_GROUP" -n "$WEBAPP" -o json 2>/dev/null \
      | jq -r '[.[]? | select(.name=="WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES") | .value] | first // empty')"
    if [ -n "$prmsetting" ] && printf '%s' "$prmsetting" | grep -q "$API_SCOPE"; then
      pass H prm-scopes-setting-present "WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES includes $API_SCOPE"
    elif [ -n "$prmsetting" ]; then
      fail H prm-scopes-setting-present "WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES includes $API_SCOPE" "setting present but lacks $API_SCOPE (=$prmsetting)" "set the app setting to include api://.../$API_SCOPE"
    else
      fail H prm-scopes-setting-present "WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES includes $API_SCOPE" "app setting not present" "set WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES"
    fi
  else
    skip H prm-scopes-setting-present "WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES includes $API_SCOPE" "webapp/RG not provided"
  fi

  # health-version-excluded (M) — /livez /readyz /version excluded (return 200 unauth)
  local hv_ok="y" hv_detail=""
  for p in /livez /readyz /version; do
    local c; c="$(curl -sS -o /dev/null -w '%{http_code}' "$base$p" 2>/dev/null || echo 000)"
    [ "$c" = "200" ] || { hv_ok="n"; hv_detail="${hv_detail}${p}:${c} "; }
  done
  if [ "$hv_ok" = "y" ]; then
    pass M health-version-excluded "/livez /readyz /version return 200 unauthenticated"
  else
    warn M health-version-excluded "/livez /readyz /version return 200 unauthenticated" "non-200: $hv_detail" "add these to excludedPaths"
  fi

  # prm-wellknown-excluded (H) — PRM reachable unauthenticated (200)
  if [ "$prm_status" = "200" ]; then
    pass H prm-wellknown-excluded "PRM endpoint reachable unauthenticated (200)"
  else
    fail H prm-wellknown-excluded "PRM endpoint reachable unauthenticated (200)" "PRM -> HTTP $prm_status" "keep the PRM endpoint anonymous (excludedPaths)"
  fi

  # no-token-passthrough (H) — not directly observable; depends on downstream MI/OBO
  skip H no-token-passthrough "Client token not forwarded downstream (MI/OBO)" "not externally observable — verify the app uses managed identity/OBO to call ACS, not token pass-through"

  # auth-allowed-clients (M) — MCP client appId in allowedApplications (if restricted)
  local allowed
  allowed="$(printf '%s' "$P" | jq -r '[.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications[]?] | @json' 2>/dev/null || echo '[]')"
  if [ "$allowed" = "[]" ] || [ "$allowed" = "null" ]; then
    skip M auth-allowed-clients "MCP client app is in allowedApplications (if restricted)" "no allowedApplications restriction configured (not required)"
  elif printf '%s' "$allowed" | jq -e --arg c "$CONFIDENTIAL_APP_ID" 'index($c)' >/dev/null 2>&1; then
    pass M auth-allowed-clients "MCP client app is in allowedApplications"
  else
    fail M auth-allowed-clients "MCP client app is in allowedApplications" "allowedApplications set but excludes the MCP client appId" "add the MCP client appId to allowedApplications"
  fi
}

# ===========================================================================
# SECTION 5 — Operations, monitoring & secret lifecycle
# ===========================================================================
section_5() {
  section 5 "Operations, monitoring & secret lifecycle"

  # app-owners-present (H) — same signal as app-has-owner but section-5 ops framing
  local noowner=""
  for pair in "api|$(api_obj_id)" "spa|$(spa_obj_id)" "confidential|$(conf_obj_id)"; do
    local lbl oid
    lbl="${pair%%|*}"; oid="${pair#*|}"
    [ -n "$oid" ] || continue
    local oc; oc="$(graph_get "$GRAPH_V1/applications/$oid/owners?\$select=id" | jq -r '(.value|length)//0' 2>/dev/null || echo 0)"
    [ "$oc" -ge 1 ] 2>/dev/null || noowner="${noowner}${lbl} "
  done
  if [ -z "$(api_obj_id)$(spa_obj_id)$(conf_obj_id)" ]; then
    skip H app-owners-present "Every app has an owner" "no apps resolvable"
  elif [ -z "$noowner" ]; then
    pass H app-owners-present "Every app has an owner"
  else
    fail H app-owners-present "Every app has an owner" "no owner: $noowner" "assign owners to each app registration"
  fi

  # no-checked-in-secret (C) — scan tracked files for literal secrets
  local secretscan repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
  if command -v git >/dev/null 2>&1 && [ -d "$repo_root/.git" ]; then
    secretscan="$(cd "$repo_root" && git grep -nIE \
      'AccountKey=|client_secret"?[[:space:]]*[:=]|DefaultEndpointsProtocol=.*AccountKey|-----BEGIN (RSA |EC )?PRIVATE KEY-----|password"?[[:space:]]*[:=][[:space:]]*"[^"]{8,}' \
      -- ':!*.lock' ':!*external-id.secret.local.json' 2>/dev/null | head -5 || true)"
    if [ -z "$secretscan" ]; then
      pass C no-checked-in-secret "No literal secrets in tracked files"
    else
      fail C no-checked-in-secret "No literal secrets in tracked files" "possible secret(s): $(printf '%s' "$secretscan" | head -1)" "move secrets to Key Vault; purge from history"
    fi
  else
    skip C no-checked-in-secret "No literal secrets in tracked files" "not a git repo (run from the repo root)"
  fi

  # ci-uses-federated-credentials (H) — CI deploy identity uses GitHub-OIDC FIC, no secret
  # Best-effort: look for a workflow that uses azure/login with OIDC and no client-secret.
  local wf
  wf="$(ls "$repo_root"/.github/workflows/*.yml "$repo_root"/.github/workflows/*.yaml 2>/dev/null || true)"
  if [ -z "$wf" ]; then
    skip H ci-uses-federated-credentials "CI deploy identity uses GitHub-OIDC FIC" "no GitHub Actions workflows found"
  else
    local usesoidc usessecret
    usesoidc="$(grep -lE 'id-token:[[:space:]]*write|azure/login' $wf 2>/dev/null | head -1 || true)"
    usessecret="$(grep -lE 'client-secret:|AZURE_CLIENT_SECRET|creds:[[:space:]]*\$\{\{[[:space:]]*secrets' $wf 2>/dev/null | head -1 || true)"
    if [ -n "$usesoidc" ] && [ -z "$usessecret" ]; then
      pass H ci-uses-federated-credentials "CI deploy uses GitHub-OIDC (no client secret)"
    elif [ -n "$usessecret" ]; then
      fail H ci-uses-federated-credentials "CI deploy uses GitHub-OIDC (no client secret)" "workflow references a client secret ($usessecret)" "use OIDC federated credentials; drop the secret"
    else
      warn H ci-uses-federated-credentials "CI deploy uses GitHub-OIDC (no client secret)" "no azure/login OIDC marker found in workflows" "ensure CI deploy uses OIDC FIC"
    fi
  fi

  # --- runtime / storage / KV posture (ARM) ---
  RUNTIME_MI="no"
  if [ -n "$RESOURCE_GROUP" ] && [ -n "$WEBAPP" ]; then
    local mi
    mi="$(az webapp identity show -g "$RESOURCE_GROUP" -n "$WEBAPP" --query type -o tsv 2>/dev/null || echo "")"
    printf '%s' "$mi" | grep -qi 'SystemAssigned\|UserAssigned' && RUNTIME_MI="yes"
    if printf '%s' "$mi" | grep -qi 'SystemAssigned\|UserAssigned'; then
      # also confirm no inline connection string app settings
      local connstr
      connstr="$(az webapp config appsettings list -g "$RESOURCE_GROUP" -n "$WEBAPP" -o json 2>/dev/null \
        | jq -r '[.[]? | select((.value|tostring)|test("AccountKey=|DefaultEndpointsProtocol=.*AccountKey";"i"))]|length' 2>/dev/null || echo 0)"
      if [ "$connstr" = "0" ]; then
        pass H runtime-managed-identity-not-connstr "Web app uses managed identity, no inline conn-string"
      else
        fail H runtime-managed-identity-not-connstr "Web app uses managed identity, no inline conn-string" "MI present but $connstr app setting(s) hold an AccountKey conn-string" "use MI + RBAC; Key Vault ref otherwise"
      fi
    else
      fail H runtime-managed-identity-not-connstr "Web app uses managed identity" "no managed identity on $WEBAPP (identity type=${mi:-none})" "assign a managed identity and use RBAC"
    fi
  else
    skip H runtime-managed-identity-not-connstr "Web app uses managed identity" "webapp/RG not provided"
  fi

  # storage-least-privilege-rbac (H) + storage-shared-key-disabled (M)
  if [ -n "$RESOURCE_GROUP" ] && [ -n "$STORAGE_ACCOUNT" ]; then
    local stid sharedkey
    stid="$(az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query id -o tsv 2>/dev/null || echo "")"
    sharedkey="$(az storage account show -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query allowSharedKeyAccess -o tsv 2>/dev/null || echo "")"
    if [ -z "$stid" ]; then
      skip H storage-least-privilege-rbac "Runtime MI has narrow Storage data role" "storage account $STORAGE_ACCOUNT not found"
      skip M storage-shared-key-disabled "Storage Shared Key access disabled" "storage account not found"
    else
      # least-priv RBAC depends on a runtime MI to bind a data role to.
      if [ "$RUNTIME_MI" != "yes" ]; then
        skip H storage-least-privilege-rbac "Runtime MI has narrow Storage data role" "web app has no managed identity yet — nothing to scope a data role to"
      else
        # enumerate role assignments at the storage scope; flag Owner/Contributor
        local broad
        broad="$(az role assignment list --scope "$stid" -o json 2>/dev/null \
          | jq -r '[.[]? | select(.roleDefinitionName|test("^(Owner|Contributor)$"))]|length' 2>/dev/null || echo "ERR")"
        if [ "$broad" = "ERR" ]; then
          skip H storage-least-privilege-rbac "Runtime MI has narrow Storage data role" "role assignments not readable at storage scope"
        elif [ "$broad" = "0" ]; then
          pass H storage-least-privilege-rbac "No Owner/Contributor role assignments at the storage scope"
        else
          warn H storage-least-privilege-rbac "Runtime MI has narrow Storage data role" "$broad Owner/Contributor assignment(s) at storage scope" "use a narrow data role (Storage Table Data Contributor/Reader)"
        fi
      fi
      # allowSharedKeyAccess: null = Azure default = Shared Key ALLOWED (not disabled).
      if [ "$sharedkey" = "false" ]; then
        pass M storage-shared-key-disabled "Storage Shared Key access disabled"
      else
        local skshow="$sharedkey"; [ -z "$skshow" ] && skshow="null (default=allowed)"
        fail M storage-shared-key-disabled "Storage Shared Key access disabled" "allowSharedKeyAccess=$skshow" "set allowSharedKeyAccess=false"
      fi
    fi
  else
    skip H storage-least-privilege-rbac "Runtime MI has narrow Storage data role" "storage account/RG not provided"
    skip M storage-shared-key-disabled "Storage Shared Key access disabled" "storage account/RG not provided"
  fi

  # keyvault-rbac-secrets-user (M) + keyvault-diagnostics-enabled (L)
  local kvname=""
  if [ -n "$RESOURCE_GROUP" ]; then
    kvname="$(az keyvault list -g "$RESOURCE_GROUP" --query '[0].name' -o tsv 2>/dev/null || echo "")"
  fi
  if [ -z "$kvname" ] || [ "$kvname" = "None" ]; then
    skip M keyvault-rbac-secrets-user "Key Vault uses RBAC + least role" "no Key Vault in the resource group"
    skip L keyvault-diagnostics-enabled "Key Vault AuditEvent logs exported" "no Key Vault in the resource group"
  else
    local kvrbac
    kvrbac="$(az keyvault show -n "$kvname" --query properties.enableRbacAuthorization -o tsv 2>/dev/null || echo "")"
    if [ "$kvrbac" = "true" ]; then
      pass M keyvault-rbac-secrets-user "Key Vault $kvname uses RBAC authorization"
    else
      fail M keyvault-rbac-secrets-user "Key Vault uses RBAC + least role" "enableRbacAuthorization=$kvrbac" "enable RBAC and assign only Key Vault Secrets User"
    fi
    local kvid kvdiag
    kvid="$(az keyvault show -n "$kvname" --query id -o tsv 2>/dev/null || echo "")"
    kvdiag="$(az monitor diagnostic-settings list --resource "$kvid" -o json 2>/dev/null | jq -r '(.value|length) // (length) // 0' 2>/dev/null || echo 0)"
    if [ "$kvdiag" -ge 1 ] 2>/dev/null; then
      pass L keyvault-diagnostics-enabled "Key Vault AuditEvent logs exported"
    else
      warn L keyvault-diagnostics-enabled "Key Vault AuditEvent logs exported" "no diagnostic settings on $kvname" "enable AuditEvent export to Log Analytics"
    fi
  fi

  # entra-logs-to-log-analytics (H) — same signal as monitoring-diagnostic-export but H/ops
  diag_check H entra-logs-to-log-analytics "Entra Sign-in + Audit logs stream to Log Analytics" "SignInLogs AuditLogs"

  # credential-expiry-alerting (M) — no active credential expiring <=30d without rotation tracking
  if [ -n "$APP_CONF_JSON" ] && [ -z "$(graph_err_code "$APP_CONF_JSON")" ]; then
    local soon
    soon="$(PYJSON="$APP_CONF_JSON" python3 -c '
import os,json,datetime,re
def pdt(s):
    s=s.strip().replace("Z","")
    m=re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?",s)
    return datetime.datetime.fromisoformat(m.group(1)+(m.group(2) or "")[:7]).replace(tzinfo=datetime.timezone.utc)
o=json.loads(os.environ["PYJSON"]); now=datetime.datetime.now(datetime.timezone.utc); n=0
for arr in ("passwordCredentials","keyCredentials"):
    for c in o.get(arr) or []:
        try:
            end=pdt(c["endDateTime"])
            if now<=end<=now+datetime.timedelta(days=30): n+=1
        except Exception: pass
print(n)
')"
    if [ "$soon" = "0" ]; then
      pass M credential-expiry-alerting "No confidential credential expiring within 30 days"
    else
      warn M credential-expiry-alerting "No confidential credential expiring within 30 days" "$soon credential(s) expire <=30d" "rotate and add scheduled expiry alerting"
    fi
  else
    skip M credential-expiry-alerting "No confidential credential expiring within 30 days" "confidential app not resolvable"
  fi

  # remove-unused-credentials (M) + remove-unused-apps (M) — Entra recommendations (Graph)
  rec_check M remove-unused-credentials "Stale-credential recommendation clear" "staleAppCreds"
  rec_check M remove-unused-apps "Stale-application recommendation clear" "staleApps"

  # --- ops CA policies (phish-resistant admin MFA, block legacy auth) ---
  local ca caerr
  ca="$(graph_get "$GRAPH_V1/identity/conditionalAccess/policies")"
  caerr="$(graph_err_code "$ca")"
  if [ -n "$caerr" ]; then
    skip H ca-privileged-roles-phish-resistant-mfa "Phishing-resistant MFA for admin roles" "CA policies not readable ($caerr)"
    skip M block-legacy-auth "Legacy auth blocked by CA policy" "CA policies not readable ($caerr)"
  else
    local phish
    phish="$(printf '%s' "$ca" | jq -r '[.value[]? | select(.state=="enabled") | select((.grantControls.authenticationStrength.id//"")!="" or ((.grantControls.builtInControls//[])|index("mfa"))) | select((.conditions.users.includeRoles//[])|length>0)]|length' 2>/dev/null || echo 0)"
    if [ "$phish" -ge 1 ] 2>/dev/null; then
      pass H ca-privileged-roles-phish-resistant-mfa "An enabled CA policy enforces MFA for admin roles"
    else
      fail H ca-privileged-roles-phish-resistant-mfa "Phishing-resistant MFA for admin roles" "no enabled CA policy targeting admin roles with MFA/auth-strength" "add a phishing-resistant admin-MFA CA policy"
    fi
    local legacy
    legacy="$(printf '%s' "$ca" | jq -r '[.value[]? | select(.state=="enabled") | select(((.conditions.clientAppTypes//[])|index("exchangeActiveSync")) or ((.conditions.clientAppTypes//[])|index("other"))) | select((.grantControls.builtInControls//[])|index("block"))]|length' 2>/dev/null || echo 0)"
    if [ "$legacy" -ge 1 ] 2>/dev/null; then
      pass M block-legacy-auth "An enabled CA policy blocks legacy auth"
    else
      fail M block-legacy-auth "Legacy auth blocked by CA policy" "no enabled block-legacy-auth CA policy" "add a CA policy blocking legacy auth client types"
    fi
  fi

  # restrict-app-registration (M) — authorizationPolicy.allowedToCreateApps == false
  local az_pol azerr createapps
  az_pol="$(graph_get "$GRAPH_V1/policies/authorizationPolicy")"
  azerr="$(graph_err_code "$az_pol")"
  if [ -n "$azerr" ]; then
    skip M restrict-app-registration "App registration restricted to admins" "authorizationPolicy not readable ($azerr)"
  else
    createapps="$(printf '%s' "$az_pol" | jq -r '.defaultUserRolePermissions.allowedToCreateApps // "null"')"
    if [ "$createapps" = "false" ]; then
      pass M restrict-app-registration "Default users cannot create app registrations"
    else
      fail M restrict-app-registration "App registration restricted to admins" "allowedToCreateApps=$createapps" "set allowedToCreateApps=false"
    fi
  fi
}

# rec_check <sev> <id> <title> <recommendationId-substr> — Entra recommendations via Graph beta
rec_check() {
  local sev="$1" id="$2" title="$3" key="$4"
  local rec recerr
  rec="$(graph_get "$GRAPH_BETA/directory/recommendations")"
  recerr="$(graph_err_code "$rec")"
  if [ -n "$recerr" ]; then
    skip "$sev" "$id" "$title" "directory recommendations not readable ($recerr — needs DirectoryRecommendations.Read.All)"
    return
  fi
  local active
  active="$(printf '%s' "$rec" | jq -r --arg k "$key" '
    [.value[]? | select((.recommendationType // "")|test($k;"i")) | select(.status!="completedBySystem" and .status!="dismissed" and ((.impactedResources//[])|length>0))] | length' 2>/dev/null || echo 0)"
  if [ "$active" = "0" ]; then
    pass "$sev" "$id" "$title"
  else
    warn "$sev" "$id" "$title" "$active active impacted resource(s) on the $key recommendation" "act on the Entra $key recommendation"
  fi
}

# ===========================================================================
# Run sections
# ===========================================================================
run_section 1 && section_1
run_section 2 && section_2
run_section 3 && section_3
run_section 4 && section_4
run_section 5 && section_5

# ===========================================================================
# Output
# ===========================================================================
N=${#R_ID[@]}

if [ "$OUTPUT_FORMAT" = "json" ]; then
  printf '['
  i=0
  while [ "$i" -lt "$N" ]; do
    [ "$i" -gt 0 ] && printf ','
    printf '%s' "$(jq -nc \
      --arg id "${R_ID[$i]}" --arg sev "${R_SEV[$i]}" \
      --arg status "${R_STATUS[$i]}" --arg reason "${R_REASON[$i]}" \
      --arg sec "${R_SEC[$i]}" \
      '{id:$id,severity:$sev,status:$status,section:($sec|tonumber),reason:$reason}')"
    i=$((i+1))
  done
  printf ']\n'
else
  SECTITLES="1:App registration & credential hygiene
2:Scopes, permissions & consent
3:External-tenant security & user flow
4:MCP / OAuth2 resource server (Easy Auth + PRM)
5:Operations, monitoring & secret lifecycle"
  echo "================================================================"
  echo "  Entra External ID best-practice diagnostic"
  echo "  tenant: $TENANT_ID    mcp-host: $MCP_HOST"
  echo "================================================================"
  for sec in 1 2 3 4 5; do
    run_section "$sec" || continue
    title="$(printf '%s\n' "$SECTITLES" | awk -F: -v s="$sec" '$1==s{ $1=""; sub(/^:/,""); print }')"
    echo ""
    echo "## Section $sec — $title"
    i=0
    while [ "$i" -lt "$N" ]; do
      if [ "${R_SEC[$i]}" = "$sec" ]; then
        printf '  [%-4s] %s %-38s — %s\n' "${R_STATUS[$i]}" "${R_SEV[$i]}" "${R_ID[$i]}" "${R_TITLE[$i]}"
        if [ "${R_STATUS[$i]}" = "FAIL" ] || [ "${R_STATUS[$i]}" = "WARN" ]; then
          [ -n "${R_REASON[$i]}" ] && printf '         reason: %s\n' "${R_REASON[$i]}"
          [ -n "${R_FIX[$i]}" ]    && printf '         fix:    %s\n' "${R_FIX[$i]}"
        elif [ "${R_STATUS[$i]}" = "SKIP" ]; then
          [ -n "${R_REASON[$i]}" ] && printf '         skip:   %s\n' "${R_REASON[$i]}"
        fi
      fi
      i=$((i+1))
    done
  done
fi

# --- Summary + exit code ---------------------------------------------------
count() { # count <status>
  local s="$1" n=0 i=0
  while [ "$i" -lt "$N" ]; do [ "${R_STATUS[$i]}" = "$s" ] && n=$((n+1)); i=$((i+1)); done
  echo "$n"
}
count_sev_fail() { # FAILs at a given severity
  local sev="$1" n=0 i=0
  while [ "$i" -lt "$N" ]; do
    { [ "${R_STATUS[$i]}" = "FAIL" ] && [ "${R_SEV[$i]}" = "$sev" ]; } && n=$((n+1)); i=$((i+1))
  done
  echo "$n"
}

P=$(count PASS); W=$(count WARN); F=$(count FAIL); S=$(count SKIP)
CF=$(count_sev_fail C); HF=$(count_sev_fail H); MF=$(count_sev_fail M); LF=$(count_sev_fail L)

if [ "$OUTPUT_FORMAT" = "text" ]; then
  echo ""
  echo "================================================================"
  echo "  Summary: $N checks — PASS $P · WARN $W · FAIL $F · SKIP $S"
  echo "  FAILs by severity: Critical $CF · High $HF · Medium $MF · Low $LF"
  echo "================================================================"
  if [ "$F" -gt 0 ]; then
    echo "  FAILs (by severity):"
    for sev in C H M L; do
      i=0
      while [ "$i" -lt "$N" ]; do
        if [ "${R_STATUS[$i]}" = "FAIL" ] && [ "${R_SEV[$i]}" = "$sev" ]; then
          printf '    %s %-40s %s\n' "$sev" "${R_ID[$i]}" "${R_REASON[$i]}"
        fi
        i=$((i+1))
      done
    done
  fi
fi

if [ "$NO_FAIL" = "true" ]; then
  exit 0
fi
if [ "$CF" -gt 0 ] || [ "$HF" -gt 0 ]; then
  exit 1
fi
exit 0
