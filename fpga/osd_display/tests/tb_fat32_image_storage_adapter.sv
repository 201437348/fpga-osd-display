`timescale 1ns/1ps

module tb_fat32_image_storage_adapter;

reg clk = 1'b0;
reg rst = 1'b1;
reg scan_start = 1'b0;
reg load_start = 1'b0;
reg load_abort = 1'b0;
reg storage_reinit = 1'b0;
reg [1:0] target_image_index = 2'd0;
reg write_req_ack = 1'b0;
reg write_fifo_afull = 1'b0;
wire storage_ready;
wire scan_done;
wire [2:0] scan_found_count;
wire source_done_pulse;
wire source_error_pulse;
wire write_req;
wire write_en;
wire [31:0] write_data;
wire audio_fifo_wr_en;
wire [31:0] audio_fifo_wr_data;
reg [9:0] audio_fifo_wrusedw = 10'd0;
reg audio_fifo_full = 1'b0;
wire audio_fifo_rst;
wire SD_nCS;
wire SD_DCLK;
wire SD_MOSI;
reg SD_MISO = 1'b1;

integer pixel_count = 0;
reg [31:0] captured_pixel [0:3];
integer audio_frame_count = 0;
reg [31:0] captured_audio_frame [0:3];

always #5 clk = ~clk;

image_storage_adapter dut (
    .clk(clk),
    .rst(rst),
    .scan_start(scan_start),
    .load_start(load_start),
    .load_abort(load_abort),
    .storage_reinit(storage_reinit),
    .target_image_index(target_image_index),
    .storage_ready(storage_ready),
    .scan_done(scan_done),
    .scan_found_count(scan_found_count),
    .source_done_pulse(source_done_pulse),
    .source_error_pulse(source_error_pulse),
    .storage_fault_pulse(),
    .state_code(),
    .write_req(write_req),
    .write_req_ack(write_req_ack),
    .write_fifo_afull(write_fifo_afull),
    .write_en(write_en),
    .write_data(write_data),
    .audio_fifo_wr_en(audio_fifo_wr_en),
    .audio_fifo_wr_data(audio_fifo_wr_data),
    .audio_fifo_wrusedw(audio_fifo_wrusedw),
    .audio_fifo_full(audio_fifo_full),
    .audio_fifo_rst(audio_fifo_rst),
    .SD_nCS(SD_nCS),
    .SD_DCLK(SD_DCLK),
    .SD_MOSI(SD_MOSI),
    .SD_MISO(SD_MISO)
);

always @(posedge clk) begin
    if (write_en) begin
        captured_pixel[pixel_count] = write_data;
        pixel_count = pixel_count + 1;
    end
end

always @(posedge audio_fifo_wr_en) begin
    captured_audio_frame[audio_frame_count] = audio_fifo_wr_data;
    audio_frame_count = audio_frame_count + 1;
end

always @(posedge source_error_pulse)
    $fatal(1, "FAIL real FAT32 path reported an unexpected source error");

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
        dut.u_sd_card_top.disk[(sector * 512) + offset] = value;
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
            dut.u_sd_card_top.disk[index] = 8'd0;
    end
endtask

task automatic make_boot_sector;
    begin
        put_le16(1, 11, 16'd512);
        put_byte(1, 13, 8'd1);
        put_le16(1, 14, 16'd1);
        put_byte(1, 16, 8'd1);
        put_le16(1, 17, 16'd0);
        put_le16(1, 22, 16'd0);
        put_le32(1, 36, 32'd1);
        put_le32(1, 44, 32'd2);
        put_byte(1, 510, 8'h55);
        put_byte(1, 511, 8'hAA);
    end
endtask

task automatic make_root_bmp;
    begin
        put_byte(3, 0, 8'h49);
        put_byte(3, 1, 8'h4D);
        put_byte(3, 2, 8'h41);
        put_byte(3, 3, 8'h47);
        put_byte(3, 4, 8'h45);
        put_byte(3, 5, 8'h30);
        put_byte(3, 6, 8'h30);
        put_byte(3, 7, 8'h31);
        put_byte(3, 8, 8'h42);
        put_byte(3, 9, 8'h4D);
        put_byte(3, 10, 8'h50);
        put_byte(3, 11, 8'h20);
        put_le16(3, 20, 16'd0);
        put_le16(3, 26, 16'd5);
        put_le32(3, 28, 32'd600);
        put_byte(3, 32, 8'h42);
        put_byte(3, 33, 8'h47);
        put_byte(3, 34, 8'h4D);
        put_byte(3, 35, 8'h20);
        put_byte(3, 36, 8'h20);
        put_byte(3, 37, 8'h20);
        put_byte(3, 38, 8'h20);
        put_byte(3, 39, 8'h20);
        put_byte(3, 40, 8'h57);
        put_byte(3, 41, 8'h41);
        put_byte(3, 42, 8'h56);
        put_byte(3, 43, 8'h20);
        put_le16(3, 52, 16'd0);
        put_le16(3, 58, 16'd7);
        put_le32(3, 60, 32'd52);
        put_byte(3, 64, 8'h00);
    end
endtask

task automatic make_wav;
    begin
        put_byte(8, 0, 8'h52);
        put_byte(8, 1, 8'h49);
        put_byte(8, 2, 8'h46);
        put_byte(8, 3, 8'h46);
        put_le32(8, 4, 32'd44);
        put_byte(8, 8, 8'h57);
        put_byte(8, 9, 8'h41);
        put_byte(8, 10, 8'h56);
        put_byte(8, 11, 8'h45);
        put_byte(8, 12, 8'h66);
        put_byte(8, 13, 8'h6D);
        put_byte(8, 14, 8'h74);
        put_byte(8, 15, 8'h20);
        put_le32(8, 16, 32'd16);
        put_le16(8, 20, 16'd1);
        put_le16(8, 22, 16'd2);
        put_le32(8, 24, 32'd48000);
        put_le32(8, 28, 32'd192000);
        put_le16(8, 32, 16'd4);
        put_le16(8, 34, 16'd16);
        put_byte(8, 36, 8'h64);
        put_byte(8, 37, 8'h61);
        put_byte(8, 38, 8'h74);
        put_byte(8, 39, 8'h61);
        put_le32(8, 40, 32'd8);
        put_byte(8, 44, 8'h01);
        put_byte(8, 45, 8'h02);
        put_byte(8, 46, 8'h03);
        put_byte(8, 47, 8'h04);
        put_byte(8, 48, 8'h11);
        put_byte(8, 49, 8'h12);
        put_byte(8, 50, 8'h13);
        put_byte(8, 51, 8'h14);
    end
endtask

task automatic make_bmp_header;
    begin
        put_byte(6, 0, 8'h42);
        put_byte(6, 1, 8'h4D);
        put_le32(6, 2, 32'd60);
        put_le32(6, 10, 32'd54);
        put_le32(6, 18, 32'd640);
        put_le32(6, 22, 32'd480);
        put_le16(6, 28, 16'd24);
        put_le32(6, 30, 32'd0);
        put_byte(6, 54, 8'h01);
        put_byte(6, 55, 8'h02);
        put_byte(6, 56, 8'h03);
        put_byte(6, 57, 8'h04);
        put_byte(6, 58, 8'h05);
        put_byte(6, 59, 8'h06);
    end
endtask

initial begin
    clear_disk();
    put_byte(0, 450, 8'h0C);
    put_le32(0, 454, 32'd1);
    put_byte(0, 510, 8'h55);
    put_byte(0, 511, 8'hAA);
    make_boot_sector();
    make_root_bmp();
    put_le32(2, 20, 32'd19);
    make_bmp_header();
    make_wav();

    repeat (2) @(posedge clk);
    rst = 1'b0;
    dut.u_sd_card_top.sd_init_done = 1'b1;
    $display("TEST real directory scan through adapter");
    @(negedge clk);
    scan_start = 1'b1;
    @(negedge clk);
    scan_start = 1'b0;
    @(posedge scan_done);
    #1;
    expect_bit(storage_ready, 1'b1, "adapter reports initialized storage");
    expect_value(scan_found_count, 3'd1, "real directory scan finds one BMP");
    expect_value(dut.image_cluster0, 32'd5, "real directory metadata has first cluster");
    expect_value(dut.image_size0, 32'd600, "real directory metadata has file size");
    expect_value(dut.volume_first_fat_lba, 32'd2, "real directory metadata has FAT LBA");
    expect_value(dut.volume_first_data_lba, 32'd3, "real directory metadata has data LBA");

    $display("TEST BGM starts through adapter");
    while (audio_frame_count < 2)
        @(posedge clk);
    #1;
    expect_value(captured_audio_frame[0], 32'h02010403,
                 "first adapter PCM frame");
    expect_value(captured_audio_frame[1], 32'h12111413,
                 "second adapter PCM frame");
    @(negedge clk);
    audio_fifo_wrusedw = 10'd768;

    fork
        begin
            @(posedge write_req);
            @(negedge clk);
            write_req_ack = 1'b1;
            repeat (3) @(negedge clk);
            write_req_ack = 1'b0;
        end
    join_none

    $display("TEST real fragmented BMP load through adapter");
    @(negedge clk);
    load_start = 1'b1;
    @(negedge clk);
    load_start = 1'b0;
    @(posedge source_done_pulse);
    #1;
    expect_bit(source_error_pulse, 1'b0, "real FAT32 load has no source error");
    expect_value(pixel_count, 32'd2, "real loader forwards BMP pixels through adapter");
    expect_value(captured_pixel[0], 32'h03020100, "first adapter pixel word");
    expect_value(captured_pixel[1], 32'h06050400, "second adapter pixel word");
    expect_value(dut.u_sd_card_top.request_count, 32'd8,
                 "scan, BGM, and fragmented load request count");
    expect_value(dut.u_sd_card_top.request_log[0], 32'd0, "MBR requested first");
    expect_value(dut.u_sd_card_top.request_log[1], 32'd1, "boot sector requested second");
    expect_value(dut.u_sd_card_top.request_log[2], 32'd3, "root sector requested third");
    expect_value(dut.u_sd_card_top.request_log[3], 32'd8, "BGM file request");
    expect_value(dut.u_sd_card_top.request_log[4], 32'd6, "header probe request");
    expect_value(dut.u_sd_card_top.request_log[5], 32'd6, "stream rereads first file sector");
    expect_value(dut.u_sd_card_top.request_log[6], 32'd2, "file FAT lookup request");
    expect_value(dut.u_sd_card_top.request_log[7], 32'd20, "fragmented file successor request");

    $display("PASS tb_fat32_image_storage_adapter");
    $finish;
end

initial begin
    #400000;
    $display("adapter=%0d directory=%0d loader=%0d requests=%0d serving=%0b pending=%0b",
             dut.state, dut.u_directory_scan.state, dut.u_fat32_bmp_loader.state,
             dut.u_sd_card_top.request_count, dut.u_sd_card_top.serving,
             dut.u_sd_card_top.end_pending);
    $fatal(1, "FAIL tb_fat32_image_storage_adapter timed out");
end

endmodule

// SD-sector responder used to run the real scanner and loader through the adapter.
module sd_card_top(
    input clk, input rst, output reg SD_nCS, output reg SD_DCLK, output reg SD_MOSI,
    input SD_MISO, output reg sd_init_done, input sd_sec_read,
    input [31:0] sd_sec_read_addr, output reg [7:0] sd_sec_read_data,
    output reg sd_sec_read_data_valid, output reg sd_sec_read_end, input sd_sec_write,
    input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output reg sd_sec_write_data_req, output reg sd_sec_write_end
);

reg [7:0] disk [0:32767];
reg serving = 1'b0;
reg end_pending = 1'b0;
reg request_complete = 1'b0;
reg [31:0] active_sector = 32'd0;
reg [8:0] response_byte_index = 9'd0;
integer request_count = 0;
reg [31:0] request_log [0:31];

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

endmodule
