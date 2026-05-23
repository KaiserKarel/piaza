#!/usr/bin/env bash
# Exit 0 and print the matching proof file path if (name, version) is
# already reviewed in this repo's proofs/ tree. Exit 1 otherwise.
#
# Source of truth is the YAML in proofs/ — not git log, not a sidecar
# index. If a proof file exists, we consider it reviewed.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <crate-name> <version>" >&2
    exit 2
fi

name=$1
version=$2
repo_root=$(cd "$(dirname "$0")/.." && pwd)

# Re-parse via list-reviewed.py so we use the same authoritative parser.
match=$("$repo_root/scripts/list-reviewed.py" | awk -F'\t' -v n="$name" -v v="$version" '$1==n && $2==v {print; exit}')

if [[ -n "$match" ]]; then
    echo "$match"
    exit 0
fi
exit 1
