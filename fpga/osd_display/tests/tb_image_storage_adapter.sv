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
wire source_error_pulse;
wire [3:0] state_code;
wire write_req;
reg write_req_ack = 1'b0;
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
    .state_code(state_code),
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
    end
endtask

task automatic report_found_file;
    input [31:0] cluster;
    input [31:0] size;
    begin
        dut.u_directory_scan.file_first_cluster = cluster;
        dut.u_directory_scan.file_size = size;
        dut.u_directory_scan.file_found = 1'b1;
        tick();
        dut.u_directory_scan.file_found = 1'b0;
        tick();
    end
endtask

task automatic start_loader;
    input [1:0] index;
    begin
        target_image_index = index;
        repeat (2) tick();          // selected_ok_q 打了一拍，与管理器的时序一致
        load_start = 1'b1;
        tick();
        load_start = 1'b0;
        dut.u_fat32_bmp_loader.busy = 1'b1;
        tick();
    end
endtask

initial begin
    dut.u_sd_card_top.sd_init_done = 1'b0;
    dut.u_directory_scan.busy = 1'b0;
    dut.u_directory_scan.done = 1'b0;
    dut.u_directory_scan.error = 1'b0;
    dut.u_directory_scan.sd_sec_read = 1'b0;
    dut.u_directory_scan.sd_sec_read_addr = 32'd0;
    dut.u_directory_scan.file_found = 1'b0;
    dut.u_directory_scan.file_count = 3'd0;
    dut.u_directory_scan.file_name = 88'd0;
    dut.u_directory_scan.file_first_cluster = 32'd0;
    dut.u_directory_scan.file_size = 32'd0;
    dut.u_directory_scan.volume_first_fat_lba = 32'd0;
    dut.u_directory_scan.volume_first_data_lba = 32'd0;
    dut.u_directory_scan.volume_sectors_per_cluster = 8'd0;
    dut.u_directory_scan.bgm_found = 1'b0;
    dut.u_directory_scan.bgm_first_cluster = 32'd0;
    dut.u_directory_scan.bgm_size = 32'd0;
    dut.u_fat32_bmp_loader.busy = 1'b0;
    dut.u_fat32_bmp_loader.done = 1'b0;
    dut.u_fat32_bmp_loader.error = 1'b0;
    dut.u_fat32_bmp_loader.write_req = 1'b0;
    dut.u_fat32_bmp_loader.bmp_data_wr_en = 1'b0;
    dut.u_fat32_bmp_loader.bmp_data = 24'd0;
    dut.u_fat32_bmp_loader.sd_sec_read = 1'b0;
    dut.u_fat32_bmp_loader.sd_sec_read_addr = 32'd0;

    repeat (2) tick();
    rst = 1'b0;
    tick();
    dut.u_sd_card_top.sd_init_done = 1'b1;
    tick();
    expect_bit(storage_ready, 1'b1, "storage initialized");

    // The ext_mem_clk acknowledgement must settle through two local clk stages.
    @(negedge clk);
    write_req_ack = 1'b1;
    tick();
    expect_bit(dut.write_req_ack_meta, 1'b1, "ack first stage captures raw input");
    expect_bit(dut.write_req_ack_sync, 1'b0, "ack second stage delays rising edge");
    expect_bit(dut.u_fat32_bmp_loader.write_req_ack, 1'b0,
               "loader does not see raw acknowledgement");
    tick();
    expect_bit(dut.write_req_ack_sync, 1'b1, "ack reaches second stage after two clocks");
    expect_bit(dut.u_fat32_bmp_loader.write_req_ack, 1'b1,
               "loader sees synchronized acknowledgement");

    @(negedge clk);
    write_req_ack = 1'b0;
    tick();
    expect_bit(dut.write_req_ack_meta, 1'b0, "ack first stage captures falling edge");
    expect_bit(dut.write_req_ack_sync, 1'b1, "ack second stage retains level for one clock");
    tick();
    expect_bit(dut.write_req_ack_sync, 1'b0, "ack second stage clears after two clocks");

    // Scan ownership prevents the loader from driving the physical SD request.
    pulse_scan_start();
    dut.u_directory_scan.busy = 1'b1;
    dut.u_directory_scan.sd_sec_read = 1'b1;
    dut.u_directory_scan.sd_sec_read_addr = 32'd55;
    tick();
    expect_bit(dut.scan_owner_active, 1'b1, "directory scanner owns SD during scan");
    expect_bit(dut.sd_sec_read, 1'b1, "scanner SD request reaches card core");
    expect_value(dut.sd_sec_read_addr, 32'd55, "scanner SD address selected");

    report_found_file(32'd10, 32'd1000);
    report_found_file(32'd11, 32'd2000);
    dut.u_directory_scan.volume_first_fat_lba = 32'd20;
    dut.u_directory_scan.volume_first_data_lba = 32'd100;
    dut.u_directory_scan.volume_sectors_per_cluster = 8'd2;
    dut.u_directory_scan.done = 1'b1;
    tick();
    dut.u_directory_scan.done = 1'b0;
    tick();
    expect_bit(scan_done, 1'b1, "scan completion is reported after metadata capture");
    expect_value(scan_found_count, 3'd2, "two file records cached");
    expect_value(dut.image_cluster[0], 32'd10, "first file cluster cached");
    expect_value(dut.image_size[1], 32'd2000, "second file size cached");
    expect_value(dut.volume_first_fat_lba, 32'd20, "FAT geometry cached");
    expect_value(dut.volume_first_data_lba, 32'd100, "data geometry cached");

    // Load ownership switches the raw SD port only after scanning is idle.
    dut.u_directory_scan.busy = 1'b0;
    dut.u_directory_scan.sd_sec_read = 1'b0;
    start_loader(2'd1);
    dut.u_fat32_bmp_loader.sd_sec_read = 1'b1;
    dut.u_fat32_bmp_loader.sd_sec_read_addr = 32'd134;
    tick();
    expect_bit(dut.load_owner_active, 1'b1, "loader owns SD during image load");
    expect_bit(dut.sd_sec_read, 1'b1, "loader SD request reaches card core");
    expect_value(dut.sd_sec_read_addr, 32'd134, "loader SD address selected");
    expect_value(dut.selected_file_cluster, 32'd11, "target image selects second metadata record");

    dut.u_fat32_bmp_loader.done = 1'b1;
    tick();
    dut.u_fat32_bmp_loader.done = 1'b0;
    expect_bit(source_done_pulse, 1'b1, "normal loader completion becomes source pulse");
    tick();
    expect_bit(source_done_pulse, 1'b0, "source completion is one pulse");

    // A loader error reaches the manager immediately and never claims completion.
    start_loader(2'd0);
    dut.u_fat32_bmp_loader.error = 1'b1;
    tick();
    dut.u_fat32_bmp_loader.error = 1'b0;
    expect_bit(source_error_pulse, 1'b1, "loader error becomes source error pulse");
    expect_bit(source_done_pulse, 1'b0, "loader error is not source completion");

    // Abort holds until the loader reports idle and does not report an error.
    start_loader(2'd0);
    load_abort = 1'b1;
    tick();
    load_abort = 1'b0;
    expect_bit(dut.loader_abort, 1'b1, "adapter forwards abort to active loader");
    dut.u_fat32_bmp_loader.busy = 1'b0;
    tick();
    expect_bit(source_done_pulse, 1'b0, "abort does not complete source");
    expect_bit(source_error_pulse, 1'b0, "abort does not report source error");

    // Storage reinitialization clears all discovered metadata.
    storage_reinit = 1'b1;
    tick();
    storage_reinit = 1'b0;
    tick();
    expect_bit(scan_done, 1'b0, "storage reinit clears scan completion");
    expect_value(scan_found_count, 3'd0, "storage reinit clears image count");
    expect_value(dut.image_cluster[0], 32'd0, "storage reinit clears file metadata");

    $display("PASS tb_image_storage_adapter");
    $finish;
end

endmodule

// Lightweight vendor stubs for the adapter's project-owned unit test.
module fat32_directory_scan #(
    parameter [2:0] MAX_FILES = 3'd4,
    parameter [15:0] MAX_ROOT_DIR_CLUSTERS = 16'd64
)(
    input clk, input rst, input start, output reg busy, output reg done, output reg error,
    output reg sd_sec_read, output reg [31:0] sd_sec_read_addr,
    input [7:0] sd_sec_read_data, input sd_sec_read_data_valid, input sd_sec_read_end,
    output reg file_found, output reg [2:0] file_count, output reg [87:0] file_name,
    output reg [31:0] file_first_cluster, output reg [31:0] file_size,
    output reg [31:0] volume_first_fat_lba, output reg [31:0] volume_first_data_lba,
    output reg [7:0] volume_sectors_per_cluster, output reg bgm_found,
    output reg [31:0] bgm_first_cluster, output reg [31:0] bgm_size
);
endmodule

module fat32_bmp_loader #(
    parameter [31:0] MIN_SRC_PIXELS = 32'd32000
)(
    input clk, input rst, input start, input abort, input [31:0] file_first_cluster,
    input [31:0] file_size, input [31:0] first_fat_lba, input [31:0] first_data_lba,
    input [7:0] sectors_per_cluster,
    output [15:0] src_width, output [15:0] src_height, output reg header_valid,
    output [3:0] dbg_state,
    output reg busy, output reg done, output reg error, output reg write_req,
    input write_req_ack, input write_fifo_afull, output reg bmp_data_wr_en,
    output reg [23:0] bmp_data, output reg sd_sec_read, output reg [31:0] sd_sec_read_addr,
    input [7:0] sd_sec_read_data, input sd_sec_read_data_valid, input sd_sec_read_end
);
endmodule

module fat32_wav_loader(
    input clk, input rst, input start, input abort, input [31:0] file_first_cluster,
    input [31:0] file_size, input [31:0] first_fat_lba, input [31:0] first_data_lba,
    input [7:0] sectors_per_cluster, input [9:0] fifo_wrusedw, input fifo_full,
    output reg audio_frame_wr_en, output reg [31:0] audio_frame_wr_data,
    output reg busy, output reg error, output reg sd_sec_read,
    output reg [31:0] sd_sec_read_addr, input [7:0] sd_sec_read_data,
    input sd_sec_read_data_valid, input sd_sec_read_end
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

module tb_sd_sector_liveness_watchdog;

reg clk = 1'b0;
reg rst = 1'b1;
reg scan_start = 1'b0;
reg load_start = 1'b0;
reg load_abort = 1'b0;
reg storage_reinit = 1'b0;
reg [1:0] target_image_index = 2'd0;
reg write_req_ack = 1'b0;
reg write_fifo_afull = 1'b0;
reg [9:0] audio_fifo_wrusedw = 10'd0;
reg audio_fifo_full = 1'b0;
reg SD_MISO = 1'b1;
wire storage_fault_pulse;
integer fault_count = 0;

always #5 clk = ~clk;

image_storage_adapter #(
    .SD_CLK_FREQ_HZ(4000),
    .SD_RESPONSE_TIMEOUT_MS(1)
) dut (
    .clk(clk),
    .rst(rst),
    .scan_start(scan_start),
    .load_start(load_start),
    .load_abort(load_abort),
    .storage_reinit(storage_reinit),
    .target_image_index(target_image_index),
    .storage_ready(),
    .scan_done(),
    .scan_found_count(),
    .source_done_pulse(),
    .source_error_pulse(),
    .storage_fault_pulse(storage_fault_pulse),
    .state_code(),
    .write_req(),
    .write_req_ack(write_req_ack),
    .write_fifo_afull(write_fifo_afull),
    .write_en(),
    .write_data(),
    .audio_fifo_wr_en(),
    .audio_fifo_wr_data(),
    .audio_fifo_wrusedw(audio_fifo_wrusedw),
    .audio_fifo_full(audio_fifo_full),
    .audio_fifo_rst(),
    .SD_nCS(),
    .SD_DCLK(),
    .SD_MOSI(),
    .SD_MISO(SD_MISO)
);

always @(posedge storage_fault_pulse)
    fault_count = fault_count + 1;

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

initial begin
    dut.u_sd_card_top.sd_init_done = 1'b0;
    dut.u_sd_card_top.sd_sec_read_data_valid = 1'b0;
    dut.u_sd_card_top.sd_sec_read_end = 1'b0;
    dut.u_directory_scan.sd_sec_read = 1'b0;
    dut.u_directory_scan.sd_sec_read_addr = 32'd0;

    repeat (2) tick();
    rst = 1'b0;
    dut.u_sd_card_top.sd_init_done = 1'b1;
    dut.u_directory_scan.sd_sec_read = 1'b1;
    dut.u_directory_scan.sd_sec_read_addr = 32'd9;

    // Returned bytes continuously prove liveness, even across more than one
    // watchdog interval.
    dut.u_sd_card_top.sd_sec_read_data_valid = 1'b1;
    repeat (8) tick();
    expect_bit(storage_fault_pulse, 1'b0, "normal sector bytes do not fault");
    expect_bit(fault_count == 0, 1'b1, "normal sector bytes emit no fault pulse");

    // With the request still active, removal stops all response progress.
    dut.u_sd_card_top.sd_sec_read_data_valid = 1'b0;
    repeat (4) tick();
    expect_bit(storage_fault_pulse, 1'b1, "hung sector request faults at timeout");
    expect_bit(fault_count == 1, 1'b1, "hung sector request emits one fault pulse");
    repeat (8) tick();
    expect_bit(fault_count == 1, 1'b1, "fault latch prevents repeated pulses");

    $display("PASS tb_sd_sector_liveness_watchdog");
    $finish;
end

initial begin
    #100000;
    $fatal(1, "FAIL tb_sd_sector_liveness_watchdog timed out");
end

endmodule
