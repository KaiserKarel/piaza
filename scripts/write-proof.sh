#!/usr/bin/env bash
# Sign a prepared review-body YAML into a cargo-crev proof and sync it
# into this repo's working tree.
#
# cargo-crev manages its own clone of the proof repo under
# `~/Library/Application Support/crev/proofs/<url-derived-dir>/` (or
# the XDG equivalent on Linux). When we ask it to write a proof, that's
# where the proof lands — NOT in our /Users/<you>/projects/piaza checkout.
# After signing, we rsync the freshly-written proof from that managed
# clone into our working tree so `commit-proof.sh` can commit and push.
#
# Why not symlink the managed clone to our working tree? cargo-crev
# performs git operations on its clone (fetch, branch tracking, etc.)
# and we don't want those side-effects mutating our working tree.
#
# Requires:
#   - cargo-crev installed and an ID generated (see scripts/bootstrap.sh)
#   - $CREV_PASSPHRASE in the environment (stdin-fed to cargo-crev to
#     unlock the signing key)

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: $0 <crate-name> <version> <src-dir> <body-yaml-file>" >&2
    exit 2
fi

name=$1
version=$2
src_dir=$3
body_file=$4

[[ -f "$body_file" ]] || { echo "error: review body not found at $body_file" >&2; exit 1; }
[[ -d "$src_dir" ]]   || { echo "error: src dir not found at $src_dir" >&2; exit 1; }
[[ -n "${CREV_PASSPHRASE:-}" ]] || {
    echo "error: CREV_PASSPHRASE not set; cargo-crev needs it to unlock the ID" >&2
    exit 1
}

repo_root=$(cd "$(dirname "$0")/.." && pwd)

# cargo-crev's `crate review` machinery requires a cargo project context
# to resolve the crate's metadata. The extracted crate source under
# .cache/src/ IS a real cargo project (it's the published crate), so
# we run from there with --unrelated to tell cargo-crev not to expect
# the crate in the workspace's dep graph.
cd "$src_dir"

# --import-unsigned-from reads the body we prepared (review section,
# issues, advisories) and merges it with the package metadata cargo-crev
# computes from the source. --no-edit skips the interactive editor.
# --no-commit suppresses cargo-crev's auto-commit; we do that ourselves
# so we control the message and enforce one-commit-per-proof.
echo "$CREV_PASSPHRASE" | cargo crev crate review \
    --unrelated \
    --no-edit \
    --no-commit \
    --import-unsigned-from "$body_file" \
    --vers "$version" \
    "$name"

# Locate cargo-crev's managed clone of this repo. The directory name is
# derived from the proof-repo URL plus a salt, so we glob for it rather
# than hard-code.
crev_data_dir=$(
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "$HOME/Library/Application Support/crev"
    else
        echo "${XDG_DATA_HOME:-$HOME/.local/share}/crev"
    fi
)
crev_clone=$(find "$crev_data_dir/proofs" -maxdepth 1 -type d -name "*piaza*" | head -1)
[[ -n "$crev_clone" ]] || {
    echo "error: cargo-crev's managed clone for this repo not found under $crev_data_dir/proofs/" >&2
    exit 1
}

id_hash=$(cargo crev id current | awk '{print $1}')
src_reviews_dir="$crev_clone/$id_hash/reviews"
[[ -d "$src_reviews_dir" ]] || {
    echo "error: cargo-crev didn't produce a reviews dir at $src_reviews_dir" >&2
    exit 1
}

# Mirror the entire reviews dir into our working tree. Idempotent: rsync
# only copies what changed. If a daily proof.crev was appended to today,
# our copy gets the appended version.
mkdir -p "$repo_root/$id_hash/reviews"
rsync -a "$src_reviews_dir/" "$repo_root/$id_hash/reviews/"

echo "proof written + synced for $name $version" >&2
