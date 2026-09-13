# Read Address Pattern Diagnostic Implementation Plan

**Goal:** Render slide pixels from accepted SDRAM read addresses while keeping
the real command and return handshake active.

**Architecture:** A latched chunk base plus the in-order return count identifies
the address paired with each return. A request-latched parameter selects an
address-derived RGB ramp at the existing scheduler return-data boundary.

**Spec:** `docs/superpowers/specs/2026-09-12-read-address-pattern-diagnostic-design.md`

### Task 1: Test and implement

- [x] Add an exact expected-address-pattern mode to the full-line test.
- [x] Require elaboration failure before RTL support exists.
- [x] Capture each chunk base and substitute its return-indexed pattern.
- [x] Run normal and all diagnostic modes, including static-frame coverage.

### Task 2: Integrate and regress

- [x] Pass the parameter through wrappers and stubs.
- [x] Enable only address-pattern mode at the top.
- [x] Run focused regressions, real/stub top elaboration, manifest checks, and
  `git diff --check`.

### Task 3: Board observation

- [x] Rebuild and check the physical left edge. The five repeating ramps moved
  without an extra left-edge line; visible multi-frame trails were display and
  camera motion persistence.
