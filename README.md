# setup-sema

Install [Sema](https://sema-lang.com) — a Lisp with first-class LLM primitives — in your GitHub Actions workflow.

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

Or pin the version in a `.sema-version` file at your repo root and just call the action with no inputs.

## Inputs

| Input          | Default            | Description                                              |
| -------------- | ------------------ | -------------------------------------------------------- |
| `sema-version` | `latest`           | `latest`, `1.30.0`, or `v1.30.0`. Falls back to `.sema-version` / `.tool-versions` when set to `""`. |
| `version`      | —                  | Deprecated alias for `sema-version`.                     |
| `check-latest` | `false`            | Reserved; `latest` is always re-resolved in this action. |
| `github-token` | repo token         | Token for release API + downloads (avoids rate limits).  |
| `download-url` | —                  | Escape hatch: install from this exact archive URL (mirrors, air-gapped CI). Bypasses version/manifest resolution **and checksum verification** — you own the URL's trust. |

## Outputs

| Output         | Description                                          |
| -------------- | --------------------------------------------------- |
| `sema-version` | Concrete version installed, e.g. `1.30.0`.          |
| `sema-path`    | Absolute path added to `PATH`.                      |
| `cache-hit`    | `true` if served from the runner tool cache.        |
| `cachekey`     | Cache-key component for a downstream dependency cache. |
| `download-url` | Asset URL actually used (or `cache`).               |

## Supported runners

Linux x64/arm64, macOS x64/arm64 (Intel + Apple Silicon), Windows x64.

## Example: run tests on every push

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

## Security: pinning

`@v1` tracks the latest `v1.x`. For a fully reproducible, tamper-proof pin, use the commit SHA:

```yaml
  - uses: sema-lisp/setup-sema@<40-char-sha>  # v1.2.3
```

Dependabot understands SHA pins with a trailing version comment.

## License

MIT
