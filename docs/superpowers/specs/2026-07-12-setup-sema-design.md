# setup-sema — design spec

**Date:** 2026-07-12
**Status:** Approved design, pre-implementation
**Repo:** `sema-lisp/setup-sema` (its own repo; currently a loose draft in the workspace, not yet git-initialized as a member or registered in `repos.tsv`)

## Goal

Make `setup-sema` the best-in-class GitHub Action for installing the Sema
language in CI — the foundation the rest of a future Sema Actions family builds
on. It should feel to a user exactly like `actions/setup-node`: one line, correct
on every supported runner, fast on repeat runs, and secure by default.

A broader suite (fmt-check, test runner, notebook/LLM-eval, dependency cache) is
the north star but explicitly **out of scope here** — those will ship as
**separate repos** later. This spec covers `setup-sema` only.

## Non-goals (v1)

- Semver *range* matching (`1.x`, `>=1.2`). The action is a **hardened composite
  bash** action (decision below); real range resolution is painful in shell. v1
  supports `latest` + exact pins. Ranges are the primary trigger for a future
  TypeScript rewrite, not a v1 requirement.
- Sibling actions (lint/test/notebook-eval) and a reusable `workflow_call` CI
  workflow — separate repos, later.
- A Sema module/dependency cache action — later. But v1 emits a `cachekey`
  output so that future cache step has a ready-made key (see Outputs).

## Key decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Implementation | **Composite bash**, hardened | No node build step, no `dist/` to commit, fully auditable. Accepts weaker Windows-shell parity and no semver ranges as the cost. |
| Asset resolution | **Driven by `dist-manifest.json`**, not hardcoded names | Immune to cargo-dist epoch changes and the `.tar.xz` (unix) vs `.zip` (windows) split. Fixes all three bugs in the current draft. |
| Version input | `sema-version` (canonical), `version` accepted as alias | Matches the setup-* family convention; alias avoids breaking the current draft's `version`. |
| Version file | **Supported in v1**: `.sema-version`, `.tool-versions` | Lets a repo pin its Sema version in one place. Small extra bash; matches setup-node/deno. |
| Repo/Marketplace name | Keep **`setup-sema`** | The searched-for term; only the root `action.yml` gets a storefront anyway, so renaming to a `sema-actions` umbrella buys nothing for siblings. |

## Ground truth (real cargo-dist release assets)

From `gh release view --repo sema-lisp/sema` (tag `v1.30.0`), the release ships:

```
dist-manifest.json
sema-lang-<triple>.tar.xz          # unix: aarch64/x86_64 apple-darwin, aarch64/x86_64 linux-gnu
sema-lang-<triple>.tar.xz.sha256   # per-file checksum
sema-lang-x86_64-pc-windows-msvc.zip
sema-lang-x86_64-pc-windows-msvc.zip.sha256
sema-lang-installer.sh / .ps1      # cargo-dist installers
sema-lang.rb                       # homebrew formula
sha256.sum                         # unified checksum file
```

The current draft's three bugs, all fixed by manifest-driven resolution:
1. App prefix is **`sema-lang-`**, not `sema-`.
2. There is **no version** in the archive filename (`sema-lang-<triple>`, not
   `sema-<tag>-<triple>`).
3. Extension is **`.tar.xz`**, not `.tar.gz` — `tar -xzf` would fail; needs `tar --xz`/`-xJf`.

The **binary inside** the archive is `sema` (the binary target name; the Cargo
package is `sema-lang`). cargo-dist tarballs **nest all files under a single root
directory** named like the archive → extraction must use `tar --strip-components=1`.
The Windows `.zip` is flat (files at root) — no strip. This tar-vs-zip asymmetry
is matrix-tested (Section: Testing).

## Architecture

A single composite `action.yml` at repo root with two steps:

1. **Install Sema** (`id: install`, `shell: bash`) — the whole resolver.
2. **Verify installation** — `sema --version` (a smoke check that PATH works).

### Install step — algorithm

```
1. Resolve version
   - inputs: sema-version (or `version` alias); if unset/empty, read version file
     (.sema-version, then .tool-versions `sema <ver>` line) if present; else `latest`.
   - `latest`         → GitHub releases API `/releases/latest` → tag_name.
   - `1.30.0`/`v1.30.0` → normalize to tag `v1.30.0`.
   - Produces: TAG (v-prefixed) and VERSION (bare).

2. Map runner → target triple
   RUNNER_OS/RUNNER_ARCH → { Linux-X64: x86_64-unknown-linux-gnu, Linux-ARM64:
   aarch64-unknown-linux-gnu, macOS-X64: x86_64-apple-darwin, macOS-ARM64:
   aarch64-apple-darwin, Windows-X64: x86_64-pc-windows-msvc }. Unsupported → ::error + exit 1.

3. Tool-cache short-circuit
   INSTALL_DIR = $RUNNER_TOOL_CACHE/sema/$VERSION/$RUNNER_ARCH
   If $INSTALL_DIR/sema[.exe] exists AND check-latest is not forcing re-resolve → cache hit, skip to step 7.

4. Resolve the asset (dist-manifest-driven, with fallback)
   - If `download-url` input is set → use it verbatim (escape hatch: mirrors, air-gapped). Skip manifest.
   - Else fetch dist-manifest.json for TAG (release asset). Find the artifact whose
     `target_triples` contains our triple; read its exact `name` and, if present, its
     sha256 checksum. Build URL = releases/download/$TAG/<name>.
   - Fallback if manifest is unreachable/unparseable: construct the corrected
     hardcoded name `sema-lang-<triple>.<ext>` (ext = zip on windows, tar.xz else)
     and emit a ::warning that manifest resolution was skipped.

5. Download + verify
   - curl the asset (Authorization: Bearer token, --retry 3).
   - Checksum: prefer the sha256 from the manifest; else fetch `<name>.sha256`
     sidecar. Verify with sha256sum/shasum -c. Verification is MANDATORY when a
     checksum is available (releases do ship them); only a genuinely-absent
     checksum downgrades to a ::warning.

6. Extract
   - tar.xz → `tar --xz -xf <asset> -C $INSTALL_DIR --strip-components=1`
   - zip    → `unzip -q <asset> -d $INSTALL_DIR` (flat; no strip)
   - Defensive: if no `sema`/`sema.exe` at INSTALL_DIR root afterward, locate it
     one level down and flatten. chmod +x.

7. Expose to later steps
   - `$INSTALL_DIR >> $GITHUB_PATH`
   - set outputs: sema-version, sema-path, cache-hit, cachekey, download-url.
```

