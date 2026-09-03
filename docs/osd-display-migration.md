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
