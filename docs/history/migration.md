# Formal Video Baseline Migration（归档）

> **已归档（2026-09-24）。** 本文是正式视频基线迁移的英文过程记录，
> 内容停在 2026-09-13，其后的工作全部记录在中文文档中。
>
> - 当前规划与状态：[`../roadmap.md`](../roadmap.md)
> - 中文上板流水账：[`board-log.md`](board-log.md)
>
> 保留原文以维持与既有设计文档的交叉引用（`docs/superpowers/specs/` 中多处引用本文件）。

---

# Formal Video Baseline Migration

Date: 2026-09-13
Current status: line-buffer horizontal transition board-validated; stable baseline frozen

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

### C2 explicit global-clock route experiment: rejected and reverted

On 2026-09-04, one controlled routing experiment inserted an explicit
`EG_LOGIC_BUFG` after the existing 125 MHz, 180-degree `sys_pll` C2 output and
before the unchanged SDRAM shifted-clock input. C1/C2 frequency and PLL phase
parameters, all protocol RTL, constraints, FIFO IP, OSD, and board settings
were unchanged.

The 19:20 TD build proved that the route request took effect: TD retained
`sys_pll_m0/bufg_sdram_clk_sft`, identified `U3/u2_ram/SDRAM_CLK` as
BUFG-driven, and reported that all clock nets avoided local routing resources.
This removed the earlier local-route critical warning, but it did not improve
the real SDRAM interface. The DQ setup path from `ext_mem_clk` to C2 worsened
from `-2.908 ns` to `-2.964 ns`; the reverse C2-to-`ext_mem_clk` path worsened
from `-6.565 ns` to `-6.692 ns`. Final global timing was `SWNS=-6.692 ns`,
`STNS=-298.147 ns`, `HWNS=+0.012 ns`, and `HTNS=0.000 ns`.

The inserted global buffer therefore adds harmful C2 insertion delay for this
hard-SDRAM path. The source was restored to the direct PLL-C2 connection and
matches the accepted CDC baseline again. The rejected bit SHA256 is
`3D5E2797E9B534F319DF68BF1F7B6628F98438F0362CFAB8FC607F1BED82ECCE`; do not
download it through JTAG or write it to configuration Flash. The local-route
warning is consequently an observation to retain, not a sufficient reason to
insert a generic BUFG.

### SDRAM hard-macro audit: completed, placement is not user-editable

The restored direct-C2 source was rebuilt on 2026-09-04 without programming
JTAG or configuration Flash. TD 6.2.168116 reports `SWNS=-6.565ns`,
`STNS=-292.832ns`, `HWNS=+0.011ns`, and `HTNS=0.000ns`. The two known SDRAM
DQ setup directions remain `-2.908ns` from `ext_mem_clk` to C2 and
`-6.565ns` from C2 to `ext_mem_clk`; this is the accepted acknowledgement-CDC
source, not a new timing result. The audit-only output bit SHA256 is
`21EFB4E31E9126737717D73197C90F39A01DEC16185D81D3123B163B168B4651`.
Its function was not board-tested, so it must not be downloaded or treated as
the board-validated `F077...4C60` CDC bit.

The audit has resolved the confusing `PHY-7002` messages. TD first rejects
the imported `U3/sdram` initial coordinates `(12,12)` and later `(164,288)`,
but the final routed timing report places the actual hard-IP clock and DQ pins
at `x020y036`. The two rejected coordinates are not final locations.

The report path also establishes the direct-C2 topology: PLL
`sys_pll_m0/pll_inst.clkc[2]` drives `U3/u2_ram/SDRAM_CLK` (fanout one), then
an internal pin at `x040y041`, then `clk0`, and finally `U3/sdram.clk` at
`x020y036`. TD explicitly reports that this net is routed on the clock mesh
but contains one local-routing segment. Thus the earlier local-route warning
is real, but the rejected explicit BUFG experiment already proved that
forcing a global buffer worsens both DQ setup directions.

TD cannot safely expose more detail for this encrypted hard macro in the
current tool/device combination. The Tcl query
`report_cells U3/sdram -pin_loc -connection` immediately terminates TD, and
the implementation log says `report_clock_utilization` is unsupported for
`EG4S20BG256`. Do not rerun those Tcl commands. `constraints/pin.adc` has no
`U3/sdram` location, and no supported user constraint syntax or legal-site
map has been found. Do not guess or add a manual coordinate.

The next SDRAM physical step, only if timing closure is required, is to obtain
from Anlogic a TD 6.2-compatible `EG_PHY_SDRAM_2M_32` reference/generated
wrapper for EG4S20BG256, including its legal hard-macro placement and C2 clock
topology. Until then, retain the board-validated direct-C2 CDC baseline and
do not attempt another frequency, phase, BUFG, or placement experiment.

### Official-source cross-check: the SDRAM warnings are baseline behaviour

On 2026-09-04, the official competition source at
`HX4S20_Contest_202606/赛题源码/anlogic_example/anlogic_example/lab_ex4_tf`
was checked against this project. Its completed `phy_1` run contains the same
two `PHY-7002` messages for `U3/sdram` initial locations `(12,12)` and
`(164,288)`, the same `PHY-5079` local-routing warning for PLL C2 to
`U3/u2_ram/SDRAM_CLK` (`Clock/Fanout 0/1`, `LocalWireNum 1`), and the same
worst C2-to-`ext_mem_clk` SDRAM DQ setup slack of `-6.565ns`.

The current `rtl/vendor/SD/sdram.v` has the same hardware-macro topology as
the competition original: `sdr_as_ram` receives direct C1/C2 clocks and
instantiates `EG_PHY_SDRAM_2M_32` without any macro placement constraint.
The current `sdr_as_ram.enc.v` and `sdr_wrrd.enc.v` are byte-identical to the
competition originals. APUG011 independently provides the same BG256 hard
macro and direct C2 reference topology, with no SDRAM location in its ADC.

These three observations establish that `PHY-7002`, the single C2 local wire,
and the reported DQ setup violation are present in the official baseline.
They must remain visible in timing reports, but they are not evidence that
this project needs a manual SDRAM placement, explicit C2 BUFG, or a replacement
wrapper. The board-validated direct-C2 acknowledgement-CDC baseline is the
correct design state. The prepared vendor question is not to be sent for these
warnings alone; retain it only if formal SDRAM timing closure becomes a separate
requirement.

### FAT32 fragmented-BMP integration: RTL simulation complete, hardware not yet built

On 2026-09-04, the active image source was changed from raw consecutive SD
sectors to FAT32 root-directory metadata and file-cluster chains. The vendor
`bmp_read.v` remains unchanged as a reference. The live path now uses these
project-owned modules in the SD-card clock domain:

- `fat32_directory_scan.v` discovers up to four root-directory 8.3 BMP files
  and exports the validated FAT/data LBAs and sectors-per-cluster value;
- `fat32_file_sector_reader.v` maps sequential logical file sectors through
  the selected FAT32 cluster chain;
- `fat32_bmp_loader.v` validates a BMP header then streams logical sectors to
  the existing frame-write interface;
