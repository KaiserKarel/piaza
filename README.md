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

## Harnesses

A *harness* is a (model, slash-command, crev-identity) triple. Each
harness gets its own cargo-crev key so consumers can choose which to
trust independently: maybe you trust Opus 4.7's default harness but not
Sonnet 4.6, or you trust the deep-scan harness more than the default
because it does longer runs.

Harnesses are declared in `harnesses.toml`:

```toml
[harnesses.opus-4-7-default]
model = "claude-opus-4-7"
review_command = "/review-crate"
id = "s1Qg5y0E..."
```

Slug convention is `<model-alias>-<harness-name>`. The slug appears in
commit messages and as the filename of the per-review log file.

## Bootstrap

One-time install:

```sh
./scripts/bootstrap.sh install
```

Then add a harness — this creates a new cargo-crev identity and appends
it to `harnesses.toml`:

```sh
./scripts/bootstrap.sh add-harness opus-4-7-default claude-opus-4-7
```

Pick a strong passphrase when prompted. Store it as `$CREV_PASSPHRASE`
(or `$CREV_PASSPHRASE_OPUS_4_7_DEFAULT` for a per-harness override) so
the scheduled agent can sign.

## Running a tick by hand

```sh
export CREV_PASSPHRASE="..."

# See what's pending
./scripts/tick.sh enumerate | head

# Run one review interactively (the harness is whatever ID is currently
# active in cargo-crev; tick.sh switches as needed below).
claude -p "/review-crate serde 1.0.219"

# Or run a tick of N reviews under a specific harness — the cron-
# equivalent entry point. tick.sh switches the crev ID, picks pending
# crates, then spawns one `claude -p` per crate so each review gets a
# fresh context.
./scripts/tick.sh run opus-4-7-default 5
```

Each successful review produces exactly one commit bundling the proof
and its matching log file.

## Logs

Every per-crate review writes a tracked log at
`review-logs/<crate>/<version>/<harness>.log`. Each log opens with a
markdown header (harness, model, slash command, started timestamp,
crev ID) followed by Claude's full output. These logs are committed
alongside the proof — anyone auditing a proof can read the exact
reasoning that produced it.

## Scheduling

The cron is a Claude scheduled agent (see the `/schedule` skill). The
schedule invokes `./scripts/tick.sh run <harness> N`, NOT a Claude
slash command directly — keeping the outer orchestration in bash means
we don't burn tokens on "which crate to pick next" (it's deterministic)
and the cron can't hallucinate. The per-crate `claude -p` calls happen
from inside `tick.sh`.

Schedule prerequisites: the right `$CREV_PASSPHRASE` env var available
in the agent's environment, `cargo`, `cargo-crev`, and `claude` on PATH.

## Repo layout

```
.
├── AGENTS.md              reviewer rubric + hard safety rules
├── README.md              you are here
├── targets.toml           list of public Rust projects we cover
├── harnesses.toml         registered (model, harness) identities
├── .claude/commands/      /review-crate slash command (only LLM entry point)
├── scripts/
│   ├── bootstrap.sh       install cargo-crev; add-harness <slug> <model>
│   ├── enumerate-targets.py   fetch lockfiles, emit (name, version, checksum)
│   ├── fetch-crate.sh     download .crate tarball without invoking cargo
│   ├── list-reviewed.py   walk <id-hash>/reviews/, emit existing reviews
│   ├── is-reviewed.sh     thin wrapper: is (name, version) already reviewed?
│   ├── tick.sh            cron entry: switch crev id, spawn claude -p per crate
│   ├── write-proof.sh     hand prepared YAML to cargo-crev for signing
│   └── commit-proof.sh    one commit per review (bundles proof + log)
├── <id-hash>/reviews/     cargo-crev proof tree (one dir per registered identity)
├── review-logs/           tracked per-review logs: <crate>/<version>/<harness>.log
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
