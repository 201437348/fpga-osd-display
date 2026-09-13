`timescale 1ns/1ps

module tb_frame_slide_phase_color_diagnostic;

localparam integer FRAME_WIDTH = 8;
localparam [31:0] OLD_COLOR = 32'hE0202000;
localparam [31:0] NEW_COLOR = 32'h20E04000;

reg mem_clk = 1'b0;
reg rst = 1'b1;
reg read_req = 1'b0;
reg Sdr_rd_en = 1'b0;
reg [31:0] Sdr_rd_dout = 32'h1234AB00;

wire read_req_ack;
wire read_finish;
wire fifo_write_en;
wire [31:0] fifo_write_data;
wire App_rd_en;
wire [9:0] App_rd_addr;
wire read_fault;

reg [9:0] return_queue [0:31];
reg [31:0] observed [0:FRAME_WIDTH-1];
integer queue_head = 0;
integer queue_tail = 0;
integer queue_count = 0;
integer observed_count = 0;
integer i;

always #4 mem_clk = ~mem_clk;

frame_slide_fifo_read #(
    .ADDR_BITS        (10),
    .FRAME_WIDTH      (FRAME_WIDTH),
    .FRAME_HEIGHT     (1),
    .FIFO_DEPTH       (512),
    .FIFO_LEVEL_BITS  (9),
    .MAX_BURST        (4),
    .FEATHER_ENABLE   (0),
    .SLIDE_PHASE_COLOR_DIAGNOSTIC (1)
) dut (
    .mem_clk          (mem_clk),
    .rst              (rst),
    .Sdr_init_done    (1'b1),
    .Sdr_busy         (1'b0),
    .App_wr_busy      (1'b0),
    .Sdr_rd_en        (Sdr_rd_en),
    .Sdr_rd_dout      (Sdr_rd_dout),
    .read_req         (read_req),
    .read_req_ack     (read_req_ack),
    .read_finish      (read_finish),
    .read_addr_0      (10'd0),
    .read_addr_1      (10'd256),
    .read_addr_2      (10'd512),
    .read_addr_3      (10'd768),
    .old_buffer_index (2'd0),
    .new_buffer_index (2'd1),
    .slide_active     (1'b1),
    .slide_position   (10'd3),
    .fifo_aclr        (),
    .wrusedw          (9'd0),
    .fifo_write_en    (fifo_write_en),
    .fifo_write_data  (fifo_write_data),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .read_busy        (),
    .read_fault       (read_fault)
);

always @(posedge mem_clk) begin
    if (App_rd_en) begin
        return_queue[queue_tail] = App_rd_addr;
        queue_tail = (queue_tail + 1) & 31;
        queue_count = queue_count + 1;
    end
end

always @(negedge mem_clk) begin
    Sdr_rd_en = 1'b0;
    if (queue_count != 0) begin
        Sdr_rd_en = 1'b1;
        Sdr_rd_dout = {return_queue[queue_head], 14'h2A5, 8'h00};
        queue_head = (queue_head + 1) & 31;
        queue_count = queue_count - 1;
    end
end

always @(posedge mem_clk) begin
    #1;
    if (fifo_write_en) begin
        if (observed_count >= FRAME_WIDTH)
            $fatal(1, "FAIL extra output word %h", fifo_write_data);
        observed[observed_count] = fifo_write_data;
        observed_count = observed_count + 1;
    end
end

initial begin
    repeat (4) @(negedge mem_clk);
    rst = 1'b0;
    repeat (3) @(negedge mem_clk);

    read_req = 1'b1;
    wait (read_req_ack === 1'b1);
    @(negedge mem_clk);
    read_req = 1'b0;

    wait (read_finish === 1'b1);
    repeat (4) @(negedge mem_clk);

    if (observed_count != FRAME_WIDTH)
        $fatal(1, "FAIL expected %0d pixels got %0d",
               FRAME_WIDTH, observed_count);
    for (i = 0; i < FRAME_WIDTH; i = i + 1) begin
        if (observed[i] !== ((i < 5) ? OLD_COLOR : NEW_COLOR))
            $fatal(1, "FAIL x=%0d expected %h got %h", i,
                   (i < 5) ? OLD_COLOR : NEW_COLOR, observed[i]);
    end
    if (read_fault !== 1'b0)
        $fatal(1, "FAIL read_fault asserted");

    $display("PASS tb_frame_slide_phase_color_diagnostic");
    $finish;
end

initial begin
    #100000;
    $fatal(1, "FAIL timeout observed=%0d", observed_count);
end

endmodule