- `image_storage_adapter.v` owns the physical SD request, selects exactly one
  scanner or loader request source, caches the four file records, and retains
  the two-register write-acknowledgement synchronizer.

The loader deliberately reads logical sector zero twice. The first pass parses
the BMP header without emitting pixels. It releases that completed reader
session, waits for the SDRAM frame-write acknowledgement, then starts a fresh
reader session from sector zero for pixel output. This avoids relying on the
acknowledgement arriving before the first sector's pixel bytes and needs no
new 512-byte buffer. FAT lookup sectors remain internal to the file reader.

`image_load_manager.v` now receives `source_error_pulse`. An invalid BMP
header or damaged FAT chain aborts and retries immediately with diagnostic
code `5`; it no longer waits for the ten-second source timeout. Normal source
completion and SDRAM write completion are still both required before a frame
is committed. No physical-card removal detection was added, so the accepted
retained-frame hot-removal behavior and no-card cold-boot fallback remain
unchanged.

The TD project file `osd_display.al` includes all three FAT32 source files.
The new tests `tb_fat32_bmp_loader.sv` and
`tb_fat32_image_storage_adapter.sv` passed in Icarus, as did the directory
scanner, file-sector reader, adapter, load-manager, playback-control,
BMP-throttle, and OSD regressions. The end-to-end adapter test uses real
scanner/reader/loader RTL and verifies raw SD request order
`0, 1, 3, 6, 6, 2, 20`: MBR, boot sector, root directory, header probe,
sector-zero data pass, FAT lookup, and the fragmented successor cluster.
A top-level Icarus elaboration using only the existing vendor black boxes also
passed.

No TD `syn_1`, `phy_1`, bit generation, JTAG download, or configuration-Flash
write has been performed for this FAT32 integration. The next action is a TD
GUI synthesis and physical build. Before downloading, inspect that new source
files are present in the project and compare routed timing against the accepted
official baseline. Use JTAG only for the first board validation; do not write
configuration Flash until cold-boot and playback tests pass.

### WAV/PCM HDMI background audio: RTL integration complete, board test pending

On 2026-09-07, continuous background audio was added without changing the
SDRAM, video timing, frame-buffer, image-load manager, or existing recovery
behavior. The project reads one root-directory FAT32 file named exactly
`BGM.WAV` (8.3 entry `BGM     WAV`). It accepts only RIFF/WAVE PCM format 1,
48 kHz, stereo, 24-bit little-endian audio with a six-byte block alignment and
288000-byte-per-second rate. The track loops independently of image changes.
Missing, malformed, or unavailable audio produces zero PCM samples and does
not change image display or fallback behavior.

`fat32_directory_scan.v` now continues past the fourth BMP file to discover
the BGM entry. `fat32_wav_loader.v` uses its own FAT32 file-sector reader, so
fragmented WAV cluster chains are supported. It validates RIFF chunks,
handles odd-byte chunk padding, checks complete stereo frames, preserves PCM
byte order, and restarts its file-chain reader at the data-chunk end. Its
write side feeds a 48-bit x 2048-frame generated asynchronous FIFO. The FIFO
crosses from `sd_card_clk` to `video_clk`; playback starts after 1024 frames,
refills below 512 frames, and pauses refills at 1536 frames. FIFO underflow
remains silent and retries refill rather than terminating the track.

The one physical SD sector interface is now owned by
`sd_sector_arbiter.v`. It gives directory scanning first priority, audio
refill second, and image loading third, while holding any active sector grant
until the requester releases it and inserting a low-request handoff cycle.
No requester can preempt a sector already being transferred.

`audio_pcm_player.v` generates 48 kHz enables directly from the 25 MHz video
clock using a fractional accumulator. It sends 24-bit PCM and silence during
prefill/underflow to the existing HDMI transmitter. `hdmi_audio_acr.v` emits
the official-style ACR cadence with `N=6144`. The HDMI transmitter remains
configured for `48K`; its formerly hardwired-zero PCM and ACR inputs are now
connected to this audio chain. Audible data is gated by video-domain
`display_valid`, so a first image commits before playback starts.

The TD project list includes the new storage and audio RTL. Icarus simulations
passed for directory BGM discovery after four BMP entries, fragmented and
padded WAV parsing, PCM frame order across a sector boundary, looping,
invalid-format silence, arbitration priority/non-preemption, FIFO prefill and
underflow silence, ACR cadence, the end-to-end adapter path with BGM plus a
fragmented BMP load, and all existing image/OSD regressions. A top-level
project-owned structural elaboration with vendor blocks treated as black boxes
also passed.

TD `syn_1`, `phy_1`, JTAG and Flash operations have not been run for this
audio integration. The next acceptance step is a TD GUI build followed by a
JTAG-only board test using a FAT32 TF card that contains the established BMP
files plus a compliant `BGM.WAV`. Confirm first-image display, continuous
audible loop, manual next, automatic play, TF removal/reinsertion, and silent
operation with no or invalid `BGM.WAV`. Do not write configuration Flash until
those JTAG checks pass.

#### Official WAV compatibility update

The official 2026 competition `lab_ex5_i2s` source contains
`src/user_source/hdl_source/python/1.wav`. It is 48 kHz, stereo, 24-bit PCM,
six-byte block-aligned and 288000 bytes/s, but is wrapped as the standard
`WAVE_FORMAT_EXTENSIBLE` container (`format=0xFFFE`) rather than the simpler
format-1 PCM header. Its sub-format GUID is the standard PCM GUID
`00000001-0000-0010-8000-00AA00389B71`, so it carries the same sample bytes
required by this project.

On 2026-09-08 `fat32_wav_loader.v` was extended to accept only this explicit
extensible PCM form in addition to ordinary PCM format 1. It still rejects
compressed, floating-point, or other sub-format GUIDs. The official-style
40-byte `fmt ` chunk, `LIST/INFO` metadata, PCM byte order and looping were
added to `tb_fat32_wav_loader.sv` and passed, alongside the original PCM,
fragmentation, padding and invalid-format cases. The end-to-end FAT32 adapter,
PCM player, ACR and top-level structural regressions also passed. To use the
official file, copy it to the FAT32 TF root and rename it exactly `BGM.WAV`.

#### Resource-optimized WAV media contract

On 2026-09-08 the background-audio path was optimized for the final contest
demonstration. The recommended TF root file remains `BGM.WAV`, but its
required export format is now **RIFF/WAVE, signed PCM, 48000 Hz, stereo,
16-bit, little-endian**. This preserves the official HDMI 48 kHz transport and
`N=6144` ACR configuration while reducing TF bandwidth from 288000 to 192000
bytes/s.

Audio is stored in a project-owned 32-bit x 1024-frame asynchronous FIFO
(left/right 16-bit samples), rather than the previous 48-bit x 2048-frame
FIFO. Playback begins with 512 frames, refills at or below 256 frames, and
stops a refill at 768 frames. The capacity is 21.33 ms at 48 kHz and lowers
estimated audio FIFO use from about 11 to about 4 BRAM9K blocks. At the HDMI
boundary, `audio_pcm_player.v` left-justifies each 16-bit channel by appending
eight zero LSBs to the transmitter's unchanged 24-bit PCM interface. This
matches the official I2S receiver's high-bit extraction; a plain sign
extension would attenuate the signal by 48 dB.

