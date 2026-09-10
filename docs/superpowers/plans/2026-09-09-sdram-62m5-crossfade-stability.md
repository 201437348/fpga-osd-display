# 62.5 MHz SDRAM Crossfade Stability Implementation Plan

**Goal:** Reduce SDRAM DQ sampling errors during the accepted dual-frame
crossfade without reintroducing the refresh-timing error from the earlier
41.667 MHz experiment.

**Architecture:** Keep all media and transition RTL unchanged.  Derate only
the 0/180-degree SDRAM clock pair to 62.5 MHz and update the controller's
compile-time SDRAM period so refresh commands retain the same physical cadence.

**Spec:** `docs/superpowers/specs/2026-09-09-sdram-62m5-crossfade-stability-design.md`

## Constraints

- Keep C0 at 100 MHz and keep the separate video PLL unchanged.
- Keep the pure 32-frame blend, 64-word bursts, 4096-word dual FIFOs, and
  sticky fault diagnostics unchanged.
- Preserve all unrelated working-tree changes and do not create a Git commit.
- Build and test through JTAG only; preserve the accepted configuration Flash.

## Task 1: Apply the Matched Clock and Refresh Change

- [x] Change generated `sys_pll.v` C1/C2 to divide-by-16 with phase taps 15/7.
- [x] Update `sys_pll.ipc` to record both outputs as 62.5 MHz, divide-by-16.
- [x] Change active `global_def.v` to calculate the SDRAM period at 62.5 MHz.
- [x] Confirm no transition, FIFO, storage, audio, OSD, or top-level behavior
  source changed as part of this experiment.

## Task 2: Verify the Source Tree

- [x] Check the Verilog and IPC frequency/divider/phase values mechanically.
- [x] Run `tb_video_transition_controller`, `tb_video_transition_blender`,
  `tb_frame_dual_fifo_read`, `tb_frame_read_write_dual`, and
  `tb_video_osd_overlay`.
- [x] Elaborate the real top level with the real dual-FIFO frame wrapper.
- [x] Record the implementation and remaining board-test boundary in the
  roadmap and migration notes.

## Task 3: TD and Board Handoff

- [x] Rebuild `syn_1`, `phy_1`, and bitstream in TD 6.2.1.
- [x] Record routed timing and confirm the generated clock frequencies.
- [x] JTAG-test first load and repeated crossfades while observing image-load
  status and visual corruption.
- [ ] Complete audio, OSD,
  and TF hot-removal recovery while observing the last diagnostic digit.
- [ ] Keep configuration Flash unchanged until the complete regression passes.

Result: first and subsequent image writes completed without `341100/341002`,
but crossfade corruption remained.  The DQ read setup group was still
`-2.565ns`; this experiment is rejected and the broader regression is not
required for its bitstream.
