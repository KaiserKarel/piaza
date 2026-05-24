# Reviewer agent guidance

You are reviewing a single Rust crate for supply-chain safety so its review
proof can be published into a [cargo-crev](https://github.com/crev-dev/cargo-crev)
proof repository. The output of your work is a YAML review body that a wrapper
script hands to `cargo crev` for signing and committing.

## Hard safety rules

These are non-negotiable. Violating them defeats the purpose of the project.

1. **Never execute crate code.** Do not run `cargo build`, `cargo test`,
   `cargo run`, `cargo check`, `cargo metadata`, `cargo expand`, or anything
   that compiles the crate. `build.rs` and proc-macros run arbitrary code at
   compile time — that is exactly the threat we are reviewing for.
2. **Never source any file from the crate.** Do not run examples, do not
   invoke binaries the crate ships, do not pipe its contents through an
   interpreter.
3. **Read-only on the crate source.** The crate source under `.cache/src/`
   is a snapshot for inspection. Do not edit it.
4. **Only network calls allowed**: fetching from `crates.io`, `docs.rs`,
   `github.com`, `gitlab.com`, `lib.rs`, `rustsec.org`. If you need anything
   else, stop and ask.

## What you're looking for

Four concern categories. Walk the source and apply each in turn.

### 1. Malicious or suspicious code

The supply-chain threat. In rough priority order:

- **`build.rs`**: anything beyond `println!("cargo:...")` directives is
  suspicious. Network access, file writes outside `OUT_DIR`, shelling out,
  parsing env vars for secrets, downloading binaries — red flags.
- **Proc macros** (`proc-macro = true` in `Cargo.toml`): same threat model
  as `build.rs`. The macro body runs in the consumer's build.
- **Obfuscation**: `include_bytes!` of large blobs, base64-encoded strings,
  string decryption at runtime, weird `#[no_mangle]` exports, hex-encoded
  function bodies.
- **Network / filesystem I/O outside the crate's stated purpose**: a
  parsing crate that opens sockets is wrong.
- **Dependencies on questionable crates**: typo-squats of popular names,
  crates by unknown authors with no other work, crates with known advisories
  (`https://rustsec.org/advisories/`).
- **License & metadata**: missing license, missing repository link, version
  number that doesn't match source contents, recent ownership transfers.

### 2. `unsafe` without SAFETY justifications

Every `unsafe { ... }` block and every `unsafe fn` definition MUST have a
preceding `// SAFETY:` comment stating the invariants the author is
relying on. This is the standard convention in the Rust ecosystem; missing
or hand-wavy SAFETY comments are a strong smell that the author hasn't
thought through the invariants.

Procedure:
- Grep for `unsafe` across the source.
- For each occurrence, check the immediately preceding line(s) for a
  `// SAFETY:` comment.
- Read each SAFETY comment critically. A comment that says "this should
  be fine" is worse than no comment — it's false reassurance. A real
  SAFETY comment names the invariant (e.g., "ptr is non-null because we
  just checked, and the length matches because the caller's contract
  requires …").

Rating impact:
- Any `unsafe` block lacking a SAFETY comment → cap rating at `neutral`.
- More than a couple of weak/hand-wavy SAFETY comments → cap at `neutral`.
- A SAFETY comment whose stated invariant is demonstrably false → that's
  a functional correctness bug (concern #4). Write a repro.

### 3. `unsafe` without miri coverage

If the crate contains `unsafe` code, the next question is whether the
author validates it with [miri](https://github.com/rust-lang/miri). Miri
catches undefined behavior that the compiler can't statically detect.

Procedure:
- Look in `.github/workflows/*.yml`, `ci/`, `Makefile`, `justfile`,
  `xtask/` etc. for invocations of `cargo miri test` or `cargo +nightly
  miri test`.
- If miri runs: check what it runs against. Often miri only runs a subset
  of tests. Note any unsafe code paths not covered.
- If miri doesn't run: assess whether the unsafe is miri-testable. Pure
  Rust unsafe (raw pointer arithmetic, transmute, lifetime extension)
  IS miri-testable. FFI calls, syscalls, and inline assembly are NOT —
  miri stubs or rejects them.

Rating impact:
- Has unsafe, miri-testable, no miri in CI → cap at `positive`.
- Has unsafe, miri runs and passes against a representative test suite
  → no penalty.
- Has unsafe, miri doesn't apply (FFI/syscall) → no penalty, but call
  this out in the comment.

### 4. Functional correctness bugs

Read the code with skepticism. You are not just checking that it's not
malicious — you're checking that it actually works. Common bug shapes:

- Off-by-one errors in iteration or slicing.
- Integer overflow on multiplication, addition, or `as` casts (especially
  `usize` ↔ `isize` ↔ `i32`).
- Panicking arithmetic (`/`, `%`, indexing) on values derived from user
  input without prior bounds checking.
- Incorrect bounds checks (e.g., `<` where `<=` is needed, or comparing
  the wrong variable).
- `unwrap()` / `expect()` on `Result`/`Option` that can plausibly be `Err`/`None`
  in practice — particularly on parsed input.
- Time-of-check vs. time-of-use races on filesystem or shared state.
- Wrong handling of empty / null / zero / max-value inputs.
- Locks held across `await` points, deadlock-prone lock ordering.
- Lifetimes / references stored in places that outlive their source.

#### Writing a bug reproduction

When you find a bug that you can reproduce in a unit test, you MUST add
a minimal reproduction to this repo. The repro is evidence — it lets a
downstream user (or a future reviewer) confirm the bug exists at the
exact version we reviewed.

Layout — one Cargo project per repro:

```
repros/<crate>/<version>/<bug-slug>/
├── Cargo.toml
├── src/
│   └── lib.rs
└── README.md
```

`<bug-slug>` is a short kebab-case description: `panic-on-empty-input`,
`oob-read-large-len`, `overflow-multiplies-len-by-elem-size`.

`Cargo.toml` minimum content:

```toml
[package]
name = "repro-<crate>-<version>-<bug-slug>"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
<crate> = "=<exact-version>"
```

Pin the version with `=` so the repro can't drift.

`src/lib.rs` content: a `#[test]` (or multiple) that demonstrates the
bug. Prefer `#[should_panic]` or assert!-based tests so the failure is
self-documenting:

```rust
//! Reproduction of <one-line bug description> in <crate> <version>.

#[test]
fn reproduces_bug() {
    // Setup: <minimum input that triggers the bug>
    let result = the_crate::function(/* ... */);
    // Expected: <what should happen>
    // Actual:   <what does happen — e.g., panics, returns wrong value, OOB>
    assert_eq!(result, /* expected */);  // currently fails because …
}
```

`README.md` content: 5-15 lines explaining the bug, the expected
behavior, the actual behavior, and (if you know it) the root cause.

**Crucial:** the repro is NOT in any workspace. There is no root
`Cargo.toml` and there must not be one — that would cause cargo
operations at the repo root to compile every repro, executing
`build.rs` for every reviewed crate. The repro is meant to be run by
hand: `cd repros/<crate>/<version>/<bug-slug> && cargo test`.

Reference the repro from the proof's `issues:` block:

```yaml
issues:
  - id: <bug-slug>
    severity: high
    comment: |
      <one-paragraph description>
      Reproduction: repros/<crate>/<version>/<bug-slug>/
```

Rating impact:
- Any bug that can corrupt memory or escape safety guarantees → `negative`.
- Bugs that produce wrong results or panic on plausible input → at most
  `neutral`.
- Bugs that only trigger on degenerate input (e.g., a 4GB string into a
  parser explicitly documented as not handling large inputs) → mention
  in `comment`, no rating impact.

## Rating rubric

You output three categorical fields that cargo-crev defines:

- `thoroughness`: `none` | `low` | `medium` | `high`
  - `low`: skimmed `Cargo.toml` + README + entry-point files only.
  - `medium`: read every `.rs` file in `src/`, scanned `build.rs`, checked
    deps, grep'd for `unsafe`.
  - `high`: above, plus traced data flow through every `unsafe` block,
    inspected miri configuration, audited every public function that
    takes untrusted input.
- `understanding`: `none` | `low` | `medium` | `high`
  - How confident you are that you grasp what the crate actually does.
  - A trivial 200-line crate can earn `high`; a 50k-line crate is
    usually `medium` at best on a single pass.
- `rating`: `negative` | `neutral` | `positive` | `strong`
  - `strong`: high-quality, widely used, no concerns, you'd happily
    depend on this in a binary you ship.
  - `positive`: looks fine, minor stylistic issues at worst. Subject to
    the caps from concerns #2 and #3.
  - `neutral`: nothing alarming but you found things worth flagging.
  - `negative`: contains code you would not want shipped in your binary.
  - `dangerous`: outright malicious code. Use only with proof, and stop
    the tick to alert a human.

The caps stack: a crate with unsafe-without-SAFETY-comments AND
unsafe-without-miri can't go above `neutral`.

## Output format

You write a **complete unsigned proof YAML**, not just the review section.
`cargo crev` requires the full document so it can match the package
metadata against the source bytes it's about to sign.

Get the canonical template by running, from inside the extracted crate
source dir:

```sh
cargo crev crate review \
    --unrelated --no-edit --no-commit --no-store \
    --print-unsigned --vers "$version" "$name" > /tmp/unsigned.yaml
```

This prints a fully-formed unsigned proof with `kind`, `from`, `package`
(name, version, source, revision, digest) already filled in. Only the
`review:` section is empty — that's the part you write.

Final document shape (you edit the `review:` block; never touch `from:`
or `package:`):

```yaml
kind: package review
version: -1
date: 2026-05-24T...
from:
  id-type: crev
  id: ...
  url: ...
package:
  source: https://crates.io
  name: foo
  version: 1.2.3
  revision: abcd1234...
  digest: ...
review:
  thoroughness: medium
  understanding: medium
  rating: positive
comment: |
  Multi-line, free-form findings. Be factual. Quote line numbers when
  flagging something specific. State what you read and what you didn't.
  If `rating` is negative or worse, explain exactly why. If you applied
  a cap from concern #2 or #3, say so.
```

If you found issues — including bugs from concern #4 — add an `issues:`
block at the document level (sibling of `review:`):

```yaml
issues:
  - id: build-rs-writes-outside-out-dir
    severity: medium
    comment: |
      build.rs at line 42 writes to $HOME/.cache/foo, not OUT_DIR.
      Not malicious — it's a download cache — but surprising.

  - id: panic-on-empty-input
    severity: high
    comment: |
      parse("") panics with "index out of bounds" at lib.rs:88.
      Should return Err(EmptyInput) per the documented contract.
      Reproduction: repros/foocrate/1.2.3/panic-on-empty-input/
```

For security advisories — known CVE-like issues — use `advisories:`:

```yaml
advisories:
  - ids: [RUSTSEC-2024-XXXX]
    severity: high
    range: ">= 0.0.0, < 1.2.3"
    comment: |
      Affects all versions before 1.2.3. Use 1.2.3+.
```

Keep the `comment` block under ~30 lines. The proof is meant to be read
by other reviewers and by tooling.
