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

# Stage the proof tree (any id-hash), the matching log file, and any
# bug-reproduction files this review may have added under
# repros/<crate>/<version>/. We use explicit paths rather than
# `git add -A` so we never sweep up unrelated working-tree changes
# into a review commit.
shopt -s nullglob
proof_paths=( */reviews/*.proof.crev )
repro_paths=( repros/"$name"/"$version"/**/* )
shopt -u nullglob

if [[ ${#proof_paths[@]} -eq 0 ]]; then
    echo "error: no .proof.crev files found under */reviews/" >&2
    exit 1
fi
git add -- "${proof_paths[@]}" "$log_file" ${repro_paths[@]+"${repro_paths[@]}"}

if git diff --cached --quiet; then
    echo "error: nothing staged for $name $version" >&2
    exit 1
fi

# Allowlist the staged diff: exactly one proof, exactly one log, and any
# number of files under repros/<name>/<version>/. Anything else means
# the working tree has unrelated drift, which we refuse to commit.
changed=$(git diff --cached --name-only)
n_proofs=$(echo "$changed" | grep -c "^[^/]\+/reviews/.*\.proof\.crev$" || true)
n_logs=$(echo "$changed"   | grep -c "^review-logs/$name/$version/.*\.log$" || true)
# Files outside the expected prefixes — should be zero.
n_other=$(echo "$changed" | grep -vE \
    "^[^/]+/reviews/.*\.proof\.crev$|^review-logs/$name/$version/.*\.log$|^repros/$name/$version/" \
    | grep -c . || true)

# A single staged .proof.crev file can contain N new proof BLOCKS — the
# file-level count won't catch a previous failed review that left an
# orphan block behind. So count `BEGIN CREV PROOF` markers added in the
# staged diff and require exactly one. This is the load-bearing check.
n_proof_blocks=$(git diff --cached -- "*/reviews/*.proof.crev" \
    | grep -c "^+----- BEGIN CREV PROOF -----$" || true)

if [[ "$n_proofs" -ne 1 || "$n_logs" -ne 1 || "$n_other" -ne 0 || "$n_proof_blocks" -ne 1 ]]; then
    echo "error: staged diff doesn't match expected shape" >&2
    echo "       expected: 1 proof file + 1 proof block + 1 log + 0+ repros" >&2
    echo "       got:      $n_proofs proof files, $n_proof_blocks proof blocks, $n_logs logs, $n_other other" >&2
    echo "$changed" >&2
    if [[ "$n_proof_blocks" -gt 1 ]]; then
        echo "       -> the proof file has orphan blocks from a previous failed review." >&2
        echo "          run \`git checkout HEAD -- */reviews/*.proof.crev\` to drop them," >&2
        echo "          then retry." >&2
    fi
    exit 1
fi

# Pull the digest out of the new proof so the commit message records the
# exact source bytes that were reviewed. For crates.io sources the digest
# is what crev uses to identify the immutable artifact — closest analogue
# to a git hash for tarball-distributed code.
digest=$("$repo_root/scripts/list-reviewed.py" \
    | awk -F'\t' -v n="$name" -v v="$version" '$1==n && $2==v {print $3; exit}')

# Retry the commit on transient signing failures (the 1Password SSH agent
# is the usual culprit during unattended ticks — it sometimes drops the
# socket connection and recovers a few seconds later). We retry up to 3
# times, waiting 5s between attempts. Non-signing failures fall through
# on the first try.
commit_msg="review $name $version ($slug)

source: crates.io
digest: ${digest:-unknown}
harness: $slug
"
attempt=1
while true; do
    if git commit -m "$commit_msg" 2>/tmp/commit-stderr.$$; then
        rm -f /tmp/commit-stderr.$$
        break
    fi
    err=$(cat /tmp/commit-stderr.$$)
    rm -f /tmp/commit-stderr.$$
    # Only retry on signing-agent failures; fail fast on everything else.
    if ! echo "$err" | grep -qE "1Password|gpg failed|signing failed|gpg.program|ssh-keygen"; then
        echo "$err" >&2
        echo "error: git commit failed for non-signing reason; not retrying." >&2
        exit 1
    fi
    if [[ "$attempt" -ge 3 ]]; then
        echo "$err" >&2
        echo "error: git commit failed after $attempt signing-related retries." >&2
        exit 1
    fi
    echo "  signing attempt $attempt failed; retrying in 5s..." >&2
    sleep 5
    attempt=$((attempt + 1))
done

echo "committed review of $name $version under $slug" >&2
