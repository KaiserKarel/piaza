#!/usr/bin/env bash
# Create ONE commit per crate review. This is a project invariant — the
# proofs/ history has to be one-commit-per-proof so consumers can audit
# any individual review in isolation.
#
# We expect exactly one new/modified .proofs.crev file when called.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <crate-name> <version>" >&2
    exit 2
fi

name=$1
version=$2
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

# Stage only proof changes — never sweep up other unrelated changes into a
# review commit. `git add -A proofs/` is bounded to that subtree.
git add -A proofs/

if git diff --cached --quiet; then
    echo "error: no proof changes staged for $name $version" >&2
    exit 1
fi

# Refuse to commit if the diff touches more than one proof. That would
# break the one-commit-per-proof invariant.
changed_files=$(git diff --cached --name-only | wc -l | tr -d ' ')
if [[ "$changed_files" -gt 1 ]]; then
    echo "error: $changed_files files staged; expected 1 proof file. Aborting." >&2
    git diff --cached --name-only >&2
    exit 1
fi

# Pull the digest out of the new proof so the commit message records the
# exact source bytes that were reviewed. For crates.io sources the digest
# is what crev uses to identify the immutable artifact — closest analogue
# to a git hash for tarball-distributed code.
digest=$("$repo_root/scripts/list-reviewed.py" | awk -F'\t' -v n="$name" -v v="$version" '$1==n && $2==v {print $3; exit}')

git commit -m "review $name $version

source: crates.io
digest: ${digest:-unknown}
"

echo "committed review of $name $version" >&2
