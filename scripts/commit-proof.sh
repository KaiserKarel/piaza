#!/usr/bin/env bash
# Create ONE commit per crate review. This is a project invariant — the
# proof history has to be one-commit-per-proof so consumers can audit
# any individual review in isolation.
#
# Each commit bundles two files:
#   - the new/appended <id-hash>/reviews/<date>.proof.crev
#   - the review-logs/<name>/<version>/<harness>.log that produced it
#
# The harness is inferred from the currently-active cargo-crev identity
# (mapped through harnesses.toml). That keeps the script's interface
# minimal — callers don't need to thread the harness slug through.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <crate-name> <version>" >&2
    exit 2
fi

name=$1
version=$2
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

# Map currently-active crev ID -> harness slug via harnesses.toml.
current_id=$(cargo crev id current 2>/dev/null | awk '{print $1}')
if [[ -z "$current_id" ]]; then
    echo "error: no current cargo-crev identity" >&2
    exit 1
fi

slug=$(python3 - "$current_id" <<'PY'
import sys, tomllib
target = sys.argv[1]
with open("harnesses.toml", "rb") as f:
    cfg = tomllib.load(f)
for s, h in cfg.get("harnesses", {}).items():
    if h.get("id") == target:
        print(s)
        sys.exit(0)
sys.exit(f"error: no harness in harnesses.toml maps to current id {target!r}")
PY
)

log_file="review-logs/$name/$version/$slug.log"
if [[ ! -f "$log_file" ]]; then
    echo "error: expected review log not found at $log_file" >&2
    exit 1
fi

# Stage the proof tree (any id-hash) and the matching log file. We use
# explicit paths rather than `git add -A` so we never sweep up unrelated
# working-tree changes into a review commit.
shopt -s nullglob
proof_paths=( */reviews/*.proof.crev )
shopt -u nullglob
if [[ ${#proof_paths[@]} -eq 0 ]]; then
    echo "error: no .proof.crev files found under */reviews/" >&2
    exit 1
fi
git add -- "${proof_paths[@]}" "$log_file"

if git diff --cached --quiet; then
    echo "error: nothing staged for $name $version" >&2
    exit 1
fi

# Refuse to commit if the diff touches anything beyond exactly one proof
# file and one log file. That keeps the one-commit-per-proof invariant
# strict — any drift means something's wrong upstream.
changed=$(git diff --cached --name-only)
n_proofs=$(echo "$changed" | grep -c "^[^/]\+/reviews/.*\.proof\.crev$" || true)
n_logs=$(echo "$changed"   | grep -c "^review-logs/.*\.log$" || true)
n_total=$(echo "$changed"  | wc -l | tr -d ' ')
if [[ "$n_proofs" -ne 1 || "$n_logs" -ne 1 || "$n_total" -ne 2 ]]; then
    echo "error: expected exactly 1 proof + 1 log; got $n_proofs proofs, $n_logs logs, $n_total total" >&2
    echo "$changed" >&2
    exit 1
fi

# Pull the digest out of the new proof so the commit message records the
# exact source bytes that were reviewed. For crates.io sources the digest
# is what crev uses to identify the immutable artifact — closest analogue
# to a git hash for tarball-distributed code.
digest=$("$repo_root/scripts/list-reviewed.py" \
    | awk -F'\t' -v n="$name" -v v="$version" '$1==n && $2==v {print $3; exit}')

git commit -m "review $name $version ($slug)

source: crates.io
digest: ${digest:-unknown}
harness: $slug
"

echo "committed review of $name $version under $slug" >&2
