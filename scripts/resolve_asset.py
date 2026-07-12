#!/usr/bin/env python3
"""Resolve the cargo-dist asset for a target triple from a dist-manifest.json.

Reads the manifest JSON on stdin. Prints two lines: the asset filename and its
checksum filename (empty if absent). Exits 1 if no artifact matches the triple.
Defensive across cargo-dist format epochs: iterates the `artifacts` map and
matches on `target_triples`, without assuming other structure.
"""
import json
import sys

def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: resolve_asset.py <target-triple>\n")
        return 2
    triple = sys.argv[1]
    manifest = json.load(sys.stdin)
    for name, art in (manifest.get("artifacts") or {}).items():
        if art.get("kind") != "executable-zip":
            continue
        if triple in (art.get("target_triples") or []):
            print(name)
            print(art.get("checksum") or "")
            return 0
    sys.stderr.write(f"no artifact for triple {triple}\n")
    return 1

if __name__ == "__main__":
    sys.exit(main())
