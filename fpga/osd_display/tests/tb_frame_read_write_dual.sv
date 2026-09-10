`timescale 1ns/1ps

module tb_frame_read_write_dual;

reg rst = 1'b1;
reg mem_clk = 1'b0;
reg read_clk = 1'b0;
reg Sdr_init_done = 1'b1;
reg Sdr_init_ref_vld = 1'b0;
reg Sdr_busy = 1'b0;
wire App_rd_en;
wire [9:0] App_rd_addr;
reg Sdr_rd_en = 1'b0;
reg [31:0] Sdr_rd_dout = 32'd0;
reg read_req = 1'b0;
reg dual_read_mode = 1'b0;
reg [1:0] new_buffer_index = 2'd0;
wire read_req_ack;
wire read_finish;
reg read_en = 1'b0;
wire [31:0] read_data;
reg read_en_old = 1'b0;
wire [31:0] read_data_old;
wire App_wr_en;
wire [9:0] App_wr_addr;
wire [31:0] App_wr_din;
wire [3:0] App_wr_dm;
wire write_req_ack;
wire write_finish;
wire write_fifo_afull;
wire [2:0] read_fault_flags;

reg [3:0] return_valid_pipe = 4'd0;
reg [9:0] return_addr_pipe [0:3];
integer i;

always #4 mem_clk = ~mem_clk;
always #20 read_clk = ~read_clk;

function [31:0] memory_word;
    input [9:0] address;
    begin
        if (address >= 10'd100)
            memory_word = 32'hB0000000 + (address - 10'd100);
        else
            memory_word = 32'hA0000000 + (address - 10'd10);
    end
endfunction

frame_read_write #(
    .ADDR_BITS            (10),
    .BURST_BITS           (9),
    .BURST_SIZE           (4),
    .READ_BURST_SIZE      (4),
    .READ_FIFO_DEPTH      (16),
    .READ_FIFO_LEVEL_BITS (4),
    .WRITE_V_FLIP         (0),
    .FRAME_WIDTH          (4),
    .FRAME_HEIGHT         (2)
) dut (
    .rst                 (rst),
    .mem_clk             (mem_clk),
    .Sdr_init_done       (Sdr_init_done),
    .Sdr_init_ref_vld    (Sdr_init_ref_vld),
    .Sdr_busy            (Sdr_busy),
    .App_rd_en           (App_rd_en),
    .App_rd_addr         (App_rd_addr),
    .Sdr_rd_en           (Sdr_rd_en),
    .Sdr_rd_dout         (Sdr_rd_dout),
    .read_clk            (read_clk),
    .read_req            (read_req),
    .read_req_ack        (read_req_ack),
    .read_finish         (read_finish),
    .read_addr_0         (10'd10),
    .read_addr_1         (10'd100),
    .read_addr_2         (10'd200),
    .read_addr_3         (10'd300),
    .read_addr_index     (new_buffer_index),
    .read_addr_index_old (2'd0),
    .dual_read_mode      (dual_read_mode),
    .read_len            (10'd8),
    .read_fault_monitor_enable(1'b1),
    .read_en             (read_en),
    .read_data           (read_data),
    .read_en_old         (read_en_old),
    .read_data_old       (read_data_old),
    .App_wr_en           (App_wr_en),
    .App_wr_addr         (App_wr_addr),
    .App_wr_din          (App_wr_din),
    .App_wr_dm           (App_wr_dm),
    .write_clk           (read_clk),
    .write_req           (1'b0),
    .write_req_ack       (write_req_ack),
    .write_finish        (write_finish),
    .write_addr_0        (10'd10),
    .write_addr_1        (10'd100),
    .write_addr_2        (10'd200),
    .write_addr_3        (10'd300),
    .write_addr_index    (2'd0),
    .write_len           (10'd8),
    .write_en            (1'b0),
    .write_data          (32'd0),
    .write_fifo_afull    (write_fifo_afull),
    .read_fault_flags    (read_fault_flags)
);

always @(negedge mem_clk) begin
    return_valid_pipe[3] <= return_valid_pipe[2];
    return_valid_pipe[2] <= return_valid_pipe[1];
    return_valid_pipe[1] <= return_valid_pipe[0];
    return_valid_pipe[0] <= App_rd_en;
    return_addr_pipe[3] <= return_addr_pipe[2];
    return_addr_pipe[2] <= return_addr_pipe[1];
    return_addr_pipe[1] <= return_addr_pipe[0];
    return_addr_pipe[0] <= App_rd_addr;
    Sdr_rd_en <= return_valid_pipe[3];
    if (return_valid_pipe[3])
        Sdr_rd_dout <= memory_word(return_addr_pipe[3]);
end

task automatic expect_word;
    input [31:0] actual;
    input [31:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %h, got %h", checkpoint, expected, actual);
    end
endtask

initial begin
    for (i = 0; i < 4; i = i + 1)
        return_addr_pipe[i] = 10'd0;

    repeat (4) @(posedge mem_clk);
    rst = 1'b0;

    @(negedge read_clk);
    read_req = 1'b1;
    wait (read_req_ack === 1'b1);
    @(negedge read_clk);
    dual_read_mode = 1'b1;
    new_buffer_index = 2'd1;
    read_req = 1'b0;
    wait (read_finish === 1'b1);

    // Allow the asynchronous write pointers to settle in the read domain.
    repeat (5) @(posedge read_clk);

    @(negedge read_clk);
    read_en = 1'b1;
    read_en_old = 1'b1;
    for (i = 0; i < 8; i = i + 1) begin
        @(posedge read_clk);
        #1;
        expect_word(read_data, 32'hB0000000 + i, "new fifo pixel sequence");
        expect_word(read_data_old, 32'hA0000000 + i, "old fifo pixel sequence");
    end
    @(negedge read_clk);
    read_en = 1'b0;
    read_en_old = 1'b0;

    repeat (4) @(posedge read_clk);
    expect_word({29'd0, read_fault_flags}, 32'd0,
                "normal paired reads do not report fifo faults");

    // Isolate the underflow check from asynchronous pointer-settling skew by
    // resetting both FIFOs to a known-empty state before the invalid request.
    rst = 1'b1;
    repeat (2) @(posedge read_clk);
    rst = 1'b0;
    dual_read_mode = 1'b1;
    @(negedge read_clk);
    read_en = 1'b1;
    read_en_old = 1'b1;
    @(posedge read_clk);
    #1;
    expect_word({29'd0, read_fault_flags}, 32'd3,
                "empty paired fifos report new and old underflow");
    @(negedge read_clk);
    read_en = 1'b0;
    read_en_old = 1'b0;

    $display("PASS tb_frame_read_write_dual");
    $finish;
end

endmodule
