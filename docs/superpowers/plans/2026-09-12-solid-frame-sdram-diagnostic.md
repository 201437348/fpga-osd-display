# Solid-Frame SDRAM Diagnostic Implementation Plan

**Goal:** Store distinct solid colors in the two real SDRAM frame buffers and
slide between them through the complete read path.

**Architecture:** A parameterized mux at the write FIFO input selects a color
from `write_addr_index`. All read-side diagnostics are disabled.

**Spec:** `docs/superpowers/specs/2026-09-12-solid-frame-sdram-diagnostic-design.md`

### Task 1: Test and implement

- [x] Add a focused wrapper test for buffer-color selection and default pass-through.
- [x] Require elaboration failure before the wrapper parameter exists.
- [x] Implement the write FIFO input mux.

### Task 2: Integrate and regress

- [x] Enable solid writes and disable all read-side diagnostics in `top.v`.
- [x] Update compile stubs and run focused regressions and top elaboration.
- [x] Validate manifests and `git diff --check`.

### Task 3: Board observation

- [ ] Rebuild, load both buffers, and inspect the physical left edge during
  red/green sliding.