For compatibility with the official `lab_ex5_i2s` 24-bit extensible sample,
the loader still accepts its exact PCM GUID and format. It intentionally drops
each 24-bit channel's least significant eight bits before putting the remaining
16 bits into the optimized FIFO. This makes the compatibility path safe but
not the recommended final media contract.

Icarus passed the updated 16-bit padded/fragmented/looping WAV parser test,
the official 24-bit compatibility test with explicit truncation checks, the
negative-sample left-alignment PCM player test, the real FAT32 adapter test
with BGM and a fragmented BMP, the existing adapter test, the HDMI ACR test,
the sector-arbiter test, and structural top-level elaboration. TD `syn_1` and
`phy_1` completed on 2026-09-08 for this optimized version. Final utilization
is 8728/19600 LUTs (44.53%), 6255/19600 registers (31.91%), 24/64 BRAM9K
(37.50%), and 10/29 DSP blocks. The `u_audio_async_fifo` instance uses four
BRAM9K blocks, matching the optimization target. Final setup WNS is -6.565 ns
and hold WNS is +0.003 ns, with no hold failures; this is consistent with the
accepted project's existing setup-timing baseline. The next user action is
JTAG-only audio, manual-change, auto-play, TF removal, and TF reinsertion
checks using a suitable `BGM.WAV`.

#### HDMI PCM left-alignment correction

The first optimized board test produced audible but extremely quiet sound even
with display volume at maximum. The source file and HDMI audio cadence were
therefore working. The cause was the 16-bit-to-24-bit conversion: the player
had sign-extended samples into bits [15:0], while the HDMI transmitter path
uses the high sample bits, as shown by the official I2S receiver.

On 2026-09-08 `audio_pcm_player.v` was corrected to drive
`{sample[15:0], 8'b0}` for both channels. This left-justifies each 16-bit PCM
sample, removes the 48 dB attenuation, and changes neither BRAM, DSP, clocks,
nor the `BGM.WAV` export format. The player test now checks positive and
negative left-aligned samples; it passed, as did post-fix top-level structural
elaboration. Re-run TD `syn_1` and `phy_1`, then JTAG-download and verify
volume before broader image and recovery checks.

#### TF hot-removal automatic audio recovery

Board testing after the HDMI volume fix established a separate TF recovery
gap. Immediate, ten-second, and long TF removal all silenced audio, but the
vendor SD core retained `sd_init_done`; the OSD therefore remained `IMAGE` or
`LOAD`, never entered `WAIT TF`, and reinsertion alone did not restart audio.
The previous user workaround was an image button press that eventually caused
the established failed-load recovery sequence (`341...`, then `540003`, then
a second press), at which point both image switching and BGM restarted. This
showed that the card and audio data were valid, but hot removal was invisible
to the existing control path.

The board constraints expose no TF card-detect input, and the vendor SPI SD
controller has no missing-card transaction timeout. The project therefore now
adds a liveness watchdog at the single physical SD sector interface. An active
sector request resets a 250 ms timer on every returned byte or sector-end
pulse. A request with no progress for the complete interval emits exactly one
`storage_fault_pulse`; normal data flow cannot trip it. `image_load_manager`
uses that pulse to reset the SD adapter and audio FIFO, retain the current
SDRAM frame/buffer/image index, and enter the existing reset-wait path.

After reinsertion, normal SD initialization makes the OSD report `SCAN`; the
directory scan refreshes BMP and BGM metadata, and the WAV loader pre-fills
audio from the beginning. In this display-preserving hot-removal path the
manager returns to idle after scanning rather than loading image 1 or changing
the currently shown frame. With no card, the retained frame remains visible,
audio is silent, and the OSD reports `WAIT TF`; no key press is required.

Icarus passed a dedicated liveness-watchdog test (normal returned bytes do not
fault; a stuck granted request faults once only), a display-preserving
manager-recovery test, the existing adapter test, the real FAT32
adapter/BGM/fragmented-BMP test, the PCM player test, and a post-change
top-level structural elaboration. TD `syn_1`, `phy_1`, and JTAG board testing
then passed on 2026-09-08. Immediate reinsertion, ten-second removal, and
one-minute removal all transitioned to `WAIT TF` on removal, retained the old
image, and automatically restored the same image plus BGM from its beginning
after reinsertion, without any key press.

The `SCAN` state is intentionally entered after reinsertion, but it is often
not visible on the OSD. With the current small root directory and high-speed
SPI data path, metadata scanning completes in less than one 60 Hz video frame
(about 16.7 ms), so the renderer samples `WAIT TF` and then the final `IMAGE`
state. A visually observable `SCAN` label is not an acceptance requirement;
the automatic image-preserving BGM recovery is the acceptance result.

#### Long BGM.WAV FAT32 cluster-chain correction

On 2026-09-08, board endurance testing found that an otherwise valid
multi-minute BGM stopped after about 1 minute 26 seconds. The cause was not
the WAV parser, HDMI PCM path, FIFO, or SD hot-removal logic. The shared FAT32
file-sector reader defaults to a 4096-cluster traversal bound as a corruption
guard. On a normally formatted card with 4 KiB clusters this limits a file to
about 16 MiB. The recommended 48 kHz stereo 16-bit PCM stream consumes exactly
192000 bytes/s, so that bound ends playback after about 87 seconds, matching
the observed symptom.

`fat32_wav_loader.v` now overrides only its reader instance to use the full
65535-cluster bounded chain. The BMP client retains the original 4096-cluster
default. The limit remains finite, so a malformed circular FAT chain still
terminates with an audio-only error rather than reading indefinitely. Icarus
passed the existing padded/fragmented 16-bit WAV loop, official 24-bit
extensible compatibility, and invalid-format regressions. A new
`tb_fat32_wav_long_file_reader.sv` also passed a 4097-cluster chain, crossing
the former cutoff without error and completing all 4097 sectors. The next user
action is TD GUI `syn_1` and `phy_1`, JTAG download, then verify the entire
track plays beyond the previous 1:26 stop point and loops cleanly. Do not use
TD command-line tools or modify configuration Flash for this check.

#### Final integrated board acceptance

The long-track acceptance subsequently passed on the target board. A valid
five-and-a-half-minute `BGM.WAV` played from beginning to end and immediately
restarted from the beginning, confirming that the former approximately-1:26
cutoff is gone. The final integrated endurance check also passed: automatic
picture playback and HDMI music remained normal, manual image changes worked,
and TF removal/reinsertion retained the displayed image, then automatically
restored image switching and music without any recovery key sequence. The
user additionally observed that recovery after reinsertion is now immediate
in normal use.

The project has therefore moved from feature implementation to contest
delivery. The operational media contract and a short live demonstration
sequence are recorded in `docs/contest-delivery-guide.md`.

#### Stable Flash baseline and objective-review transition

