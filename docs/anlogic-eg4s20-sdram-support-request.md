# Anlogic Support Request Draft: EG4S20 SDRAM Hard Macro and C2 Clock Route

## Status

Do not send this request for `PHY-7002`, the C2 local-wire warning, or the
reported `-6.565ns` DQ setup slack alone. The official competition
`lab_ex4_tf` baseline has the same two initial-location messages, the same C2
local-wire summary, and the same worst DQ slack while using the same direct-C2
topology. Retain this draft only if formal SDRAM timing closure is required.

## Environment

- Device: EG4S20BG256
- Tool: Tang Dynasty v6.2.168116
- Project: `osd_display`, using the device-library `EG_PHY_SDRAM_2M_32` macro
- SDRAM clocks: C1 is 125 MHz at 0 degrees; C2 is 125 MHz at 180 degrees
- Controller wrappers such as `sdr_as_ram.enc.v` are encrypted

## Validated Baseline

The direct-C2 design operates reliably on the board. First-image display takes
about 22 seconds, and long stress tests of manual-next, automatic playback,
and TF-card removal/reinsertion passed. A separate `write_req_ack` CDC issue
was repaired with a two-flop SD-clock synchronizer; this change does not alter
the SDRAM clocks, phases, or constraints.

Latest routed timing from the read-only audit:

- `SWNS=-6.565ns`, `STNS=-292.832ns`
- `HWNS=+0.011ns`, `HTNS=0.000ns`
- SDRAM DQ setup, `ext_mem_clk -> C2`: `-2.908ns`
- SDRAM DQ setup, `C2 -> ext_mem_clk`: `-6.565ns`

Adding an explicit `EG_LOGIC_BUFG` after C2 worsened those two DQ setup paths
to `-2.964ns` and `-6.692ns`, respectively. That experiment was reverted.
This request does not seek a frequency, phase, or BUFG change.

## Physical-Implementation Observations

1. TD emits `PHY-7002` twice: initial `U3/sdram` coordinates `(12,12)` and
   `(164,288)` are illegal and moved. The active `constraints/pin.adc` has no
   `U3/sdram` coordinate constraint.
2. The final routed timing report places `U3/sdram.clk` and its hard-IP DQ
   pins at `x020y036`; neither reported initial coordinate is final.
3. `U3/u2_ram/SDRAM_CLK` is driven by `sys_pll_m0/pll_inst.clkc[2]` with
   fanout one. TD reports clock-mesh routing plus one local-routing segment.
   The detailed path is C2 -> `SDRAM_CLK` -> `U3/sdram_syn_45.do[0]` at
   `x040y041` -> `clk0` -> `U3/sdram.clk` at `x020y036`.
4. Tcl command `report_cells U3/sdram -pin_loc -connection` immediately
   terminates TD. The implementation log also says `report_clock_utilization`
   is unsupported on EG4S20BG256.

## Requested Guidance

1. Does `EG_PHY_SDRAM_2M_32` on EG4S20BG256 have a user-configurable legal
   hard-macro location? If yes, provide the legal-site map, TD 6.2 ADC/Tcl
   syntax, and a complete constraint example.
2. If placement is managed by the encrypted wrapper or tool, explain the
   origin and intended handling of the two `PHY-7002` initial coordinates;
   also provide a safe way to report final placement and dedicated-clock
   connections without the `report_cells` crash.
3. Provide a TD 6.2-compatible EG4S20BG256 reference project or generated
   `EG_PHY_SDRAM_2M_32` wrapper, including recommended C1/C2 frequency,
   phase, clock-buffer topology, and SDRAM DQ constraints.
4. Is the reported local-routing segment on C2 to the SDRAM hard macro normal
   for the intended dedicated connection? If not, what topology is required?
5. Please confirm the STA model, recommended target frequency, and acceptable
   implementation result for the two DQ setup paths above.

## Available Attachments

- `osd_display_Runs/phy_1/run.log`
- `osd_display_Runs/phy_1/final_timing.rpt`
- `constraints/pin.adc` and `constraints/timing.sdc`
- Timing comparison for direct C2 and the rejected explicit-BUFG experiment

This is a draft only. It does not change RTL, ADC, SDC, or generated IP.
