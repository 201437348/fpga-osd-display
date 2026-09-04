`timescale 1ns/1ps

module tb_image_storage_adapter;

reg clk = 1'b0;
reg rst = 1'b1;
reg scan_start = 1'b0;
reg load_start = 1'b0;
reg load_abort = 1'b0;
reg storage_reinit = 1'b0;
reg [1:0] target_image_index = 2'd0;
reg write_fifo_afull = 1'b0;
wire storage_ready;
wire scan_done;
wire [2:0] scan_found_count;
wire source_done_pulse;
wire [3:0] state_code;
wire write_req;
reg write_req_ack = 1'b0;
wire write_en;
wire [31:0] write_data;
wire SD_nCS;
wire SD_DCLK;
wire SD_MOSI;
reg SD_MISO = 1'b1;

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
    .state_code(state_code),
    .write_req(write_req),
    .write_req_ack(write_req_ack),
    .write_fifo_afull(write_fifo_afull),
    .write_en(write_en),
    .write_data(write_data),
    .SD_nCS(SD_nCS),
    .SD_DCLK(SD_DCLK),
    .SD_MOSI(SD_MOSI),
    .SD_MISO(SD_MISO)
);

task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
endtask

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

task automatic pulse_scan_start;
    begin
        scan_start = 1'b1;
        tick();
        scan_start = 1'b0;
        tick();
    end
endtask

task automatic report_found_sector;
    input [31:0] sector;
    begin
        dut.u_bmp_read.scan_found_sector = sector;
        dut.u_bmp_read.scan_found_valid = 1'b1;
        tick();
        dut.u_bmp_read.scan_found_valid = 1'b0;
        tick();
    end
endtask

initial begin
    dut.u_sd_card_top.sd_init_done = 1'b0;
    dut.u_bmp_read.ready = 1'b1;
    dut.u_bmp_read.scan_done = 1'b0;
    dut.u_bmp_read.scan_found_valid = 1'b0;
    dut.u_bmp_read.scan_found_sector = 32'd0;
    dut.u_bmp_read.scan_found_total = 3'd0;
    dut.u_bmp_read.state_code = 4'd0;
    dut.u_bmp_read.write_req = 1'b0;
    dut.u_bmp_read.sd_sec_read = 1'b0;
    dut.u_bmp_read.sd_sec_read_addr = 32'd0;
    dut.u_bmp_read.bmp_data_wr_en = 1'b0;
    dut.u_bmp_read.bmp_data = 24'd0;

    repeat (2) tick();
    rst = 1'b0;
    tick();
    dut.u_sd_card_top.sd_init_done = 1'b1;
    tick();
    expect_bit(storage_ready, 1'b1, "storage initialized");

    // The ext_mem_clk acknowledgement must settle through two local clk stages
    // before the SD-clocked BMP reader can consume it.
    @(negedge clk);
    write_req_ack = 1'b1;
    tick();
    expect_bit(dut.write_req_ack_meta, 1'b1, "ack first stage captures raw input");
    expect_bit(dut.write_req_ack_sync, 1'b0, "ack second stage delays rising edge");
    expect_bit(dut.u_bmp_read.write_req_ack, 1'b0, "bmp reader does not see raw ack");
    tick();
    expect_bit(dut.write_req_ack_sync, 1'b1, "ack reaches second stage after two clocks");
    expect_bit(dut.u_bmp_read.write_req_ack, 1'b1, "bmp reader sees synchronized ack");

    @(negedge clk);
    write_req_ack = 1'b0;
    tick();
    expect_bit(dut.write_req_ack_meta, 1'b0, "ack first stage captures falling edge");
    expect_bit(dut.write_req_ack_sync, 1'b1, "ack second stage retains level for one clock");
    tick();
    expect_bit(dut.write_req_ack_sync, 1'b0, "ack second stage clears after two clocks");
    expect_bit(dut.u_bmp_read.write_req_ack, 1'b0, "bmp reader sees cleared synchronized ack");

    // A completed previous scan must not be accepted until the raw done level drops.
    dut.u_bmp_read.scan_done = 1'b1;
    pulse_scan_start();
    expect_bit(scan_done, 1'b0, "stale scan done rejected");
    tick();
    expect_bit(scan_done, 1'b0, "stale scan done remains rejected");
    dut.u_bmp_read.scan_done = 1'b0;
    tick();

    report_found_sector(32'd100);
    report_found_sector(32'd200);
    report_found_sector(32'd300);
    dut.u_bmp_read.scan_found_sector = 32'd400;
    dut.u_bmp_read.scan_found_valid = 1'b1;
    dut.u_bmp_read.scan_done = 1'b1;
    tick();
    expect_bit(scan_done, 1'b0, "completion delayed after final sector");
    dut.u_bmp_read.scan_found_valid = 1'b0;
    tick();
    expect_bit(scan_done, 1'b1, "scan completion visible");
    expect_value(scan_found_count, 3'd4, "all four sectors captured before completion");
    expect_value(dut.image_sector0, 32'd100, "sector zero cache");
    expect_value(dut.image_sector3, 32'd400, "sector three cache");

    // Reinitializing storage clears cached scan state before a new SD init.
    storage_reinit = 1'b1;
    tick();
    storage_reinit = 1'b0;
    tick();
    expect_bit(scan_done, 1'b0, "storage reinit clears scan completion");
    expect_value(scan_found_count, 3'd0, "storage reinit clears image count");
    expect_value(dut.image_sector0, 32'd0, "storage reinit clears sector cache");

    // A new scan cannot reuse the old completion level.
    pulse_scan_start();
    expect_value(scan_found_count, 3'd0, "new scan clears count");
    expect_bit(scan_done, 1'b0, "new scan clears completion");
    tick();
    expect_bit(scan_done, 1'b0, "old completion still rejected after rescan");
    dut.u_bmp_read.scan_done = 1'b0;
    tick();

    // Source completion requires an observed busy-to-ready transition.
    load_start = 1'b1;
    tick();
    load_start = 1'b0;
    tick();
    expect_bit(source_done_pulse, 1'b0, "ready without busy is not completion");
    dut.u_bmp_read.ready = 1'b0;
    tick();
    expect_bit(source_done_pulse, 1'b0, "busy is not completion");
    dut.u_bmp_read.ready = 1'b1;
    tick();
    expect_bit(source_done_pulse, 1'b1, "busy-to-ready produces completion");
    tick();
    expect_bit(source_done_pulse, 1'b0, "source completion is one pulse");

    // Abort suppresses a pending busy-to-ready completion.
    load_start = 1'b1;
    tick();
    load_start = 1'b0;
    dut.u_bmp_read.ready = 1'b0;
    tick();
    load_abort = 1'b1;
    dut.u_bmp_read.ready = 1'b1;
    tick();
    expect_bit(source_done_pulse, 1'b0, "abort clears pending source completion");
    load_abort = 1'b0;
    tick();
    expect_bit(source_done_pulse, 1'b0, "aborted load does not complete later");

    $display("PASS tb_image_storage_adapter");
    $finish;
end

endmodule

// Lightweight vendor stubs for the adapter's project-owned unit test.
module bmp_read(
    input clk, input rst, output reg ready,
    input scan_start, input [31:0] scan_start_sector, input [31:0] scan_max_sector,
    input [2:0] scan_target_count, output reg scan_done, output reg scan_found_valid,
    output reg [31:0] scan_found_sector, output reg [2:0] scan_found_total,
    input load_start, input load_abort, input [31:0] load_sector, input sd_init_done,
    output reg [3:0] state_code, input [15:0] bmp_width, input [15:0] bmp_height,
    output reg write_req, input write_req_ack, output reg sd_sec_read,
    output reg [31:0] sd_sec_read_addr, input [7:0] sd_sec_read_data,
    input sd_sec_read_data_valid, input sd_sec_read_end, input write_fifo_afull,
    output reg bmp_data_wr_en,
    output reg [23:0] bmp_data
);
endmodule

module sd_card_top(
    input clk, input rst, output reg SD_nCS, output reg SD_DCLK, output reg SD_MOSI,
    input SD_MISO, output reg sd_init_done, input sd_sec_read,
    input [31:0] sd_sec_read_addr, output reg [7:0] sd_sec_read_data,
    output reg sd_sec_read_data_valid, output reg sd_sec_read_end, input sd_sec_write,
    input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output reg sd_sec_write_data_req, output reg sd_sec_write_end
);
endmodule
