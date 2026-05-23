#!/usr/bin/env python3
"""Emit `name<TAB>version<TAB>digest` for every existing package-review proof.

This is the source of truth for "is crate X@Y already reviewed?". We walk
`proofs/` (the cargo-crev proof tree) and parse each `*.proofs.crev` file.

A proofs.crev file is a sequence of blocks framed like:

    -----BEGIN CREV PACKAGE REVIEW-----
    <yaml body>
    -----BEGIN CREV PACKAGE REVIEW SIGNATURE-----
    <signature>
    -----END CREV PACKAGE REVIEW-----

We extract each YAML body and pull out the `package:` block's name, version,
and digest. We do NOT verify signatures here — that's `cargo crev verify`'s
job. We just need the inventory.

We avoid PyYAML so the bootstrap stays "stdlib only". The cargo-crev proof
format is stable enough that a small targeted parser is fine.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROOFS_DIR = REPO_ROOT / "proofs"

BODY_RE = re.compile(
    r"-----BEGIN CREV PACKAGE REVIEW-----\n(.*?)\n-----BEGIN CREV PACKAGE REVIEW SIGNATURE-----",
    re.DOTALL,
)


def extract_pkg_field(body: str, field: str) -> str | None:
    """Pull `<field>: <value>` from inside the indented `package:` block.

    The proof YAML structure is:
        package:
          source: "..."
          name: foo
          version: 1.2.3
          digest: AbCdEf...
    We just need name/version/digest under that one block. A naive global
    grep would also match e.g. `name` under `from:`, so we anchor on the
    `package:` line and stop at the next top-level key.
    """
    in_pkg = False
    for line in body.splitlines():
        if line.rstrip() == "package:":
            in_pkg = True
            continue
        if in_pkg:
            if line and not line.startswith((" ", "\t")):
                break  # left the package: block
            stripped = line.strip()
            if stripped.startswith(f"{field}:"):
                value = stripped[len(field) + 1 :].strip()
                # Strip surrounding quotes if present.
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                return value
    return None


def main() -> int:
    if not PROOFS_DIR.exists():
        return 0  # no proofs yet, nothing to emit
    seen: set[tuple[str, str, str]] = set()
    for proof_file in PROOFS_DIR.rglob("*.proofs.crev"):
        text = proof_file.read_text(encoding="utf-8", errors="replace")
        for match in BODY_RE.finditer(text):
            body = match.group(1)
            name = extract_pkg_field(body, "name")
            version = extract_pkg_field(body, "version")
            digest = extract_pkg_field(body, "digest") or ""
            if name and version:
                seen.add((name, version, digest))
    for name, version, digest in sorted(seen):
        print(f"{name}\t{version}\t{digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
