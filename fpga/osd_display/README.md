# OSD Display FPGA Project

This is the formal project for the reliable video baseline. `fpga/tf_hdmi_diag`
remains the diagnostic reference and is not modified by this project.

## Current migration status

- `rtl/top/top.v` is the functionally equivalent 10-second timeout baseline.
- `rtl/vendor`, `ip/anlogic`, and `constraints` are local migration copies.
- `rtl/control/image_load_manager.v` is an independently tested replacement
  boundary for image loading and recovery. It is deliberately not connected to
  the top-level baseline until the migration build and board equivalence test
  have passed.

## Required first hardware checks

1. Open `osd_display.al` in this directory with TD 6.2.1 and run `syn_1` then `phy_1`.
2. Record all clock, SDRAM, and timing warnings. Do not add broad false paths.
3. Download through JTAG and confirm the four official BMP images, `KEY1`,
   `KEY2`, and `KEY4` behave as in the validated diagnostic baseline.
4. Only after JTAG equivalence, write configuration Flash and perform three
   power-off cold starts, followed by a 30-minute automatic-play run.

Generated `*_Runs` directories and programming files are intentionally ignored.
