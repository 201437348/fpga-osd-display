# Solid-Frame No-Feather Diagnostic Implementation Plan

**Goal:** Disable only feathering in the solid-frame SDRAM diagnostic build.

**Spec:** `docs/superpowers/specs/2026-09-12-solid-frame-no-feather-diagnostic-design.md`

- [x] Set `SLIDE_FEATHER_ENABLE` to 0 in `top.v`.
- [x] Run feather-disabled exact-pixel regression and related RTL tests.
- [x] Run real/stub top elaboration, manifest checks, and `git diff --check`.
- [x] Rebuild and separately observe the moving white line and fixed A/B lines.
  Disabling feathering changed none of them; the moving multi-edge spacing
  matches the 31-34 pixel per-frame motion, while A/B retain the next-frame
  color.
