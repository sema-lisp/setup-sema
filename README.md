<div align="center">

<img src="https://sema-lang.com/logo.svg" alt="Sema" height="64">

# Setup Sema

**[Sema](https://sema-lang.com) setup action for GitHub Actions** — a Lisp with first-class LLM primitives.

[![CI](https://img.shields.io/github/actions/workflow/status/sema-lisp/setup-sema/test.yml?branch=main&label=CI&logo=github)](https://github.com/sema-lisp/setup-sema/actions)
[![License](https://img.shields.io/github/license/sema-lisp/setup-sema?color=c8a855)](LICENSE)
[![Website](https://img.shields.io/badge/website-sema--lang.com-c8a855)](https://sema-lang.com)
[![Marketplace](https://img.shields.io/badge/marketplace-setup--sema-c8a855?logo=githubactions&logoColor=white)](https://github.com/marketplace/actions/setup-sema)

</div>

Install [Sema](https://sema-lang.com) in your GitHub Actions workflow — cross-platform, checksum-verified, and tool-cached.

## Usage

```yaml
steps:
  - uses: sema-lisp/setup-sema@v1
  - run: sema my-script.sema
```

Pin a version:

```yaml
  - uses: sema-lisp/setup-sema@v1
    with:
      sema-version: "1.30.0"
```

## Version

The version is resolved in this order, stopping at the first that yields a value:

1. the `sema-version` input,
2. the deprecated `version` input,
3. a **`.sema-version`** file at the repo root (a bare version, e.g. `1.30.0`),
4. a **`.tool-versions`** file (asdf/mise) with a `sema <version>` line,
5. `latest` — the newest GitHub release.

So you can pin once in a file and call the action with no inputs:

```yaml
  - uses: sema-lisp/setup-sema@v1        # reads .sema-version / .tool-versions
```

```
# .sema-version
1.30.0
```

```
# .tool-versions
sema 1.30.0
```

Only plain versions (`1.30.0`, `v1.30.0`) are supported in version files — ranges and `ref:` specifiers are not.

## Inputs

| Input          | Default        | Description                                                                                                   |
| -------------- | -------------- | ------------------------------------------------------------------------------------------------------------ |
| `sema-version` | *(empty)*      | `latest`, `1.30.0`, or `v1.30.0`. When empty, falls back to `.sema-version` / `.tool-versions`, then `latest`. |
| `version`      | *(empty)*      | **Deprecated** alias for `sema-version` (removed in v2).                                                       |
| `github-token` | repo token     | Token for release **API** calls (avoids rate limits). Never sent to asset downloads.                          |
| `download-url` | *(empty)*      | Escape hatch: install this exact archive URL (mirrors, air-gapped CI). See [Security](#security--pinning).    |
| `verify`       | `true`         | Run `sema --version` after install to confirm the binary executes. Set `false` for cross-arch/container jobs. |

## Outputs

| Output         | Description                                                                        |
| -------------- | --------------------------------------------------------------------------------- |
| `sema-version` | Concrete version installed, e.g. `1.30.0` (or `custom` for a `download-url` with no version in it). |
| `sema-path`    | Absolute path added to `PATH`.                                                     |
| `cache-hit`    | `true` if served from the runner tool cache.                                       |
| `cache-key`    | Cache-key component (`sema-<version>-<triple>`) for a downstream dependency cache. |
| `download-url` | Asset URL actually used, or `cache` on a tool-cache hit.                           |
| `version`      | Deprecated alias of `sema-version`.                                               |

## Examples

Run tests on every push:

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: sema-lisp/setup-sema@v1
      - run: sema test.sema
```

Across every supported OS and architecture:

```yaml
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, ubuntu-24.04-arm, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: sema-lisp/setup-sema@v1
      - run: sema test.sema
```

## How it works

1. **Resolve** the version (input → version file → `latest` via the releases API) and validate it (rejects anything that isn't a plain version — see [Security](#security--pinning)).
2. **Map** the runner to a Rust target triple.
3. **Tool cache** — if `sema <version>` is already cached for this runner, use it and stop.
4. **Resolve the asset** from the release's cargo-dist `dist-manifest.json` (with a hardcoded-name fallback if the manifest is unreachable).
5. **Download** the archive and **verify** its SHA-256 (fail-closed — see below).
6. **Extract**, locate the `sema` binary, and populate the tool cache atomically.
7. **Expose** it — append to `PATH` and set the [outputs](#outputs).

## Supported platforms

| Runner OS / arch      | Target triple                  |
| --------------------- | ------------------------------ |
| Linux x64             | `x86_64-unknown-linux-gnu`     |
| Linux arm64           | `aarch64-unknown-linux-gnu`    |
| macOS arm64 (Apple)   | `aarch64-apple-darwin`         |
| macOS x64 (Intel)     | `x86_64-apple-darwin`          |
| Windows x64           | `x86_64-pc-windows-msvc`       |

Requires **Python 3** on `PATH` (present on all GitHub-hosted runners; install it on minimal self-hosted/container runners).

## Caching

Installs land in the runner tool cache at `RUNNER_TOOL_CACHE/sema/<version>/<arch>`. A second run for the same version is a cache hit (no download) and sets `cache-hit: true`. `latest` still calls the API each run to resolve the concrete version, then reuses the cached binary if that version is already present.

## Security & pinning

- **Checksum verification is mandatory and fail-closed.** Every release download is verified against its published `.sha256`; a mismatch, a missing checksum for a known target, or a failed checksum fetch **aborts** the install. The only exception is the `download-url` escape hatch, which verifies against `<url>.sha256` when present and otherwise installs unverified — you own that URL's trust.
- **Version strings are validated** before building any URL, so a `.sema-version` / `.tool-versions` file in an untrusted PR checkout cannot steer the download to another repository (path traversal).
- **The token is only sent to `api.github.com`**, never to asset downloads, so it can't leak to a redirect target.
- **Pinning:** `@v1` tracks the latest `v1.x`. For a fully reproducible, tamper-proof pin, use the commit SHA:

  ```yaml
    - uses: sema-lisp/setup-sema@<40-char-sha>  # v1.2.3
  ```

  Dependabot understands SHA pins with a trailing version comment. Avoid `@main`.

## Troubleshooting

| Message | Cause / fix |
| --- | --- |
| `python3 (or python) is required` | Install Python 3 on the runner (self-hosted/container). |
| `Refusing unsafe/malformed Sema version` | The requested version (or a `.sema-version`/`.tool-versions` entry) isn't a plain version like `1.30.0`. |
| `Failed to download … does Sema version 'X' exist?` | The pinned version has no release/asset for this platform. |
| `No checksum published … refusing to install unverified` | Transient GitHub Releases/network issue — re-run; or the release is missing its `.sha256`. |
| `Unsupported platform` | The runner OS/arch isn't in the [table above](#supported-platforms). |

## Links

- **Website** — [sema-lang.com](https://sema-lang.com)
- **Playground** — [sema.run](https://sema.run)
- **Documentation** — [sema-lang.com/docs](https://sema-lang.com/docs)
- **Language & tooling** — [github.com/sema-lisp](https://github.com/sema-lisp)

## License

[MIT](LICENSE) © [Helge Sverre](https://github.com/HelgeSverre)
