# Formal Video Baseline Migration

Date: 2026-09-03

## Migration boundary

`fpga/osd_display` is an independent TD 6.2.1 project for the formal video
baseline. The diagnostic project at `fpga/tf_hdmi_diag` remains unchanged as a
phase-0 reference. The official resource package is not modified.

The first migration copy contains every HDL, IP and constraint referenced by
the June pure-video `.al` project, including files marked `AutoExcluded` by TD.
The project top is `rtl/top/top.v`; its current behavior is the validated
10-second timeout baseline. Generated `_Runs`, logs and programming artifacts
are excluded by the repository rules.

The IPC files also require their generated support files to remain beside the
IPC: both FIFO `.tcl` files and the `sys_pll.vhd` / `video_pll.vhd` companions
are included, even though the active build selects the Verilog implementations.

Two vendor include paths had to be adapted to the new local directory layout:

- `rtl/vendor/include/sdr_init_ref.enc.v` now includes `global_def.v` from its
  own include directory.
- `rtl/vendor/SD/sdram.v` now includes `../include/global_def.v`.

The adapted file hashes and the pre-adaptation source hashes are recorded in
`fpga/osd_display/vendor-manifest.sha256`.

## Tested project-owned boundary

`rtl/control/image_load_manager.v` is a standalone control boundary for the
next migration step. It provides:

- explicit reset, scan, load, verify, commit, idle and recovery states;
- a ten-second parameterized load guard;
- up to two retries per image;
- test-pattern fallback after repeated first-image failure;
- previous-frame retention when a later image fails;
- inactive-buffer selection for atomic frame commits;
- storage-loss recovery without invalidating an already displayed frame.

It is intentionally not connected to the migrated top until the functionally
equivalent TD build and board test have passed.

## Verification status

`tests/tb_image_load_manager.sv` passes with shortened timeout parameters in
Icarus Verilog. TD `syn_1`/`phy_1`, JTAG equivalence, configuration-Flash cold
starts, SDRAM timing review and the 30-minute automatic-play test are pending
hardware/tool execution. A full top-level Icarus compile is not a valid
replacement for TD: the migrated design contains vendor-encrypted HDMI/SDRAM
wrappers and Anlogic primitives that Icarus cannot parse or elaborate. The
project-owned control boundary is therefore tested separately, while the
functionally equivalent top is reserved for TD validation.

### TD 6.2.1 migration build

On 2026-09-03, TD 6.2.1 completed `syn_1` and `phy_1` for
`osd_display.al`; bitgen completed at 16:40:25. The two bit locations below
have the same SHA256:

```text
05ca4640de35fee1f58a5d7889c58da3175029d0be588300fb5017fb15919a4d
osd_display_Runs/best_result/osd_display.bit
osd_display_Runs/phy_1/osd_display.bit
```

Final implementation resources were 3538 LUT, 3113 registers, 14 BRAM9K,
2 PLL and 2 global clocks. IPC load errors are resolved. Final routed timing
was `SWNS=-6.565ns`, `STNS=-296.897ns`, `HWNS=0.000ns` and `HTNS=0.000ns`.
The remaining critical warnings are inherited from the diagnostic baseline:
both requested `U3/sdram` locations are not honored, and the phase-shifted
`U3/u2_ram/SDRAM_CLK` uses one local routing segment. The negative SDRAM
timing must be investigated before this baseline can be accepted as timed.

The next acceptance operation is JTAG-only equivalence testing. Do not write
configuration Flash until JTAG behavior, reset, manual switching and automatic
play have passed.

### JTAG equivalence result

JTAG testing of the migration bit completed successfully on 2026-09-03 with
the established board, HDMI connection and TF card containing four official
BMP images. First image display, `KEY1` user reset, `KEY2` manual switching
and `KEY4` automatic-play control all behaved correctly.

The first image appeared about 22 seconds after power-on. The diagnostic
baseline exhibits the same delay. `LOAD_TIMEOUT_SECONDS=10` is only the guard
that starts after an image load has begun; it is not a boot-to-picture delay.
The observed 22 seconds include TF initialization, physical-sector scanning
and first-frame transfer. No startup-time optimization is part of this
reliability-baseline acceptance step.

Next: program only the FPGA configuration Flash, perform three power-off cold
starts with the same TF card and HDMI setup, and record the first-image result
and approximate display time for each start.

