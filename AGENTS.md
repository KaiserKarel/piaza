# Reviewer agent guidance

You are reviewing a single Rust crate for supply-chain safety so its review proof
can be published into a [cargo-crev](https://github.com/crev-dev/cargo-crev)
proof repository. The output of your work is a YAML review body that a wrapper
script will hand to `cargo crev` for signing and committing.

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

## What to look for

Walk the crate source and skim every file. You are looking for things that
deviate from a normal, well-behaved library/binary. In rough priority order:

- **`build.rs`**: anything beyond `println!("cargo:...")` directives is
  suspicious. Network access, file writes outside `OUT_DIR`, shelling out,
  parsing env vars for secrets, downloading binaries — all red flags.
- **Proc macros** (`proc-macro = true` in Cargo.toml): same threat model
  as `build.rs`. The macro body runs in the consumer's build.
- **`unsafe` blocks**: count them, read each one. Note any that touch raw
  pointers from user input, transmute lifetimes, or skip bounds checks.
- **Network / filesystem I/O outside the crate's stated purpose**: a
  parsing crate that opens sockets is wrong.
- **Obfuscation**: `include_bytes!` of large blobs, base64-encoded strings,
  string decryption at runtime, weird `#[no_mangle]` exports, hex-encoded
  function bodies.
- **Dependencies on questionable crates**: typo-squats of popular names,
  crates by unknown authors with no other work, crates with known advisories
  (check `https://rustsec.org/advisories/`).
- **License & metadata**: missing license, missing repository link, version
  number that doesn't match the source contents.
- **Maintenance signals**: last commit date, open issue volume, whether the
  crate is in maintenance mode or abandoned (record as `issues`, not as a
  negative rating on its own).

## Rating rubric

You output three categorical fields that cargo-crev defines:

- `thoroughness`: `none` | `low` | `medium` | `high`
  - `low`: skimmed Cargo.toml + README + entry-point files only.
  - `medium`: read every `.rs` file in `src/`, scanned `build.rs`, checked deps.
  - `high`: above, plus traced data flow through every `unsafe` block and
    every public function that takes untrusted input.
- `understanding`: `none` | `low` | `medium` | `high`
  - How confident you are that you grasp what the crate actually does.
  - A trivial 200-line crate can earn `high`; a 50k-line crate is usually
    `medium` at best on a single pass.
- `rating`: `negative` | `neutral` | `positive` | `strong`
  - `strong`: high-quality, widely used, no concerns, you'd happily depend.
  - `positive`: looks fine, minor stylistic issues at worst.
  - `neutral`: nothing alarming but you found things worth flagging.
  - `negative`: contains code you would not want shipped in your binary.
  - There is also `dangerous` for outright malicious code — use it only
    with proof, and stop the tick to alert a human.

## Output format

The wrapper hands you the path to write the YAML body. Write **only the body**
of the review proof — cargo-crev wraps it in headers and signs it. Schema:

```yaml
review:
  thoroughness: medium
  understanding: medium
  rating: positive
comment: |
  Multi-line, free-form findings. Keep it factual. Quote line numbers when
  flagging something specific. Mention what you read and what you didn't.
  If `rating` is negative or worse, explain exactly why.
```

If you found issues that don't drop the rating but a downstream user should
know about, add an `issues:` block:

```yaml
issues:
  - id: build-rs-writes-outside-out-dir
    severity: medium
    comment: |
      build.rs at line 42 writes to $HOME/.cache/foo, not OUT_DIR. Not
      malicious — it's a download cache — but surprising.
```

For advisories that rise to genuine security concern, use `advisories:`:

```yaml
advisories:
  - ids: [RUSTSEC-2024-XXXX]
    severity: high
    range: ">= 0.0.0, < 1.2.3"
    comment: |
      Affects all versions before 1.2.3. Use 1.2.3+.
```

Keep the comment block under ~30 lines. The proof is meant to be read by
other reviewers and by tooling.
