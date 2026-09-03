`timescale 1ns/1ps

module tb_sd_card_bmp_diag;

reg         clk = 1'b0;
reg         rst = 1'b1;
reg         key_next = 1'b1;
reg         key_auto = 1'b1;
reg         write_finish_toggle = 1'b0;
wire        display_valid;
wire [3:0]  state_code;
wire [7:0]  diag_status;
wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire        write_req;
wire        write_en;
wire [31:0] write_data;
wire        sd_ncs;
wire        sd_dclk;
wire        sd_mosi;

always #5 clk = ~clk;

sd_card_bmp #(
    .CLK_FREQ_HZ       (1_000),
    .LOAD_TIMEOUT_SECONDS(2),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd16),
    .SCAN_TARGET_COUNT (3'd4)
) dut (
    .clk                (clk),
    .rst                (rst),
    .key_next           (key_next),
    .key_auto           (key_auto),
    .bmp_width          (16'd640),
    .bmp_height         (16'd480),
    .display_valid      (display_valid),
    .state_code         (state_code),
    .diag_status        (diag_status),
    .write_finish_toggle(write_finish_toggle),
    .write_buf_idx      (write_buf_idx),
    .disp_buf_idx       (disp_buf_idx),
    .write_req          (write_req),
    .write_req_ack      (1'b0),
    .write_en           (write_en),
    .write_data         (write_data),
    .SD_nCS             (sd_ncs),
    .SD_DCLK            (sd_dclk),
    .SD_MOSI            (sd_mosi),
    .SD_MISO            (1'b0)
);

task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
endtask

task automatic expect_diag(input [7:0] expected, input [255:0] checkpoint);
    begin
        if (diag_status !== expected) begin
            $display("FAIL %0s: expected diag=%02h, got %02h", checkpoint, expected, diag_status);
            $fatal(1);
        end
    end
endtask

task automatic reset_dut;
    begin
        rst = 1'b1;
        write_finish_toggle = 1'b0;
        dut.bmp_read_m0.ready = 1'b1;
        dut.bmp_read_m0.scan_done = 1'b0;
        dut.bmp_read_m0.scan_found_valid = 1'b0;
        dut.bmp_read_m0.scan_found_sector = 32'd0;
        repeat (2) tick();
        rst = 1'b0;
        tick();
        expect_diag(8'h00, "reset");
    end
endtask

task automatic start_first_image;
    integer i;
    begin
        // The first ready cycle starts scanning. Report four valid images.
        tick();
        dut.bmp_read_m0.ready = 1'b0;
        dut.bmp_read_m0.scan_found_valid = 1'b1;
        for (i = 0; i < 4; i = i + 1) begin
            dut.bmp_read_m0.scan_found_sector = i + 1;
            tick();
        end
        dut.bmp_read_m0.scan_found_valid = 1'b0;
        dut.bmp_read_m0.scan_done = 1'b1;
        dut.bmp_read_m0.ready = 1'b1;
        tick();

        // load_busy rises one cycle before bmp_read consumes load_start.
        // This residual ready cycle must not be reported as source complete.
        expect_diag(8'h90, "load-start ready residual");
        tick();
        expect_diag(8'h90, "ready residual ignored");

        dut.bmp_read_m0.ready = 1'b0;
        tick();
        expect_diag(8'h90, "first load started");
    end
endtask

initial begin
    reset_dut();
    if (dut.LOAD_TIMEOUT_CYCLES != 32'd2_000)
        $fatal(1, "FAIL timeout parameter calculation");
    start_first_image();

    // Source completion is valid only after the load was observed active.
    dut.bmp_read_m0.ready = 1'b1;
    tick();
    expect_diag(8'h98, "source complete");

    // A later write-finish toggle crosses the synchronizer and commits the frame.
    write_finish_toggle = 1'b1;
    repeat (4) tick();
    expect_diag(8'h9E, "display committed");
    if (display_valid !== 1'b1)
        $fatal(1, "FAIL display_valid was not asserted");

    // Sticky events survive idle cycles and all clear on user reset.
    dut.bmp_read_m0.ready = 1'b0;
    repeat (3) tick();
    expect_diag(8'h9E, "sticky events");
    reset_dut();

    // A load that only completes at the source must preserve R and latch timeout.
    start_first_image();
    dut.bmp_read_m0.ready = 1'b1;
    tick();
    dut.bmp_read_m0.ready = 1'b0;
    expect_diag(8'h98, "source-only completion");
    force dut.load_timeout_cnt = 32'd1_998;
    tick();
    release dut.load_timeout_cnt;
    expect_diag(8'h98, "cycle before timeout");
    tick();
    expect_diag(8'h98, "timeout threshold reached");
    tick();
    expect_diag(8'h99, "timeout");

    $display("PASS tb_sd_card_bmp_diag");
    $finish;
end

endmodule

module bmp_read (
    input             clk,
    input             rst,
    output reg        ready,
    input             scan_start,
    input      [31:0] scan_start_sector,
    input      [31:0] scan_max_sector,
    input      [2:0]  scan_target_count,
    output reg        scan_done,
    output reg        scan_found_valid,
    output reg [31:0] scan_found_sector,
    output reg [2:0]  scan_found_total,
    input             load_start,
    input             load_abort,
    input      [31:0] load_sector,
    input             sd_init_done,
    output reg [3:0]  state_code,
    input      [15:0] bmp_width,
    input      [15:0] bmp_height,
    output reg        write_req,
    input             write_req_ack,
    output reg        sd_sec_read,
    output reg [31:0] sd_sec_read_addr,
    input      [7:0]  sd_sec_read_data,
    input             sd_sec_read_data_valid,
    input             sd_sec_read_end,
    output reg        bmp_data_wr_en,
    output reg [23:0] bmp_data
);
initial begin
    ready = 1'b1;
    scan_done = 1'b0;
    scan_found_valid = 1'b0;
    scan_found_sector = 32'd0;
    scan_found_total = 3'd0;
    state_code = 4'd1;
    write_req = 1'b0;
    sd_sec_read = 1'b0;
    sd_sec_read_addr = 32'd0;
    bmp_data_wr_en = 1'b0;
    bmp_data = 24'd0;
end
endmodule

module sd_card_top (
    input             clk,
    input             rst,
    output            SD_nCS,
    output            SD_DCLK,
    output            SD_MOSI,
    input             SD_MISO,
    output            sd_init_done,
    input             sd_sec_read,
    input      [31:0] sd_sec_read_addr,
    output     [7:0]  sd_sec_read_data,
    output            sd_sec_read_data_valid,
    output            sd_sec_read_end,
    input             sd_sec_write,
    input      [31:0] sd_sec_write_addr,
    input      [7:0]  sd_sec_write_data,
    output            sd_sec_write_data_req,
    output            sd_sec_write_end
);
assign SD_nCS = 1'b1;
assign SD_DCLK = 1'b0;
assign SD_MOSI = 1'b0;
assign sd_init_done = 1'b1;
assign sd_sec_read_data = 8'd0;
assign sd_sec_read_data_valid = 1'b0;
assign sd_sec_read_end = 1'b0;
assign sd_sec_write_data_req = 1'b0;
assign sd_sec_write_end = 1'b0;
endmodule
