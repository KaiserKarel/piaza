# bcrypt 0.19.0 — `verify` panics on 60-byte non-ASCII hash

## Bug

`bcrypt::verify(_, hash)` panics with
`"byte index 22 is not a char boundary; it is inside 'X' …"` when the hash
argument is a 60-byte `&str` that satisfies the prefix checks but contains a
multi-byte UTF-8 character straddling byte index 29 (== index 22 of
`&hash[7..]`).

## Expected

Return `Err(BcryptError::InvalidHash(_))` — bcrypt hashes are always ASCII,
so any non-ASCII input is by definition invalid, not panic-worthy.

## Actual

`split_hash` (src/lib.rs:220, 223) does `&salt_and_hash[..22]` and
`&salt_and_hash[22..]` after only validating length and `$..$..$` byte
positions. If byte 22 of `salt_and_hash` lies inside a multi-byte char, the
`str::Index` impl panics. The library has an existing test
`does_no_error_on_char_boundary_splitting`, but that test's input fails the
prefix check before ever reaching the slice, so the test doesn't actually
exercise this path.

## Root cause

`split_hash` validates only that the hash has the right *byte* length and a
few ASCII byte positions, but then does `&str` slicing at arbitrary byte
indices. The fix is to validate that bytes 7..60 are ASCII (or work on
`hash.as_bytes()` for the slicing and decode from there).

## Severity

Denial-of-service / unexpected panic. Anywhere user-controlled input flows
into `verify` (e.g. a login endpoint that doesn't pre-validate the stored
hash format, or an importer fed external data) can crash the process /
unwind into an `unwrap`. No memory safety implications — the crate is
`#![forbid(unsafe_code)]`.

## Run

```
cd repros/bcrypt/0.19.0/panic-on-non-ascii-hash
cargo test
```

The test currently fails (panic caught by `catch_unwind`).
