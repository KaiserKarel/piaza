#!/usr/bin/env bash
# One-time bootstrap. Run once on the operator's machine; the resulting
# crev ID + passphrase are then used by the scheduled agent.
#
# What this does:
#   1. Sanity-checks that cargo is available and installs cargo-crev.
#   2. Creates a fresh crev ID dedicated to this project, with this repo
#      as the proof-repo URL.
#   3. Prints next steps so you can wire up the scheduled agent.
#
# What this does NOT do:
#   - Push to a remote (you do that once you've reviewed the layout).
#   - Configure any scheduler (see README "Scheduling").

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not on PATH. Install Rust first: https://rustup.rs" >&2
    exit 1
fi

if ! command -v cargo-crev >/dev/null 2>&1; then
    echo "installing cargo-crev (this builds from source — a few minutes)..."
    cargo install cargo-crev --locked
fi

# Read the repo URL — this is what other people will use to fetch our
# proofs via `cargo crev repo fetch url ...`. If the operator hasn't
# pushed yet they can pass it as an argument or accept the placeholder
# and update it later in ~/.config/crev/.
url=${1:-}
if [[ -z "$url" ]]; then
    # Try to infer from git remote.
    if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
        url=$(git -C "$repo_root" remote get-url origin)
    fi
fi
if [[ -z "$url" ]]; then
    echo "error: no proof-repo URL given and no 'origin' remote configured." >&2
    echo "usage: $0 <https-url-of-this-repo>" >&2
    exit 1
fi

echo
echo "Creating a new crev ID for proof repo: $url"
echo "You'll be prompted for a passphrase. Pick something strong and save"
echo "it in your secret manager — the scheduled agent will need it via"
echo "the CREV_PASSPHRASE environment variable to sign reviews."
echo
cargo crev id new --url "$url"

echo
echo "=========================================================================="
echo "Bootstrap complete. Next steps:"
echo
echo "  1. Verify your ID:"
echo "       cargo crev id current"
echo
echo "  2. Push this repo to its remote so others can fetch the proofs:"
echo "       git push -u origin main"
echo
echo "  3. Store the passphrase you just set as a secret. The scheduled"
echo "     agent reads it from \$CREV_PASSPHRASE. Locally you can export"
echo "     it before running scripts/tick.sh."
echo
echo "  4. Set up the recurring agent — see README.md \"Scheduling\"."
echo "=========================================================================="
