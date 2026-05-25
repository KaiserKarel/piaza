#!/usr/bin/env bash
# Driver for the review loop. Subcommands:
#
#   tick.sh enumerate
#       Print pending (name, version, checksum) lines — crates that appear
#       in any target's Cargo.lock but have no proof at all in any
#       <id-hash>/reviews/ tree yet.
#
#   tick.sh pending-count
#       Print just the count of pending crates.
#
#   tick.sh run <harness-slug> [batch-size]
#       The main entry point — invoked by cron / /schedule. Looks up the
#       harness in harnesses.toml, switches cargo-crev to its identity,
#       picks the top `batch-size` (default 5) pending crates, and spawns
#       `claude -p` per crate. Each per-crate review gets its own fresh
#       Claude context so state can't bleed between unrelated reviews.
#
# Requires for `run`:
#   - harnesses.toml entry for the slug
#   - $CREV_PASSPHRASE (or $CREV_PASSPHRASE_<UPPER_SLUG> as override)
#   - `cargo crev`, `claude` on PATH

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cmd=${1:-enumerate}

enumerate() {
    all=$(mktemp)
    reviewed=$(mktemp)
    trap 'rm -f "$all" "$reviewed"' RETURN

    "$repo_root/scripts/enumerate-targets.py" | sort -t$'\t' -k1,1 -k2,2 >"$all"
    # "Done" = anything we have a proof for, plus anything we've explicitly
    # decided not to review (skip.toml). Both should disappear from the
    # pending queue; the filter logic below joins on (name, version) so the
    # third column (digest or blank) is ignored.
    {
        "$repo_root/scripts/list-reviewed.py"
        "$repo_root/scripts/list-skipped.py"
    } | sort -u -t$'\t' -k1,1 -k2,2 >"$reviewed"

    # Lines in $all whose (name, version) prefix isn't already in $reviewed.
    # When $reviewed is empty, the NR==FNR awk-join idiom misbehaves (it
    # never sees a file-transition, so every row in the second file is
    # treated as "seen"). Guard on file size.
    if [[ -s "$reviewed" ]]; then
        awk -F'\t' '
            NR==FNR { seen[$1 "\t" $2] = 1; next }
            !($1 "\t" $2 in seen)
        ' "$reviewed" "$all"
    else
        cat "$all"
    fi
}

# Read three fields (model, review_command, id) for the given harness slug
# out of harnesses.toml. Emits one field per line on stdout. Exits non-zero
# if the slug isn't present.
read_harness() {
    local slug=$1
    python3 - "$slug" <<'PY'
import sys, tomllib
slug = sys.argv[1]
with open("harnesses.toml", "rb") as f:
    cfg = tomllib.load(f)
h = cfg.get("harnesses", {}).get(slug)
if not h:
    sys.exit(f"error: harness '{slug}' not found in harnesses.toml")
for k in ("model", "review_command", "id"):
    if k not in h:
        sys.exit(f"error: harness '{slug}' missing field '{k}'")
    print(h[k])
PY
}

# Resolve the right passphrase env var for a given harness slug. Allows a
# per-harness override (CREV_PASSPHRASE_<UPPER_SLUG_WITH_UNDERSCORES>) so
# different identities can have different passphrases; falls back to the
# shared CREV_PASSPHRASE.
resolve_passphrase() {
    local slug=$1
    # Slug "opus-4-7-default" -> env var "CREV_PASSPHRASE_OPUS_4_7_DEFAULT".
    local upper
    upper=$(echo "$slug" | tr '[:lower:]-' '[:upper:]_')
    local per_harness_var="CREV_PASSPHRASE_$upper"
    if [[ -n "${!per_harness_var:-}" ]]; then
        echo "${!per_harness_var}"
    elif [[ -n "${CREV_PASSPHRASE:-}" ]]; then
        echo "$CREV_PASSPHRASE"
    else
        return 1
    fi
}

