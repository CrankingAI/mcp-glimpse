#!/usr/bin/env bash
# seed-gates.sh — pure gate functions for check.sh. Sourced, not executed.
# Defines functions only; sets no shell options and runs nothing at load time so
# it is safe to source from both check.sh and the kit self-tests. macOS bash 3.2
# and BSD grep/find compatible.

# slot_is_placeholder <repo_root> <slot>  -> 0 if the slot still carries its
# placeholder sentinel (apps/<slot>/.placeholder), else 1.
slot_is_placeholder() {
  [[ -f "$1/apps/$2/.placeholder" ]]
}

# slot_is_deploy_wired <repo_root> <slot> -> 0 if a deploy artifact references the
# slot (so shipping it as a placeholder would be a defect), else 1.
slot_is_deploy_wired() {
  local root="$1" slot="$2"
  local path="apps/$slot"
  [[ "$slot" == "web" && -f "$root/staticwebapp.config.json" ]] && return 0
  # Anchor with a trailing boundary so "apps/web" does not match "apps/webby".
  local re="$path([/\"'[:space:]]|\$)"
  [[ -f "$root/azure.yaml" ]] && grep -qE "$re" "$root/azure.yaml" && return 0
  if [[ -d "$root/infra" ]]; then
    grep -rqE "$re" "$root/infra" 2>/dev/null && return 0
  fi
  return 1
}

# slot_has_framework_config <repo_root> <slot> -> 0 if the slot has been scaffolded
# (web: astro.config.*; app: vite.config.*), else 1.
slot_has_framework_config() {
  local root="$1" slot="$2" d="$1/apps/$2"
  case "$slot" in
    web) ls "$d"/astro.config.* >/dev/null 2>&1 ;;
    app) ls "$d"/vite.config.* >/dev/null 2>&1 ;;
    *)   return 1 ;;
  esac
}

# gate_placeholder_slots <repo_root> -> 0 if every app slot is either a
# not-yet-deployed placeholder (skipped) or properly scaffolded; non-zero if a
# placeholder is wired for deploy, or a sentinel was removed without scaffolding.
gate_placeholder_slots() {
  local root="$1" rc=0 slot
  for slot in web app; do
    [[ -d "$root/apps/$slot" ]] || continue
    if slot_is_placeholder "$root" "$slot"; then
      if slot_is_deploy_wired "$root" "$slot"; then
        echo "    FAIL: apps/$slot is a placeholder but wired for deploy (shipping a placeholder)"
        rc=1
      else
        echo "    skip: apps/$slot is an unscaffolded placeholder (ok in a fresh seed)"
      fi
    elif slot_has_framework_config "$root" "$slot"; then
      echo "    ok:   apps/$slot scaffolded"
    else
      echo "    FAIL: apps/$slot placeholder marker removed but not scaffolded (no framework config)"
      rc=1
    fi
  done
  return $rc
}

# gate_token_drift <repo_root> -> 0 if no app slot hard-codes design values that
# must come from @<org>/tokens; non-zero on raw hex colors (including Tailwind
# arbitrary values like bg-[#2563eb]) or literal font-family stacks. Placeholder
# slots are skipped. Build/dep output is excluded: node_modules, dist, build
# (React Router 7 framework-mode output dir), and .react-router (its typegen
# cache) — all carry compiled Tailwind CSS that would false-positive on hex.
gate_token_drift() {
  local root="$1" rc=0 slot f hits
  for slot in web app; do
    [[ -d "$root/apps/$slot" ]] || continue
    if slot_is_placeholder "$root" "$slot"; then
      echo "    skip: apps/$slot (placeholder)"
      continue
    fi
    while IFS= read -r f; do
      # Only plausible CSS color literals: a '#' in value position (preceded by
      # ':', '(', ',', or whitespace — excludes &#123; entities and "#frag"
      # href/anchor fragments) followed by exactly 3, 6, or 8 hex digits with a
      # trailing word boundary (so 4/5/7-digit runs are not colors).
      hits="$(grep -nE '[:(,[:space:]]#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})([^0-9a-fA-F]|$)' "$f" 2>/dev/null || true)"
      if [[ -n "$hits" ]]; then
        echo "    FAIL: raw hex color in apps/$slot (use the @<org>/tokens palette) -> $f"
        printf '%s\n' "$hits" | sed 's/^/        /'
        rc=1
      fi
      # Tailwind arbitrary color values — bg-[#2563eb], text-[#fff] — escape the
      # value-position check above because '[' is not a value delimiter there.
      hits="$(grep -nE '\[#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\]' "$f" 2>/dev/null || true)"
      if [[ -n "$hits" ]]; then
        echo "    FAIL: arbitrary hex color in apps/$slot (use the @<org>/tokens palette) -> $f"
        printf '%s\n' "$hits" | sed 's/^/        /'
        rc=1
      fi
      hits="$(grep -nEi 'font-family[[:space:]]*:' "$f" 2>/dev/null | grep -v 'var(--font' || true)"
      if [[ -n "$hits" ]]; then
        echo "    FAIL: literal font-family in apps/$slot (use the font-* utilities) -> $f"
        printf '%s\n' "$hits" | sed 's/^/        /'
        rc=1
      fi
    done < <(find "$root/apps/$slot" \
               -type d \( -name node_modules -o -name dist -o -name build -o -name '.react-router' \) -prune -o \
               -type f \( -name '*.css' -o -name '*.astro' -o -name '*.tsx' -o -name '*.ts' \) -print)
  done
  return $rc
}

