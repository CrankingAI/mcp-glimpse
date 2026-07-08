#!/usr/bin/env node
// Generate a Tailwind v4 theme.css from DTCG tokens.json. Zero dependencies.
// Defaults to files beside this script; TOKENS_FILE / THEME_FILE override (tests).
//
// Supports (DTCG 2025.10): color, fontFamily, dimension, duration, cubicBezier,
// shadow, number — plus alias references ("{path.to.token}", resolved with cycle
// detection) and a top-level "dark" group: tokens under dark.* re-derive the
// same variable names and are emitted as a [data-theme="dark"] override block
// after @theme, so one tokens.json carries both themes (docs/design-md.md).
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const TOKENS_FILE = process.env.TOKENS_FILE ?? join(here, "tokens.json");
const THEME_FILE = process.env.THEME_FILE ?? join(here, "theme.css");

// Tailwind v4 sizing-scale leaf keys — the t-shirt scale plus `px`. Shadowing
// only breaks Tailwind for the MULTIPLIER-DRIVEN namespaces (--spacing-*, whose
// scale derives from the single --spacing base, and --text-*, the type scale) —
// so the safe-prefix remap applies ONLY under those heads. Elsewhere (e.g.
// --radius-sm) shadowing the built-in scale is deliberate theming and passes
// through untouched. Set verified against https://tailwindcss.com/docs/theme.
const RESERVED = new Set([
  "xs", "sm", "md", "lg", "xl",
  "2xl", "3xl", "4xl", "5xl", "6xl", "7xl", "8xl", "9xl",
  "px",
]);
const REMAP_HEADS = new Set(["spacing", "text"]);
const REMAP_PREFIX = "space";

function die(msg) {
  console.error(`tokens build: ${msg}`);
  process.exit(1);
}

// DTCG: a node is a token when it has "$value". Groups nest tokens and may carry
// a "$type" that descendants inherit. Returns [{ segments, value, type }].
function collect(node, inheritedType, segments, acc) {
  if (node && typeof node === "object" && "$value" in node) {
    acc.push({ segments, value: node.$value, type: node.$type ?? inheritedType });
    return acc;
  }
  if (!node || typeof node !== "object") return acc;
  const type = node.$type ?? inheritedType;
  for (const [key, child] of Object.entries(node)) {
    if (key.startsWith("$")) continue;
    collect(child, type, [...segments, key], acc);
  }
  return acc;
}

// Alias resolution: "{color.green.600}" -> that token's resolved value.
// byPath is keyed on the dot-joined segments. Cycles and dangling refs die.
function isAlias(v) {
  return typeof v === "string" && v.startsWith("{") && v.endsWith("}");
}
function resolveValue(token, byPath, seen) {
  let { value, type } = token;
  while (isAlias(value)) {
    const refPath = value.slice(1, -1);
    if (seen.has(refPath)) die(`alias cycle at "{${refPath}}"`);
    seen.add(refPath);
    const target = byPath.get(refPath);
    if (!target) die(`alias "{${refPath}}" (from "${token.segments.join(".")}") points at no token`);
    value = target.value;
    type = type ?? target.type;
  }
  return { value, type };
}

function dim(value, path) {
  if (value && typeof value === "object" && "value" in value && "unit" in value) {
    return `${value.value}${value.unit}`;
  }
  if (typeof value === "string") return value;
  die(`dimension/duration token "${path}" must be {value,unit} or a string`);
}

function formatValue(type, value, path) {
  if (type === "color") {
    if (typeof value !== "string") die(`color token "${path}" must be a string`);
    return value;
  }
  if (type === "fontFamily") {
    return (Array.isArray(value) ? value : [value]).join(", ");
  }
  if (type === "dimension" || type === "duration") {
    return dim(value, path);
  }
  if (type === "cubicBezier") {
    if (!Array.isArray(value) || value.length !== 4) {
      die(`cubicBezier token "${path}" must be a 4-number array`);
    }
    return `cubic-bezier(${value.join(", ")})`;
  }
  if (type === "shadow") {
    const shadows = Array.isArray(value) ? value : [value];
    return shadows
      .map((s) => {
        if (!s || typeof s !== "object" || !("color" in s)) {
          die(`shadow token "${path}" layers must be {color, offsetX, offsetY, blur, spread}`);
        }
        const parts = [s.offsetX, s.offsetY, s.blur, s.spread]
          .filter((p) => p !== undefined)
          .map((p) => dim(p, path));
        return `${parts.join(" ")} ${s.color}`;
      })
      .join(", ");
  }
  if (type === "number") {
    if (typeof value !== "number") die(`number token "${path}" must be a number`);
    return String(value);
  }
  die(`token "${path}" has unsupported $type "${type}"`);
}

function varName(segments) {
  const leaf = segments[segments.length - 1];
  if (RESERVED.has(leaf) && REMAP_HEADS.has(segments[0])) {
    const head = segments.slice(0, -1);
    const remapped = `--${[...head, REMAP_PREFIX, leaf].join("-")}`;
    console.error(`tokens build: remapped reserved key "${segments.join(".")}" -> ${remapped}`);
    return remapped;
  }
  return `--${segments.join("-")}`;
}

function emitLines(tokens, byPath, stripHead) {
  const seen = new Set();
  return tokens.map((token) => {
    const path = token.segments.join(".");
    const { value, type } = resolveValue(token, byPath, new Set([path]));
    if (!type) die(`token "${path}" has no $type`);
    const nameSegments = stripHead ? token.segments.slice(1) : token.segments;
    const name = varName(nameSegments);
    if (seen.has(name)) {
      die(`duplicate emitted variable "${name}" (token "${path}" collides with an earlier token)`);
    }
    seen.add(name);
    return `  ${name}: ${formatValue(type, value, path)};`;
  });
}

function main() {
  let raw;
  try {
    raw = readFileSync(TOKENS_FILE, "utf8");
  } catch {
    die(`cannot read ${TOKENS_FILE}`);
  }
  let tokens;
  try {
    tokens = JSON.parse(raw);
  } catch (e) {
    die(`invalid JSON in ${TOKENS_FILE}: ${e.message}`);
  }

  const collected = collect(tokens, undefined, [], []);
  if (collected.length === 0) die("no tokens found");

  // Aliases resolve against the FULL tree (a dark token may reference a light
  // primitive); emission is split: dark.* becomes the override block.
  const byPath = new Map(collected.map((t) => [t.segments.join("."), t]));
  const lightTokens = collected.filter((t) => t.segments[0] !== "dark");
  const darkTokens = collected.filter((t) => t.segments[0] === "dark");

  const themeLines = emitLines(lightTokens, byPath, false);
  let css =
    `/* Generated from tokens.json by build.mjs — do not edit. */\n` +
    `@theme {\n${themeLines.join("\n")}\n}\n`;

  if (darkTokens.length > 0) {
    // Same var names as the light theme (head "dark" stripped), emitted as a
    // plain CSS override. Apps opt in by stamping data-theme="dark" on <html>
    // (and may add an @custom-variant for dark: utilities — docs/design-md.md).
    const darkLines = emitLines(darkTokens, byPath, true);
    css += `\n[data-theme="dark"] {\n${darkLines.join("\n")}\n}\n`;
  }

  writeFileSync(THEME_FILE, css);
  console.error(`tokens build: wrote ${THEME_FILE} (${collected.length} tokens)`);
}

main();
