---
description: Review a single crate (name + version) and write a signed cargo-crev proof.
argument-hint: <crate-name> <version>
---

Review the crate `$1` version `$2`. Follow `AGENTS.md` for the rubric and
safety rules — the rules there are non-negotiable.

Workflow:

1. Verify the crate isn't already reviewed in this repo:
   ```
   ./scripts/is-reviewed.sh "$1" "$2"
   ```
   If it prints a path, stop and tell the user — don't double-review.

2. Fetch the crate source. This downloads the .crate tarball from crates.io
   and extracts it. It does NOT invoke cargo and does NOT run build.rs:
   ```
   src_dir=$(./scripts/fetch-crate.sh "$1" "$2")
   ```
   The script echoes the extracted directory path on its last line.

3. Inspect the source. Read every `.rs` file under `src/`. Always read
   `Cargo.toml`, `build.rs` (if present), `README.md`, and the top-level
   entry points (`lib.rs`, `main.rs`). For crates with proc-macros, read
   every macro implementation. Use Grep to scan for suspicious patterns
   (`unsafe`, `include_bytes!`, `std::process::Command`, network APIs,
   raw `libc` calls).

4. Write the review YAML body to a temp file. Schema is in `AGENTS.md`.
   Write only the body — no `-----BEGIN-----` headers, no signature.

5. Hand the body to the signing wrapper, which calls `cargo crev` with
   our reviewer identity:
   ```
   ./scripts/write-proof.sh "$1" "$2" "$src_dir" /tmp/review-body.yaml
   ```

6. Commit the new proof file with a one-line message:
   ```
   ./scripts/commit-proof.sh "$1" "$2"
   ```
   This makes ONE commit per review — that's a hard project requirement.

If any step fails, stop and report — do not paper over errors with
fallback logic. A failed review is fine; a wrong review is not.
