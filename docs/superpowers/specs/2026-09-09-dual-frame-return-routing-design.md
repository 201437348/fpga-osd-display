# Dual-Frame SDRAM Return Routing Design

## Goal

Make the diagonal crossfade read both complete source frames without routing any
SDRAM return word into the wrong asynchronous FIFO.

## Cause

`frame_dual_fifo_read` currently keeps `route_old_fifo` selected for a fixed
ten memory-clock cycles after issuing a burst.  `Sdr_rd_en` is the actual data
valid signal and its latency can vary with the SDRAM controller.  A late tail
of an old-frame burst can therefore be written to the new-frame FIFO, or vice
versa.  Mixing these unrelated pixels produces the observed flashing blocks
and a lone diagonal transition line.

## Design

The reader will receive `Sdr_rd_en` as an input.  Each time it chooses an old
or new burst, it clears a per-burst return-word counter and holds
`selected_old` unchanged.  The counter increments only for real `Sdr_rd_en`
cycles.  The reader does not select the next burst, toggle its preferred FIFO,
or report completion until exactly `BURST_SIZE` return words have arrived.

This preserves the existing alternating old/new scheduling, FIFO capacity
checks, addresses, and single-frame behavior.  It adds no new frame storage,
image-loader behavior, audio behavior, OSD behavior, or external interface
change beyond the private `frame_read_write` to `frame_dual_fifo_read` link.

## Verification

The scheduler test will emulate SDRAM data valid after a delay longer than the
former fixed wait.  It will record the selected route on every returned word
and assert that all returned words from each command burst reach the FIFO that
was selected when that command was issued.  Existing command address, burst
alternation, and FIFO-full assertions remain in place.

## Board Acceptance

After TD synthesis and place-and-route, JTAG testing must show the old image
remaining intact while the new image crossfades in.  Repeated KEY2 changes,
automatic cycling, and TF removal/reinsertion must not introduce blocks,
stripes, black gaps, or HDMI/audio regressions.