### Configuration Flash cold-start result

The configuration-Flash image was programmed from the validated migration
bitstream. Three power-off cold starts completed successfully with the same
board, TF card and HDMI setup. Each boot displayed the first image after about
22 seconds, matching the JTAG and diagnostic-baseline result.

The next board acceptance operation is a 30-minute automatic-play run. Enable
automatic play with `KEY4` only after the first image is visible; verify that
images continue to switch, the HDMI output stays locked, and `KEY2` / `KEY4`
remain responsive near the end of the run.

### Automatic-play result

The 30-minute automatic-play run completed successfully. HDMI output remained
stable, images continued to switch, and the manual/automatic-play controls
remained responsive. The migration-equivalence baseline is therefore accepted
for normal TF-card operation. The next implementation boundary is the tested
image-load recovery manager, followed by fault-injection board tests and the
separate SDRAM timing review.

### Recovery-control integration status

The recovery controller is now connected in `rtl/top/top.v` without changing
the TF/BMP reader, frame FIFO, SDRAM interface or HDMI transport path. The
new top-level control boundary uses `image_storage_adapter` for the vendor
reader, `image_load_manager` for scan/load/commit/retry control, and
`image_playback_control` for `KEY2` manual switching and `KEY4` automatic
play. The SDRAM write-finish event crosses back to the manager through a
synchronized toggle. Manager display state and buffer selection are
synchronized into the video clock domain before they select output pixels.

Project-owned simulations passed on 2026-09-03:

- `tb_image_load_manager`: first-frame commit, retry, skip, previous-frame
  retention, storage loss and fallback behavior.
- `tb_image_storage_adapter`: final scan-sector capture, stale scan-complete
  rejection, source busy-to-ready completion and abort suppression.
- `tb_image_playback_control`: button debounce, manual next, automatic play
  and automatic-request suppression during an auto-play toggle.
- A top-level syntax/elaboration check passed using local black boxes for the
  encrypted vendor IP. It checks project-owned ports and connections only; it
  is not a substitute for TD.

This integration is not yet TD-built or board-validated. The required next
operation is a TD `syn_1`, `phy_1` and bitgen build from the root
`osd_display.al`, followed by JTAG-only normal-card equivalence testing.
Do not overwrite configuration Flash with this integration build before first
image display, `KEY1` reset, `KEY2` manual next and `KEY4` automatic play all
pass. Fault injection and the separate SDRAM timing review remain pending.

### Recovery-control and FIFO-throttle board result

The integrated recovery path and sector-based write-FIFO throttle have now
passed TD build and board validation. With no TF card present at boot, the
design displays the colour-bar fallback. If a valid image is already shown,
removing the TF card and requesting the next image retains that image. After
the card is reinserted and initialization completes, manual switching and
automatic play recover normally.

The short-interval button cases were also retested. Request coalescing,
recovery-state convergence and sector throttling removed the observed long
`341100` retry and the `321100` wait condition. First-image display, manual
switching, automatic play and TF removal/reinsertion recovery all passed on
the established board, card, four-BMP and HDMI setup.

### SDRAM timing review and pending clock-derate experiment

The routed `SWNS=-6.565ns` is a real SDRAM hard-macro DQ timing violation,
not a path to suppress. The worst path is from `ext_mem_clk` to the
180-degree `sys_pll_m0/pll_inst.clkc[2]` DQ domain; the reverse direction is
`-2.908ns`. The official 2026-06-05 `lab_ex4_tf` routed report has the same
path groups and the same `-6.565ns` worst slack. This establishes that the
issue predates this project's recovery controller and FIFO changes.

The approved experiment changes only `sys_pll` C1/C2 from 125 MHz (0/180
degrees) to 41.667 MHz (0/180 degrees). The generated Verilog and active IPC
now use divide-by-24, with phase taps 23 and 11 respectively. The 100 MHz SD
clock, 25 MHz video clock, 125 MHz HDMI serial clock, RTL and constraints are
unchanged. This source change is awaiting a TD build and JTAG-only board
test; configuration Flash must not be programmed. Passing requires
non-negative setup slack in both DQ directions plus normal first image,
manual/close-spaced switching, automatic play and TF-card recovery. Rollback
is C1/C2 divide-by-8 with phase taps 7 and 3.

### Clock-derate result: rejected

