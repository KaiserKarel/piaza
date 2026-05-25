//! Reproduction of `BitVec::split_off` leaving an excess storage block
//! in bit-vec 0.8.0.
//!
//! When `at` falls inside a block (i.e. `at % B::bits() != 0`) and the
//! original length satisfies `self.nbits % B::bits() <= at % B::bits()`,
//! the function pushes `self.storage.len() - w` blocks into the result —
//! one more than `blocks_for_bits(self.nbits - at)`. The trailing extra
//! block is always zero, so most operations look fine, but methods that
//! iterate the raw storage (count_ones, count_zeros, none, hash) leak
//! the bits of that excess block into their answers once anything
//! writes into it.
//!
//! The invariant violated is documented at the top of `src/lib.rs`:
//!     (2) Make sure that the underlying vector has no excess length.
//! The check `is_last_block_fixed` doesn't catch this because it
//! returns `true` whenever `nbits % B::bits() == 0`.

use bit_vec::BitVec;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

fn split_off_with_excess() -> BitVec {
    // 33 bits → 2 storage blocks. Split at 1 leaves 32 bits in the
    // returned half, which only needs one block.
    let mut a = BitVec::from_elem(33, true);
    a.split_off(1)
}

#[test]
fn split_off_should_not_leave_excess_storage() {
    let b = split_off_with_excess();
    assert_eq!(b.len(), 32);
    // Bug: storage has 2 blocks (one is excess zero), but 32 bits fit
    // in a single u32.
    assert_eq!(b.storage().len(), 1, "split_off left an excess storage block");
}

#[test]
fn count_ones_should_ignore_excess_block_after_negate() {
    let mut b = split_off_with_excess();
    // b is semantically 32 ones. After negate, semantically 32 zeros.
    b.negate();
    // The excess block was 0; negate flips it to !0, and count_ones
    // sums all blocks unconditionally.
    assert_eq!(b.count_ones(), 0, "count_ones leaked bits from the excess block");
}

#[test]
fn none_should_ignore_excess_block_after_negate() {
    let mut b = split_off_with_excess();
    b.negate();
    // Semantically all 32 valid bits are 0 → none() should be true.
    assert!(b.none(), "none() saw bits in the excess storage block");
}

#[test]
fn hash_eq_invariant_must_hold() {
    // Two BitVecs that compare equal must hash the same.
    let b = split_off_with_excess();
    let c = BitVec::from_elem(32, true);
    assert_eq!(b, c, "b and c should compare equal");

    let mut h1 = DefaultHasher::new();
    b.hash(&mut h1);
    let mut h2 = DefaultHasher::new();
    c.hash(&mut h2);

    // BitVec::hash writes every block in storage, so the excess zero
    // block makes b hash differently from c even though they're equal.
    assert_eq!(
        h1.finish(),
        h2.finish(),
        "Hash/Eq invariant violated: equal BitVecs hash differently"
    );
}
