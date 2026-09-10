# SDRAM Hard-Macro Read-Only Audit

Date: 2026-09-04

## Goal

Determine the final legal placement and dedicated clock connection selected by
TD for the `EG_PHY_SDRAM_2M_32` hard macro in the accepted 125 MHz design.
The audit distinguishes a real user-controlled location constraint from
placement metadata carried by the encrypted SDRAM implementation or TD's
initial-placement process.

## Fixed Boundary

- `sys_pll.v` is restored to the accepted direct C2 connection: C1 = 125 MHz
  at 0 degrees and C2 = 125 MHz at 180 degrees.
- No RTL, PLL, SDC, ADC, FIFO, encrypted SDRAM file, physical location, or
  timing exception is changed in this audit.
- TD is operated only through the GUI by the user. No JTAG download or
  configuration-Flash operation is allowed.

## Evidence and Scope

The active `constraints/pin.adc` contains board I/O assignments but no
`U3/sdram` instance coordinate. Nevertheless, TD imports instance constraints
and reports that initial positions `(12, 12)` and `(164, 288)` for `U3/sdram`
are illegal and moved during placement. The message alone does not prove that
either coordinate is a user-editable constraint: the active ADC does not
contain it and the SDRAM controller implementation is encrypted.

The prior explicit C2 BUFG experiment removed the local-route warning, but
worsened both real SDRAM DQ setup directions. It is rejected and the source
is restored. This audit therefore observes the direct-C2 baseline rather than
trying another route, phase, or location change.

## Alternatives Considered

1. **Read-only final-placement audit (selected).** Rebuild the restored
   baseline and use TD physical-report commands to capture the hard macro's
   final pin locations, dedicated DRAM clock allocation, and SDRAM clock-net
   route. It has no behavioral or bitstream risk.

2. **Manual coordinate override.** No device-specific legal-site map or
   verified user-constraint syntax is available for this hard macro. Applying
   guessed coordinates could make the implementation unroutable or alter DQ
   insertion delay. Rejected.

3. **Replace the encrypted SDRAM controller.** This depends on a
   device-matched vendor-generated SDRAM package and changes a board-validated
   subsystem. Deferred until the audit identifies a concrete vendor question.

## Procedure

1. In TD GUI, reset `syn_1` and `phy_1`, then rerun `syn_1`, `phy_1`, and
   bit generation from the restored source. This overwrites the rejected BUFG
   experiment artifact. Do not download the resulting bit.
2. Open the completed `phy_1` run and use the TD Tcl Console to execute these
   read-only queries exactly:

```tcl
report_cells U3/sdram -pin_loc -connection
report_clock_utilization -dramhardcon -file D:/fpga/project/fpga/osd_display/osd_display_Runs/phy_1/dramhardcon.rpt
report_nets U3/u2_ram/SDRAM_CLK -timing -rsmt -dr -file D:/fpga/project/fpga/osd_display/osd_display_Runs/phy_1/sdram_clk_route.rpt
```

3. Preserve the Tcl Console output from `report_cells` as a screenshot. The
other two commands write reports inside the generated `phy_1` directory for
local review.

## Analysis Rules

- Record the final legal `U3/sdram` placement and each hard-macro clock pin
  reported by TD. Do not infer the final site from the rejected initial
  coordinates in `PHY-7002`.
- Record the DRAM dedicated-clock allocation and whether
  `U3/u2_ram/SDRAM_CLK` uses a local segment in the restored direct-C2 build.
- Compare the two DQ setup directions with the accepted CDC reference,
  `-2.908 ns` (`ext_mem_clk -> C2`) and `-6.565 ns`
  (`C2 -> ext_mem_clk`). Their remaining negativity is a finding, not a reason
  to suppress timing.
- If the output does not expose a user-editable legal hard-macro location,
  stop before any placement change and prepare an Anlogic support request for
  an EG4S20BG256/TD 6.2 SDRAM reference or generated wrapper.

## Acceptance

This phase succeeds when the three reports identify the final hard-macro and
clock-routing topology, or conclusively establish that it is opaque to this
project. It does not require timing closure, JTAG testing, or Flash changes.

## Execution Result

The restored direct-C2 baseline was rebuilt successfully by TD 6.2.168116 on
2026-09-04. Its routed timing is `SWNS=-6.565ns`, `STNS=-292.832ns`,
`HWNS=+0.011ns`, and `HTNS=0.000ns`; the two SDRAM DQ setup directions are
unchanged at `-2.908ns` (`ext_mem_clk -> C2`) and `-6.565ns`
(`C2 -> ext_mem_clk`). The audit-only bit SHA256 is
`21EFB4E31E9126737717D73197C90F39A01DEC16185D81D3123B163B168B4651`.
It was not board-validated and was not downloaded or programmed to Flash.

The proposed per-cell Tcl query is not usable with this design: executing
`report_cells U3/sdram -pin_loc -connection` terminates TD. In addition, the
implementation log records that `report_clock_utilization` is unsupported by
the `EG4S20BG256` device. These are tool limitations, not evidence that a
different placement is required; do not rerun either command on this project.

The standard routed reports provide the required evidence without accessing
the opaque hard macro through Tcl:

- `final_timing.rpt` records `U3/sdram.clk` and its hard-IP DQ pins at
  `x020y036`. This is the final legal hard-macro position used by the routed
  design, not either rejected initial position in `PHY-7002`.
- `run.log` identifies `U3/u2_ram/SDRAM_CLK` as PLL C2, routes it on the
  clock mesh, and then records one local-routing segment for its sole sink.
  The detailed routed timing path is PLL C2 -> `SDRAM_CLK` ->
  `U3/sdram_syn_45.do[0]` at `x040y041` -> `clk0` -> `U3/sdram.clk` at
  `x020y036`.
- The project ADC still has no `U3/sdram` coordinate, while the controller
  wrapper is encrypted. Consequently no verified, user-editable legal-site
  constraint has been exposed. Manual coordinate changes remain out of scope.

The audit therefore completes with an opaque-placement finding. Any future
placement or SDRAM-wrapper change requires an Anlogic EG4S20BG256 / TD 6.2
reference or vendor support confirmation first.

## Official Reference Resolution

The local official materials provide the needed reference. The completed
competition `lab_ex4_tf` `phy_1` log has the exact same two `PHY-7002`
messages for `U3/sdram` initial positions `(12,12)` and `(164,288)`. It also
has the same `PHY-5079` C2 local-wire summary: PLL C2 drives
`U3/u2_ram/SDRAM_CLK` with `Clock/Fanout 0/1` and `LocalWireNum 1`. Its final
routed report has the same worst C2-to-`ext_mem_clk` hard-SDRAM DQ setup slack
of `-6.565ns`.

APUG011 is an independent EG4S20BG256 reference for the same
`EG_PHY_SDRAM_2M_32` macro. It routes its C2 shifted clock directly into the
SDRAM wrapper and has no hard-macro coordinate in its ADC. The competition
`sdram.v` is topologically identical to this project's `sdram.v`, and both
`sdr_as_ram.enc.v` and `sdr_wrrd.enc.v` are byte-identical.

The audit result is therefore refined: the warnings and negative hard-macro
DQ setup report occur in the official baseline. They remain timing-debt
observations, but do not justify manual placement, a generic BUFG, an encrypted
wrapper replacement, or a vendor escalation for this board-validated design.

## Self-Review

The procedure is read-only after the necessary baseline rebuild. It excludes
all timing suppression, phase/frequency changes, manual placement guesses,
and board programming. The report names, command paths, target instance, and
decision boundary are explicit.
