#!/usr/bin/env bash
# Download a crate's source tarball from crates.io and extract it.
#
# Crucially this does NOT invoke cargo at any point — we only download
# the .crate file (a tar.gz of the published source) and extract it. No
# build.rs, no proc-macros, no resolver run.
#
# Outputs the extracted source directory path as the LAST line on stdout.
# All progress messages go to stderr so callers can capture stdout cleanly.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <crate-name> <version>" >&2
    exit 2
fi

name=$1
version=$2
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cache_dir="$repo_root/.cache/src"
mkdir -p "$cache_dir"

src_dir="$cache_dir/${name}-${version}"
if [[ -d "$src_dir" ]]; then
    echo "cached: $src_dir" >&2
    echo "$src_dir"
    exit 0
fi

# crates.io serves .crate files (tar.gz) at this canonical URL. The 302
# redirect goes to a CDN; curl -L follows it.
url="https://crates.io/api/v1/crates/${name}/${version}/download"
tmp_tarball=$(mktemp -t "crate-${name}-${version}.XXXXXX.tar.gz")
trap 'rm -f "$tmp_tarball"' EXIT

echo "downloading $url" >&2
curl --silent --show-error --fail --location \
     --user-agent "piaza-reviewer/0.1" \
     --output "$tmp_tarball" \
     "$url"

# Tarballs unpack into a top-level `<name>-<version>/` directory by convention,
# matching the cache layout we want. Extract into the cache dir.
tar -xzf "$tmp_tarball" -C "$cache_dir"

if [[ ! -d "$src_dir" ]]; then
    # Some older crates use slightly different top-level names. Locate
    # whatever directory the tarball created and rename it.
    extracted=$(tar -tzf "$tmp_tarball" | head -1 | cut -d/ -f1)
    if [[ -n "$extracted" && -d "$cache_dir/$extracted" && "$extracted" != "${name}-${version}" ]]; then
        mv "$cache_dir/$extracted" "$src_dir"
    fi
fi

if [[ ! -d "$src_dir" ]]; then
    echo "error: extracted source dir not found at $src_dir" >&2
    exit 1
fi

echo "extracted to $src_dir" >&2
echo "$src_dir"
