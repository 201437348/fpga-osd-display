# FAT32 Root Directory Discovery

## Goal

Add a project-owned, synthesizable FAT32 directory scanner that discovers up
to four BMP files from the TF card root directory. The scanner reports each
file's short name, first data-cluster number, and byte size. It is an isolated
discovery boundary: this phase does not change the active image player.

## Scope

The scanner supports:

- 512-byte sectors;
- an MBR containing a primary FAT32 partition, or a FAT32 boot sector at
  logical sector zero;
- FAT32 root-directory cluster chains;
- the first four regular root-directory entries with an 8.3 `BMP` extension,
  in directory order.

It ignores deleted entries, volume labels, directories, and long-file-name
entries. A long-name file remains discoverable through its mandatory 8.3 alias
when that alias has a `BMP` extension.

It does not support subdirectories, FAT12/FAT16, non-512-byte sectors,
writing a card, file data reads, image decoding, or a playback/top-level
integration. It uses the first FAT copy only.

## Architecture

Add `rtl/storage/fat32_directory_scan.v`. The module owns a one-sector-at-a-
time request protocol:

```text
fat32_directory_scan -> sd_sec_read, sd_sec_read_addr
sd_card_top          -> sd_sec_read_data, sd_sec_read_data_valid, sd_sec_read_end
```

It exposes a `start` input, `busy`, `done`, and `error` outputs, plus a
one-clock `file_found` pulse carrying `file_name[87:0]`, `file_first_cluster`,
and `file_size`. A consumer increments its own count from `file_found`; the
scanner's `file_count` reports the total found on `done`.

The scanner proceeds through these states:

1. Read logical sector zero. Inspect its four MBR primary partition entries
   and use the first nonzero-start entry whose type is FAT32 CHS (`0x0B`) or
   FAT32 LBA (`0x0C`). If none exists, treat sector zero as the boot sector.
2. Parse the FAT32 BIOS parameter block. Require the boot signature, 512-byte
   sectors, a nonzero power-of-two sectors-per-cluster value, nonzero reserved
   sectors and FAT count, FAT16 size zero, nonzero FAT32 size, root-entry count
   zero, and a root cluster of at least two.
3. Calculate the first FAT LBA and first data LBA, then read sectors in the
   root directory's first cluster.
4. Parse each 32-byte directory entry. Emit valid `.BMP` regular files until
   four are found or the end marker is reached.
5. At a cluster boundary, read the relevant FAT sector and follow the
   root-directory's next-cluster entry. An end-of-chain value completes the
   scan. A bounded root-directory cluster count prevents a damaged FAT loop
   from keeping the scanner busy indefinitely.

The first data LBA is `partition_start + reserved_sectors +
(fat_count * fat_size_32)`. A directory-cluster LBA is `first_data_lba +
((cluster - 2) * sectors_per_cluster)`. The FAT entry for a cluster is at
`first_fat_lba + (cluster >> 7)`, at byte offset `(cluster[6:0] * 4)` within
that sector; only its low 28 bits are used.

All arithmetic is unsigned sector/cluster arithmetic. The module consumes
only one outstanding sector request. It assumes the existing SD-sector layer
returns the requested sector as a valid byte stream ending with
`sd_sec_read_end`; it does not alter that layer or add a new clock domain.

## Errors

`done` is asserted for a valid empty directory and for normal completion. For
an error, `done` and `error` assert together for one clock, then `busy` falls.
No `file_found` is emitted after the fault. Errors cover an unsupported format,
a malformed BPB, an invalid root-directory cluster, or a root-directory chain
that exceeds the configured traversal bound. The module resets all discovery
outputs on reset and on each new `start`.

## Verification

Add `tests/tb_fat32_directory_scan.sv` with a 512-byte-sector response model.
The test cases are:

- MBR plus FAT32 boot sector with four root BMP files;
- a root directory that spans two clusters;
- skipped deleted, volume-label, directory, and long-file-name entries;
- a valid empty root directory;
- invalid BPB values and an overlong/damaged root-directory chain.

Passing requires the emitted metadata and ordering to match the constructed
directory entries, completion on every valid image, and an error rather than
an endless scan for malformed media. Existing playback, OSD, SDRAM, FIFO,
clock, reset, and configuration-Flash behavior remain untouched because this
module is not integrated into `top.v` in this phase.

## Follow-On Boundary

After this scanner passes simulation, the next phase will use its metadata to
replace the raw-sector image discovery path. A separate FAT32 file-cluster
reader will follow each BMP file's data-cluster chain and feed the existing
BMP parser. That integration requires a fresh design review and regression
test plan.