The accepted integrated image was subsequently written to the configuration
Flash and passed its board retest. It is now the stable, recoverable baseline
for further work. New features must first be compiled and board-tested through
JTAG; the configuration Flash is updated only after their regression checks
pass.

This establishes functional stability, not final contest completeness. The
initial roadmap emphasized making the inherited TF/SDRAM/HDMI examples
reliable and adding the required HDMI audio path. Before any further RTL work,
the next phase is to review the official competition requirements against the
verified implementation, produce a score-oriented gap matrix, and replace the
early development roadmap with a focused final-objective plan. The stable RTL
is frozen during that review.

#### Contest-presentation enhancements and current transition handoff

The official contest analysis was reviewed after the stable audio/video
baseline. The implementation already covers the essential media-player path:
FAT32 TF-card image playback, retained-frame recovery on TF removal and
reinsertion, automatic/manual image changes, HDMI PCM background music, and
live OSD state. The remaining work is presentation-oriented rather than basic
bring-up. The selected order is to finish a stable image transition first,
then continue with scrolling OSD presentation work and later consider scaling
and optional audio visualization. Energy bars/waveforms remain a late optional
feature because they should not risk the verified playback path.

The display used for board testing was also changed from an inexpensive 1080p
panel to a portable 2K/144 Hz HDMI monitor with built-in speakers. With the
same validated design, first-image presentation is now normally visible in
about one second (at most a few seconds) rather than the earlier roughly
22-second observation. Image playback, BGM, automatic playback, OSD, and TF
hot-removal recovery remained normal on that monitor. This is an observed
display/handshake difference, not a claimed RTL boot-time optimization.

The first presentation transition candidate was a diagonal crossfade. Board
observation found that its initial implementation was not acceptable: the old
image appeared to disappear abruptly, the new image emerged in visibly coarse
blocks, the motion was too fast, and transition-only corruption appeared as
small flashing rectangles plus a diagonal line. The original dark red accent
also competed with the intended fade. Slow-motion phone video confirmed that
a mathematical blend existed, but the naked-eye result was still discontinuous
and unsuitable for the final advertisement-style display.

Investigation identified two independent contributors. First, the transition
reads the old and new SDRAM frames through separate FIFOs; a route change made
before all requested SDRAM return words arrived can send delayed data into the
wrong FIFO and cause transition-only corruption. Second, sixteen alpha levels
at 60 Hz complete in about 0.28 seconds, so each 6.25% brightness change is
visibly stepped. The full reasoning and fallback are recorded in
`docs/superpowers/specs/2026-09-09-dual-frame-return-routing-design.md` and
`docs/superpowers/specs/2026-09-09-smooth-crossfade-stability-design.md`.

On 2026-09-09 the working tree was updated, but this revision is **not yet TD
compiled or board accepted**. `frame_dual_fifo_read.v` now keeps a selected
old/new route until the actual `Sdr_rd_en` return count completes the whole
request, including delayed returns. `frame_read_write.v` now uses 128-word
display-read bursts while preserving the 256-word write bursts. The transition
controller and top-level alpha interface now use 0--64 alpha steps (about
1.08 seconds at 60 Hz) instead of 16 levels. The blender now divides by 64,
moves the diagonal in roughly 18-pixel increments, and replaces the dark red
stripe with a narrow, non-wrapping soft-white accent. Focused Icarus tests for
the transition controller, blender, and dual-FIFO reader passed, as did
top-level Icarus elaboration. The only observed elaboration warning is the
pre-existing `rdusedw` 9-bit-to-10-bit zero-extension warning.

The immediate next action in a new conversation is therefore narrowly scoped:
run TD `syn_1`, `phy_1`, and bitstream generation; JTAG-download only; then
test at least ten `KEY2` transitions, several `KEY4` automatic cycles, audio
continuity, OSD stability, and one TF removal/reinsertion. Do not update
configuration Flash unless all checks pass. If any transition-only blocks,
stripes, tearing, or clearly stepped/stiff motion remain, stop extending the
dual-frame transition and replace it with a single-frame fade-through-white
design; that fallback preserves a deliberate old-image exit and new-image
entrance without simultaneous old/new SDRAM reads.

The user prefers the assistant to select the best technical option directly
and to pause only when board testing or a real blocker requires user action.
All further feature work must use JTAG first; the previously accepted Flash
image remains the recovery baseline.

#### Single-frame fallback after the second board result

The user subsequently compiled and JTAG-tested the 0--64 dual-frame revision.
The fade itself was substantially smoother, but its roughly 1.08-second
duration felt too long and transition-only corruption remained visible. The
soft-white diagonal was also too pale to read as an intentional effect and
could be mistaken for uncorrected video tearing. This result triggered the
documented fallback; no further dual-frame scheduling complexity will be
added.

The working tree now contains a single-frame warm-white transition, but this
revision is **not yet TD compiled or board accepted**. `frame_read_write.v`
has been restored to the board-proven single read FIFO and `frame_fifo_read`
scheduler, including removal of the dual-read compatibility ports. Neither
the old FIFO nor `frame_dual_fifo_read` is instantiated. The buffer changes
only at a fully covered video-frame boundary, removing simultaneous old/new
SDRAM reads from the production path.

The new sequence uses 16 fade-out and 16 fade-in frames, for about 0.53 seconds
at 60 Hz. Its fade levels follow the symmetric ease curve
`0,1,2,4,7,11,16,23,32,41,48,53,57,60,62,63,64` in each direction. A separate
0--64 sweep position advances monotonically across all 32 frames, so the
diagonal never reverses during fade-in. The accent is now a 40-pixel warm-gold
band targeting `#FFD166`, with a stronger 16-pixel core and direction-aware
channel interpolation that cannot wrap. The OSD remains composited after the
effect and is therefore unaffected.

Focused controller, blender, retained dual-reader, and OSD simulations pass.
The full top-level elaboration also passes with the real single-frame reader
and generated FIFO sources; only the existing FIFO width-padding and vendor
RAM dangling-port warnings remain. The implementation is documented in
`docs/superpowers/specs/2026-09-09-single-frame-warm-white-transition-design.md`
and `docs/superpowers/plans/2026-09-09-single-frame-warm-white-transition.md`.

The next action is TD `syn_1`, `phy_1`, and bitstream generation followed by
JTAG-only validation. Test at least ten `KEY2` transitions, several `KEY4`
automatic cycles, continuous audio, stable OSD, and one TF removal/reinsertion.
Do not update configuration Flash until the transition has no blocks, tearing,
black frames, HDMI loss, or ambiguous pale diagonal artifacts.

#### Pure crossfade selected after the single-frame board result

The user compiled and tested the single-frame warm-white revision. It removed
the transition corruption completely and its roughly 0.53-second duration was
accepted, but the visible result was rejected: it looked like a basic fade plus
yellow brightness modulation and a yellow diagonal bar. The diagonal could be
mistaken for uncorrected tearing.

After comparing the second visual candidates, the user explicitly requested a
true old-image-transparent/new-image-visible crossfade with no flash or other
decoration. This necessarily supersedes the earlier dual-read fallback. The
working tree now contains that implementation, but it is **not yet TD compiled
or board accepted**.

