`timescale 1ns/1ps

module tb_fat32_file_sector_reader;

localparam integer DISK_SECTORS = 160;

reg clk = 1'b0;
reg rst = 1'b1;
reg start = 1'b0;
reg abort = 1'b0;
reg [31:0] file_first_cluster = 32'd0;
reg [31:0] file_size = 32'd0;
reg [31:0] first_fat_lba = 32'd0;
reg [31:0] first_data_lba = 32'd0;
reg [7:0] sectors_per_cluster = 8'd0;
wire busy;
wire done;
wire error;
reg file_sec_read = 1'b0;
reg [31:0] file_sec_index = 32'd0;
wire file_sec_read_ack;
wire [7:0] file_sec_data;
wire file_sec_data_valid;
wire file_sec_read_end;
wire file_complete;
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;
reg [7:0] sd_sec_read_data = 8'd0;
reg sd_sec_read_data_valid = 1'b0;
reg sd_sec_read_end = 1'b0;

reg [7:0] disk [0:(DISK_SECTORS * 512)-1];
reg serving = 1'b0;
reg end_pending = 1'b0;
reg request_complete = 1'b0;
reg [31:0] active_sector = 32'd0;
reg [8:0] response_byte_index = 9'd0;
integer request_count = 0;
reg [31:0] request_log [0:31];
integer cluster_offset_prepare_cycles = 0;

reg check_file_data = 1'b0;
reg [7:0] expected_file_data = 8'd0;
integer file_byte_count = 0;

always #5 clk = ~clk;

fat32_file_sector_reader #(
    .MAX_FILE_CLUSTERS(16'd2)
) dut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .abort(abort),
    .file_first_cluster(file_first_cluster),
    .file_size(file_size),
    .first_fat_lba(first_fat_lba),
    .first_data_lba(first_data_lba),
    .sectors_per_cluster(sectors_per_cluster),
    .busy(busy),
    .done(done),
    .error(error),
    .file_sec_read(file_sec_read),
    .file_sec_index(file_sec_index),
    .file_sec_read_ack(file_sec_read_ack),
    .file_sec_data(file_sec_data),
    .file_sec_data_valid(file_sec_data_valid),
    .file_sec_read_end(file_sec_read_end),
    .file_complete(file_complete),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end)
);

// Model the existing SD core: 512 valid bytes followed by one end pulse.
// request_complete requires a low request level before a new request can start.
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
    if (!rst && ((dut.state == 3'd5) || (dut.state == 3'd6))) begin
        if (sd_sec_read)
            $fatal(1, "FAIL cluster preparation started an SD request");
        cluster_offset_prepare_cycles = cluster_offset_prepare_cycles + 1;
    end
end

always @(posedge clk) begin
    if (file_sec_data_valid && check_file_data) begin
        if (file_sec_data !== expected_file_data)
            $fatal(1, "FAIL file byte %0d: expected %h, got %h",
                   file_byte_count, expected_file_data, file_sec_data);
        file_byte_count = file_byte_count + 1;
    end
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

task automatic put_byte;
    input integer sector;
    input integer offset;
    input [7:0] value;
    begin
        disk[(sector * 512) + offset] = value;
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

task automatic fill_sector;
    input integer sector;
    input [7:0] value;
    integer index;
    begin
        for (index = 0; index < 512; index = index + 1)
            put_byte(sector, index, value);
    end
endtask

task automatic clear_disk;
    integer index;
    begin
        for (index = 0; index < (DISK_SECTORS * 512); index = index + 1)
            disk[index] = 8'd0;
    end
endtask

task automatic clear_request_log;
    integer index;
    begin
        request_count = 0;
        cluster_offset_prepare_cycles = 0;
        for (index = 0; index < 32; index = index + 1)
            request_log[index] = 32'd0;
    end
endtask

task automatic settle_sd;
    begin
        repeat (3) @(posedge clk);
        expect_bit(serving, 1'b0, "SD responder is idle");
        expect_bit(end_pending, 1'b0, "no pending SD end pulse");
        expect_bit(request_complete, 1'b0, "SD request level released");
    end
endtask

task automatic start_session;
    input [31:0] first_cluster;
    input [31:0] size;
    input [7:0] cluster_sectors;
    begin
        @(negedge clk);
        file_first_cluster = first_cluster;
        file_size = size;
        first_fat_lba = 32'd20;
        first_data_lba = 32'd100;
        sectors_per_cluster = cluster_sectors;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end
endtask

task automatic request_file_sector;
    input [31:0] index;
    input [7:0] expected_data;
    begin
        check_file_data = 1'b1;
        expected_file_data = expected_data;
        file_byte_count = 0;
        @(negedge clk);
        file_sec_index = index;
        file_sec_read = 1'b1;
        @(posedge file_sec_read_ack);
        @(negedge clk);
        file_sec_read = 1'b0;
        @(posedge file_sec_read_end);
        #1;
        expect_value(file_byte_count, 32'd512, "file sector returns exactly 512 bytes");
        check_file_data = 1'b0;
    end
endtask

task automatic expect_done_error;
    input expected_error;
    input [255:0] checkpoint;
    begin
        @(posedge done);
        #1;
        expect_bit(error, expected_error, checkpoint);
    end
endtask

initial begin
    clear_disk();
    clear_request_log();
    repeat (2) @(posedge clk);
    rst = 1'b0;

    // Fragmented file: cluster 5 has sectors 106/107, then FAT[5] selects 19.
    // The final logical sector is only 12 bytes long in the file, but SD still returns 512.
    clear_disk();
    clear_request_log();
    fill_sector(106, 8'hA6);
    fill_sector(107, 8'hA7);
    fill_sector(134, 8'hC6);
    fill_sector(135, 8'hC7);
    fill_sector(20, 8'hF0);
    put_le32(20, 20, 32'd19);

    start_session(32'd5, (32'd3 * 32'd512) + 32'd12, 8'd2);
    $display("TEST fragmented file");
    request_file_sector(32'd0, 8'hA6);
    request_file_sector(32'd1, 8'hA7);
    request_file_sector(32'd2, 8'hC6);
    request_file_sector(32'd3, 8'hC7);
    expect_bit(done, 1'b1, "fragmented final sector completes cleanly");
    expect_bit(error, 1'b0, "fragmented final sector has no error");
    expect_bit(file_complete, 1'b1, "last file sector raises file_complete");
    expect_value(request_count, 32'd5, "fragmented file physical request count");
    expect_value(request_log[0], 32'd106, "first cluster sector zero");
    expect_value(request_log[1], 32'd107, "first cluster sector one");
    expect_value(request_log[2], 32'd20, "FAT lookup remains internal");
    expect_value(request_log[3], 32'd134, "fragmented successor sector zero");
    expect_value(request_log[4], 32'd135, "fragmented successor sector one");
    expect_value(cluster_offset_prepare_cycles, 32'd4,
                 "initial and successor clusters each prepare twice");
    settle_sd();

    // Start-time geometry errors reject the session without issuing an SD request.
    clear_request_log();
    $display("TEST invalid start");
    start_session(32'd1, 32'd512, 8'd2);
    @(negedge clk);   // start 在读取器内部寄存一拍
    expect_bit(done, 1'b1, "invalid first cluster completes with error");
    expect_bit(error, 1'b1, "invalid first cluster is rejected");
    expect_value(request_count, 32'd0, "invalid start makes no SD request");
    expect_value(cluster_offset_prepare_cycles, 32'd0,
                 "invalid start skips cluster preparation");
    settle_sd();

    // A consumer cannot skip logical sectors; the bad request is terminal.
    clear_request_log();
    $display("TEST nonsequential request");
    start_session(32'd5, 32'd1024, 8'd2);
    @(negedge clk);
    file_sec_index = 32'd1;
    file_sec_read = 1'b1;
    expect_done_error(1'b1, "nonsequential file request is rejected");
    @(negedge clk);
    file_sec_read = 1'b0;
    expect_value(request_count, 32'd0, "nonsequential request makes no SD request");
    expect_value(cluster_offset_prepare_cycles, 32'd2,
                 "valid initial cluster prepares before request rejection");
    settle_sd();

    // FAT EOC before all logical sectors are served is a damaged file chain.
    clear_disk();
    clear_request_log();
    $display("TEST premature end-of-chain");
    fill_sector(106, 8'hD6);
    fill_sector(107, 8'hD7);
    fill_sector(20, 8'hF1);
    put_le32(20, 20, 32'h0FFFFFFF);
    start_session(32'd5, 32'd1536, 8'd2);
    request_file_sector(32'd0, 8'hD6);
    request_file_sector(32'd1, 8'hD7);
    expect_done_error(1'b1, "premature FAT end-of-chain is rejected");
    expect_value(request_count, 32'd3, "premature EOC reads data then FAT only");
    expect_value(cluster_offset_prepare_cycles, 32'd2,
                 "premature EOC has no successor cluster preparation");
    settle_sd();

    // A looping chain is bounded even when it points at a usable cluster number.
    clear_disk();
    clear_request_log();
    $display("TEST bounded cluster loop");
    fill_sector(106, 8'hE6);
    fill_sector(107, 8'hE7);
    fill_sector(20, 8'hF2);
    put_le32(20, 20, 32'd5);
    start_session(32'd5, 32'd2560, 8'd2);
    request_file_sector(32'd0, 8'hE6);
    request_file_sector(32'd1, 8'hE7);
    request_file_sector(32'd2, 8'hE6);
    request_file_sector(32'd3, 8'hE7);
    expect_done_error(1'b1, "cluster-chain traversal bound rejects loop");
    expect_value(request_count, 32'd6, "bounded loop physical request count");
    expect_value(cluster_offset_prepare_cycles, 32'd4,
                 "loop prepares the initial and first successor clusters twice");
    settle_sd();

    $display("PASS tb_fat32_file_sector_reader");
    $finish;
end

initial begin
    #200000;
    $fatal(1, "FAIL tb_fat32_file_sector_reader timed out");
end

endmodule
