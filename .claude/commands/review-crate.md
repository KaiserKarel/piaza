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

   Apply each of the four concern categories from `AGENTS.md` in turn:
   - (1) malicious / suspicious code,
   - (2) `unsafe` without `// SAFETY:` comments,
   - (3) `unsafe` without miri coverage in CI,
   - (4) functional correctness bugs.

   If you find a reproducible bug under concern #4, add a repro under
   `repros/<crate>/<version>/<bug-slug>/` per the layout in `AGENTS.md`
   before writing the proof. The repro is required — it's the evidence
   that backs the finding.

4. Get the canonical unsigned-proof template from cargo-crev. This is
   the document `cargo crev` will sign — `package` metadata is already
   filled in (name, version, source, revision, digest). You'll edit
   only the `review:` section (and add `issues:`/`advisories:` if
   appropriate). Run from inside the extracted source dir so cargo-crev
   has the cargo project context it needs:
   ```
   cd "$src_dir"
   cargo crev crate review \
       --unrelated --no-edit --no-commit --no-store \
       --print-unsigned --vers "$2" "$1" > /tmp/unsigned.yaml
   cd -
   ```

5. Edit `/tmp/unsigned.yaml` in place. Do NOT touch `kind`, `from`,
   `package`, `date`, or `version` — those came from cargo-crev and
   must stay byte-identical or the proof won't match the source.
   Replace the empty `review:` section with your filled-in rubric
   per `AGENTS.md`. Add `issues:` / `advisories:` at the document
   level if your findings warrant it. Reference any repros you added.

6. Hand the unsigned proof to the signing wrapper:
   ```
   ./scripts/write-proof.sh "$1" "$2" "$src_dir" /tmp/unsigned.yaml
   ```

7. Commit the new proof file (and its log) with a one-line message:
   ```
   ./scripts/commit-proof.sh "$1" "$2"
   ```
   This makes ONE commit per review — that's a hard project requirement.

If any step fails, stop and report — do not paper over errors with
fallback logic. A failed review is fine; a wrong review is not.
