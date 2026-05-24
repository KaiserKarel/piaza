#!/usr/bin/env python3
"""Emit `name<TAB>version<TAB>digest` for every existing package-review proof.

This is the source of truth for "is crate X@Y already reviewed?". We glob
`<id-hash>/reviews/*.proof.crev` at the repo root — cargo-crev's layout
puts proofs under a per-reviewer-identity directory at the repo root, not
under a `proofs/` subdir.

A proof.crev file is a sequence of blocks framed like:

    ----- BEGIN CREV PROOF -----
    kind: package review
    <yaml body>
    ----- SIGN CREV PROOF -----
    <signature>
    ----- END CREV PROOF -----

Multiple proof kinds share the same framing (trust proofs, package
reviews, advisories), so we filter to `kind: package review` before
extracting fields. We DO NOT verify signatures — that's
`cargo crev verify`'s job. We just need the inventory.

We avoid PyYAML so the bootstrap stays "stdlib only". The cargo-crev
proof format is stable enough that a small targeted parser is fine.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
# cargo-crev stores proofs as <id-hash>/reviews/<date>.proof.crev at the
# repo root. We don't know the id-hash ahead of time (it varies per
# reviewer identity), so glob for it.
PROOFS_GLOB = "*/reviews/*.proof.crev"

# `\s*` tolerates any whitespace variations around BEGIN/SIGN; cargo-crev
# emits exactly one space on each side today, but the spec doesn't pin it.
BODY_RE = re.compile(
    r"-----\s*BEGIN CREV PROOF\s*-----\n(.*?)\n-----\s*SIGN CREV PROOF\s*-----",
    re.DOTALL,
)
KIND_RE = re.compile(r"^kind:\s*package review\s*$", re.MULTILINE)


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
    seen: set[tuple[str, str, str]] = set()
    for proof_file in REPO_ROOT.glob(PROOFS_GLOB):
        text = proof_file.read_text(encoding="utf-8", errors="replace")
        for match in BODY_RE.finditer(text):
            body = match.group(1)
            # Skip non-package-review proofs (trust, advisory, etc.).
            if not KIND_RE.search(body):
                continue
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