# assert_view_source_html <htmlfile> -> 0 if the raw HTML satisfies the
# first-GET-without-JS contract (seo-discoverability.md): a valid JSON-LD block,
# og: + twitter: tags, exactly one <h1>, header/nav/main/footer landmarks, and no
# inline executable <script> (application/ld+json data blocks are exempt).
assert_view_source_html() {
  local f="$1" rc=0 h1count lm content tag jsonld
  # Flatten newlines to spaces so structural checks survive attributes/tags that
  # wrap across lines (multi-line <script ...>, <h1\n class=...>).
  content="$(tr '\n' ' ' < "$f")"
  grep -qi 'application/ld+json' "$f" || { echo "    FAIL: no JSON-LD block ($f)"; rc=1; }
  grep -qiE "property=[\"']og:" "$f" || { echo "    FAIL: no og: tags ($f)"; rc=1; }
  grep -qiE "name=[\"']twitter:" "$f" || { echo "    FAIL: no twitter: tags ($f)"; rc=1; }
  h1count="$(printf '%s' "$content" | grep -oiE '<h1[ />>]' | wc -l | tr -d ' ')"
  [[ "$h1count" == "1" ]] || { echo "    FAIL: expected one <h1>, found $h1count ($f)"; rc=1; }
  for lm in header nav main footer; do
    grep -qi "<${lm}[ >/]" "$f" || { echo "    FAIL: missing <$lm> landmark ($f)"; rc=1; }
  done
  # inline executable script: a <script ...> opening tag with no src= and not a
  # JSON data type. (Built Astro emits processed scripts as external src= files.)
  # Newline-insensitive: extract each opening tag from the flattened content.
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    case "$tag" in
      *src=*) continue ;;
      *application/ld+json*|*application/json*) continue ;;
    esac
    echo "    FAIL: inline executable <script> in first-GET HTML ($f)"
    rc=1
    break
  done < <(printf '%s' "$content" | grep -oiE '<script[^>]*>')
  # ld+json block must contain a JSON object (cheap non-node guard against an
  # empty <script type="application/ld+json"></script>).
  jsonld="$(printf '%s' "$content" | grep -oiE '<script[^>]*application/ld\+json[^>]*>[^<]*</script>' || true)"
  case "$jsonld" in
    *'{'*) : ;;
    *) echo "    FAIL: empty JSON-LD block (no JSON object) ($f)"; rc=1 ;;
  esac
  # JSON-LD validity (best-effort; requires node). Surface node's parse detail
  # instead of swallowing it (diagnose-from-logs rule).
  if command -v node >/dev/null 2>&1; then
    local nodeout noderc
    nodeout="$(node -e '
      const fs = require("fs");
      const html = fs.readFileSync(process.argv[1], "utf8");
      const re = /<script[^>]*type=["\x27]application\/ld\+json["\x27][^>]*>([\s\S]*?)<\/script>/gi;
      let m, n = 0;
      while ((m = re.exec(html))) { n++; try { JSON.parse(m[1]); } catch (e) { console.error("invalid JSON-LD block " + n + ": " + e.message); process.exit(2); } }
      if (n === 0) process.exit(3);
    ' "$f" 2>&1)"
    noderc=$?
    if [[ "$noderc" -ne 0 ]]; then
      echo "    FAIL: missing or invalid JSON-LD ($f)"
      [[ -n "$nodeout" ]] && printf '%s\n' "$nodeout" | sed 's/^/        /'
      rc=1
    fi
  fi
  return $rc
}

# gate_view_source_dir <dir> -> run assert_view_source_html over every *.html in a
# built output directory. Non-zero if any page fails. Empty dir is a pass (the
# caller decides whether an empty build is itself a problem).
gate_view_source_dir() {
  local dir="$1" rc=0 f
  while IFS= read -r f; do
    assert_view_source_html "$f" || rc=1
  done < <(find "$dir" -type f -name '*.html' 2>/dev/null)
  return $rc
}
