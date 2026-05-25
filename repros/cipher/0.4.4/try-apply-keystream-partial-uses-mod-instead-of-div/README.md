# cipher 0.4.4 — `try_apply_keystream_partial` uses `%` where it needs `/`

## Bug

`StreamCipherCore::try_apply_keystream_partial` (default method in
`src/stream_core.rs:103-133`) is supposed to return `Err(StreamCipherError)`
when the input data needs more keystream blocks than the cipher has left.
The check at lines 108-112 instead reads:

```rust
let blocks = if buf.len() % Self::BlockSize::USIZE == 0 {
    buf.len() % Self::BlockSize::USIZE     // <- bug: always 0 in this arm
} else {
    buf.len() % Self::BlockSize::USIZE + 1 // <- bug: should be / not %
};
if blocks > rem {
    return Err(StreamCipherError);
}
```

Both arms use `%` (modulo) where `/` (integer division) is required to
compute the number of blocks `ceil(buf.len() / BlockSize)`.

## Expected

For `buf.len()` an exact multiple of the block size: `blocks = buf.len() / bs`.
For `buf.len()` not a multiple: `blocks = buf.len() / bs + 1`.

So 32 bytes with a 16-byte block requires 2 keystream blocks; 33 bytes
requires 3.

## Actual

`buf.len() % bs` evaluates to the leftover-byte count, not the block count:

| `buf.len()` | `bs` | required | computed |
|------------:|-----:|---------:|---------:|
| 16          | 16   | 1        | 0        |
| 32          | 16   | 2        | 0        |
| 17          | 16   | 2        | 2        |
| 33          | 16   | 3        | 2        |
| 1024        | 16   | 64       | 0        |

The sufficiency check `blocks > rem` then under-estimates the required
keystream and the function proceeds to drive the backend past
`remaining_blocks()`. Concrete consequences depend on the backend
implementation: most ciphers in `RustCrypto/stream-ciphers` panic on
counter overflow, but a backend that wraps would silently emit a
reused keystream — catastrophic for a stream cipher.

## Root cause

Looks like a copy-paste from a sibling block-count computation. Note
that `StreamCipherCoreWrapper::check_remaining` in `src/stream_wrapper.rs:96-100`
gets the same calculation right, using `/` in both arms — so the bug is
localised to the default-method path in `StreamCipherCore` itself.

## Run

```
cd repros/cipher/0.4.4/try-apply-keystream-partial-uses-mod-instead-of-div
cargo test
```

Both tests currently fail (return `Ok` when the contract requires `Err`).
