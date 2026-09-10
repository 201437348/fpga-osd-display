# SDRAM C2 Clock-Route Parity Experiment

Date: 2026-09-04

## Goal

Investigate whether routing the existing SDRAM phase-shifted clock through an
explicit EG4 global-clock buffer changes the two real SDRAM DQ timing groups
without changing the accepted data path, operating frequency, or nominal PLL
phase relationship.

The experiment is diagnostic. It is not permission to suppress timing paths,
claim timing closure, or program configuration Flash.

## Fixed Boundary

- The active `sys_pll` configuration remains C1 = 125 MHz at 0 degrees and
  C2 = 125 MHz at 180 degrees. Its divide and phase parameters remain
  `CLKC1_DIV=8`, `CLKC1_CPHASE=7`, `CLKC2_DIV=8`, and `CLKC2_CPHASE=3`.
- The SDRAM controller, encrypted SDRAM wrappers, FIFO IP, CDC repair, TF
  reader, image manager, OSD, reset topology, board pin assignments, and SDC
  clocks remain unchanged.
- The build is JTAG-only. The accepted configuration-Flash image must not be
  replaced.
- Neither SDRAM DQ timing direction may be false-pathed, multicycled, or
  otherwise removed from analysis.

## Evidence

The accepted CDC build reports the two hard-SDRAM DQ setup groups as
`ext_mem_clk -> C2 = -2.908 ns` and `C2 -> ext_mem_clk = -6.565 ns`. The
worst direction is from `sys_pll_m0/pll_inst.clkc[2]`, through the SDRAM hard
macro DQ pins, into logic clocked by `ext_mem_clk`.

TD recognises `U3/u2_ram/SDRAM_CLK` as a clock and routes it on the clock
mesh, but reports one local resource segment between PLL C2 and the SDRAM
hard-macro clock input. The C2-to-hard-macro net includes about 2.176 ns of
routed delay; the hard macro contributes about 3.434 ns to the observed
clock-to-DQ path. Therefore the local segment is relevant, but cannot by
itself explain or prove correction of the whole 6.565 ns violation.

The TD 6.2 installed command catalogue documents
`set_clock_net <net> -bufg`, described as creating a BUFG. The EG4 primitive
library defines `EG_LOGIC_BUFG` as the driver for global-clock resources. This
is an actual routing and insertion-delay change, not a reporting-only
constraint.

The official APUG011 SDRAM reference uses the same SDRAM hard macro family and
0/180-degree clocks, but it only constrains the input clock and derives PLL
clocks. It does not provide a `set_clock_net` or explicit BUFG example. Its
150 MHz implementation and older TD report cannot be copied as proof that the
current 125 MHz DQ endpoints are closed.

## Alternatives Considered

1. **Explicit C2 BUFG route experiment (recommended).** Drive the SDRAM
   shifted-clock input from a named `EG_LOGIC_BUFG` output while keeping the
   PLL C2 generation unchanged. This gives TD an unambiguous global-clock
   request and produces a directly comparable report. It can improve, worsen,
   or leave unchanged either DQ direction because it changes insertion delay.

2. **PLL phase sweep.** Change C2 phase in one or more steps. This may move
   slack, but it alters SDRAM sampling behavior and opposite-direction
   violations mean an apparent improvement in one group can degrade the
   other. It is deliberately excluded from this experiment.

3. **Copy APUG011 SDRAM wrapper or timing constraints.** This would introduce
   encrypted-controller and frequency-specific behavior into a board-validated
   image path. It has a larger failure surface and does not isolate clock
   routing, so it is rejected.

## Proposed Change

Make one RTL-only clock-routing change in `ip/anlogic/sys_pll.v`:

1. Keep the PLL's raw C2 output on an internal wire.
2. Instantiate one named `EG_LOGIC_BUFG` with raw C2 as input.
3. Drive the existing `clk2_out` module port from that BUFG output.

`rtl/top/top.v` continues to pass `clk2_out` to the existing `sdram` wrapper
as `Clk_sft`; no other module interface changes. This makes the experiment
easy to revert by restoring the prior direct C2 connection.

The named RTL primitive is preferred to an unverified physical Tcl insertion:
the tool confirms the primitive and its intent directly in the elaborated
design, rather than relying on a post-synthesis net name that can change.

## Build and Decision Rules

After source review, the user runs TD `syn_1`, `phy_1`, and bit generation in
the GUI. The result is rejected immediately, with no JTAG download, if TD
fails to use the BUFG, reports a new hard error, or makes either DQ direction
worse than the accepted CDC baseline.

If both DQ directions are no worse, inspect the route warning and exact path
delays. A JTAG test is allowed only when the report shows the intended C2 BUFG
and does not introduce a new unresolved clock-resource error. The board test
then covers first image, twenty single manual-next operations, ten
short-interval double-press groups, 30 minutes of automatic play, and three
TF removal/reinsertion recovery cycles. Any `341100` timeout rejects the bit.

Even a fully functional result remains an experiment unless both real DQ
setup directions are non-negative. Configuration Flash remains untouched.

## Rollback

Revert only the C2 BUFG insertion, rebuild in TD, and use the existing CDC
accepted baseline source. No generated run outputs are version-controlled as
the rollback mechanism.

## Implementation Status

The experimental source change was implemented in `ip/anlogic/sys_pll.v`:
`clk2_raw` carried the PLL C2 output, and the named `bufg_sdram_clk_sft`
instance drove the existing `clk2_out` port. The C1/C2 divide and phase
parameters were unchanged. The change was later rejected and reverted as
recorded below.

Local verification passed on 2026-09-04: the PLL source parsed with vendor
primitives treated as black boxes; `tb_image_load_manager`,
`tb_image_playback_control`, `tb_bmp_read_throttle`,
`tb_image_storage_adapter`, and `tb_video_osd_overlay` all passed; and the
top-level port/connection elaboration with vendor stubs passed. TD synthesis,
physical design, and routed-report comparison were then completed; the JTAG
decision is recorded below.

## Build Result: Rejected and Reverted

The 19:20 TD build retained `bufg_sdram_clk_sft`; it identified
`U3/u2_ram/SDRAM_CLK` as BUFG-driven and reported that all clock nets avoided
local routing resources. Thus the intended route change took effect.

It nevertheless made both real SDRAM DQ setup directions worse relative to
the accepted CDC baseline:

- `ext_mem_clk -> C2`: `-2.908 ns` to `-2.964 ns` (56 ps worse).
- `C2 -> ext_mem_clk`: `-6.565 ns` to `-6.692 ns` (127 ps worse).
- Global timing: `SWNS=-6.692 ns`, `STNS=-298.147 ns`, `HWNS=+0.012 ns`, and
  `HTNS=0.000 ns`.

The explicit C2 BUFG increased the relevant clock insertion delay and does
not improve the DQ interface. It is rejected; the source has been restored to
the direct PLL-C2 connection. The generated bit SHA256 was
`3D5E2797E9B534F319DF68BF1F7B6628F98438F0362CFAB8FC607F1BED82ECCE`; it must
not be downloaded or written to configuration Flash.

## Self-Review

The scope changes one clock-route implementation point only. Frequency,
nominal phase, protocol logic, timing exceptions, FIFO IP, and Flash contents
are all explicitly excluded. Acceptance criteria distinguish report review,
JTAG permission, functional stability, and true timing closure.