The controller locks old and new buffer indexes for 32 mixed frames and uses
the eased alpha sequence
`0,1,2,3,4,5,7,9,11,13,15,17,20,23,26,29,32,35,38,41,44,47,49,51,53,55,57,59,60,61,62,63`.
The next frame is exact new-image output. The blender performs only complementary
RGB weighting; all warm-white, gold, diagonal, and coordinate logic has been
removed. OSD remains after the blender.

The dual reader now uses 64-word bursts and two 1024-word asynchronous FIFOs.
It prioritizes the lower eligible FIFO watermark and holds the selected return
route until all real `Sdr_rd_en` words for the burst arrive. Top-level wiring
explicitly sends the committed target buffer to the new FIFO and the current
display buffer to the old FIFO. The write path and media subsystems are unchanged.

Review exposed a request-metadata race absent from the earlier idealized test.
The video read request reaches the memory domain before the controller updates
dual mode and the target index; the old scheduler could therefore start the
first transition frame as a single read and leave the old FIFO empty. The ACK
state now performs a final atomic metadata capture on the first synchronized
request-low cycle before issuing any address. A regression first reproduced
the old 8-command result where 16 paired commands were required, then passed
after this correction.

Controller, blender, scheduler, real dual-FIFO wrapper, and OSD simulations pass.
The wrapper-level test returns distinguishable old/new pixel sequences through
the generated FIFO implementation, applies mode/index with the real late-update
timing, and confirms aligned, correctly routed output.
Top-level Icarus elaboration with the real frame wrapper also passes. Only the
existing write-FIFO level padding and 24-to-21-bit address constant warnings
remain.

The next action is TD `syn_1`, `phy_1`, and bitstream generation followed by
JTAG-only validation. Test at least ten `KEY2` transitions, several `KEY4`
automatic cycles, continuous audio, stable OSD, and one TF removal/reinsertion.
Do not update configuration Flash until there is no transition corruption,
tearing, black frame, or HDMI loss.

#### Read-margin diagnostic after pure-crossfade board failure

The pure 32-frame crossfade passed visual review in the latest JTAG test, but
transition-only corruption remained.  The 19:57 implementation confirms that
the two configured 1024-word read FIFOs were each synthesized into three
BRAM9K blocks.  Its resources are 9445 LUTs, 6475 registers, 28 BRAM9Ks and
13 DSPs.  Routed timing remains `SWNS=-6.565ns`, `STNS=-410.468ns`,
`HWNS=+0.004ns`; the inherited SDRAM DQ path is still the worst path.

The working tree now contains a JTAG-only read-margin and diagnostic revision.
The accepted blend, alpha curve, duration, 64-word bursts, and 125 MHz 0/180
degree SDRAM clocks are unchanged.  Both display-read FIFOs are enlarged to
4096 32-bit words.  After `display_valid`, pixel reads against an empty new or
old FIFO latch fault bits 0 or 1.  The scheduler latches bit 2 if another frame
request arrives before the previous frame's required read commands complete.

The three sticky bits are synchronized to the board-clock domain and override
the final seven-segment digit only when nonzero: `1` is new-FIFO underflow,
`2` is old-FIFO underflow, `3` is both underflows, and `4` is a frame-read
overrun; combined faults display `5` through `7`.  With no read fault, the
existing media error digit remains unchanged.  `KEY1` reset clears the sticky
code.

All five focused simulations pass, including explicit underflow and scheduler
overrun cases.  Top-level elaboration passes both with the frame wrapper stub
and with the real dual FIFOs and scheduler.  Only the pre-existing write-FIFO
level padding and 24-to-21-bit address warnings remain.

Next, rebuild `syn_1`, `phy_1`, and the bitstream in TD 6.2.1 and use JTAG
only.  Reset once with `KEY1`, exercise at least ten manual transitions and
several automatic cycles, and record the final digit immediately after any
corruption.  A nonzero code identifies a continuity/throughput failure.  If
corruption remains with code zero, stop changing FIFO depth or scheduling and
treat the unresolved SDRAM DQ sampling path as the leading cause.  Do not
program configuration Flash before a clean full regression.

#### Matched 62.5 MHz SDRAM experiment after zero-code corruption

The 4096-word diagnostic revision was built and tested on hardware.  Pixel
corruption remains, but the last diagnostic digit stays at zero.  Neither
display FIFO was read empty and no frame-read request overtook an unfinished
frame, so further FIFO enlargement and scheduler tuning are no longer
justified.  The leading cause is now SDRAM DQ sampling under the dual-frame
read duty cycle; the latest 125 MHz build still reports `SWNS=-6.565ns` on the
inherited DQ path.

Review also corrected the interpretation of the earlier 41.667 MHz failure.
That experiment changed the PLL without changing the active
`SDR_CLK_PERIOD=1000000000/125000000` definition.  Its refresh counter
therefore ran at roughly three times the intended physical interval.  The
observed `341100 -> 341002` write timeout was not a clean test of a matched
lower-frequency controller.

The workspace now contains a controlled 62.5 MHz revision.  C1 and C2 use
divide-by-16 and phase taps 15/7 for 0/180 degrees, while C0 remains 100 MHz.
The active period definition is updated to `1000000000/62500000`, preserving
the physical refresh cadence.  The accepted 32-frame pure RGB blend, 64-word
bursts, 4096-word FIFOs, diagnostics, storage, audio, and OSD logic are
unchanged.

Mechanical PLL/IPC/refresh checks pass.  All five focused simulations pass,
and the real dual-FIFO top-level elaboration passes with only the pre-existing
FIFO level-padding and address-width warnings.  Next, rebuild `syn_1`, `phy_1`,
and bitstream in TD 6.2.1.  Record routed timing and JTAG-test first-image
writing before repeated manual and automatic transitions.  Also check audio,
OSD, TF recovery, and the last diagnostic digit.  Do not program configuration
Flash unless the full test is clean.

#### 62.5 MHz result and final phase-balanced experiment

The matched 62.5 MHz revision completed TD and JTAG testing.  Image writes no
longer produced `341100` or `341002`, validating the corrected refresh timebase,
but transition corruption remained.  The 20:52 bitstream SHA256 is
`9F877864246163AD14F0B5863EBE6DC4527D9FF8277F8C3F9A26ACB760A0AB33`.
TD reported `SWNS=-3.766ns`, `STNS=-189.381ns`, and `HWNS=+0.004ns`.
The global worst path is now unrelated 100 MHz FAT32/WAV logic, while the
hard-SDRAM DQ write and read setup groups are `+1.092ns` and `-2.565ns`.
The read direction still has all 32 endpoints failing, consistent with the
board result.  Reject this bitstream for final use.

The final dual-frame experiment uses C1/C2 at 50 MHz, with C1 at zero degrees
and C2 at 144 degrees (`DIV=20`, `CPHASE=19/7`).  This keeps C2's absolute
rising-edge offset at the measured 8 ns position.  The write budget therefore
retains its positive 62.5 MHz result, while the following C1 edge moves four
nanoseconds later; expected DQ setup is approximately `+1.092ns` write and
`+1.435ns` read.  The active period macro is matched to 50 MHz so refresh stays
near 31.24 us.

