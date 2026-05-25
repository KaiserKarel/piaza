# bit-vec 0.8.0 — `split_off` leaves an excess storage block

## Bug

`BitVec::split_off(at)` can produce a `BitVec` whose internal storage
contains one block more than `blocks_for_bits(nbits)` requires. This
violates invariant (2) documented at the top of `src/lib.rs` ("the
underlying vector has no excess length").

Triggers when both:

- `at % B::bits() != 0` (split inside a block), and
- `self.nbits % B::bits() <= at % B::bits()` (the source's tail
  bits all shift out of the final pushed block).

## Expected

After `let b = a.split_off(at);`, `b.storage().len()` should equal
`ceil(b.len() / B::bits())`.

## Actual

For `a = BitVec::from_elem(33, true); let b = a.split_off(1);`:

- `b.len() == 32` ✓
- `b.storage().len() == 2` ✗ (expected 1; second block is `0`)

The excess block is always zero immediately after `split_off`, so
`b == c` still holds against a freshly constructed `BitVec::from_elem(32, true)`.
But methods that iterate raw storage diverge once anything writes
to the excess block, and `Hash`/`Eq` are inconsistent even before
that:

- `b.hash(_)` hashes the extra `0` block; `c.hash(_)` does not →
  two equal BitVecs hash to different values (`Hash`/`Eq` contract
  violation).
- After `b.negate()`, the excess block becomes `!0`, so
  `count_ones()` returns `32` instead of `0`,
  `count_zeros()` returns `0` instead of `32`,
  and `none()` / `any()` flip the wrong way.

## Root cause

In `split_off` (src/lib.rs:1218), when `b != 0`, the code unconditionally
pushes `self.storage.len() - w` blocks into `other` (one per element of
`self.storage[w..]`). The last pushed block is `last >> b`, which is
zero whenever the source's final `self.nbits % B::bits()` valid bits
fit entirely in the part that gets shifted out. The function doesn't
check whether that last block is needed.

`is_last_block_fixed` doesn't catch this because it returns `true`
unconditionally when `nbits % B::bits() == 0`.

## Run

```
cd repros/bit-vec/0.8.0/split-off-excess-storage
cargo test
```

All four tests currently fail.
