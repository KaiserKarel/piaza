#!/usr/bin/env bash
# Driver for the review loop. Two subcommands:
#
#   tick.sh enumerate
#       Print pending (name, version, checksum) lines — crates that appear
#       in any target's Cargo.lock but have no proof in proofs/ yet. Output
#       is sorted deterministically.
#
#   tick.sh pending-count
#       Print just the count of pending crates. Useful for monitoring.
#
# The actual review work is driven by Claude via the /review-tick slash
# command, which calls `tick.sh enumerate` then invokes /review-crate per
# row. We don't shell out to Claude from here — keeping the bash side
# pure-data makes it easy to test and easy to swap reviewers later.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cmd=${1:-enumerate}

case "$cmd" in
    enumerate)
        # `comm` needs both inputs sorted on the same key. Our scripts
        # already sort lexicographically on the full line, and the (name,
        # version) prefix matches between enumerate and list-reviewed, so
        # a join on (name, version) works.
        all=$(mktemp)
        reviewed=$(mktemp)
        trap 'rm -f "$all" "$reviewed"' EXIT

        "$repo_root/scripts/enumerate-targets.py" | sort -t$'\t' -k1,1 -k2,2 >"$all"
        "$repo_root/scripts/list-reviewed.py"    | sort -t$'\t' -k1,1 -k2,2 >"$reviewed"

        # Lines in $all whose (name, version) prefix isn't already in $reviewed.
        # When $reviewed is empty, the NR==FNR awk-join idiom misbehaves
        # (it never sees a file-transition, so every row in the second file
        # is treated as "seen"). Guard on file size.
        if [[ -s "$reviewed" ]]; then
            awk -F'\t' '
                NR==FNR { seen[$1 "\t" $2] = 1; next }
                !($1 "\t" $2 in seen)
            ' "$reviewed" "$all"
        else
            cat "$all"
        fi
        ;;

    pending-count)
        "$0" enumerate | wc -l | tr -d ' '
        ;;

    *)
        echo "usage: $0 {enumerate|pending-count}" >&2
        exit 2
        ;;
esac
