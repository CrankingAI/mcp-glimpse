# Versioning

One file is the single source of truth for the application version. Everything else
is derived from it — never edited by hand.

## VERSION vs SEED_KIT_VERSION

Two version files live at the repo root. They mean different things and must never be
confused.

| File | Means | Bumped by |
|---|---|---|
| `VERSION` | This **application's** version (semver `MAJOR.MINOR.PATCH`) | `./scripts/bump-version.sh` |
| `SEED_KIT_VERSION` | Which **seed-kit tag** this repo was vendored from (`DevPartners/meta-agent-md@<tag>`) | the re-seed/sync process, not app releases |

`VERSION` tracks *your code*. `SEED_KIT_VERSION` tracks *the conventions you copied
in*, so a later reconcile knows the baseline to 3-way merge against. They move
independently. Do not derive anything from `SEED_KIT_VERSION`.

## VERSION is the single source

`VERSION` contains a bare semver string and nothing else:

```text
1.4.2
```

Everything downstream derives from it at build time:

- **.NET assembly properties** — `Version` / `AssemblyVersion` / `FileVersion` /
  `InformationalVersion` are read from `VERSION` in `Directory.Build.props` (never
  literal numbers in `.csproj`).
- **`package.json`** — the JS `version` field is synced from `VERSION`, not edited.
- **`/version` endpoint** — every backend serves the same string at `/version`, so a
  deployed instance can be asked what it is running.

Editing `VERSION` is the only way to change the version. Hand-editing any derived
location is a bug.

## Bumping

```text
./scripts/bump-version.sh patch   # 1.4.2 -> 1.4.3
./scripts/bump-version.sh minor   # 1.4.2 -> 1.5.0
./scripts/bump-version.sh major   # 1.4.2 -> 2.0.0
```

The script rewrites `VERSION`, leaving the derived artifacts to pick it up at build.
It follows the [scripts conventions](scripts.md) (`-h`/`--help`, fail-fast).

## Releases and tags

A release is a git tag `v<VERSION>` (e.g. `v1.4.2`). The tag-push triggers the deploy
pipeline (see [deployment](deployment.md)). The deployed bits, the `/version` endpoint,
and the tag must all agree — a tag that doesn't match the built bits is a release bug.

## How to wire and verify it

Do not reinvent the plumbing:

- **version-source-of-truth** — establishes the `VERSION` → assembly props /
  `package.json` / `/version` derivation and the `bump-version.sh` script.
- **tag-version-bits-alignment** — verifies the git tag, `VERSION`, and the
  actually-deployed `/version` are aligned, catching drift between what was tagged and
  what shipped.
