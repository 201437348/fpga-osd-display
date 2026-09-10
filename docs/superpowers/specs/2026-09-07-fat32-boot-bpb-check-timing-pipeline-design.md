# FAT32 Boot BPB Check Timing Pipeline

## Goal

Eliminate the remaining two `sd_card_clk` setup violations caused by the
FAT32 boot-sector BPB validation path in `fat32_directory_scan`.

The pre-change worst path starts at `bpb_root_cluster`, evaluates the
`bpb_root_cluster < 2` comparison as part of the complete BPB validity
condition, then drives the state-control mux. Its reported slack is
`-0.175 ns` at the 100 MHz `sd_card_clk` constraint.

## Scope

Only `fat32_directory_scan` changes. The public interface, FAT32 on-card
format handling, directory traversal, file reader, BMP loader, SD-card
ownership, SDRAM, clocks, constraints, OSD/video, and configuration Flash
are out of scope.

## Architecture

Add a registered BPB-result stage between boot-sector parsing and layout
address preparation:

```text
ST_PARSE_BOOT -> ST_CHECK_BOOT_BPB -> ST_CALC_DATA_LBA
                                     -> ST_CALC_ROOT_OFFSET
                                     -> ST_START_DIR
```

`ST_PARSE_BOOT` evaluates the existing complete BPB-invalid condition and
stores its result in a one-bit `boot_bpb_invalid` register. It does not make
the success or failure state transition based on that combinational result.

`ST_CHECK_BOOT_BPB` reads only `boot_bpb_invalid`:

- A set bit produces the existing one-clock `done` and `error` pulses,
  deasserts `busy`, and returns to `ST_IDLE`.
- A clear bit enters `ST_CALC_DATA_LBA` with the same captured BPB fields and
  layout inputs as before.

The new stage adds one 100 MHz clock (10 ns) to boot parsing. This is
negligible compared with the approximately 22-second initial image load.

## Behavioral Compatibility

The BPB invalidity condition remains exactly:

- invalid `0x55AA` boot signature;
- bytes-per-sector other than 512;
- invalid, non-power-of-two, or over-128 sectors-per-cluster;
- zero reserved-sector or FAT-count fields;
- nonzero FAT16 root-entry-count or FAT16 size fields;
- zero FAT32 size; or
- root directory cluster below 2.

No SD read request occurs during `ST_CHECK_BOOT_BPB`. Invalid media therefore
continues to terminate before any root-directory read. Valid media preserves
the existing root directory location and logical request order.

## Verification

Update `tb_fat32_directory_scan` to account for the new state and verify:

1. A valid FAT32 boot sector reaches directory reading, with no extra or
   reordered SD request.
2. Root cluster values below 2 produce one `done + error` pulse and no
   root-directory SD request.
3. Invalid boot signatures retain the same failure behavior.
4. `sd_sec_read` remains low while in `ST_CHECK_BOOT_BPB`.

Run the established FAT32 scanner, file-reader, BMP-loader, adapter,
load-manager, playback-control, OSD, throttle, and top-level structural
simulation checks. After they pass, request a TD GUI compile. Acceptance is
nonnegative `sd_card_clk` setup WNS with no new RTL or simulation regression.
The pre-existing SDRAM timing paths are not part of this work.

## Git

No Git operation is part of this change. Repository commits remain under
explicit user control.