The 41.667 MHz TD build completed on 2026-09-04. Routed timing was
`SWNS=-1.526ns`, `STNS=-7.172ns`, `HWNS=0.037ns` and `HTNS=0.000ns`. The
specific SDRAM DQ groups passed: `ext_mem_clk -> clkc[2]` was `+4.983ns` and
`clkc[2] -> ext_mem_clk` was `+1.435ns`. Remaining negative paths are the
`rst_all` release path from `clk` to `ext_mem_clk` (`-0.823ns`) and the
asynchronous-FIFO-clear path from `ext_mem_clk` to `sd_card_clk` (`-1.526ns`).

JTAG functional validation rejects the 41.667 MHz version. First image and
ordinary manual switching work, but automatic playback repeatedly reaches
`341100` for about ten seconds before `341002` and a retry eventually switches
the image. The digits mean the BMP source completed but the SDRAM full-frame
write completion was never observed; error `2` confirms the ten-second load
timeout. The same timeout can occur on a single manual request after TF-card
removal and reinsertion, so it is not an auto-play button issue. The reduced
clock cannot complete all write-frame transactions reliably. Do not program
this build to configuration Flash; retain the accepted 125 MHz Flash image
and restore the experiment's divide-by-8 PLL parameters before other timing
closure work. On 2026-09-04 the workspace IPC and generated Verilog were
restored to C1/C2 divide-by-8 with phase taps 7 and 3; TD and JTAG rollback
verification then passed. The 15:17 routed report is `SWNS=-6.565ns`,
`STNS=-299.804ns`, `HWNS=0.011ns` and `HTNS=0.000ns`; the DQ groups are
`-2.908ns` from `ext_mem_clk` to `clkc[2]` and `-6.565ns` in reverse. The
JTAG bit SHA256 is
`ad7ed0cdf25b65593158fa4af513758625fdefe1d183d7260805b6d8bb8702b9`.
The established automatic-play and TF-card recovery behavior returned with
no `341100` timeout. This bit was not written to configuration Flash.

### Session handoff

This session is complete. The recovery controller, TF-card fallback and
reinsertion behavior, close-spaced button handling, and sector-based
write-FIFO throttling are board-validated. The configuration Flash remains
on the previously accepted 125 MHz baseline; the clock-derate experiment has
not been programmed to Flash.

The next work must not be another blind SDRAM-frequency experiment. Keep the
accepted 125 MHz JTAG and Flash baselines unchanged while separately designing
the `rst_all` release crossing, the `ext_mem_clk -> sd_card_clk` FIFO-clear
protocol and a throughput-preserving solution for the 125 MHz SDRAM DQ paths.

### Reset-release synchronization experiment: reverted

On 2026-09-04, a three-stage asynchronous-assertion/synchronous-release reset
wrapper was added for `sd_card_clk`, `ext_mem_clk` and `video_clk`. The local
tests, TD build and bit generation passed. Routed timing was `SWNS=-6.565ns`,
`STNS=-300.403ns`, `HWNS=0.011ns`, `HTNS=0.000ns`; the project-owned
`clk -> ext_mem_clk` reset path became positive at `+0.494ns`. The existing
`ext_mem_clk -> sd_card_clk` FIFO-clear crossing remained negative at
`-1.124ns`.

JTAG validation failed acceptance: after the first image, repeated manual
requests and some TF remove/reinsert recovery cases frequently entered
`341100` for about ten seconds, then `341002` and retry. The code means the
BMP source completed but the SDRAM full-frame write completion did not return.
The stable 125 MHz rollback behavior was not preserved. The changed source
could have altered placement/routing and exposed the pending FIFO-clear issue,
so this result does not prove the reset wrapper alone is the root cause.

The reset wrapper, its top-level connections and both TD project-list entries
were removed. Its generated bitstream hash was
`608F9430C264611843FC6D1D26761290F0155580AFDD48736C0D072EC39C3011`; do not
program it to configuration Flash. The current source is restored to the
pre-experiment reset topology. Rebuild it in TD and JTAG-test the established
normal-card sequence before taking the next timing-closure step.

The rollback rebuild and JTAG retest then passed. TD bit generation completed
at 16:04 on 2026-09-04 with routed timing `SWNS=-6.565ns`,
`STNS=-299.804ns`, `HWNS=0.011ns` and `HTNS=0.000ns`. The rebuilt JTAG bit is
`osd_display_Runs/phy_1/osd_display.bit`, SHA256
`32F292C2C1E2E7DFC9174598F3718349F87540F80D01A5629436B2CEB749ACB4`.
Board behavior returned to the pre-experiment 125 MHz baseline. This bit is
accepted only as the current JTAG baseline; configuration Flash was not
updated.