No transition or media RTL changes.  The next TD build must show both DQ setup
groups non-negative before JTAG testing.  A nonzero last digit identifies
insufficient 50 MHz dual-read throughput; corruption with a zero digit rejects
the hard-macro dual-frame path despite timing.  Either failure triggers the
board-proven single-frame fallback, with no further frequency experiments and
no configuration-Flash update.

Source verification confirms C0 is unchanged, C2 retains an 8 ns absolute
offset, the refresh interval is 31.24 us, and average dual-frame reads consume
73.728% of the theoretical 50 MHz one-word-per-cycle bandwidth.  All five
focused Icarus tests pass, and real dual-FIFO top-level elaboration passes with
only the existing FIFO-padding and 24-to-21-bit address warnings.  TD timing
and JTAG board validation are the only remaining steps for this revision.

The first 50 MHz build at 21:08 did not implement that intended phase.  The
source incorrectly used C2 `CPHASE=11`; TD reported the actual derived clock
as phase 216 with a 12 ns rising edge.  Consequently DQ write setup increased
to `+5.130ns`, while DQ read setup stayed exactly `-2.565ns`.  Hardware loaded
images without `341100/341002` but still corrupted transitions.  The invalid
bitstream SHA256 is
`8CB458E71F0E6591678A66610A65FE91A49066B24102C777413E1C6AC65B5B8B`.

The corrected source uses C2 `CPHASE=7`, which is the primitive setting for an
8 ns / 144-degree rising edge at 50 MHz.  Do not accept the next build unless
TD itself reports phase 144 and both DQ setup groups are non-negative.

Post-correction source checks, all five focused Icarus tests, and real
dual-FIFO top-level elaboration pass.  Only the established FIFO-padding and
address-width warnings remain.  The 21:08 bitstream cannot be reused; a full
new TD build is required.

#### Final rollback to the board-proven single-frame transition

The dual-frame path is now rejected.  Hardware continued to corrupt the
transition without `341100/341002`, and the user requested the exact version
that had already passed board testing before the later crossfade experiments.
No further dual-reader, FIFO-depth, SDRAM-frequency, or PLL-phase experiments
are planned.

The source rollback is complete.  `sys_pll` C1/C2 are restored to the accepted
125 MHz, 0/180-degree configuration (`DIV=8`, `CPHASE=7/3`), and
`SDR_CLK_PERIOD` again matches 125 MHz.  Production `frame_read_write` once
again contains one 512-word read FIFO and `frame_fifo_read`; the top reads only
`active_buffer_index`.  The old-image path, second FIFO, dual scheduler ports,
and seven-segment read-fault override are absent.  The historical dual-reader
source and standalone test remain excluded from production synthesis.

The restored visual behavior is the previously accepted 16-frame fade to
warm white, buffer switch only under full cover, and 16-frame fade back to the
new image, approximately 0.53 seconds total at 60 Hz.  The warm-gold diagonal
accent is restored with the same single-frame implementation.  Audio, FAT32,
TF recovery, OSD, image writes, and vertical-flip behavior are unchanged.

The controller, blender, OSD, and retained historical scheduler simulations
pass.  Both stubbed and real single-FIFO top-level elaboration pass, with only
the established FIFO-width padding and 24-to-21-bit address warnings.  Status
is source-complete and TD/JTAG-pending.  The user's workflow is correct: keep
TD open, Reset Runs, rebuild `syn_1`, `phy_1`, and bitstream, then program by
JTAG.  Do not reuse a dual-frame or 50/62.5 MHz bitstream, and do not update
configuration Flash before this rollback passes on hardware.

The first post-rollback synthesis attempt failed during design read at 21:54.
TD reported `HDL-8007` for `video_transition_controller`,
`video_transition_blender`, and `frame_read_write`.  All three source files
were present; TD had removed their paths from its in-memory project when the
files were briefly replaced, then overwrote the repaired `.al` manifest while
closing.  This was a project-manifest failure, not an RTL or user-workflow
failure.

With TD fully stopped, the manifest has now been repaired again.  Each missing
module is registered exactly once, `frame_fifo_read`, `frame_fifo_write`, and
the read-FIFO IP are enabled, and historical `frame_dual_fifo_read` remains
excluded.  Manifest assertions and real single-FIFO top-level elaboration
pass.  Reopen the project, Reset Runs, and rebuild normally.

#### Line-buffer horizontal push transition

The production transition now implements the contest's line-buffer sliding
option on top of the board-proven 125 MHz single-output-FIFO baseline. The new
frame enters from the right while the old frame exits to the left. The
warm-white/gold filter, diagonal sweep, and flash are absent from the active
pixel path; OSD remains a fixed final overlay.

The controller advances over 28 frame intervals, about 0.47 seconds at 60 Hz,
using the exact position table
`0,2,9,20,35,54,76,100,127,156,187,219,252,286,320,354,388,421,453,484,513,540,564,586,605,620,631,638,640`.
It locks old/new buffer indexes for the complete transition and changes the
active buffer only at position 640. The first committed image remains direct.

The memory-domain scheduler serializes old and new line segments through one
512-word asynchronous output FIFO. Normal positions require exactly 640 reads
per line. Positions 16 through 624 add a 32-pixel overlap cache and linear RGB
feather, for at most 672 reads while still emitting exactly 640 pixels. Read
chunks contain at most 128 commands, and segment routing changes only after the
same number of real `Sdr_rd_en` returns has arrived. Existing write priority and
`frame_fifo_write` behavior are unchanged. An overtaking frame request latches
a fault, cancels the slide without changing the active buffer, and holds the
playback interlock until reset.

The controller test checks every position plus direct-first-frame, locked
indexes, endpoint handoff, and fault hold. The scheduler test uses an 8x2 frame,
a four-pixel feather, and gapped SDRAM returns to verify addresses, ordering,
mixing, endpoints, steady current-frame reads, output counts, and overrun
detection. Controller, scheduler, OSD, image manager, and storage adapter tests
all pass. Real-wrapper top-level elaboration passes with only established FIFO
padding, address-width, and timescale warnings. The manifest enables exactly
one `frame_slide_fifo_read` and excludes historical `frame_fifo_read`,
`frame_dual_fifo_read`, and `video_transition_blender` sources.

SDRAM remains at the accepted C1/C2 125 MHz, 0/180-degree configuration
(`DIV=8`, `CPHASE=7/3`) with the matching
`SDR_CLK_PERIOD=1000000000/125000000`. Status is source-complete and
TD/JTAG-pending. Rebuild `syn_1`, `phy_1`, and bitstream from reset runs, then
JTAG-test at least ten manual transitions, several automatic cycles, continuous
audio, fixed OSD, and one TF removal/reinsertion. Any corruption, black band,
row displacement, HDMI loss, or load timeout rejects the build; do not program
configuration Flash before the complete board test passes.

#### Board test result: transition-boundary corruption, underflow diagnostic added

The first board test of the line-buffer slide still shows corruption during
the transition: a vertical yellow line at the moving old/new boundary, with a
red tint added when the source image contains red content. The line tracks
`slide_position` and only appears while a transition is active.

