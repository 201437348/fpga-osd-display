`timescale 1ns/1ps

module tb_frame_dual_fifo_read;

reg mem_clk = 1'b0;
reg rst = 1'b1;
reg Sdr_init_done = 1'b0;
reg App_wr_busy = 1'b0;
reg read_req = 1'b0;
reg dual_read_mode = 1'b0;
reg [1:0] new_buffer_index = 2'd1;
reg [1:0] old_buffer_index = 2'd0;
reg [9:0] read_len = 10'd8;
reg [9:0] new_wrusedw = 10'd0;
reg [9:0] old_wrusedw = 10'd0;
reg return_gaps = 1'b1;
wire read_req_ack;
wire read_finish;
wire new_fifo_aclr;
wire old_fifo_aclr;
wire App_rd_en;
wire [9:0] App_rd_addr;
wire route_old_fifo;
wire frame_overrun_seen;
reg Sdr_rd_en = 1'b0;

integer trace_count = 0;
reg [9:0] trace_addr [0:63];
reg trace_old [0:63];

integer pending_returns = 0;
integer return_delay = 0;
reg pending_target_old = 1'b0;
reg returned_target_old = 1'b0;
reg app_rd_en_d = 1'b0;
reg gap_phase = 1'b0;

always #5 mem_clk = ~mem_clk;

frame_dual_fifo_read #(
    .ADDR_BITS      (10),
    .BURST_SIZE     (4),
    .FIFO_DEPTH     (16),
    .FIFO_LEVEL_BITS(10)
) dut (
    .mem_clk              (mem_clk),
    .rst                  (rst),
    .Sdr_init_done        (Sdr_init_done),
    .App_wr_busy          (App_wr_busy),
    .Sdr_rd_en            (Sdr_rd_en),
    .read_req             (read_req),
    .dual_read_mode       (dual_read_mode),
    .new_buffer_index     (new_buffer_index),
    .old_buffer_index     (old_buffer_index),
    .read_addr_0          (10'd10),
    .read_addr_1          (10'd100),
    .read_addr_2          (10'd200),
    .read_addr_3          (10'd300),
    .read_len             (read_len),
    .new_wrusedw          (new_wrusedw),
    .old_wrusedw          (old_wrusedw),
    .read_req_ack         (read_req_ack),
    .read_finish          (read_finish),
    .new_fifo_aclr        (new_fifo_aclr),
    .old_fifo_aclr        (old_fifo_aclr),
    .O_rd_busy            (),
    .App_rd_en            (App_rd_en),
    .App_rd_addr          (App_rd_addr),
    .route_old_fifo       (route_old_fifo),
    .frame_overrun_seen   (frame_overrun_seen)
);

always @(posedge mem_clk) begin
    if (App_rd_en) begin
        trace_addr[trace_count] = App_rd_addr;
        trace_old[trace_count] = route_old_fifo;
        trace_count = trace_count + 1;
    end
end

// Queue a complete command burst, then return its words after a delay.  In
// gap mode every second return cycle is idle, exercising route locking across
// a response stream that is neither fixed-latency nor contiguous.
always @(posedge mem_clk) begin
    if (rst) begin
        Sdr_rd_en = 1'b0;
        pending_returns = 0;
        return_delay = 0;
        pending_target_old = 1'b0;
        returned_target_old = 1'b0;
        app_rd_en_d = 1'b0;
        gap_phase = 1'b0;
    end else begin
        Sdr_rd_en = 1'b0;
        app_rd_en_d = App_rd_en;
        gap_phase = ~gap_phase;

        if (App_rd_en) begin
            pending_returns = pending_returns + 1;
            pending_target_old = route_old_fifo;
        end

        if (app_rd_en_d && !App_rd_en) begin
            return_delay = 6;
        end else if (return_delay > 0) begin
            return_delay = return_delay - 1;
        end else if ((pending_returns > 0) && (!return_gaps || gap_phase)) begin
            Sdr_rd_en = 1'b1;
            returned_target_old = pending_target_old;
            pending_returns = pending_returns - 1;
        end

        if (Sdr_rd_en && (route_old_fifo !== returned_target_old))
            $fatal(1, "FAIL returned word routed to wrong fifo: expected old=%b, got old=%b",
                   returned_target_old, route_old_fifo);
    end
end

task automatic expect_value;
    input [9:0] actual;
    input [9:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

task automatic expect_bit;
    input actual;
    input expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %b, got %b", checkpoint, expected, actual);
    end
endtask

task automatic start_read;
    begin
        @(negedge mem_clk);
        read_req = 1'b1;
        wait (read_req_ack === 1'b1);
        @(negedge mem_clk);
        read_req = 1'b0;
        wait (read_finish === 1'b1);
        @(posedge mem_clk);
        #1;
    end
endtask

task automatic clear_trace;
    begin
        trace_count = 0;
    end
endtask

initial begin
    repeat (2) @(posedge mem_clk);
    Sdr_init_done = 1'b1;
    rst = 1'b0;
    #1;

    // Single mode reads only the new/current buffer.
    dual_read_mode = 1'b0;
    read_len = 10'd8;
    clear_trace;
    start_read;
    expect_value(trace_count, 10'd8, "single mode read count");
    expect_value(trace_addr[0], 10'd100, "single first address");
    expect_value(trace_addr[3], 10'd103, "single first burst end");
    expect_value(trace_addr[4], 10'd104, "single second burst starts");
    expect_bit(trace_old[0], 1'b0, "single routes to new fifo");

    // The video controller updates dual mode and buffer metadata on the same
    // pixel-clock edge that drops read_req after acknowledgement.  The memory
    // domain must capture that final synchronized metadata before reading.
    dual_read_mode = 1'b0;
    read_len = 10'd8;
    new_wrusedw = 10'd0;
    old_wrusedw = 10'd0;
    clear_trace;
    @(negedge mem_clk);
    read_req = 1'b1;
    wait (read_req_ack === 1'b1);
    @(negedge mem_clk);
    dual_read_mode = 1'b1;
    read_req = 1'b0;
    wait (read_finish === 1'b1);
    @(posedge mem_clk);
    #1;
    expect_value(trace_count, 10'd16, "late dual metadata selects paired read");
    expect_bit(trace_old[0], 1'b1, "late metadata fills old fifo first");
    expect_value(trace_addr[0], 10'd10, "late metadata locks old address");
    expect_value(trace_addr[4], 10'd100, "late metadata locks new address");

    // Equal watermarks alternate complete old/new bursts.  Gapped returns
    // must not change the route before all four words arrive.
    dual_read_mode = 1'b1;
    read_len = 10'd8;
    new_wrusedw = 10'd0;
    old_wrusedw = 10'd0;
    clear_trace;
    start_read;
    expect_value(trace_count, 10'd16, "dual mode total read count");
    expect_value(trace_addr[0], 10'd10, "dual old first address");
    expect_value(trace_addr[3], 10'd13, "dual old first burst end");
    expect_value(trace_addr[4], 10'd100, "dual new first address");
    expect_value(trace_addr[7], 10'd103, "dual new first burst end");
    expect_value(trace_addr[8], 10'd14, "dual old second address");
    expect_value(trace_addr[12], 10'd104, "dual new second address");
    expect_bit(trace_old[0], 1'b1, "old burst routes old fifo");
    expect_bit(trace_old[3], 1'b1, "old route stays constant through commands");
    expect_bit(trace_old[4], 1'b0, "new burst routes new fifo");

    // With both FIFOs eligible, service the lower watermark first.
    read_len = 10'd4;
    old_wrusedw = 10'd10;
    new_wrusedw = 10'd0;
    clear_trace;
    start_read;
    expect_bit(trace_old[0], 1'b0, "lower new watermark has priority");
    expect_value(trace_addr[0], 10'd100, "lower new fifo uses new address");

    old_wrusedw = 10'd0;
    new_wrusedw = 10'd10;
    clear_trace;
    start_read;
    expect_bit(trace_old[0], 1'b1, "lower old watermark has priority");
    expect_value(trace_addr[0], 10'd10, "lower old fifo uses old address");

    // A nearly full FIFO blocks its burst until enough space is reported.
    dual_read_mode = 1'b0;
    read_len = 10'd8;
    new_wrusedw = 10'd15;
    clear_trace;
    @(negedge mem_clk);
    read_req = 1'b1;
    wait (read_req_ack === 1'b1);
    @(negedge mem_clk);
    read_req = 1'b0;
    repeat (8) @(posedge mem_clk);
    expect_value(trace_count, 10'd0, "full fifo blocks burst");
    new_wrusedw = 10'd0;
    wait (read_finish === 1'b1);
    @(posedge mem_clk);
    #1;
    expect_value(trace_count, 10'd8, "burst resumes after fifo drains");

    expect_bit(frame_overrun_seen, 1'b0, "completed reads do not report overrun");

    // A new frame request arriving before the current dual-frame command set
    // completes must be retained as board-visible evidence.
    dual_read_mode = 1'b1;
    read_len = 10'd8;
    new_wrusedw = 10'd0;
    old_wrusedw = 10'd0;
    return_gaps = 1'b1;
    @(negedge mem_clk);
    read_req = 1'b1;
    wait (read_req_ack === 1'b1);
    @(negedge mem_clk);
    read_req = 1'b0;
    wait (App_rd_en === 1'b1);
    repeat (2) @(negedge mem_clk);
    read_req = 1'b1;
    repeat (4) @(negedge mem_clk);
    read_req = 1'b0;
    wait (frame_overrun_seen === 1'b1);
    expect_bit(frame_overrun_seen, 1'b1, "incomplete frame request reports overrun");

    $display("PASS tb_frame_dual_fifo_read");
    $finish;
end

endmodule
