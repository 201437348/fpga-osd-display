# SDRAM Return Uniform Diagnostic Implementation Plan

**Goal:** Substitute slide-frame SDRAM return payloads before scheduler
composition while retaining all command and downstream timing.

**Architecture:** A request-latched diagnostic flag selects a uniform word in
the scheduler's return-data consumption logic. The wrapper exposes the
parameter and the top enables it while disabling the later FIFO-payload
override.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog, Icarus Verilog 14.0, Anlogic
TD 6.2.1.

**Spec:** `docs/superpowers/specs/2026-09-12-sdram-return-uniform-diagnostic-design.md`

## Constraints

- Do not change read commands, addresses, enables, counts, or FIFO timing.
- Apply the substitution only to accepted slide frames.
- Keep static frames on real SDRAM pixels.
- Keep TD and the downloader closed while editing.

### Task 1: Test and implement the return-entry override

- [x] Add the return-entry mode to the full-line exact-pixel test.
- [x] Require elaboration failure before the RTL parameter exists.
- [x] Implement the request-latched substitution at every `Sdr_rd_dout`
  consumption point.
- [x] Run normal, feather-disabled, FIFO-output, and SDRAM-return modes.

### Task 2: Integrate and regress

- [x] Pass the parameter through the wrapper and test stubs.
- [x] Enable only the SDRAM-return diagnostic in `top.v`.
- [x] Run focused regressions, real/stub top elaboration, manifest checks, and
  `git diff --check`.

### Task 3: Board observation

- [x] Rebuild and observe the uniform-color slide. No left-edge line appeared,
  locating the defect in real SDRAM data/address behavior rather than the
  scheduler's post-return composition.
