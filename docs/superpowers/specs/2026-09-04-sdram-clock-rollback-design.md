# SDRAM Clock Rollback Design

## Decision

The 41.667 MHz SDRAM clock experiment is rejected. It made both hard-SDRAM
DQ setup path groups positive, but JTAG testing repeatedly produced a
ten-second `341100 -> 341002` timeout and retry. The same failure occurred
in automatic play and after TF-card reinsertion on a single manual request.

Restore the accepted 125 MHz SDRAM operating clock before further development.
This rollback restores the known functional source baseline only; it does not
claim timing closure for the 125 MHz SDRAM DQ paths.

## Scope

Change only the active `sys_pll` configuration files:

- `fpga/osd_display/ip/anlogic/sys_pll.ipc`
- `fpga/osd_display/ip/anlogic/sys_pll.v`

Restore C1 and C2 as follows:

| Output | Frequency | Phase | Divide | Phase tap |
| --- | ---: | ---: | ---: | ---: |
| C1 / `ext_mem_clk` | 125 MHz | 0 degrees | 8 | 7 |
| C2 / `ext_mem_clk_sft` | 125 MHz | 180 degrees | 8 | 3 |

The 100 MHz SD-card clock, 25 MHz video clock, 125 MHz HDMI serial clock,
SDRAM controller RTL, TF/BMP reader, FIFO settings, recovery controller,
button behavior, pin constraints and configuration Flash contents remain
unchanged.

## Verification

1. Build the root `fpga/osd_display/osd_display.al` through `syn_1`, `phy_1`
   and bit generation.
2. Record global `SWNS`, `STNS`, `HWNS` and the SDRAM DQ path groups. The
   expected result is restoration of the earlier 125 MHz timing condition;
   negative DQ slack remains an open issue rather than a rollback failure.
3. JTAG-download only. Do not program configuration Flash.
4. Verify first image, one manual next-image request, close-spaced manual
   requests, automatic play, TF removal followed by next-image request, and
   reinsertion recovery.
5. Accept the rollback only if no prolonged `341100` or `341002` timeout
   occurs during normal automatic play or after reinsertion recovery.

## Follow-on Boundary

After functional rollback acceptance, timing closure is split into independent
work items:

- reset-release synchronization for `rst_all` in each receiving clock domain;
- replacement of the cross-domain FIFO asynchronous-clear control path with
  a safe request/acknowledgement protocol;
- SDRAM DQ timing closure at a throughput that preserves reliable image loads.

No `false_path` may be used to hide the SDRAM DQ paths.

## Implementation Status

On 2026-09-04, the workspace `sys_pll.ipc` and generated `sys_pll.v` were
restored to C1/C2 divide-by-8 with phase taps 7 and 3. TD build and JTAG
rollback verification passed. The 15:17 report was `SWNS=-6.565ns`,
`STNS=-299.804ns`, `HWNS=0.011ns`, `HTNS=0.000ns`; DQ setup slack was
`-2.908ns` toward `clkc[2]` and `-6.565ns` in the reverse direction. Normal
behavior returned with no `341100` timeout. The rollback bit was not written
to configuration Flash.
