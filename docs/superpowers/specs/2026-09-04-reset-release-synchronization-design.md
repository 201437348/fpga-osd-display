# Reset Release Synchronization Design

## Problem

`rst_all` is generated in the 50 MHz input-clock domain after the PLL lock
guard. It is currently passed directly to logic clocked by `sd_card_clk`,
`ext_mem_clk` and `video_clk`. Its deassertion is therefore asynchronous to
those receiving domains.

The 125 MHz routed report contains a `clk -> ext_mem_clk` path with
`SWNS=-0.378ns`, beginning at the root-reset register and ending in the SDRAM
write-side control. This is a real reset-release crossing. It is independent
of the hard-SDRAM DQ violation and of the `ext_mem_clk -> sd_card_clk` FIFO
control crossing.

## Scope

Add a project-owned `reset_release_sync` module. It accepts an active-high
asynchronous reset and produces an active-high local reset with these rules:

- assertion is immediate;
- deassertion occurs only after three rising edges of the receiving clock;
- the three stages are reset to `3'b111` on every assertion.

Instantiate it in `rtl/top/top.v` for `sd_card_clk`, `ext_mem_clk` and
`video_clk`, producing `rst_sd`, `rst_mem` and `rst_video`.

Use the local resets for the project-owned single-clock boundaries:

| Local reset | Consumers |
| --- | --- |
| `rst_sd` | TF storage adapter, image-load manager, playback controller, SD-domain write-finish synchronizer |
| `rst_mem` | SDRAM wrapper, frame read/write wrapper, memory-domain write-finish toggle |
| `rst_video` | video timing, video delay, display-state synchronizer, fallback pattern and RGB-to-AXIS converter |

The HDMI encrypted multi-clock wrappers retain their existing reset interface
in this change. Their internal clock/reset contract is not inspectable, and
they are outside the reported `clk -> ext_mem_clk` path. The top-level reset
guard and its 20 ms PLL-lock delay remain unchanged.

## Exclusions

This change does not alter:

- `sys_pll` or any clock frequency or phase;
- the FIFO asynchronous-clear protocol or `ext_mem_clk -> sd_card_clk` path;
- SDRAM DQ timing, pin constraints or timing exceptions;
- image loading, retry policy, TF recovery, playback interval or frame-buffer
  behavior;
- configuration Flash contents.

No `false_path` is added.

## Verification

1. Add an Icarus testbench for `reset_release_sync` with unrelated local clock
   periods. Check immediate assertion, three local rising edges before release
   and repeatable reassertion.
2. Keep existing project-owned control tests passing.
3. Build the root TD project through `syn_1`, `phy_1` and bit generation.
   Record `SWNS`, `STNS`, `HWNS`, plus the `clk -> ext_mem_clk` and
   `ext_mem_clk -> sd_card_clk` groups. The first group must no longer trace
   from the raw root-reset register.
4. JTAG-test first image, manual next image, close-spaced manual requests,
   automatic play, TF removal and TF reinsertion recovery. Do not program
   configuration Flash.

## Acceptance Boundary

Success removes the unsafe project-owned root-reset release crossing without
regressing the established 125 MHz behavior. It does not require non-negative
global SWNS because SDRAM DQ timing and FIFO-clear crossing remain explicitly
open work items.

## Implementation and JTAG Result

The implementation added one three-stage synchronizer for each of
`sd_card_clk`, `ext_mem_clk` and `video_clk`. The synchronizer unit test,
project-owned control tests, top-level stub elaboration, TD synthesis, TD
place-and-route and bit generation all passed.

The 2026-09-04 15:44 routed result was `SWNS=-6.565ns`,
`STNS=-300.403ns`, `HWNS=0.011ns` and `HTNS=0.000ns`. The project-owned
`clk -> ext_mem_clk` reset release endpoint was replaced by the local
`rst_mem` synchronizer and reported `+0.494ns`. The deferred
`ext_mem_clk -> sd_card_clk` FIFO-clear group remained negative at
`-1.124ns`.

JTAG functional validation rejected the implementation. The first image and
automatic playback initially worked, but repeated manual image requests and
some TF-card recovery cases frequently reached `341100` for about ten seconds
before `341002` and a retry. This state means the BMP source completed but the
SDRAM frame-write completion did not return. The accepted 125 MHz baseline
does not show this behavior.

The root cause is not proven to be the synchronizer itself: adding it caused
a new place-and-route result and can expose the already open FIFO asynchronous
clear crossing. Regardless of cause, the regression fails the acceptance
boundary. The reset-release implementation was therefore removed from source
and both TD project file lists. The generated failing bitstream, SHA256
`608F9430C264611843FC6D1D26761290F0155580AFDD48736C0D072EC39C3011`, must not
be programmed to configuration Flash. Rebuild the restored source and perform
the same JTAG test sequence before further timing work.

That source rollback was rebuilt through TD `syn_1`, `phy_1` and bit
generation at 16:04 on 2026-09-04. Its routed timing returned to
`SWNS=-6.565ns`, `STNS=-299.804ns`, `HWNS=0.011ns` and `HTNS=0.000ns`.
The resulting JTAG-only bit has SHA256
`32F292C2C1E2E7DFC9174598F3718349F87540F80D01A5629436B2CEB749ACB4`.
Board retest restored the earlier established behavior; the regression from
the reset-release experiment was absent. This is the current source and JTAG
baseline. Configuration Flash remains unchanged.
