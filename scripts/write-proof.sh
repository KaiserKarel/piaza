#!/usr/bin/env bash
# Take a YAML review body prepared by Claude and let cargo-crev sign it
# into a real proof under proofs/.
#
# cargo-crev's `crate review` command is interactive — it spawns $EDITOR
# on a template that includes the package metadata it already knows about,
# then signs whatever the editor left behind. We weaponize that hook by
# setting EDITOR to a tiny script that overwrites the template with the
# review section Claude wrote, leaving the package: header intact.
#
# Requires:
#   - cargo-crev installed (see scripts/bootstrap.sh)
#   - a generated crev ID with its passphrase available in
#     $CREV_PASSPHRASE (cargo-crev reads it from stdin when unlocking)

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: $0 <crate-name> <version> <src-dir> <body-yaml-file>" >&2
    exit 2
fi

name=$1
version=$2
src_dir=$3
body_file=$4

if [[ ! -f "$body_file" ]]; then
    echo "error: review body not found at $body_file" >&2
    exit 1
fi

if [[ -z "${CREV_PASSPHRASE:-}" ]]; then
    echo "error: CREV_PASSPHRASE must be set so cargo-crev can unlock the ID" >&2
    exit 1
fi

# The EDITOR shim. cargo-crev calls $EDITOR <template-file>; we splice the
# review body into the template, replacing the placeholder review: block.
shim=$(mktemp -t crev-editor.XXXXXX.sh)
trap 'rm -f "$shim"' EXIT
cat >"$shim" <<EDITOR_SHIM
#!/usr/bin/env bash
set -euo pipefail
template=\$1
# cargo-crev's default template starts the body with the package: header and
# an empty review: block. We replace everything from the first 'review:' line
# onward with Claude's prepared body.
awk '
  BEGIN { keep = 1 }
  /^review:/ { keep = 0 }
  keep { print }
' "\$template" >"\$template.head"
cat "\$template.head" "$body_file" >"\$template"
rm -f "\$template.head"
EDITOR_SHIM
chmod +x "$shim"

# cargo-crev wants to run from a directory inside a Cargo workspace; the
# extracted crate source IS one. From there it can find the crate by name.
echo "$CREV_PASSPHRASE" | EDITOR="$shim" cargo crev crate review \
    --unrelated "$name" "$version" \
    --working-directory "$src_dir"

echo "proof written for $name $version" >&2
