# anes 0.1.6 — arrow-key modifiers ignored

## Bug

`Parser` returns `KeyModifiers::empty()` for every standard xterm cursor-key-
with-modifier sequence (e.g. `ESC[1;5A` for Ctrl+Up, `ESC[1;2A` for Shift+Up).

## Expected

Per the xterm / VT control sequence spec, `ESC [ 1 ; <m> <letter>` reports the
arrow letter (`A`/`B`/`C`/`D`) with modifier `<m>` (2=shift, 3=alt, 5=ctrl,
6=shift+ctrl, …).

## Actual

`parse_csi_sequence` in `src/parser/parsers.rs` passes `parameters.first()`
(the cursor-key id, always `1`) — not `parameters[1]` (the modifier) — into
`parse_csi_arrow_key_modifiers`, which then applies `saturating_sub(48)` to
that *integer* value (treating it as if it were an ASCII digit character).
The numeric parameter `1` saturates to `0`, which maps to `KeyModifiers::empty()`
in `parse_key_modifiers`.

The crate's own `csi_arrow_key_modifiers` test in `tests/parser/key.rs` uses
the non-standard inputs `\x1B[50A` and `\x1B[53A` — which only "pass" because
50−48=2 (SHIFT) and 53−48=5 (CONTROL). No real terminal emits those
sequences.

## Root cause

Looks like a refactor leftover: `parse_csi_arrow_key_modifiers` was written
to subtract ASCII `'0'` from a digit character, but the function now takes
an already-parsed `u64` modifier value. The subtraction and the wrong index
together make the function inert for real input.

## Run

```
cd repros/anes/0.1.6/arrow-key-modifiers-ignored
cargo test
```

All three tests currently fail.
