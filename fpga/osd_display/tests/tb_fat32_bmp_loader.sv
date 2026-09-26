`timescale 1ns/1ps

module tb_fat32_bmp_loader;

localparam integer DISK_SECTORS = 160;

reg clk = 1'b0;
reg rst = 1'b1;
reg start = 1'b0;
reg abort = 1'b0;
reg [31:0] file_first_cluster = 32'd0;
reg [31:0] file_size = 32'd0;
reg [31:0] first_fat_lba = 32'd20;
reg [31:0] first_data_lba = 32'd100;
reg [7:0] sectors_per_cluster = 8'd1;
wire busy;
wire done;
wire error;
wire write_req;
reg write_req_ack = 1'b0;
reg write_fifo_afull = 1'b0;
wire bmp_data_wr_en;
wire [23:0] bmp_data;
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
integer pixel_count = 0;
reg [23:0] captured_pixel [0:3];

always #5 clk = ~clk;

fat32_bmp_loader #(.MIN_SRC_PIXELS(1)) dut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .abort(abort),
    .file_first_cluster(file_first_cluster),
    .file_size(file_size),
    .first_fat_lba(first_fat_lba),
    .first_data_lba(first_data_lba),
    .sectors_per_cluster(sectors_per_cluster),
    .src_width(),
    .src_height(), .header_valid(), .dbg_state(),
    .busy(busy),
    .done(done),
    .error(error),
    .write_req(write_req),
    .write_req_ack(write_req_ack),
    .write_fifo_afull(write_fifo_afull),
    .bmp_data_wr_en(bmp_data_wr_en),
    .bmp_data(bmp_data),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end)
);

// The SD-card model emits a complete sector and waits for a low request level.
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
    if (bmp_data_wr_en) begin
        captured_pixel[pixel_count] = bmp_data;
        pixel_count = pixel_count + 1;
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

task automatic clear_observations;
    integer index;
    begin
        request_count = 0;
        pixel_count = 0;
        for (index = 0; index < 32; index = index + 1)
            request_log[index] = 32'd0;
        for (index = 0; index < 4; index = index + 1)
            captured_pixel[index] = 24'd0;
    end
endtask

task automatic make_valid_bmp_header;
    input integer sector;
    begin
        put_byte(sector, 0, 8'h42);
        put_byte(sector, 1, 8'h4D);
        put_le32(sector, 2, 32'd60);
        put_le32(sector, 10, 32'd54);
        put_le32(sector, 14, 32'd40);
        put_le32(sector, 18, 32'd2);
        put_le32(sector, 22, 32'd1);
        put_le16(sector, 26, 16'd1);
        put_le16(sector, 28, 16'd24);
        put_le32(sector, 30, 32'd0);
        put_byte(sector, 54, 8'h01);
        put_byte(sector, 55, 8'h02);
        put_byte(sector, 56, 8'h03);
        put_byte(sector, 57, 8'h04);
        put_byte(sector, 58, 8'h05);
        put_byte(sector, 59, 8'h06);
    end
endtask

task automatic start_loader;
    input [31:0] size;
    begin
        @(negedge clk);
        file_first_cluster = 32'd5;
        file_size = size;
        sectors_per_cluster = 8'd1;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    end
endtask

task automatic acknowledge_write;
    begin
        @(posedge write_req);
        @(negedge clk);
        write_req_ack = 1'b1;
        @(negedge clk);
        write_req_ack = 1'b0;
    end
endtask

task automatic wait_for_request_count;
    input integer expected;
    begin
        while (request_count < expected)
            @(posedge clk);
    end
endtask

task automatic settle_sd;
    begin
        repeat (3) @(posedge clk);
        expect_bit(serving, 1'b0, "SD responder idle");
        expect_bit(end_pending, 1'b0, "SD end pulse cleared");
        expect_bit(request_complete, 1'b0, "SD request released");
    end
endtask

initial begin
    clear_disk();
    clear_observations();
    repeat (2) @(posedge clk);
    rst = 1'b0;

    // Cluster 5 maps to LBA 103. FAT[5] maps to cluster 19 at LBA 117.
    clear_disk();
    clear_observations();
    fill_sector(103, 8'h00);
    fill_sector(117, 8'h99);
    fill_sector(20, 8'hF0);
    make_valid_bmp_header(103);
    put_le32(20, 20, 32'd19);
    start_loader(32'd600);
    acknowledge_write();

    // Assert full after the streaming sector starts. FAT lookup may finish,
    // but the next file-data sector must wait until the FIFO drains.
    wait_for_request_count(2);
    @(negedge clk);
    write_fifo_afull = 1'b1;
    wait_for_request_count(3);
    repeat (10) @(posedge clk);
    expect_value(request_count, 32'd3, "FIFO pause holds next file-data sector");
    @(negedge clk);
    write_fifo_afull = 1'b0;
    @(posedge done);
    #1;
    expect_bit(error, 1'b0, "fragmented BMP completes without error");
    expect_value(pixel_count, 32'd2, "two BMP pixels emitted");
    expect_value(captured_pixel[0], 24'h030201, "first BMP pixel byte order");
    expect_value(captured_pixel[1], 24'h060504, "second BMP pixel byte order");
    expect_value(request_count, 32'd4, "header pass plus fragmented stream requests");
    expect_value(request_log[0], 32'd103, "header probe reads logical sector zero");
    expect_value(request_log[1], 32'd103, "stream deliberately rereads sector zero");
    expect_value(request_log[2], 32'd20, "stream follows FAT internally");
    expect_value(request_log[3], 32'd117, "stream reads fragmented successor");
    settle_sd();

    // Invalid headers do not claim a frame-write buffer and fail cleanly.
    clear_disk();
    clear_observations();
    fill_sector(103, 8'h00);
    start_loader(32'd512);
    @(posedge error);
    #1;
    expect_bit(done, 1'b0, "invalid header has no normal completion");
    expect_bit(write_req, 1'b0, "invalid header does not request frame write");
    expect_value(request_count, 32'd1, "invalid header reads only the probe sector");
    settle_sd();

    // 其余字段合法、只有 planes != 1 的头同样被拒绝
    clear_disk();
    clear_observations();
    fill_sector(103, 8'h00);
    make_valid_bmp_header(103);
    put_le16(103, 26, 16'd0);
    start_loader(32'd512);
    @(posedge error);
    #1;
    expect_bit(write_req, 1'b0, "planes=0 header does not request frame write");
    expect_value(request_count, 32'd1, "planes=0 header reads only the probe sector");
    settle_sd();

    // A premature FAT end-of-chain reaches the loader as an error, not done.
    clear_disk();
    clear_observations();
    fill_sector(103, 8'h00);
    fill_sector(20, 8'hF1);
    make_valid_bmp_header(103);
    put_le32(20, 20, 32'h0FFFFFFF);
    start_loader(32'd600);
    acknowledge_write();
    @(posedge error);
    #1;
    expect_bit(done, 1'b0, "damaged FAT chain has no normal completion");
    expect_value(request_count, 32'd3, "damaged chain stops after FAT lookup");
    settle_sd();

    $display("PASS tb_fat32_bmp_loader");
    $finish;
end

initial begin
    #300000;
    $fatal(1, "FAIL tb_fat32_bmp_loader timed out");
end

endmodule
