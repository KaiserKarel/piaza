# const_format_proc_macros 0.2.34 — panic on `\\u` in format string

Run `cargo test` (or `cargo build`) from this directory. Expected: the
test passes. Actual: compilation aborts inside the `formatcp!`
proc-macro with

```
thread '...' panicked at 'called `Option::unwrap()` on a `None` value',
.../const_format_proc_macros-0.2.34/src/parse_utils.rs:208:48
```

## Root cause

`LitStr::parse_from_literal` in `src/parse_utils.rs` uses
`value.match_indices(r#"\u"#)` to find Rust unicode escapes in the
source representation of a string literal. It does not check whether
the matched `\u` is preceded by another backslash. For the input
`"\\u"` (a two-character string `\u`), the source repr is `"\\u"` (5
chars including quotes) and the matcher fires at byte 2 — the second
`\` plus `u`. The code then assumes there is a closing `}` and calls
`value[pos..].find('}').unwrap()`, which panics.

## Why this matters

Any format string containing a literal backslash followed by `u`
crashes the proc-macro. A correct implementation must respect Rust
string-escape semantics when scanning for `\u{...}` — `\\` is a
two-byte token and the matcher should resume after it.

Related related case (not exercised by this repro):
`formatcp!("\\u{41}")` does not panic at the same site, but its
inner `\u{41}` is mistakenly substituted with `A`, after which the
re-tokeniser sees the invalid escape `\A` and the same unwrap chain
fails at `parse::<TokenStream2>().unwrap()` in
`StrRawness::tokenize_sub`.
