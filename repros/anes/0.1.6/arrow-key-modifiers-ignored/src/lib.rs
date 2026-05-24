//! Reproduction of arrow-key modifier parsing bug in anes 0.1.6.
//!
//! The xterm/VT escape sequence for "Ctrl+Up" is `ESC [ 1 ; 5 A` — the
//! engine parses this into two parameters `[1, 5]` with final char `A`,
//! and the standard says parameter[1] (= 5) is the modifier (1=plain,
//! 2=shift, 3=alt, 4=shift+alt, 5=ctrl, ...).
//!
//! anes 0.1.6 passes `parameters.first()` (= 1, the cursor key id) into
//! `parse_csi_arrow_key_modifiers`, then `saturating_sub(48)` (treating
//! the numeric parameter as if it were an ASCII digit). The result is
//! that every single-digit modifier saturates to 0, so the function
//! returns `KeyModifiers::empty()` for every real xterm-format input.
//!
//! The crate's own tests use the non-standard inputs `\x1B[50A` /
//! `\x1B[53A`, which only work because `50 - 48 = 2` (SHIFT) and
//! `53 - 48 = 5` (CONTROL). No real terminal emits those sequences.

use anes::parser::{KeyCode, KeyModifiers, Parser, Sequence};

fn parse(bytes: &[u8]) -> Option<Sequence> {
    let mut parser = Parser::default();
    parser.advance(bytes, false);
    parser.next()
}

#[test]
fn ctrl_up_should_set_control_modifier() {
    // Standard xterm sequence for Ctrl+Up.
    let got = parse(b"\x1B[1;5A");
    let want = Some(Sequence::Key(KeyCode::Up, KeyModifiers::CONTROL));
    assert_eq!(got, want, "Ctrl+Up should report CONTROL modifier");
}

#[test]
fn shift_up_should_set_shift_modifier() {
    // Standard xterm sequence for Shift+Up.
    let got = parse(b"\x1B[1;2A");
    let want = Some(Sequence::Key(KeyCode::Up, KeyModifiers::SHIFT));
    assert_eq!(got, want, "Shift+Up should report SHIFT modifier");
}

#[test]
fn alt_right_should_set_alt_modifier() {
    let got = parse(b"\x1B[1;3C");
    let want = Some(Sequence::Key(KeyCode::Right, KeyModifiers::ALT));
    assert_eq!(got, want, "Alt+Right should report ALT modifier");
}