`video_delay.read_en` (the video-side consumer of the read FIFO) has no
empty-flag gating — `assign read_en = de_d[18];` pulls from the FIFO purely on
display timing, regardless of whether the memory-side producer has actually
written that word yet. The slide scheduler's only cross-buffer address jump
per line (`old_base+608` direct/cache region to `new_base+0` blend region)
lands exactly at the screen boundary; if that jump costs extra SDRAM latency,
the producer can momentarily fall behind the fixed-rate consumer there,
causing a genuine FIFO underflow whose stale/undefined `dout` would show up as
exactly this kind of boundary-localized, image-content-dependent artifact.
This is the same underflow failure mode `crossfade-read-margin-diagnostics`
found for the earlier dual-frame design, just triggered by a different access
pattern.

To confirm or rule this out before changing any margin/depth parameters,
`frame_read_write.v` now connects the previously-unused `empty_flag` output of
`read_buf` and latches a new sticky `read_fifo_underflow_seen` whenever
`read_en` and that empty flag are asserted together. `top.v` synchronizes it
into the `sd_card_clk` domain (mirroring the existing `transition_busy_sd_sync`
pattern) and overrides the last 7-segment digit (`seg_digit_x`, otherwise
`error_code`) with `F` when it latches — `error_code` only uses 0-5, so `F`
cannot be confused with an existing load-manager error.

A new focused test, `tb_frame_read_write_underflow.sv`, exercises the latch
directly (write-before-read never trips it; reading while empty trips it and
it stays sticky through subsequent normal activity until reset) using minimal
local behavioral stand-ins for the vendor FIFOs and the write/read schedulers,
since the generated FIFO IP sources are not checked into this repository.
Controller and scheduler regressions (`tb_video_transition_controller`,
`tb_frame_slide_fifo_read`) still pass unchanged.

Status: diagnostic only, simulation-verified, board-unverified. This does not
fix the corruption. Next board test: rebuild in TD and watch the last digit
during a transition. If `F` lights up, the underflow hypothesis is confirmed
and the next step is increasing read-FIFO depth/margin (or prefetching the
boundary-crossing segment earlier) rather than guessing at parameters blind.
If `F` never lights up, the corruption has a different cause and the search
continues elsewhere (e.g. clock constraints, OSD compositing timing).

#### Diagnostic false-positive: gated the latch on display_valid

The first board run of the diagnostic showed `F` from power-on onward,
including but not limited to transitions — not useful, since it never
distinguished "underflowed once at boot" from "underflowed again during a
transition." Root cause: `video_delay.read_en` pulses on every active video
line unconditionally, including before `Sdr_init_done` and the very first
committed frame, when `frame_slide_fifo_read` is still sitting in `S_IDLE`
and has written nothing to the FIFO yet. That startup-window emptiness is
harmless — before the first commit, `display_valid` is low and the display
mux outputs black/test-pattern instead of `read_data` — but the sticky latch
had no way to tell it apart from a later, visually-real underflow, so it
tripped once at boot and stayed stuck forever.

`frame_read_write` now takes a new `display_valid` input and only latches
`read_fifo_underflow_seen` when `display_valid && read_en && read_fifo_empty`.
`top.v` connects the same `display_valid` wire already used for the video
output mux (video_clk domain, matching `read_clk`), so the flag now only
reflects underflows that happen while a real committed image is actually on
screen — which stays true throughout a transition, since `display_valid`
does not drop during the slide. `tb_frame_read_write_underflow.sv` gained a
case proving pre-first-frame empty reads no longer trip the latch, alongside
the existing post-commit latch/sticky/reset cases. All four focused
simulations (controller, scheduler, this diagnostic test, and the stub-path
top elaboration) still pass.

Status remains diagnostic only, simulation-verified, board-unverified. Next
board test: rebuild and watch the last digit specifically from first-image
display onward, including during transitions.

#### Board result: underflow trips on the very first frame, no transition needed

The gated diagnostic was rebuilt and tested. Result: the digit reads `0`
throughout power-on, then flips to `F` the instant the first image is
displayed — with zero key presses, i.e. before any slide transition has ever
been triggered. This rules out the working theory that the underflow is
specific to the transition's one cross-buffer address jump (old-cache to
new-blend). Whatever is causing it is present in the ordinary steady
(`slide_active=0`, `p=0`) display path too, at least once, right at
first-frame start.

Because the previous diagnostic was a single sticky bit, it could not
distinguish "underflowed once, right at startup, then recovered" from
"underflows continuously on every line/frame thereafter." Given `read_en`
(`video_delay.read_en`) stays high for an entire active video line rather
than pulsing once, a single stalled line could otherwise look identical to
one brief hiccup. `frame_read_write` now exposes a 4-bit saturating
`read_fifo_underflow_count` instead: it edge-detects the gated condition
(`display_valid && read_en && read_fifo_empty`) so one continuous empty
stretch counts as one episode, increments once per distinct episode, and
saturates at `4'hF` (does not wrap). `top.v` double-registers the whole
4-bit bus into the `sd_card_clk` domain (matching the existing
`disp_buf_idx_video_sync`/`osd_status_video_sync` pattern already used for
multi-bit diagnostic buses in this file — acceptable for a board-diagnostic
value that changes at most a few times per second) and displays it directly
on `seg_digit_x` in place of `error_code` whenever it is nonzero.

`tb_frame_read_write_underflow.sv` was rewritten for counter semantics:
pre-first-frame empty reads still don't count; two isolated empty pulses
count as two separate episodes; a 20-cycle held-empty stretch (modeling a
whole stalled video line) counts as exactly one episode, not twenty; the
counter saturates at `4'hF` under sustained repeated episodes; and only
reset clears it. Controller, scheduler, and stub-path top elaboration
regressions are unaffected.

Status remains diagnostic only, simulation-verified, board-unverified. Next
board test: watch the actual count value (not just zero/nonzero) from
first-image display onward. If it lands on a small number and stops
climbing during ordinary steady playback (no transition triggered), that
points to a one-time startup/cold-SDRAM-access hiccup, cosmetically harmless
on its own — and the transition-time visible artifact would need a separate
explanation (or the same underlying margin issue made visible by the
sustained per-frame boundary jump). If the count keeps climbing during
ordinary steady playback with no transition ever triggered, the new
`frame_slide_fifo_read` scheduler has a general throughput/margin regression
relative to the previous direct frame reader, independent of the slide
address jump, and that regression — not the transition boundary specifically
— is the priority to fix next.

#### Board result: saturates within half a second of first display, steady playback, no transition

Rebuilt and tested again. Result: the digit reads `0` through power-on, then
climbs rapidly to `F` within well under a second of the first image
appearing — with no key press, no transition ever triggered. Because the
counter was still forever-sticky (only cleared by global reset), it could
not distinguish "saturated once, early, then recovered" from "saturates
this fast on every single frame, continuously." That ambiguity motivated a
deeper simulation investigation before changing the diagnostic further.

