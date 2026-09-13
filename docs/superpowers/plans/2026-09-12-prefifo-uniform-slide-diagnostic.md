# Pre-FIFO Uniform Slide Diagnostic Implementation Plan

> **For agentic workers:** Execute each checked step in order and keep TD and
> the downloader closed while editing project files.

**Goal:** Replace sliding-frame pixels at the asynchronous FIFO write boundary
with one frame-uniform color for a board-level binary diagnostic.

**Architecture:** `frame_slide_fifo_read` latches a diagnostic enable for each
accepted request and overrides only its final FIFO payload. The parameter is
passed through `frame_read_write`; the top restores normal video selection and
enables the pre-FIFO diagnostic.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, Icarus Verilog 14.0,
Anlogic TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-12-prefifo-uniform-slide-diagnostic-design.md`

## Global Constraints

- Keep static frames on real SDRAM pixels.
- Do not alter FIFO enables, addresses, timing, reset, or read control.
- Restore the top-level output from the video-clock bypass to `vout_data_raw`.
- Keep TD and the downloader closed while editing.

---

### Task 1: Test the FIFO-boundary override

- [x] Add a parameterized expected uniform-color mode to
  `tests/tb_frame_slide_full_line.sv`.
- [x] Run it before RTL support and require elaboration to fail.
- [x] Add the disabled-by-default frame-latched override to
  `frame_slide_fifo_read.v`.
- [x] Run normal, feather-disabled, and uniform diagnostic modes, including a
  real-pixel static frame with the diagnostic parameter enabled.

### Task 2: Integrate the board diagnostic

- [x] Pass the parameter through `frame_read_write.v` and its compile stub.
- [x] Enable it in `top.v` and restore normal `vout_data_raw` selection.
- [x] Run focused regressions, real/stub top elaboration, manifest checks, and
  `git diff --check`.

### Task 3: Board result

- [x] Rebuild `syn_1`, `phy_1`, and Generate Bitstream. No left-edge line was
  visible while the uniform color changed, locating the fault before the FIFO
  write boundary.
