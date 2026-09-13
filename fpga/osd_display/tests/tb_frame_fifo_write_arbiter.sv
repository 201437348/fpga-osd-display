`timescale 1ns/1ps

module tb_frame_fifo_write_arbiter;

localparam integer S_CHECK_FIFO = 2;

reg mem_clk = 1'b0;
reg rst = 1'b1;
reg Sdr_init_done = 1'b1;
reg Sdr_init_ref_vld = 1'b0;
reg Sdr_busy = 1'b0;
reg App_rd_busy = 1'b0;
reg write_req = 1'b0;
reg [7:0] write_len = 8'd8;
reg [1:0] write_addr_index = 2'd0;
reg [9:0] rdusedw = 10'd0;

wire O_wr_busy;
wire App_wr_en;
wire [7:0] App_wr_addr;
wire write_req_ack;
wire write_finish;
wire fifo_aclr;

always #4 mem_clk = ~mem_clk;

frame_fifo_write #(
    .ADDR_BITS     (8),
    .BURST_BITS    (3),
    .BURST_SIZE    (4),
    .WRITE_V_FLIP  (0),
    .FRAME_WIDTH   (8),
    .FRAME_HEIGHT  (1)
) dut (
    .rst              (rst),
    .mem_clk          (mem_clk),
    .Sdr_init_done    (Sdr_init_done),
    .Sdr_init_ref_vld (Sdr_init_ref_vld),
    .Sdr_busy         (Sdr_busy),
    .App_rd_busy      (App_rd_busy),
    .O_wr_busy        (O_wr_busy),
    .App_wr_en        (App_wr_en),
    .App_wr_addr      (App_wr_addr),
    .write_req        (write_req),
    .write_req_ack    (write_req_ack),
    .write_finish     (write_finish),
    .write_addr_0     (8'h20),
    .write_addr_1     (8'h40),
    .write_addr_2     (8'h60),
    .write_addr_3     (8'h80),
    .write_addr_index (write_addr_index),
    .write_len        (write_len),
    .fifo_aclr        (fifo_aclr),
    .rdusedw          (rdusedw)
);

initial begin
    repeat (3) @(negedge mem_clk);
    rst = 1'b0;

    // Complete the existing request/ack handshake and enter FIFO checking.
    @(negedge mem_clk);
    write_req = 1'b1;
    wait (write_req_ack === 1'b1);
    @(negedge mem_clk);
    write_req = 1'b0;
    wait (dut.state == S_CHECK_FIFO);

    if (O_wr_busy !== 1'b0)
        $fatal(1, "FAIL write busy asserted before FIFO data was available");

    // Change the FIFO level between clock edges. The arbitration output must
    // not expose this long FIFO-pointer arithmetic path combinationally.
    #1 rdusedw = 10'd5;
    #1;
    if (O_wr_busy !== 1'b0)
        $fatal(1, "FAIL rdusedw propagated asynchronously to O_wr_busy");

    // The registered decision must warn the read scheduler one full cycle
    // before the write data enable pipeline begins.
    @(posedge mem_clk);
    #1;
    if (O_wr_busy !== 1'b1)
        $fatal(1, "FAIL registered FIFO readiness did not assert O_wr_busy");
    if (App_wr_en !== 1'b0)
        $fatal(1, "FAIL App_wr_en asserted without an arbitration warning cycle");

    @(posedge mem_clk);
    #1;
    if (dut.state == S_CHECK_FIFO)
        $fatal(1, "FAIL writer did not start after the warning cycle");
    if (O_wr_busy !== 1'b1)
        $fatal(1, "FAIL O_wr_busy dropped when the write burst started");

    // A ready second burst must remain blocked while the read side owns the
    // SDRAM interface. The write may start only after App_rd_busy releases.
    App_rd_busy = 1'b1;
    wait (dut.state == S_CHECK_FIFO);
    repeat (2) begin
        @(posedge mem_clk);
        #1;
        if (dut.state != S_CHECK_FIFO)
            $fatal(1, "FAIL writer started while App_rd_busy was asserted");
        if (O_wr_busy !== 1'b0)
            $fatal(1, "FAIL O_wr_busy claimed arbitration during a read");
    end

    @(negedge mem_clk);
    App_rd_busy = 1'b0;
    #1;
    if (O_wr_busy !== 1'b1)
        $fatal(1, "FAIL ready writer did not claim released arbitration");
    @(posedge mem_clk);
    #1;
    if (dut.state == S_CHECK_FIFO)
        $fatal(1, "FAIL writer did not start after App_rd_busy released");

    $display("PASS tb_frame_fifo_write_arbiter");
    $finish;
end

endmodule
