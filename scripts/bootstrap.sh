#!/usr/bin/env bash
# Bootstrap the reviewer infrastructure.
#
# Subcommands:
#   bootstrap.sh install
#       Install cargo-crev (idempotent). Safe to re-run.
#
#   bootstrap.sh add-harness <slug> <model> [<slash-command>]
#       Create a new cargo-crev identity dedicated to this (model, harness)
#       pair and append it to harnesses.toml. Slug convention is
#       `<model-alias>-<harness-name>` (e.g. opus-4-7-default), but the
#       tooling treats slugs as opaque. Slash command defaults to
#       /review-crate.
#
#       Will prompt for a passphrase. Pick a strong one and store it as
#       $CREV_PASSPHRASE (or $CREV_PASSPHRASE_<UPPER_SLUG_WITH_UNDERSCORES>
#       for per-harness passphrases). The scheduled agent needs it to sign.
#
# Re-running with the same slug is a no-op — bootstrap refuses to clobber
# an existing entry. Re-keying a harness is a deliberate, destructive
# operation we don't automate; do it by hand if you really need to.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

cmd=${1:-}

install_cargo_crev() {
    if ! command -v cargo >/dev/null 2>&1; then
        echo "error: cargo not on PATH. Install Rust first: https://rustup.rs" >&2
        exit 1
    fi
    if ! command -v cargo-crev >/dev/null 2>&1; then
        echo "installing cargo-crev (this builds from source — a few minutes)..."
        cargo install cargo-crev --locked
    else
        echo "cargo-crev already installed: $(cargo-crev --version 2>/dev/null || echo '?')"
    fi
}

case "$cmd" in
    install)
        install_cargo_crev
        ;;

    add-harness)
        slug=${2:-}
        model=${3:-}
        review_command=${4:-/review-crate}

        if [[ -z "$slug" || -z "$model" ]]; then
            echo "usage: $0 add-harness <slug> <model> [<slash-command>]" >&2
            echo "  example: $0 add-harness opus-4-7-default claude-opus-4-7" >&2
            exit 2
        fi

        install_cargo_crev

        # Resolve the proof-repo URL from `origin`. cargo-crev needs this
        # so the new ID is bound to the right published location.
        if ! url=$(git remote get-url origin 2>/dev/null); then
            echo "error: no 'origin' remote configured. Push the repo first." >&2
            exit 1
        fi

        # Reject duplicate slugs to keep harnesses.toml unambiguous.
        if grep -q "^\[harnesses\.${slug}\]" harnesses.toml 2>/dev/null; then
            echo "error: harness '$slug' already exists in harnesses.toml" >&2
            echo "  edit the file by hand if you really mean to re-key." >&2
            exit 1
        fi

        echo
        echo "Creating a new crev ID for harness: $slug"
        echo "  model:    $model"
        echo "  command:  $review_command"
        echo "  url:      $url"
        echo
        echo "You'll be prompted for a passphrase. Store it in your secret"
        echo "manager — the scheduled agent will read it from"
        echo "  \$CREV_PASSPHRASE   or"
        echo "  \$CREV_PASSPHRASE_$(echo "$slug" | tr '[:lower:]-' '[:upper:]_')"
        echo

        before_ids=$(mktemp)
        after_ids=$(mktemp)
        trap 'rm -f "$before_ids" "$after_ids"' EXIT
        cargo crev id list >"$before_ids" 2>/dev/null || true

        cargo crev id new --url "$url"

        cargo crev id list >"$after_ids" 2>/dev/null

        # Diff the id list to identify which hash is new. (cargo-crev's
        # `id current` switches to the new one after creation, but reading
        # `id current` is fragile if the user has additional unrelated ids.
        # The set-diff is unambiguous.)
        new_id=$(comm -13 <(sort "$before_ids") <(sort "$after_ids") | awk '{print $1}' | head -1)
        if [[ -z "$new_id" ]]; then
            echo "error: couldn't determine the new crev ID hash" >&2
            exit 1
        fi

        # Append the entry. Leading blank line keeps existing layout clean
        # when multiple harnesses get added sequentially.
        cat >>harnesses.toml <<EOF

[harnesses.${slug}]
model = "${model}"
review_command = "${review_command}"
id = "${new_id}"
EOF

        echo
        echo "added harness '$slug' with crev id $new_id"
        echo "wrote entry to harnesses.toml — commit it when ready."
        ;;

    *)
        cat <<EOF >&2
usage: $0 <subcommand>

subcommands:
  install                                          install cargo-crev
  add-harness <slug> <model> [<slash-command>]     create a new identity

example first-time setup:
  $0 install
  $0 add-harness opus-4-7-default claude-opus-4-7
EOF
        exit 2
        ;;
esac