case "$cmd" in
    enumerate)
        enumerate
        ;;

    pending-count)
        enumerate | wc -l | tr -d ' '
        ;;

    run)
        slug=${2:-}
        batch=${3:-5}
        if [[ -z "$slug" ]]; then
            echo "usage: $0 run <harness-slug> [batch-size]" >&2
            echo "  available harnesses:" >&2
            python3 -c "import tomllib; print('\n'.join(f'    {s}' for s in tomllib.load(open('harnesses.toml','rb')).get('harnesses',{})))" >&2
            exit 2
        fi
        if ! command -v claude >/dev/null 2>&1; then
            echo "error: claude CLI not on PATH" >&2
            exit 1
        fi

        cd "$repo_root"

        # Look up the harness and switch cargo-crev to its identity. We
        # do the switch up-front so write-proof.sh signs with the right
        # key for the whole batch.
        mapfile -t fields < <(read_harness "$slug")
        model=${fields[0]}
        review_command=${fields[1]}
        crev_id=${fields[2]}

        passphrase=$(resolve_passphrase "$slug") || {
            echo "error: no passphrase available for harness $slug" >&2
            echo "  set \$CREV_PASSPHRASE or \$CREV_PASSPHRASE_$(echo "$slug" | tr '[:lower:]-' '[:upper:]_')" >&2
            exit 1
        }

        echo "switching crev id to $crev_id (harness: $slug)" >&2
        echo "$passphrase" | cargo crev id switch "$crev_id" >/dev/null
        export CREV_PASSPHRASE="$passphrase"  # propagate to write-proof.sh

        run_id=$(date -u +%Y%m%dT%H%M%SZ)

        # `head -n` closes its input as soon as it has $batch lines, which
        # makes the upstream awk in enumerate() take SIGPIPE — and with
        # `set -o pipefail` (inherited from the top of this script) that
        # bubbles up as a failure of the whole `$()`. We want head's early
        # exit to be the success path, so disable pipefail just for this
        # subshell.
        pending=$(set +o pipefail; enumerate | head -n "$batch")
        if [[ -z "$pending" ]]; then
            echo "no pending crates — nothing to review" >&2
            exit 0
        fi

        echo "tick $run_id ($slug, model=$model) — reviewing up to $batch crates" >&2
        echo "$pending" | nl -ba -w2 -s'. ' >&2
        echo "---" >&2

        successes=0
        failures=0

        while IFS=$'\t' read -r name version _checksum; do
            [[ -z "$name" ]] && continue

            log_dir="$repo_root/review-logs/$name/$version"
            mkdir -p "$log_dir"
            log_file="$log_dir/$slug.log"
            started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

            # Markdown header up top — gives anyone auditing the proof
            # enough metadata to know which model+harness produced it
            # and when, without parsing the proof YAML.
            cat >"$log_file" <<EOF
# Review log: $name $version

- **Harness:** \`$slug\`
- **Model:** \`$model\`
- **Slash command:** \`$review_command $name $version\`
- **Started (UTC):** $started
- **Crev ID:** \`$crev_id\`

---

EOF

            echo "[$name $version] starting (log: ${log_file#$repo_root/})" >&2

            # </dev/null is load-bearing: without it, claude -p inherits
            # stdin from the surrounding `while read ... done <<<"$pending"`
            # heredoc and drains it after the first iteration, so the loop
            # silently runs only once.
            head_before=$(git rev-parse HEAD)
            claude_ok=0
            if claude -p "$review_command $name $version" \
                --model "$model" \
                --permission-mode bypassPermissions \
                --no-session-persistence \
                </dev/null >>"$log_file" 2>&1; then
                claude_ok=1
            else
                rc=$?
                echo "[$name $version] FAILED (rc=$rc); see ${log_file#$repo_root/}" >&2
            fi

            head_after=$(git rev-parse HEAD)
            if [[ "$claude_ok" == "1" && "$head_after" != "$head_before" ]]; then
                # Real success: claude completed AND a new commit landed.
                echo "[$name $version] OK ($(git rev-parse --short HEAD))" >&2
                successes=$((successes + 1))
                # commit-proof.sh staged + committed the log mid-session.
                # Claude often keeps writing post-commit chatter to stdout
                # (summary, follow-up questions). Discard that so the
                # working tree stays clean for the next iteration; the
                # substantive content is already in the commit.
                git checkout HEAD -- "$log_file"
            elif [[ "$claude_ok" == "1" ]]; then
                # Claude returned 0 but no new commit landed. Most common
                # cause: commit-proof.sh failed (signing broken, etc.) and
                # claude reported the failure narratively but still exited
                # cleanly. Treat as a failure so the operator can see it.
                echo "[$name $version] FAILED: no new commit despite claude exit=0; staged state may be dirty" >&2
                failures=$((failures + 1))
            else
                # Claude itself exited non-zero — already logged above.
                failures=$((failures + 1))
                # Leave the log on disk untouched so it captures the failure.
            fi
        done <<<"$pending"

        echo "---" >&2
        echo "tick $run_id complete: $successes ok, $failures failed" >&2
        if [[ "$failures" -gt 0 ]]; then
            exit 1
        fi
        ;;

    *)
        echo "usage: $0 {enumerate|pending-count|run <harness-slug> [batch-size]}" >&2
        exit 2
        ;;
esac
