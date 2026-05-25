//! Reproduction of a compile-time proc-macro panic in
//! const_format_proc_macros 0.2.34.
//!
//! `LitStr::parse_from_literal` in src/parse_utils.rs scans the source
//! representation of a string literal for `\u` to expand Rust unicode
//! escapes (`\u{...}`) so the format-string parser sees the decoded
//! characters. The scan uses `value.match_indices(r#"\u"#)` and does
//! not check whether the preceding character is itself a backslash.
//!
//! For the format string `"\\u"` (a two-character runtime string
//! `\u`, written in source as an escaped backslash followed by `u`),
//! the source repr handed to the proc-macro is `"\\u"` (5 chars
//! including the surrounding quotes). `match_indices(r#"\u"#)` matches
//! at byte 2 — the second `\` plus `u`. The code then runs
//! `value[pos..].find('}').unwrap()` (parse_utils.rs:208), but there
//! is no `}` to find, so the proc-macro panics with
//! `called \`Option::unwrap()\` on a \`None\` value`.
//!
//! Expected: `formatcp!("\\u")` compiles and produces the two-character
//! constant `"\u"`.

#[test]
fn formatcp_double_backslash_u_should_compile_to_backslash_u() {
    // Expected: this constant equals "\\u" (two chars: backslash + 'u').
    // Actual:   compilation aborts before this point — the proc-macro
    //           panics in const_format_proc_macros-0.2.34/src/parse_utils.rs
    //           at the `find('}').unwrap()` call.
    const S: &str = const_format::formatcp!("\\u");
    assert_eq!(S, "\\u");
    assert_eq!(S.len(), 2);
}
