# Crossfade Read-Margin Diagnostics Design

## Context

The 32-frame pure old/new crossfade has passed visual review, but the latest
JTAG board test still shows transition-only corruption.  The same project is
stable when only one SDRAM frame is read.  Focused simulations prove command
order and old/new return routing, while the routed design still contains the
inherited `-6.565 ns` SDRAM DQ setup violation.  Simulation therefore cannot
distinguish a real FIFO starvation event from corrupt SDRAM samples on the
board.

## Decision

Keep the accepted transition timing, alpha curve, RGB blend, 125 MHz SDRAM
clock, media pipeline, and stable Flash image unchanged.  Increase each
display read FIFO from 1024 to 4096 32-bit words and add sticky observation of
the failure modes that can be detected without probing internal signals:

- bit 0: the new/current-frame FIFO was empty while a display pixel requested
  data;
- bit 1: the old-frame FIFO was empty while a dual-read display pixel requested
  data;
- bit 2: a new frame request reached the memory scheduler before the previous
  frame's required read commands had completed.

The synchronized three-bit value overrides only the last seven-segment digit
when nonzero.  Codes are additive: `1` means new underflow, `2` old underflow,
`3` both, and `4` frame-read overrun.  When no read fault is latched, the digit
continues to show the existing media error code.

## Rationale

The larger FIFOs use available BRAM to increase tolerance to SDRAM refresh,
row-change, arbitration, and physical timing jitter without changing the
external-memory protocol.  Sticky diagnostics make the next JTAG run
decisive:

- no corruption and code `0`: the added buffering restored adequate read
  margin;
- corruption with code `1`, `2`, `3`, or `4`: the dual-read stream cannot meet
  its real-time demand with the present schedule;
- corruption with code `0`: FIFO continuity was preserved and the unresolved
  SDRAM DQ sampling path is the leading cause, so another FIFO/scheduler tweak
  is not justified.

## Constraints

- Do not alter the accepted roughly 0.53-second visual effect.
- Do not change SDRAM frequency or phase in the same experiment.
- Do not program configuration Flash; this revision is JTAG-only until board
  acceptance.
- Preserve all existing TF-card, audio, OSD, retry, and recovery behavior.
- Unit tests cover both underflow bits and scheduler overrun before handoff to
  TD synthesis and board testing.