### OSD v1: visual validation passed; storage stability remains unresolved

On 2026-09-04, work moved to a visible feature that is isolated from the
unresolved SDRAM and CDC timing debt. `rtl/video/video_osd_overlay.v` adds an
always-visible OSD entirely in the 25 MHz `video_clk` domain. It is inserted
after image/fallback selection and before the existing RGB-to-AXIS converter.
It has a dark-blue top bar with `OSD DISPLAY` and a dark-blue bottom bar with
one of `WAIT TF`, `FALLBACK`, `IMAGE B0`, or `IMAGE B1`. The selected status
uses only the video-domain-safe display state, so the TF, SDRAM, FIFO, clock,
reset, button, CDC and encrypted HDMI paths are unchanged.

The OSD module is registered in both `osd_display.al` project lists. Icarus
unit tests passed for OSD transparency, bar background, title glyph, all
status colours and buffer indication. The existing image-load manager,
playback control, BMP throttle and storage-adapter tests also passed, as did a
top-level syntax/connection check using vendor stubs.

The TD build and JTAG board test then completed. The OSD remains visible
during first-image display, manual next, automatic playback, TF removal and
TF reinsertion. Its bottom status is correct in those cases, including the
intentional retained-image `IMAGE B0`/`IMAGE B1` status after card removal and
the `FALLBACK` status when the fallback colour pattern is displayed.

This confirms the OSD itself, but it does not create a stable new playback
baseline. Manual next has intermittent `341100` timeouts; automatic playback
and post-reinsertion loading show the same timeout at a lower rate. The
timeout still means that the BMP source completed while the SDRAM full-frame
write completion did not return before the ten-second protection limit. The
OSD has no connection to that control path other than changing the overall
implementation placement.

The 16:44 routed report for this build is `SWNS=-6.565ns`,
`STNS=-294.223ns`, `HWNS=+0.004ns` and `HTNS=0.000ns`; bit SHA256 is
`F8C1754F9332C7B89BB122DC683783E80078784F781B4788251D655073876077`.
The worst path remains SDRAM DQ input timing, from
`sys_pll_m0/pll_inst.clkc[2]` through `U3/sdram.dq[*]` to the
`ext_mem_clk` capture registers, at `-6.565ns`. The opposite DQ direction is
`-2.829ns`, slightly better than the accepted baseline's `-2.908ns`; therefore
the report does not support claiming that OSD worsened the worst setup path.
The total hold margin did fall from `+0.011ns` to `+0.004ns`, which leaves
essentially no implementation margin.

The report also confirms the separate FIFO-clear crossing: the
`ext_mem_clk`-registered
`frame_read_write_m0/frame_fifo_write_m0/fifo_aclr` signal combinationally
reaches `image_storage_adapter_m0/u_bmp_read` state logic in the
`sd_card_clk` domain with `-0.974ns` setup slack. This is the concrete path to
use when reviewing Anlogic asynchronous-FIFO clear/reset guidance; it must not
be dismissed as a harmless timing-report artefact without checking the IP's
documented reset protocol.

Keep the OSD source for further work, but do not program this bit to
configuration Flash and do not treat it as a stable replacement for the
accepted 125 MHz JTAG baseline. The next technical task is not another blind
feature or frequency change: obtain Anlogic documentation or a verified
reference for `EG_PHY_SDRAM_2M_32`/the generated SDRAM hard macro, its
PLL-phase and DQ timing requirements, and the asynchronous FIFO reset/clear
requirements. Those two boundaries must be understood before layout-sensitive
playback reliability can be claimed.

### Official FIFO/SDRAM evidence and approved acknowledgement CDC repair

On 2026-09-04, the official IPUG012 Soft FIFO manual and APUG011 high
performance SDRAM reference were reviewed. The generated project FIFO RTL
matches IPUG012's asynchronous-assertion, per-clock synchronous-release reset
mode: both FIFO instances include independent read- and write-clock release
registers. IPUG012 specifies release after four local clock cycles and warns
not to disable its generated Gray-pointer CDC timing constraints. Therefore
the routed net name `fifo_aclr` is not evidence that the FIFO reset protocol
needs to be replaced; neither the FIFO IP nor its clock constraints will be
changed in this step.

