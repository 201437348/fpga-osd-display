# FAT32 Directory Scan Timing Pipeline

## Goal

Remove the newly introduced setup-time violation in the 100 MHz
`sd_card_clk` domain of `fat32_directory_scan`. The scan must retain its
current FAT32 behavior, SD-card request protocol, and externally visible
outputs.

## Scope

Only the valid-BPB path after `ST_PARSE_BOOT` is changed. SDRAM, PLL, clock
routing, constraints, SD-card core, loader, adapter, playback control, video,
and OSD are out of scope.

The existing invalid-BPB path remains in `ST_PARSE_BOOT`: it pulses `done`
and `error`, returns to idle, and never starts a directory request.

## Design

The current implementation computes the FAT-region size and the root
directory LBA in one clock. It combines multiplication and multiple 32-bit
additions in a path that is too long for `sd_card_clk`.

Add three internal states between `ST_PARSE_BOOT` and `ST_READ_DIR`:

1. `ST_CALC_DATA_LBA` consumes registered values from the successful BPB
   parse and registers the FAT start LBA, FAT-region sector count, and the
   root-cluster delta (`root_cluster - 2`).
2. `ST_CALC_ROOT_OFFSET` registers `first_data_lba` and the root-directory
   sector offset (`root_cluster_delta * sectors_per_cluster`).
3. `ST_START_DIR` performs the final add, assigns the existing volume
   geometry outputs, assigns `current_dir_sector_lba` and
   `sd_sec_read_addr`, initializes directory traversal counters, and
   transitions to the existing `ST_READ_DIR` state.

Each state performs one bounded arithmetic stage. The old directory-reader
state continues to assert `sd_sec_read`; all preparation states keep it low.
The first raw SD request therefore occurs only after the complete root LBA is
registered.

## Behavioral Contract

The public module ports and output meanings are unchanged. The successful
request order remains:

```text
MBR -> boot sector -> root-directory sector -> FAT sector when needed -> next directory sector
```

Successful scans take three additional `sd_card_clk` cycles, about 30 ns. The
adapter consumes file records and volume geometry only after the scanner's
successful `done` pulse, so this latency cannot change loading behavior.

## Verification

Extend `tb_fat32_directory_scan` to check that no directory read begins in
the three preparation states and that the root-directory request address
remains correct. Preserve its successful MBR, successful superfloppy,
invalid-BPB, and cyclic-directory coverage.

Run the directory-scanner test, the FAT32 loader and adapter tests, the
existing storage-adapter and playback-manager tests, and top-level Icarus
structural elaboration. Then request a TD GUI rebuild. Acceptance requires:

- no simulation regression;
- no errors from the new RTL;
- `sd_card_clk` setup WNS at or above zero for the new directory-scan path;
- the known external SDRAM worst path remains unchanged at approximately
  `-6.565 ns`;
- no Flash programming before JTAG-only board validation passes.

## Git

This design document is intentionally not committed in this step. Git changes
remain under explicit user control.
