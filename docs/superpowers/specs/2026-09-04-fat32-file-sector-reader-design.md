# FAT32 File Sector Reader

## Goal

Add a synthesizable, project-owned FAT32 file-sector reader that maps a BMP
file's sequential logical sectors to the physical sectors named by its FAT32
cluster chain. It removes the existing raw-reader assumption that all file
sectors are physically contiguous.

This phase is an isolated module and testbench. It does not replace
`bmp_read`, connect to `image_storage_adapter`, change `top.v`, or alter the
active TF, SDRAM, FIFO, HDMI, OSD, clock, reset, or configuration-Flash path.

## Inputs And Outputs

Add `rtl/storage/fat32_file_sector_reader.v` in the SD-card clock domain.
`start` latches one file session's `file_first_cluster`, `file_size`,
`first_fat_lba`, `first_data_lba`, and `sectors_per_cluster`. The reader
rejects a start cluster below two, a zero file size, or a zero/non-power-of-two
sectors-per-cluster value.

A consumer requests the next logical file sector through a level request:

```text
consumer -> file_sec_read, file_sec_index
reader   -> file_sec_read_ack
```

The consumer holds `file_sec_read` and `file_sec_index` stable until the
one-clock `file_sec_read_ack` pulse. Each accepted index must equal the next
unread logical file-sector index. This deliberately forbids random access and
keeps cluster traversal sequential.

For an accepted request, the reader returns one full 512-byte sector on:

```text
reader -> file_sec_data, file_sec_data_valid, file_sec_read_end
```

The final partial logical sector is still returned as 512 bytes. The consumer
uses the supplied file size to ignore bytes after the end of the file. The
reader pulses `file_complete` and `done` together after the final requested
file sector finishes, then returns to its inactive state.

The reader owns the physical SD request port:

```text
reader      -> sd_sec_read, sd_sec_read_addr
sd_card_top -> sd_sec_read_data, sd_sec_read_data_valid, sd_sec_read_end
```

It passes data from a physical file-data sector to the file-data output
unchanged. FAT lookup sectors are consumed internally and are never exposed to
the consumer.

## Mapping And State

At `start`, the current cluster is the file's first cluster and the within-
cluster sector index is zero. A logical sector request maps to:

```text
physical_lba = first_data_lba + ((current_cluster - 2) * sectors_per_cluster)
             + sector_in_cluster
```

After each physical file-data sector completes, the reader increments its
logical sector count and within-cluster index. If more file sectors remain and
the cluster boundary is reached, it reads the 32-bit FAT entry for the current
cluster before acknowledging another data-sector request. The FAT entry is at
`first_fat_lba + (current_cluster >> 7)`, with byte offset
`current_cluster[6:0] * 4`; only its low 28 bits are significant.

The reader follows only the first FAT copy. It permits an end-of-chain value
only after all logical sectors required by `file_size` have been delivered.

## Errors And Abort

The reader provides one-clock `done` and `error` outputs, then returns to its
inactive state. It errors for an invalid session geometry, a nonsequential or
out-of-range logical-sector request, a free, bad, reserved, or premature
end-of-chain FAT value, or a FAT traversal exceeding a configurable file-
cluster bound. It must never expose FAT-sector bytes as BMP data.

`abort` clears the session state and deasserts the reader's SD request. It is
for a future owner to use only after the underlying SD request has completed;
this isolated module does not redefine the existing SD-core abort behaviour.

## Verification

Add `tests/tb_fat32_file_sector_reader.sv` with the same 512-byte physical
sector response model used by directory-scanner tests. It will verify:

- a four-logical-sector file with two sectors per cluster and a fragmented
  chain, including the expected physical request order;
- data from each requested logical sector arrives unchanged and in file order;
- FAT lookup data never appears on the file output;
- final partial-sector completion;
- invalid start geometry, bad/premature FAT entries, and nonsequential logical
  sector requests produce `done` and `error` without an endless request.

No TD build or board test is required in this phase because the production
top-level has no dependency on the new module. Integration with the BMP
decoder will be a separate reviewed change with existing playback and recovery
regression tests.