**Simulation investigation.** Built a scratch integration testbench (not
part of the tracked suite) instantiating the real `video_timing_data`,
`video_delay`, `frame_read_write`, and `frame_slide_fifo_read` at their real
clock ratio (25MHz video / 125MHz mem, matching `video_pll.v`/`sys_pll.v`),
with an idealized best-case SDRAM stand-in (fixed 4-cycle latency, accepts a
new command every cycle, no busy stalls, zero write-side contention) and a
`display_valid` that only turns on after several real video frames have
already elapsed — modeling a realistic TF-card load delay rather than an
instant one, specifically to rule out the earlier cold-start-before-first-
real-`read_req` artifact.

Finding: even in ordinary steady playback (`slide_active=0`, `p=0`, no
transition ever triggered, addressing pattern identical to the pre-slide
direct frame reader), the read FIFO underflows repeatedly, roughly 426
distinct episodes per frame, indefinitely — not a one-time startup
transient. Tracing the scheduler's internal state at the moment of
underflow showed it consistently sitting in `S_IDLE` with `row_index=479`
(the last row) and the FIFO completely empty, while the video side's `de`
is still active mid-frame needing more lines. Root cause: `read_req` fires
once per frame (on the vsync edge); once triggered, the scheduler's
admission control (`wrusedw < FIFO_START_LEVEL`) only bounds *instantaneous*
FIFO occupancy to at most ~512 words ahead of consumption — it has no
mechanism pacing *cumulative* production against the video's actual
per-frame consumption rate. Under fast/idealized memory timing, the
scheduler can finish writing an entire frame's 307,200 words in a small
fraction of the ~15.36ms the video side needs to actually display all 480
active lines, then sits idle for the remainder of that frame with nothing
left to feed — exactly matching the "climbs to saturation almost instantly,
independent of any transition" board symptom.

Important caveat: this exact admission-control pattern (`FIFO_DEPTH=512`,
`BURST_SIZE=128`, `wrusedw < FIFO_DEPTH-BURST_SIZE`) also exists unchanged
in the previous, board-proven `frame_fifo_read.v`, and in steady mode
(`p=0`) `frame_slide_fifo_read` issues the identical single 640-word
contiguous burst per row with no extra address jumps — so this is not a
regression introduced by the slide address-jump logic specifically. Real
SDRAM (with actual row-activate/precharge/refresh overhead this idealized
model ignores entirely) is almost certainly slower than the idealized
stand-in, so the *exact* frequency (426/frame) measured in simulation likely
overstates what the real board experiences. But the board's own timing
(saturates in well under a second, independent of any transition) matches
the *mechanism* closely enough that this is treated as the leading
explanation rather than a simulation artifact.

**Diagnostic upgraded to per-frame, non-sticky.** A forever-sticky counter
can only ever say "has this happened at least once since power-on" — it
cannot show whether the same high count recurs every frame (a chronic
per-frame throughput problem, matching the simulation finding) or only
appears for the first frame or two (a one-time transient). `frame_read_write`
now exposes `read_fifo_underflow_count_per_frame`: a running episode counter
(edge-detected on the gated underflow condition, saturating at `4'hF`) that
snapshots its value into a stable output register on every frame boundary
(`read_req`'s rising edge, already in the `read_clk` domain) and restarts at
0 for the new frame. The displayed value therefore holds steady for a full
~16.8ms and updates once per frame, rather than flickering mid-frame or
staying pinned forever after one early saturation. `top.v`'s existing
double-register sync and `seg_digit_x` override are unchanged in structure,
just renamed to match. `tb_frame_read_write_underflow.sv` was rewritten to
drive explicit frame boundaries and verify: mid-frame episodes don't move
the displayed value early; the displayed value updates to the *previous*
frame's tally only at the next boundary; saturation within one frame is
independent of the display; and a subsequent clean frame brings the
displayed value back to 0 (proving it is a snapshot, not a sticky latch).
Controller and scheduler regressions are unaffected.

Status remains diagnostic only, simulation-verified, board-unverified. Next
board test: watch the digit over several seconds of steady playback with no
transition triggered. If it settles at 0 (or a small, non-recurring value)
after the first frame or two, the startup-transient theory holds and the
transition-time artifact needs separate investigation. If it keeps reading
a high value (very plausibly `F`, given simulation) on every single frame
indefinitely, that confirms the scheduler has no real per-frame pacing
margin and the fix is to add explicit rate limiting to
`frame_slide_fifo_read` (e.g. bound how many rows it may complete ahead of
the video's actual real-time line position, not just bound instantaneous
FIFO occupancy) rather than continuing to treat this as transition-specific.

## Final horizontal-transition baseline (2026-09-13)

The diagnostic sequence continued past the per-frame underflow experiment.
Solid-color, address-pattern, phase-color, FIFO-uniform, and SDRAM-uniform
builds separated the fixed physical-left-edge artifact from the moving
old/new-image boundary artifact. The final hardware result did not require a
deeper FIFO, an SDRAM clock change, or video-rate pacing.

The accepted read path discards four preroll responses before every visible
address chunk and issues each payload as a complete fixed 128-word burst.
Surplus tail responses are drained before the scheduler changes address
segments. `video_delay.v` consumes the FIFO `valid` signal through a four-entry
video-domain alignment queue, and the read FIFO remains
`SHOW_AHEAD_EN=0 + OUTREG` so it continues to use BRAM.

The production top selects this exact configuration:

```verilog
.WRITE_BUFFER_SOLID_DIAGNOSTIC(0),
.SLIDE_FEATHER_ENABLE(0),
.SLIDE_FIFO_UNIFORM_DIAGNOSTIC(0),
.SLIDE_SDRAM_UNIFORM_DIAGNOSTIC(0),
.SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC(0),
.SLIDE_PHASE_COLOR_DIAGNOSTIC(0),
.READ_CHUNK_PREROLL_WORDS(4),
.FIXED_READ_BURST_ENABLE(1),
```

Focused stale-return and fixed-burst tests, a 640x480 full-frame test, seven
slide positions with pixel-exact multiframe checking, FIFO/video-delay/AXIS/
OSD/underflow/marker/write diagnostics, real and stub top elaboration, and
both TD project-list parses pass. The completed refresh-stall/depth records
show zero underflow, dropped commands, and scheduler stalls; the worst
`stall=16, depth=512` case completed 24 frames. `git diff --check` also passes.

TD synthesis, place/route, bitstream generation, and JTAG board acceptance are
complete. Real-image manual transitions and automatic playback no longer show
either the fixed left-edge color line or the moving boundary line. Stable
display, OSD, audio, controls, and TF-card removal/reinsertion recovery also
pass. This feather-disabled build is the formal development and competition
baseline for subsequent stages.

Feathering is retired from the plan. With complete fixed bursts, its two extra
32-pixel segments per row caused incomplete frames, severe horizontal and
vertical ghosting, a failed transition, and a blocked next-image key on real
hardware. Restoring `SLIDE_FEATHER_ENABLE=0` restored correct behavior.
Sixteen-word preroll was also rejected after producing almost no improvement
over four words. Do not reopen SDRAM frequency/phase, FIFO-depth, preroll, or
feather experiments while beginning the image-scaling stage.
