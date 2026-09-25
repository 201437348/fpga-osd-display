`timescale 1ns/1ps

// image_storage_adapter 的 abort -> load_start 握手：
// manager 中止预加载 / 超时重试时，load_abort 之后几拍就发下一个 load_start，
// 此时 adapter 还在 ST_LOAD_ABORT 等 loader 收尾。load_start 必须被锁存并在
// 回到 ST_IDLE 后执行，不能丢；loader 刚启动（ST_LOAD_START）时来的 abort 也要转发。
// fat32_bmp_loader / sd_card_top 用下面的桩模块代替。
module tb_adapter_abort_restart;

reg clk = 1'b0;
reg rst = 1'b1;
reg load_start = 1'b0;
reg load_abort = 1'b0;
wire source_done_pulse;
wire source_error_pulse;

always #5 clk = ~clk;

image_storage_adapter #(.SCAN_TARGET_COUNT(4'd6)) dut (
    .clk(clk), .rst(rst),
    .scan_start(1'b0), .load_start(load_start), .load_abort(load_abort),
    .storage_reinit(1'b0), .target_image_index(3'd0),
    .storage_ready(), .scan_done(), .scan_found_count(),
    .source_done_pulse(source_done_pulse), .source_error_pulse(source_error_pulse),
    .storage_fault_pulse(), .state_code(), .scaler_overflow_count(),
    .shown_img_width(), .shown_img_height(), .shown_scale_x100(), .shown_info_pulse(),
    .load_diag_state(), .load_diag_sector(), .load_diag_flags(), .load_progress_pulse(),
    .write_req(), .write_req_ack(1'b0), .write_fifo_afull(1'b0),
    .write_en(), .write_data(),
    .audio_fifo_wr_en(), .audio_fifo_wr_data(), .audio_fifo_wrusedw(10'd0),
    .audio_fifo_full(1'b0), .audio_fifo_rst(),
    .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1)
);

integer done_count = 0;
integer error_count = 0;
always @(posedge clk) begin
    if (source_done_pulse)  done_count  = done_count + 1;
    if (source_error_pulse) error_count = error_count + 1;
end

task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
endtask

task automatic pulse_start;
    begin
        load_start = 1'b1; tick(); load_start = 1'b0;
    end
endtask

task automatic pulse_abort;
    begin
        load_abort = 1'b1; tick(); load_abort = 1'b0;
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

task automatic wait_done;
    input [255:0] checkpoint;
    integer n;
    begin
        n = 0;
        while ((done_count == 0) && (n < 2000)) begin tick(); n = n + 1; end
        if (done_count == 0)
            $fatal(1, "FAIL %0s: no source_done (restart lost)", checkpoint);
    end
endtask

initial begin
    // 让 adapter 认为目录已扫描、目标文件有效
    force dut.selected_ok_q = 1'b1;
    repeat (3) tick();
    rst = 1'b0;
    repeat (3) tick();

    // 1) 读到一半中止，manager 3 拍后重新发 load_start（loader 还要 30 拍才收尾）
    pulse_start();
    repeat (20) tick();
    expect_value(dut.u_fat32_bmp_loader.busy, 1, "1: loader busy");
    pulse_abort();
    repeat (2) tick();
    pulse_start();
    expect_value(dut.u_fat32_bmp_loader.start_count, 1, "1: restart waits for abort");
    wait_done("1: abort then restart");
    expect_value(dut.u_fat32_bmp_loader.start_count, 2, "1: loader restarted");
    expect_value(dut.u_fat32_bmp_loader.abort_seen, 1, "1: loader saw the abort");
    expect_value(error_count, 0, "1: no source error");
    expect_value(dut.load_start_pending, 0, "1: pending consumed");

    // 2) abort 落在 ST_LOAD_START（loader 还没拉 busy）也要转发，然后重启
    done_count = 0;
    repeat (5) tick();
    pulse_start();
    pulse_abort();
    repeat (2) tick();
    pulse_start();
    wait_done("2: early abort then restart");
    expect_value(dut.u_fat32_bmp_loader.start_count, 4, "2: loader restarted");
    expect_value(dut.u_fat32_bmp_loader.abort_seen, 2, "2: early abort forwarded");
    expect_value(done_count, 1, "2: exactly one completion");

    // 3) 只有 abort、没有重启：不能凭空再启动一次
    done_count = 0;
    repeat (5) tick();
    pulse_start();
    repeat (20) tick();
    pulse_abort();
    repeat (300) tick();
    expect_value(dut.u_fat32_bmp_loader.start_count, 5, "3: no spurious restart");
    expect_value(done_count, 0, "3: aborted load never completes");
    expect_value(dut.state, 0, "3: adapter back to idle");

    // 4) 普通加载不受影响
    pulse_start();
    wait_done("4: plain load");
    expect_value(dut.u_fat32_bmp_loader.start_count, 6, "4: one start");

    $display("PASS tb_adapter_abort_restart");
    $finish;
end

endmodule

// loader 桩：start 后一拍 busy；200 拍后 done；abort 后 30 拍才放掉 busy
module fat32_bmp_loader #(
    parameter [15:0] MAX_SRC_WIDTH  = 16'd1920,
    parameter [15:0] MAX_SRC_HEIGHT = 16'd1080,
    parameter [31:0] MIN_SRC_PIXELS = 32'd32000
)(
    input  wire        clk, input wire rst, input wire start, input wire abort,
    input  wire [31:0] file_first_cluster, input wire [31:0] file_size,
    input  wire [31:0] first_fat_lba, input wire [31:0] first_data_lba,
    input  wire [7:0]  sectors_per_cluster,
    output wire [15:0] src_width, output wire [15:0] src_height,
    output reg         header_valid, output reg busy, output reg done, output reg error,
    output wire [3:0]  dbg_state,
    output reg         write_req, input wire write_req_ack, input wire write_fifo_afull,
    output reg         bmp_data_wr_en, output reg [23:0] bmp_data,
    output wire        sd_sec_read, output wire [31:0] sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data, input wire sd_sec_read_data_valid,
    input  wire        sd_sec_read_end
);
assign src_width = 16'd0;
assign src_height = 16'd0;
assign dbg_state = 4'd0;
assign sd_sec_read = 1'b0;
assign sd_sec_read_addr = 32'd0;
integer start_count = 0;
integer abort_seen = 0;
integer cnt = 0;
reg aborting = 1'b0;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        busy <= 1'b0; done <= 1'b0; error <= 1'b0; header_valid <= 1'b0;
        write_req <= 1'b0; bmp_data_wr_en <= 1'b0; bmp_data <= 24'd0;
        aborting <= 1'b0; cnt = 0;
    end else begin
        done <= 1'b0;
        if (!busy) begin
            if (start) begin
                if (abort) $fatal(1, "FAIL loader got start and abort together");
                busy <= 1'b1; aborting <= 1'b0; cnt = 0;
                start_count = start_count + 1;
            end
        end else if (aborting) begin
            cnt = cnt + 1;
            if (cnt >= 30) busy <= 1'b0;
        end else if (abort) begin
            aborting <= 1'b1; cnt = 0;
            abort_seen = abort_seen + 1;
        end else begin
            cnt = cnt + 1;
            if (cnt >= 200) begin busy <= 1'b0; done <= 1'b1; end
        end
    end
end
endmodule

module sd_card_top(
    input clk, input rst, output reg SD_nCS, output reg SD_DCLK, output reg SD_MOSI,
    input SD_MISO, output reg sd_init_done, input sd_sec_read,
    input [31:0] sd_sec_read_addr, output reg [7:0] sd_sec_read_data,
    output reg sd_sec_read_data_valid, output reg sd_sec_read_end, input sd_sec_write,
    input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output reg sd_sec_write_data_req, output reg sd_sec_write_end
);
initial begin
    sd_init_done = 1'b1; sd_sec_read_data = 8'd0;
    sd_sec_read_data_valid = 1'b0; sd_sec_read_end = 1'b0;
    sd_sec_write_data_req = 1'b0; sd_sec_write_end = 1'b0;
end
endmodule