The review instead found a concrete, independent CDC defect. `write_req`
crosses from the SD reader into `ext_mem_clk` through three registers in
`frame_fifo_write`, but its reverse `write_req_ack` was sampled directly by
the SD-clocked `bmp_read` state machine. Synthesis can merge that register
with `fifo_aclr`, explaining the routed report's `fifo_aclr` name at the
reader endpoint. The approved repair adds a two-stage synchronizer in
`image_storage_adapter` and connects only the synchronized level to
`bmp_read`. The request/acknowledgement remains a level handshake, so the
extra two SD-clock cycles cannot lose the acknowledgement.

APUG011 also confirms the separate SDRAM limitation: actual board frequency
and phase may cause a one-cycle SDRAM data error and must be adjusted for the
hardware; transactions must respect SDRAM busy/refresh state. This repair does
not claim to close the existing SDRAM DQ timing violations. It is a bounded
CDC correction to be built and tested by JTAG only before further SDRAM work.

Implementation is now present in `rtl/storage/image_storage_adapter.v`.
`bmp_read` receives `write_req_ack_sync`, the second of two SD-clocked
registers, instead of the raw acknowledgement. The adapter test now checks
both edges of that two-clock propagation. On 2026-09-04, the adapter,
load-manager, playback-control, BMP-throttle and OSD tests all passed in
Icarus, and a top-level port/connection elaboration using vendor black boxes
passed. TD `syn_1`, `phy_1`, bit generation, routed-report review and JTAG
board validation are still required; configuration Flash must remain unchanged.

### Acknowledgement CDC implementation build

TD `syn_1`, `phy_1` and bit generation completed at 17:38 on 2026-09-04 for
the acknowledgement CDC source. The generated JTAG bit is
`osd_display_Runs/phy_1/osd_display.bit`, SHA256
`F077F5A5746C6C85E63C64B868A44AC772D6EE733E3A981B673D976497CD4C60`.
Routed timing is `SWNS=-6.565ns`, `STNS=-292.832ns`, `HWNS=+0.011ns` and
`HTNS=0.000ns`; it does not regress the known worst SDRAM DQ setup path.

The report confirms the intended CDC topology. The memory-side net that TD
still names `fifo_aclr` now ends at
`image_storage_adapter_m0/write_req_ack_meta_reg_syn_5`, the first stage of
the new SD-clock synchronizer, with `+1.132ns` setup and `+0.252ns` hold
slack. It no longer ends in `image_storage_adapter_m0/u_bmp_read` state
logic. The DQ direction from the SDRAM hard macro into `ext_mem_clk` remains
at `-6.565ns` and the reverse DQ direction remains at `-2.908ns`; neither is
changed or accepted by this CDC repair.

Next: JTAG-only board validation of first image, repeated manual next,
close-spaced manual requests, automatic play, and TF removal/reinsertion.
Do not program configuration Flash with this bit.

### Acknowledgement CDC first JTAG board result

The acknowledgement CDC bit was JTAG-programmed and exercised on 2026-09-04.
First image display was normal. Repeated single manual-next requests issued as
soon as the preceding image completed did not produce a timeout. Multiple
manual-next pairs with approximately 0.5 seconds between the two presses also
completed normally. Automatic play completed multiple switch groups with no
`341100` timeout.

TF removal/reinsertion retained the established recovery trace:
`341000`, then `341002`, then `540003`; after reinsertion and the next request
it showed `100003` and recovered to normal image operation. This is expected
recovery behavior, not a regression. The first JTAG run therefore passes the
targeted functional checks. It is not yet a configuration-Flash acceptance:
the remaining SDRAM DQ setup violation requires extended stress testing and
separate timing work.

Extended JTAG stress then completed without any `341100` occurrence: 30
successive single manual-next operations, 20 manual double-press groups with
about 0.5 seconds between presses, 30 minutes of automatic play, and three
complete TF removal/reinsertion recovery cycles all passed. The two-flop
`write_req_ack` synchronizer is therefore accepted as the fix for the observed
intermittent acknowledgement CDC failure. The configuration Flash remains
unchanged because the independent hard-SDRAM DQ setup violations remain
negative; this source placement must not be represented as timing-closed.
