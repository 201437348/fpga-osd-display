`timescale 1ns/1ps

module tb_fat32_directory_scan;

reg clk = 1'b0;
reg rst = 1'b1;
reg start = 1'b0;
wire busy;
wire done;
wire error;
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;
reg [7:0] sd_sec_read_data = 8'd0;
reg sd_sec_read_data_valid = 1'b0;
reg sd_sec_read_end = 1'b0;
wire file_found;
wire [2:0] file_count;
wire [87:0] file_name;
wire [31:0] file_first_cluster;
wire [31:0] file_size;
wire [31:0] volume_first_fat_lba;
wire [31:0] volume_first_data_lba;
wire [7:0] volume_sectors_per_cluster;
wire bgm_found;
wire [31:0] bgm_first_cluster;
wire [31:0] bgm_size;

reg [7:0] disk [0:32767];
reg serving = 1'b0;
reg end_pending = 1'b0;
reg request_complete = 1'b0;
reg [31:0] active_sector = 32'd0;
reg [8:0] response_byte_index = 9'd0;
integer request_count = 0;
reg [31:0] request_log [0:31];
integer boot_bpb_check_cycles = 0;
integer directory_prepare_cycles = 0;
integer directory_next_prepare_cycles = 0;

integer capture_count = 0;
reg [87:0] captured_name [0:3];
reg [31:0] captured_cluster [0:3];
reg [31:0] captured_size [0:3];

always #5 clk = ~clk;

fat32_directory_scan #(
    .MAX_ROOT_DIR_CLUSTERS(16'd2)
) dut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .busy(busy),
    .done(done),
    .error(error),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),
    .file_found(file_found),
    .file_count(file_count),
    .file_name(file_name),
    .file_first_cluster(file_first_cluster),
    .file_size(file_size),
    .volume_first_fat_lba(volume_first_fat_lba),
    .volume_first_data_lba(volume_first_data_lba),
    .volume_sectors_per_cluster(volume_sectors_per_cluster),
    .bgm_found(bgm_found),
    .bgm_first_cluster(bgm_first_cluster),
    .bgm_size(bgm_size)
);

// Model the established SD-layer contract: 512 valid bytes, then one end pulse.
always @(posedge clk) begin
    sd_sec_read_data_valid <= 1'b0;
    sd_sec_read_end <= 1'b0;

    if (end_pending) begin
        sd_sec_read_end <= 1'b1;
        end_pending <= 1'b0;
        request_complete <= 1'b1;
    end else if (request_complete) begin
        if (!sd_sec_read)
            request_complete <= 1'b0;
    end else if (serving) begin
        sd_sec_read_data <= disk[(active_sector * 512) + response_byte_index];
        sd_sec_read_data_valid <= 1'b1;
        if (response_byte_index == 9'd511) begin
            serving <= 1'b0;
            end_pending <= 1'b1;
        end else begin
            response_byte_index <= response_byte_index + 9'd1;
        end
    end else if (sd_sec_read) begin
        serving <= 1'b1;
        active_sector <= sd_sec_read_addr;
        response_byte_index <= 9'd0;
        request_log[request_count] <= sd_sec_read_addr;
        request_count <= request_count + 1;
    end
end

always @(posedge clk) begin
    if (!rst && (dut.state == 4'd13)) begin
        if (sd_sec_read)
            $fatal(1, "FAIL boot BPB check started an SD request");
        boot_bpb_check_cycles = boot_bpb_check_cycles + 1;
    end
end

always @(posedge clk) begin
    if (!rst && ((dut.state == 4'd11) || (dut.state == 4'd12))) begin
        if (sd_sec_read)
            $fatal(1, "FAIL successor directory preparation started an SD request");
        directory_next_prepare_cycles = directory_next_prepare_cycles + 1;
    end
end

always @(posedge clk) begin
    if (!rst && ((dut.state == 4'd8) || (dut.state == 4'd9) ||
                 (dut.state == 4'd10))) begin
        if (sd_sec_read)
            $fatal(1, "FAIL directory address preparation started an SD request");
        directory_prepare_cycles = directory_prepare_cycles + 1;
    end
end

always @(posedge file_found) begin
    #1;
    captured_name[capture_count] = file_name;
    captured_cluster[capture_count] = file_first_cluster;
    captured_size[capture_count] = file_size;
    capture_count = capture_count + 1;
end

task automatic expect_bit;
    input actual;
    input expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0b, got %0b", checkpoint, expected, actual);
    end
endtask

task automatic expect_value;
    input [31:0] actual;
    input [31:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

task automatic expect_name;
    input [87:0] actual;
    input [87:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %h, got %h", checkpoint, expected, actual);
    end
endtask

task automatic put_byte;
    input integer sector;
    input integer offset;
    input [7:0] value;
    begin
        disk[(sector * 512) + offset] = value;
    end
endtask

task automatic put_le16;
    input integer sector;
    input integer offset;
    input [15:0] value;
    begin
        put_byte(sector, offset, value[7:0]);
        put_byte(sector, offset + 1, value[15:8]);
    end
endtask

task automatic put_le32;
    input integer sector;
    input integer offset;
    input [31:0] value;
    begin
        put_byte(sector, offset, value[7:0]);
        put_byte(sector, offset + 1, value[15:8]);
        put_byte(sector, offset + 2, value[23:16]);
        put_byte(sector, offset + 3, value[31:24]);
    end
endtask

task automatic clear_disk;
    integer index;
    begin
        for (index = 0; index < 32768; index = index + 1)
            disk[index] = 8'd0;
    end
endtask

task automatic clear_capture;
    integer index;
    begin
        capture_count = 0;
        request_count = 0;
        boot_bpb_check_cycles = 0;
        directory_prepare_cycles = 0;
        directory_next_prepare_cycles = 0;
        for (index = 0; index < 4; index = index + 1) begin
            captured_name[index] = 88'd0;
            captured_cluster[index] = 32'd0;
            captured_size[index] = 32'd0;
        end
        for (index = 0; index < 32; index = index + 1)
            request_log[index] = 32'd0;
    end
endtask

task automatic make_mbr;
    input integer partition_start;
    begin
        put_byte(0, 450, 8'h0C);
        put_le32(0, 454, partition_start);
        put_byte(0, 510, 8'h55);
        put_byte(0, 511, 8'hAA);
    end
endtask

task automatic make_boot_sector;
    input integer sector;
    input [15:0] bytes_per_sector;
    begin
        put_le16(sector, 11, bytes_per_sector);
        put_byte(sector, 13, 8'd1);
        put_le16(sector, 14, 16'd1);
        put_byte(sector, 16, 8'd1);
        put_le16(sector, 17, 16'd0);
        put_le16(sector, 22, 16'd0);
        put_le32(sector, 36, 32'd1);
        put_le32(sector, 44, 32'd2);
        put_byte(sector, 510, 8'h55);
        put_byte(sector, 511, 8'hAA);
    end
endtask

task automatic make_bmp_entry;
    input integer sector;
    input integer entry_index;
    input [87:0] name;
    input [31:0] first_cluster;
    input [31:0] size;
    integer offset;
    begin
        offset = entry_index * 32;
        put_byte(sector, offset + 0, name[87:80]);
        put_byte(sector, offset + 1, name[79:72]);
        put_byte(sector, offset + 2, name[71:64]);
        put_byte(sector, offset + 3, name[63:56]);
        put_byte(sector, offset + 4, name[55:48]);
        put_byte(sector, offset + 5, name[47:40]);
        put_byte(sector, offset + 6, name[39:32]);
        put_byte(sector, offset + 7, name[31:24]);
        put_byte(sector, offset + 8, name[23:16]);
        put_byte(sector, offset + 9, name[15:8]);
        put_byte(sector, offset + 10, name[7:0]);
        put_byte(sector, offset + 11, 8'h20);
        put_le16(sector, offset + 20, first_cluster[31:16]);
        put_le16(sector, offset + 26, first_cluster[15:0]);
        put_le32(sector, offset + 28, size);
    end
endtask

task automatic fill_deleted_entries;
    input integer sector;
    input integer first_entry;
    integer entry_index;
    begin
        for (entry_index = first_entry; entry_index < 16; entry_index = entry_index + 1)
            put_byte(sector, entry_index * 32, 8'hE5);
    end
endtask

task automatic start_scan;
    begin
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end
endtask

task automatic wait_for_done;
    begin
        @(posedge done);
        #1;
    end
endtask

initial begin
    clear_disk();
    clear_capture();
    repeat (2) @(posedge clk);
    rst = 1'b0;

    // MBR FAT32 volume: the root spans clusters 2 and 3 and contains four BMPs.
    clear_disk();
    clear_capture();
    make_mbr(1);
    make_boot_sector(1, 16'd512);
    put_le32(2, 8, 32'd3);
    put_le32(2, 12, 32'h0FFFFFFF);
    put_byte(3, 0, 8'h41);
    put_byte(3, 11, 8'h0F);
    put_byte(3, 32, 8'hE5);
    put_byte(3, 64, 8'h53);
    put_byte(3, 75, 8'h10);
    make_bmp_entry(3, 3, "IMAGE001BMP", 32'd10, 32'd1000);
    make_bmp_entry(3, 4, "IMAGE002BMP", 32'd11, 32'd2000);
    fill_deleted_entries(3, 5);
    put_byte(4, 0, 8'h56);
    put_byte(4, 11, 8'h08);
    put_byte(4, 32, 8'h42);
    put_byte(4, 43, 8'h0F);
    make_bmp_entry(4, 2, "IMAGE003BMP", 32'd12, 32'd3000);
    make_bmp_entry(4, 3, "IMAGE004BMP", 32'd13, 32'd4000);
    make_bmp_entry(4, 4, "BGM     WAV", 32'd30, 32'd606);
    put_byte(4, 160, 8'h00);

    start_scan();
    wait_for_done();
    expect_bit(error, 1'b0, "MBR root scan has no error");
    expect_value(file_count, 3'd4, "four BMP files discovered");
    expect_value(capture_count, 4, "four discovery pulses emitted");
    expect_name(captured_name[0], "IMAGE001BMP", "first BMP name");
    expect_value(captured_cluster[0], 32'd10, "first BMP cluster");
    expect_value(captured_size[0], 32'd1000, "first BMP size");
    expect_name(captured_name[3], "IMAGE004BMP", "fourth BMP name");
    expect_value(captured_cluster[3], 32'd13, "fourth BMP cluster");
    expect_bit(bgm_found, 1'b1, "BGM after four BMP entries is discovered");
    expect_value(bgm_first_cluster, 32'd30, "BGM first cluster");
    expect_value(bgm_size, 32'd606, "BGM size");
    expect_value(volume_first_fat_lba, 32'd2, "MBR volume FAT LBA");
    expect_value(volume_first_data_lba, 32'd3, "MBR volume data LBA");
    expect_value({24'd0, volume_sectors_per_cluster}, 32'd1,
                 "MBR volume sectors per cluster");
    expect_value(request_count, 5, "cross-cluster scan request count");
    expect_value(request_log[0], 32'd0, "MBR sector requested first");
    expect_value(request_log[1], 32'd1, "boot sector requested second");
    expect_value(request_log[2], 32'd3, "first root cluster requested");
    expect_value(request_log[3], 32'd2, "FAT sector requested for root chain");
    expect_value(request_log[4], 32'd4, "second root cluster requested");
    expect_value(boot_bpb_check_cycles, 32'd1,
                 "boot BPB validation uses one idle cycle");
    expect_value(directory_prepare_cycles, 32'd3,
                 "root address preparation uses three idle cycles");
    expect_value(directory_next_prepare_cycles, 32'd2,
                 "successor directory preparation uses two idle cycles");

    // A superfloppy FAT32 boot sector with an empty root completes without error.
    clear_disk();
    clear_capture();
    make_boot_sector(0, 16'd512);
    put_le32(1, 8, 32'h0FFFFFFF);
    put_byte(2, 0, 8'h00);

    start_scan();
    wait_for_done();
    expect_bit(error, 1'b0, "empty superfloppy root has no error");
    expect_value(file_count, 3'd0, "empty root reports zero files");
    expect_value(capture_count, 0, "empty root emits no discovery pulse");
    expect_value(volume_first_fat_lba, 32'd1, "superfloppy FAT LBA");
    expect_value(volume_first_data_lba, 32'd2, "superfloppy data LBA");
    expect_value(boot_bpb_check_cycles, 32'd1,
                 "superfloppy boot BPB validation uses one idle cycle");
    expect_value(directory_prepare_cycles, 32'd3,
                 "superfloppy root address preparation uses three idle cycles");
    expect_value(directory_next_prepare_cycles, 32'd0,
                 "single-cluster root skips successor preparation");

    // Unsupported BPB parameters are rejected before any root-directory request.
    clear_disk();
    clear_capture();
    make_mbr(1);
    make_boot_sector(1, 16'd1024);

    start_scan();
    wait_for_done();
    expect_bit(error, 1'b1, "non-512-byte BPB is rejected");
    expect_value(file_count, 3'd0, "invalid BPB reports no files");
    expect_value(request_count, 2, "invalid BPB stops after boot sector");
    expect_value(boot_bpb_check_cycles, 32'd1,
                 "invalid BPB uses one idle validation cycle");
    expect_value(directory_prepare_cycles, 32'd0,
                 "invalid BPB skips address preparation");
    expect_value(directory_next_prepare_cycles, 32'd0,
                 "invalid BPB skips successor preparation");

    // A root-directory loop stops at the configured traversal bound.
    clear_disk();
    clear_capture();
    make_mbr(1);
    make_boot_sector(1, 16'd512);
    put_le32(2, 8, 32'd2);
    fill_deleted_entries(3, 0);

    start_scan();
    wait_for_done();
    expect_bit(error, 1'b1, "root-directory loop is rejected");
    expect_value(file_count, 3'd0, "damaged root reports no files");
    expect_value(boot_bpb_check_cycles, 32'd1,
                 "cyclic root boot BPB validation uses one idle cycle");
    expect_value(directory_prepare_cycles, 32'd3,
                "cyclic root still uses three preparation cycles");
    expect_value(directory_next_prepare_cycles, 32'd2,
                 "cyclic root uses successor preparation before rejection");

    // Root-directory clusters below 2 are rejected before directory access.
    clear_disk();
    clear_capture();
    make_mbr(1);
    make_boot_sector(1, 16'd512);
    put_le32(1, 44, 32'd1);

    start_scan();
    wait_for_done();
    expect_bit(error, 1'b1, "root cluster below 2 is rejected");
    expect_value(request_count, 2, "invalid root cluster stops after boot sector");
    expect_value(boot_bpb_check_cycles, 32'd1,
                 "invalid root cluster uses one idle validation cycle");

    // A damaged boot signature is rejected before directory access.
    clear_disk();
    clear_capture();
    make_mbr(1);
    make_boot_sector(1, 16'd512);
    put_byte(1, 511, 8'h00);

    start_scan();
    wait_for_done();
    expect_bit(error, 1'b1, "invalid boot signature is rejected");
    expect_value(request_count, 2, "invalid signature stops after boot sector");
    expect_value(boot_bpb_check_cycles, 32'd1,
                 "invalid signature uses one idle validation cycle");

    $display("PASS tb_fat32_directory_scan");
    $finish;
end

endmodule
