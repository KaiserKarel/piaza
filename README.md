# piaza

AI-driven Rust supply-chain reviews, published as
[cargo-crev](https://github.com/crev-dev/cargo-crev) proofs.

This repo serves two roles at once:

1. **A cargo-crev proof repository.** Other Rust projects can pull our
   reviews with `cargo crev repo fetch url <this-repo>` and use them in
   their own trust webs.
2. **The tooling that produces those reviews.** A scheduled Claude agent
   periodically reads `targets.toml`, enumerates the dependency graph of
   each target, picks crates that haven't been reviewed yet, and runs a
   review for each one — one commit per review.

## What gets reviewed

Add public Rust projects to `targets.toml`. Each entry points at a
`Cargo.lock` URL (preferred, because versions are pinned). On every
tick we:

1. Fetch each target's lockfile.
2. Take the union of every crates.io package listed across all targets.
3. Subtract the crates we've already reviewed (the YAML in `proofs/` is
   the source of truth — not commit messages, not any sidecar index).
4. Hand the remainder to Claude one at a time.

There's no notion of "deps of deps" beyond what's already flattened in
the lockfile, because Cargo.lock already enumerates the full transitive
graph.

## Safety model

The whole point of crev is to catch supply-chain attacks **before** a
crate runs on your machine. So the reviewer must never run the crate.
`AGENTS.md` codifies this; the short version:

- Sources are pulled as `.crate` tarballs from crates.io and extracted.
  We never invoke `cargo build`, `cargo metadata`, or anything that
  would execute `build.rs` or a proc-macro.
- The reviewer reads the source. That's it. No tests, no examples, no
  shelling out to anything the crate ships.

## Bootstrap

```sh
./scripts/bootstrap.sh https://github.com/<you>/piaza
```

This installs `cargo-crev` and creates a new crev ID whose proof-repo
URL is this repo. Pick a strong passphrase and store it in your secret
manager — the scheduled agent reads it from `$CREV_PASSPHRASE`.

## Running a tick by hand

```sh
export CREV_PASSPHRASE="..."
# See what's pending
./scripts/tick.sh enumerate | head

# Run a single review (Claude does the work)
claude -p "/review-crate serde 1.0.219"

# Or run a full tick of N crates
claude -p "/review-tick 5"
```

Each successful review produces exactly one commit in `proofs/`.

## Scheduling

The cron is a Claude scheduled agent (see the `/schedule` skill). Once
the repo is pushed and `$CREV_PASSPHRASE` is set in the scheduled
agent's environment, schedule:

```
/review-tick 10
```

at whatever cadence you want (daily is fine to start). The agent will
run the tick, commit each new review, and push.

## Repo layout

```
.
├── AGENTS.md              reviewer rubric + hard safety rules
├── README.md              you are here
├── targets.toml           list of public Rust projects we cover
├── .claude/commands/      /review-crate, /review-tick slash commands
├── scripts/
│   ├── bootstrap.sh       one-time setup
│   ├── enumerate-targets.py   fetch lockfiles, emit (name, version, checksum)
│   ├── fetch-crate.sh     download .crate tarball without invoking cargo
│   ├── list-reviewed.py   parse proofs/, emit existing reviews
│   ├── is-reviewed.sh     thin wrapper: is (name, version) already reviewed?
│   ├── tick.sh            orchestrate one cron tick (data only — no Claude)
│   ├── write-proof.sh     hand prepared YAML to cargo-crev for signing
│   └── commit-proof.sh    one commit per review
├── proofs/                cargo-crev proof tree (populated by `cargo crev id new`)
└── repros/                bug reproductions, one Cargo project per finding
```

### About `repros/`

When a review turns up a real bug (concern #4 in `AGENTS.md`), the reviewer
checks in a minimal reproduction: one Cargo project per bug, under
`repros/<crate>/<version>/<bug-slug>/`. Each repro pins the affected crate
version exactly and ships one or more `#[test]`s that demonstrate the bug.

**There is no root `Cargo.toml` and there must not be one.** A root
workspace would cause every cargo operation to compile every repro,
which would execute the `build.rs` of every reviewed crate — directly
violating the project's safety model. Repros are run manually:
`cd repros/<crate>/<version>/<bug-slug> && cargo test`.

## Status

Early scaffolding. Things that work: enumeration, fetch, the reviewer
prompt, the proofs-as-source-of-truth check. Things that need real-world
shakeout: the EDITOR-shim trick in `write-proof.sh`, the scheduled-agent
wiring. Expect to iterate on those once the first review goes through
end-to-end.
