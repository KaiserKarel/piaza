//! Reproduction of a panic in bcrypt 0.19.0 `verify` when the hash string
//! is exactly 60 bytes, passes the `$..$..$` prefix check, but contains a
//! multi-byte UTF-8 character that straddles byte index 29 of the hash
//! string (i.e. byte index 22 of the salt-and-hash slice).
//!
//! `split_hash` in src/lib.rs does:
//!
//! ```ignore
//! let salt_and_hash = &hash[7..];
//! BASE_64.decode_slice(&salt_and_hash[..22], &mut salt)?;
//! BASE_64.decode_slice(&salt_and_hash[22..], &mut hash_bytes)?;
//! ```
//!
//! The `&salt_and_hash[..22]` (and `[22..]`) slice operations require byte
//! 22 of `salt_and_hash` (== byte 29 of `hash`) to be a UTF-8 char boundary.
//! Nothing in the function validates that, so a hash whose only invariant
//! violation is "contains non-ASCII bytes around index 28-29" panics inside
//! the `str::Index` impl with "byte index 22 is not a char boundary".
//!
//! Real bcrypt hashes are always ASCII, so a deployment that only sees
//! hashes from a database/another bcrypt impl is safe; the bug matters
//! only when untrusted UTF-8 input is fed directly into `verify`.

#[test]
fn verify_does_not_panic_on_non_ascii_hash_of_correct_length() {
    // 60-byte hash:
    //   bytes 0-6   "$2a$04$"  (valid prefix)
    //   bytes 7-27  21 ASCII chars
    //   bytes 28-29 "£" (U+00A3, two bytes: 0xC2 0xA3)
    //   bytes 30-59 30 ASCII chars
    let hash = "$2a$04$AAAAAAAAAAAAAAAAAAAAA£AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    assert_eq!(hash.len(), 60, "test setup: hash must be 60 bytes");

    // Expected: returns Err(BcryptError::InvalidHash(_)) — the salt portion
    //           isn't valid base64.
    // Actual:   panics inside split_hash with
    //           "byte index 22 is not a char boundary; it is inside '£' …"
    let result = std::panic::catch_unwind(|| bcrypt::verify("anything", hash));
    assert!(
        result.is_ok(),
        "verify panicked on a 60-byte non-ASCII hash; \
         it should have returned Err(InvalidHash)"
    );
    // If the panic is fixed, the call must return Err, not Ok.
    assert!(result.unwrap().is_err());
}
