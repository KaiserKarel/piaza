#!/usr/bin/env python3
"""Emit `name<TAB>version` for every entry in skip.toml.

Mirrors the output shape of list-reviewed.py (minus the digest column,
which we don't have for an unreviewed crate). tick.sh's enumerate
function unions reviewed-and-skipped before computing pending, so a
skip entry hides the crate from the queue exactly the way a real proof
would.
"""
import sys
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SKIP_PATH = REPO_ROOT / "skip.toml"


def main() -> int:
    if not SKIP_PATH.exists():
        return 0
    with SKIP_PATH.open("rb") as f:
        cfg = tomllib.load(f)
    rows: set[tuple[str, str]] = set()
    for entry in cfg.get("skip", []):
        name = entry.get("name")
        version = entry.get("version")
        if not name or not version:
            print(f"warning: skip entry missing name/version: {entry}", file=sys.stderr)
            continue
        rows.add((name, version))
    for name, version in sorted(rows):
        # Trailing empty digest field keeps the column shape consistent with
        # list-reviewed.py — tick.sh joins on (name, version) so the third
        # column is ignored, but downstream consumers shouldn't choke.
        print(f"{name}\t{version}\t")
    return 0


if __name__ == "__main__":
    sys.exit(main())
