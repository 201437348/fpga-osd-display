# 50 MHz Phase-Balanced SDRAM Crossfade Design

## Decision

Run one final dual-frame SDRAM experiment at 50 MHz with the shifted clock at
144 degrees.  This keeps the shifted edge at the same absolute 8 ns offset
used by the measured 62.5 MHz build while extending the unshifted clock period
from 16 ns to 20 ns.  The accepted crossfade and all media RTL remain
unchanged.

## Evidence

The 62.5 MHz route measured these hard-SDRAM DQ setup groups:

| Direction | Timing budget | Setup slack |
| --- | ---: | ---: |
| `ext_mem_clk -> C2` (write) | 8 ns | `+1.092 ns` |
| `C2 -> ext_mem_clk` (read) | 8 ns | `-2.565 ns` |

At 50 MHz with C2 still rising 8 ns after C1, the write budget remains 8 ns
and the next C1 edge moves from 16 ns to 20 ns.  The read budget therefore
becomes 12 ns.  Assuming the measured routed delays remain comparable, the
expected DQ setup slacks are approximately `+1.092 ns` write and `+1.435 ns`
read.  TD's routed report, rather than this arithmetic estimate, is the
acceptance authority.

The PLL VCO remains 1 GHz.  The exact output settings are:

| Output | Frequency | Phase | Absolute offset | Divide | Phase tap |
| --- | ---: | ---: | ---: | ---: | ---: |
| C0 / SD-card domain | 100 MHz | 0 degrees | 0 ns | 10 | 9 |
| C1 / `ext_mem_clk` | 50 MHz | 0 degrees | 0 ns | 20 | 19 |
| C2 / `ext_mem_clk_sft` | 50 MHz | 144 degrees | 8 ns | 20 | 7 |

For this generated PLL convention, the coarse rising-edge offset is
`(CPHASE + 1) * VCO_PERIOD`, modulo the output period.  With a 1 GHz VCO,
`DIV=20, CPHASE=7` therefore gives an 8 ns offset: `8 / 20 * 360 = 144`
degrees.  The zero-degree C1 setting uses `CPHASE=19`, whose 20 ns offset wraps
to the start of the next output period.

## Alternatives Rejected

A 45.45 MHz 0/180-degree pair would also be expected to make both DQ setup
directions positive, but the dual-frame stream would consume over 81% of its
theoretical one-word-per-cycle bandwidth before SDRAM command and return gaps.
The 50 MHz phase-balanced pair preserves the same predicted minimum DQ margin
with about 10% more memory bandwidth.

The board-proven single-frame fade is the fallback if this experiment fails.
It is not selected yet because it cannot produce the true old/new transparency
effect that passed visual review.

## Scope

Change only `sys_pll.v`, `sys_pll.ipc`, and the active `SDR_CLK_PERIOD` macro.
Set the period macro to `1000000000/50000000`; the refresh count becomes 1562
cycles, or approximately 31.24 us at 50 MHz, matching the established physical
cadence.  Do not change C0, the video PLL, transition controller, blender,
64-word read bursts, 4096-word FIFOs, diagnostics, FAT32 logic, audio, OSD,
reset behavior, or constraints.

## Verification and Stop Conditions

1. Mechanically verify C1 `DIV/CPHASE=20/19`, C2 `DIV/CPHASE=20/7`, IPC
   frequencies of 50 MHz, C2 phase of 144 degrees, and the 50 MHz period macro.
2. Run the five focused Icarus regressions and real dual-FIFO top elaboration.
3. Rebuild TD `syn_1`, `phy_1`, and bitstream.  Both DQ setup groups must be
   non-negative; also record hold slack and the unrelated 100 MHz path.
4. JTAG only.  Confirm first-image loading has no `341100/341002`, then test at
   least ten manual transitions and several automatic cycles.
5. A nonzero last diagnostic digit means 50 MHz lacks sustained dual-read
   throughput.  Corruption with a zero digit despite non-negative DQ timing
   means the dual-frame path is not dependable with the available hard macro.
   Either result ends clock experimentation and triggers the single-frame
   fallback.  Do not program configuration Flash before complete acceptance.

## Invalid Phase Attempt (2026-09-09 21:08)

The first source implementation incorrectly used `CLKC2_CPHASE=11` while its
comment and IPC metadata said 144 degrees.  TD's derived-clock report correctly
showed that the primitive actually produced 216 degrees with a rising edge at
12 ns.  That left the read budget at 8 ns: DQ write setup improved to
`+5.130ns`, but DQ read setup remained exactly `-2.565ns`.  The board loaded
images without `341100/341002` and still corrupted transitions, as expected
for the unchanged read violation.

That build did not test this design's intended 8 ns sampling point.  Its
bitstream SHA256 is
`8CB458E71F0E6591678A66610A65FE91A49066B24102C777413E1C6AC65B5B8B` and it is
rejected.  The source correction is `CLKC2_CPHASE=7`; TD must report C2 phase
144 degrees and a rising edge at 8 ns before the corrected build is tested.
