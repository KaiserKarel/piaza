//! Reproduction of the `%`-vs-`/` typo in `StreamCipherCore::try_apply_keystream_partial`
//! in cipher 0.4.4 (src/stream_core.rs:108-112).
//!
//! The function's documented contract is:
//!
//!   "Returns an error if number of remaining blocks is not sufficient
//!    for processing the input data."
//!
//! The block-count expression instead computes `buf.len() % BlockSize::USIZE`
//! where it must compute `buf.len() / BlockSize::USIZE`. For any input whose
//! length is an exact multiple of the block size, this yields `blocks = 0`,
//! the sufficiency check is vacuously satisfied, and the function proceeds to
//! drive the backend past `remaining_blocks()` — silently producing wrong
//! output (or panicking inside the backend, depending on implementation).
//!
//! The test below uses a toy `StreamCipherCore` whose backend marks blocks
//! generated past the declared budget with a sentinel byte. We then assert
//! that `try_apply_keystream_partial` honours its contract — which it does
//! not.
#![cfg(test)]

use cipher::{
    consts::{U1, U16},
    inout::InOutBuf,
    Block, BlockSizeUser, ParBlocksSizeUser, StreamBackend, StreamCipherCore, StreamClosure,
};

/// Minimal `StreamCipherCore` impl that advertises a finite keystream budget.
struct ToyCipher {
    remaining: usize,
}

impl BlockSizeUser for ToyCipher {
    type BlockSize = U16;
}

impl ParBlocksSizeUser for ToyCipher {
    type ParBlocksSize = U1;
}

impl StreamBackend for ToyCipher {
    fn gen_ks_block(&mut self, block: &mut Block<Self>) {
        if self.remaining == 0 {
            // Sentinel: backend was driven past its declared budget.
            block.fill(0xFF);
            return;
        }
        self.remaining -= 1;
        block.fill(0xAA);
    }
}

impl StreamCipherCore for ToyCipher {
    fn remaining_blocks(&self) -> Option<usize> {
        Some(self.remaining)
    }

    fn process_with_backend(&mut self, f: impl StreamClosure<BlockSize = U16>) {
        f.call(self);
    }
}

#[test]
fn returns_err_when_remaining_blocks_insufficient_for_multiple_of_block_size() {
    // 32 bytes / 16-byte block = 2 keystream blocks required.
    // Only 1 keystream block remains.
    // Contract: returns Err(StreamCipherError) without touching the data.
    // Bug: `blocks = 32 % 16 = 0`, so the check passes; the second
    //      block is XORed with the 0xFF sentinel from the exhausted backend.
    let cipher = ToyCipher { remaining: 1 };
    let mut buf = [0u8; 32];
    let res = cipher.try_apply_keystream_partial(InOutBuf::from(&mut buf[..]));

    assert!(
        res.is_err(),
        "expected Err for insufficient keystream, got Ok; \
         second half of buf was XORed with sentinel: {:02x?}",
        &buf[16..]
    );
}

#[test]
fn returns_err_when_remaining_blocks_insufficient_for_partial_block_tail() {
    // 33 bytes -> needs ceil(33/16) = 3 keystream blocks. Only 2 remain.
    // Bug: `blocks = 33 % 16 + 1 = 2`, so check `2 > 2` is false and the
    //      function proceeds. Real requirement is 3, so the backend is
    //      driven one block past its declared budget.
    let cipher = ToyCipher { remaining: 2 };
    let mut buf = [0u8; 33];
    let res = cipher.try_apply_keystream_partial(InOutBuf::from(&mut buf[..]));

    assert!(
        res.is_err(),
        "expected Err for insufficient keystream, got Ok; \
         tail byte XORed with sentinel: 0x{:02x}",
        buf[32]
    );
}
