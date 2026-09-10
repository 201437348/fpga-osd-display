# 62.5 MHz SDRAM Crossfade Stability Design

## Problem

The accepted 32-frame pure crossfade still corrupts pixels on hardware.  The
4096-word dual-read-FIFO diagnostic build keeps its sticky last digit at zero,
so neither FIFO was read while empty and no new frame request overtook an
unfinished frame.  Enlarging the FIFOs or changing the read scheduler again
would not address the observed failure.

The remaining leading cause is the SDRAM DQ interface.  The latest 125 MHz
route reports `SWNS=-6.565ns`, with the hard-macro DQ read path still the worst
path.  A single-frame transition can tolerate this interface in practice, but
a true crossfade reads two SDRAM frames for every displayed pixel and exercises
the marginal return path much more heavily.

## Prior Experiment Correction

The rejected 41.667 MHz experiment changed only the PLL.  Its active
`global_def.v` still defined `SDR_CLK_PERIOD` for 125 MHz, so the refresh
counter retained the same cycle count while each cycle became three times
longer.  The physical refresh interval was therefore stretched by roughly
three times.  Its `341100 -> 341002` write-frame failures cannot be used as a
clean verdict on correctly timed SDRAM derating.

## Design

Change only the SDRAM PLL outputs and the controller's matching period macro:

| Output | Frequency | Phase | Divide | Phase tap |
| --- | ---: | ---: | ---: | ---: |
| C0 / SD-card domain | 100 MHz | 0 degrees | 10 | 9 |
| C1 / `ext_mem_clk` | 62.5 MHz | 0 degrees | 16 | 15 |
| C2 / `ext_mem_clk_sft` | 62.5 MHz | 180 degrees | 16 | 7 |

Set `SDR_CLK_PERIOD` to `1000000000/62500000`.  This halves the refresh
counter's cycle count relative to 125 MHz and therefore preserves its physical
refresh interval.  C0, the separate video PLL, all RTL behavior, pin
constraints, burst sizes, FIFO depths, diagnostics, audio, OSD, FAT32 loading,
and the accepted crossfade remain unchanged.

The crossfade consumes 36.864 million 32-bit words per second at
640x480x60 with two source frames.  A 62.5 MHz interface retains useful margin
over that average demand for 64-word bursts, while doubling the DQ half-cycle
window from 4 ns to 8 ns.  This is a balanced stability experiment, not a claim
of timing closure before the routed report and board test exist.

## Verification and Acceptance

1. Source checks must show C1/C2 divide values `16/16`, phase taps `15/7`,
   IPC frequencies `62.5 MHz`, and a 62.5 MHz `SDR_CLK_PERIOD`.
2. Run the five existing focused Icarus regressions and elaborate the real top
   level with the generated FIFO sources.
3. In TD 6.2.1, rebuild `syn_1`, `phy_1`, and the bitstream.  Record resource
   use plus `SWNS`, `STNS`, and `HWNS`.
4. JTAG-download only.  Do not update configuration Flash.
5. Confirm first-image loading completes without `341100` or `341002`, then
   exercise at least ten manual transitions, several automatic cycles, audio,
   OSD, and TF removal/reinsertion.
6. Accept only if the image remains clean and the final diagnostic digit stays
   zero.  A nonzero digit returns investigation to FIFO continuity; corruption
   with digit zero means the DQ path still needs a different operating point or
   a single-frame fallback.

## Result (2026-09-09)

The experiment failed visual acceptance.  TD correctly generated both SDRAM
clocks at 62.5 MHz.  Final timing was `SWNS=-3.766ns`, `STNS=-189.381ns`, and
`HWNS=+0.004ns`; the global worst path moved to unrelated 100 MHz FAT32/WAV
logic.  More importantly, the two hard-SDRAM DQ setup groups were `+1.092ns`
for `ext_mem_clk -> C2` and `-2.565ns` for `C2 -> ext_mem_clk`.  The latter is
the SDRAM read-data direction and remains outside timing.

The JTAG build loaded images without `341100` or `341002`, confirming that the
matched refresh-period correction removed the earlier derating experiment's
write timeout.  Transition corruption remained, however, matching the
negative DQ read timing.  The bitstream was generated at 20:52 with SHA256
`9F877864246163AD14F0B5863EBE6DC4527D9FF8277F8C3F9A26ACB760A0AB33` and is
rejected for final use.
