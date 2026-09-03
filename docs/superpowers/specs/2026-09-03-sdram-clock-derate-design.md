# SDRAM Clock Derate Design

## Problem

The routed 125 MHz SDRAM interface reports a worst setup slack of -6.565 ns
on the hard SDRAM macro's DQ read path. The reverse DQ write path reports
-2.908 ns. The current project and the official 2026-06-05 `lab_ex4_tf`
build have the same two path groups and the same worst slack, so this is an
inherited 125 MHz SDRAM-template limitation rather than a regression from the
recovery controller or FIFO throttle.

The paths are between `ext_mem_clk` and the 180-degree shifted
`ext_mem_clk_sft` clock. They are real SDRAM interface paths and must not be
hidden with a false-path constraint.

## Scope

Change only the two SDRAM clocks produced by `sys_pll`:

- C1: 125 MHz, 0 degrees -> 41.667 MHz, 0 degrees.
- C2: 125 MHz, 180 degrees -> 41.667 MHz, 180 degrees.

The 100 MHz SD-card clock, 25 MHz video clock, 125 MHz HDMI serial clock,
SDRAM controller RTL, FIFO settings, image-recovery behavior, reset flow and
pin constraints remain unchanged.

The PLL VCO remains at 1 GHz. C1 and C2 use divide-by-24; C1 uses phase tap
23 for zero degrees and C2 uses phase tap 11 for 180 degrees, matching the
existing generated-IP convention of zero-degree `DIV-1` and 180-degree
`DIV/2-1`.

## Rationale

At 125 MHz, the phase-separated DQ paths have a 4 ns setup window. The
timing report calculates a minimum safe period of 21.130 ns (47.326 MHz) for
the reverse DQ path. A 24 ns SDRAM period leaves margin over that result while
preserving an estimated 166 MB/s 32-bit peak transfer rate, above the
approximately 74 MB/s display-read requirement at 640x480@60 Hz.

This is a controlled timing experiment, not final timing closure. Existing
reset-release and FIFO asynchronous-reset crossings remain a separate audit
item. The prior 125 MHz settings stay available as the immediate rollback.

## Verification

1. Build the root `osd_display.al` in TD through synthesis, place/route and
   bit generation.
2. Confirm the SDRAM DQ timing groups
   `ext_mem_clk -> clkc[2]` and `clkc[2] -> ext_mem_clk` have non-negative
   setup slack.
3. JTAG-download only. Do not program configuration Flash during this
   experiment.
4. Verify first-image display, single and close-spaced `KEY1` next-image
   requests, automatic play, TF removal/reinsertion recovery, and the absence
   of a prolonged `341100` retry.
5. If any functional check fails, restore C1/C2 divide-by-8 settings without
   changing any other source file.