### `parse dist-manifest.json`

Use `python3` (present on all GitHub-hosted runners) for JSON parsing, matching
the draft's existing `python3 -c` approach — no `jq` dependency assumption. A
tiny inline script reads `artifacts` / `releases`, finds the artifact whose
`target_triples` includes our triple, and prints `name` + checksum. Reference the
`cargo-dist-schema` crate (`docs.rs/cargo-dist-schema`, root type `DistManifest`)
for the exact shape during implementation; guard against all three format epochs
by locating artifacts defensively (iterate `artifacts` map; match on
`target_triples`), and fall back (step 4) rather than hard-failing on shape drift.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `sema-version` | `latest` | `latest`, `1.30.0`, or `v1.30.0`. Canonical. |
| `version` | — | Deprecated alias for `sema-version`; used only if `sema-version` unset. |
| `check-latest` | `false` | If true, always re-resolve `latest` from the API instead of trusting a tool-cache hit. |
| `github-token` | GHES-aware default (below) | Auth for release API + asset download; avoids rate limits. |
| `download-url` | — | Escape hatch: download the archive from this exact URL, bypassing manifest/version resolution (mirrors, air-gapped CI). |

**Version-file behavior:** when neither `sema-version` nor `version` is provided,
read `.sema-version` (whole-file trimmed value), then a `sema <version>` line in
`.tool-versions`. If none found, default to `latest`.

**GHES-aware token default** (copied from setup-node):
`${{ github.server_url == 'https://github.com' && github.token || '' }}`.

## Outputs

| Output | Description |
| --- | --- |
| `sema-version` | Concrete installed version, e.g. `1.30.0`. |
| `sema-path` | Absolute path to the install dir added to PATH. |
| `cache-hit` | `true` if satisfied from the runner tool cache. |
| `cachekey` | A ready-made cache-key component (`sema-<version>-<triple>`) for a future dependency-cache step. |
| `download-url` | The resolved asset URL actually used (debugging + the Bun-style escape-hatch echo). |

`version` is retained as an output alias of `sema-version` for one major version
to avoid breaking the current draft's consumers.

## Error handling

- Unsupported `RUNNER_OS`/`RUNNER_ARCH` → `::error` + exit 1 (never silently
  install the wrong binary).
- Manifest unreachable → `::warning` + hardcoded-name fallback (do not hard-fail
  on a transient API/CDN hiccup).
- Checksum present but mismatched → hard fail (tamper/corruption).
- Checksum genuinely absent → `::warning`, proceed.
- `sema --version` verify step failing → job fails loudly (PATH/extract bug).
- `set -euo pipefail` throughout; every `curl` uses `--retry 3 -fsSL`.

## Testing (`.github/workflows/test.yml`)

Matrix `os × sema-version`, `fail-fast: false`:
- os: `ubuntu-latest`, `ubuntu-24.04-arm`, `macos-latest` (Apple Silicon),
  `macos-13` (Intel), `windows-latest`.
- sema-version: `latest`, and one pinned older version (e.g. `1.30.0`) for
  backward-compat coverage.

Assertions per cell:
1. Action runs from `./` (tests this repo's own action).
2. `steps.sema.outputs.sema-version` is non-empty and, for a pinned cell, equals
   the pin.
3. `sema --version` runs and its output contains the resolved version.
4. **Smoke-eval:** `echo '(println (+ 1 2))' > smoke.sema; sema smoke.sema` → `3`.
5. **Idempotent re-run:** invoke the action a second time in the same job and
   assert `cache-hit == true` (tool-cache path exercised).

Weekly `schedule` cron (Mon 06:00) so a new Sema release that changes asset shape
is caught before users hit it.

## Publishing

- **Marketplace listing:** the root `action.yml` (branding already `icon: code,
  color: green`). The action `name` ("Setup Sema") must be globally unique on the
  Marketplace — verify at publish time.
- **Moving `v1` major tag:** cut real releases `v1.0.0`, `v1.1.0`, …; after each,
  force-move `v1` (`git tag -fa v1 && git push origin v1 --force`), automated by a
  small release workflow. Users pin `@v1`.
- **README:** usage, inputs/outputs tables, supported runners, a CI example, and a
  **SHA-pinning security note** (tags are mutable; security-sensitive consumers
  pin the 40-char commit SHA; Dependabot understands SHA pins with a version
  comment).
- **v2** is reserved for input-breaking changes only.

## Workspace integration (implementation-plan steps, not spec substance)

Because `setup-sema` is currently a loose, gitignored draft:
1. Initialize it as its own git repo (done, to host this spec).
2. Create the `sema-lisp/setup-sema` GitHub remote and push.
3. Register it in the workspace `repos.tsv` (`setup-sema  setup-sema`).
4. (No Jakefile `@import` unless it grows a `@rooted` Jakefile.)

## Open questions

None blocking. Semver ranges + a TypeScript rewrite are the known future fork,
triggered by user demand, not required for v1.
