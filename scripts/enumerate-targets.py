#!/usr/bin/env python3
"""Resolve targets.toml -> sorted list of (name, version, checksum).

For each `[[target]]`:
  - `lockfile = "<url>"`  : HTTP-fetch the Cargo.lock and parse it.
  - `git = "<url>"` + `ref` : shallow-clone the repo, run
    `cargo generate-lockfile`, then parse the materialized Cargo.lock.

`cargo generate-lockfile` resolves the dependency graph by reading Cargo.toml
files (the target's, and each dependency's manifest from the registry index).
It does NOT compile anything and does NOT run build.rs or proc-macros — safe
to invoke inside our review pipeline.

Output: one TSV line per unique crates.io package across all targets,
sorted by (name, version). Workspace-internal crates (no `source` field)
and non-crates.io sources (git, path, alternate registries) are skipped.
"""
import shutil
import subprocess
import sys
import tomllib
import urllib.request
from pathlib import Path

CRATES_IO_SOURCE = "registry+https://github.com/rust-lang/crates.io-index"
REPO_ROOT = Path(__file__).resolve().parent.parent
TARGETS_PATH = REPO_ROOT / "targets.toml"
REPOS_CACHE = REPO_ROOT / ".cache" / "repos"


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "piaza-reviewer/0.1"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def run(cmd: list[str], cwd: Path | None = None) -> None:
    """Run a subprocess; raise with a useful message on failure."""
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"stdout: {proc.stdout}\nstderr: {proc.stderr}"
        )


def ensure_clone(name: str, url: str, ref: str) -> Path:
    """Idempotently shallow-clone `url` @ `ref` into the repos cache.

    We recurse submodules because some targets (e.g. bun) have workspace
    members that path-depend on vendored Rust code stored in submodules.
    Without those submodule trees on disk, `cargo generate-lockfile`
    fails to read the path-dep's Cargo.toml.

    All clones use blob filtering + shallow depth to keep the cache small;
    we never need full history, only the current tree.
    """
    REPOS_CACHE.mkdir(parents=True, exist_ok=True)
    dest = REPOS_CACHE / name
    if not (dest / ".git").exists():
        if dest.exists():
            shutil.rmtree(dest)
        run([
            "git", "clone",
            "--filter=blob:none", "--no-tags", "--depth=1", "--branch", ref,
            "--recurse-submodules", "--shallow-submodules",
            url, str(dest),
        ])
    else:
        run(["git", "fetch", "--depth=1", "--no-tags", "origin", ref], cwd=dest)
        run(["git", "reset", "--hard", "FETCH_HEAD"], cwd=dest)
        # Bring submodules in line with the freshly-reset superproject.
        run(["git", "submodule", "update", "--init", "--recursive",
             "--depth=1", "--filter=blob:none"], cwd=dest)
    return dest


def lockfile_from_git(name: str, git_url: str, ref: str) -> bytes:
    """Clone if needed, run cargo generate-lockfile, return Cargo.lock bytes."""
    clone = ensure_clone(name, git_url, ref)
    lock = clone / "Cargo.lock"
    # If the project commits its lockfile we still regenerate so the ref's
    # state is canonical. `--offline` would block index reads, so leave it
    # online; this still doesn't execute crate code.
    run(["cargo", "generate-lockfile", "--manifest-path", str(clone / "Cargo.toml")])
    return lock.read_bytes()


def crates_from_lockfile(lock_bytes: bytes) -> set[tuple[str, str, str]]:
    """Return {(name, version, checksum)} for crates.io packages."""
    data = tomllib.loads(lock_bytes.decode("utf-8"))
    out: set[tuple[str, str, str]] = set()
    for pkg in data.get("package", []):
        if pkg.get("source") != CRATES_IO_SOURCE:
            continue
        out.add((pkg["name"], pkg["version"], pkg.get("checksum", "")))
    return out


def resolve_target(t: dict) -> bytes:
    """Return Cargo.lock bytes for one target, however it's configured."""
    name = t["name"]
    if "lockfile" in t:
        print(f"fetching {name}: {t['lockfile']}", file=sys.stderr)
        return fetch(t["lockfile"])
    if "git" in t:
        ref = t.get("ref", "HEAD")
        print(f"resolving {name}: {t['git']} @ {ref}", file=sys.stderr)
        return lockfile_from_git(name, t["git"], ref)
    raise ValueError(
        f"target {name!r} needs either `lockfile = ...` or `git = ...` + `ref = ...`"
    )


def main() -> int:
    if not TARGETS_PATH.exists():
        print(f"error: {TARGETS_PATH} not found", file=sys.stderr)
        return 1
    with TARGETS_PATH.open("rb") as f:
        targets = tomllib.load(f)

    all_crates: set[tuple[str, str, str]] = set()
    for t in targets.get("target", []):
        try:
            lock_bytes = resolve_target(t)
        except Exception as e:
            print(f"  WARN: target {t.get('name', '?')} failed: {e}", file=sys.stderr)
            continue
        crates = crates_from_lockfile(lock_bytes)
        print(f"  {len(crates)} crates.io packages", file=sys.stderr)
        all_crates |= crates

    for name, version, checksum in sorted(all_crates):
        print(f"{name}\t{version}\t{checksum}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
