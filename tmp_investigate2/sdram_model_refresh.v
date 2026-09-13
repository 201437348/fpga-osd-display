`timescale 1ns/1ps
// Behavioral SDRAM read-side stand-in with periodic refresh-stall modeling.
//
// Same fixed-latency + chunk-boundary-gap structure as sdram_model.v, plus:
// every REFRESH_INTERVAL_CYCLES mem_clk cycles, Sdr_busy is asserted for
// REFRESH_STALL_CYCLES cycles. Since neither frame_slide_fifo_read.v nor
// frame_fifo_write.v actually reads/waits on Sdr_busy (confirmed: it's a
// declared-but-unused input port in both), any App_rd_en pulse that lands
// during the stall window is modeled as SILENTLY DROPPED -- not queued,
// never returns -- which is the more pessimistic of the two plausible real
// controller behaviors and therefore the more informative one to test. The
// active frame_slide_fifo_read now gates commands with Sdr_busy; retaining
// drop-on-busy semantics here makes any backpressure regression immediately
// visible instead of allowing the model to hide it by queuing the command.
//
// REFRESH_INTERVAL_CYCLES = 0 disables refresh modeling entirely (falls back
// to the same behavior as sdram_model.v).
module sdram_model_refresh #(
    parameter ADDR_BITS             = 21,
    parameter MAX_BURST             = 128,
    parameter FIXED_LATENCY         = 4,
    parameter GAP_CYCLES            = 0,
    parameter REFRESH_INTERVAL_CYCLES = 0,
    parameter REFRESH_STALL_CYCLES    = 0
) (
    input                       mem_clk,
    input                       rst,
    input                       App_rd_en,
    input      [ADDR_BITS-1:0]  App_rd_addr,
    output                      Sdr_rd_en,
    output     [31:0]           Sdr_rd_dout,
    output                      Sdr_busy
);
    // ---- periodic refresh stall generator ----
    reg [31:0] refresh_counter;
    reg        refresh_stall_active;
    reg [31:0] refresh_stall_remaining;

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            refresh_counter         <= 32'd0;
            refresh_stall_active    <= 1'b0;
            refresh_stall_remaining <= 32'd0;
        end else if (REFRESH_INTERVAL_CYCLES == 0) begin
            refresh_counter      <= 32'd0;
            refresh_stall_active <= 1'b0;
        end else if (refresh_stall_active) begin
            if (refresh_stall_remaining <= 32'd1) begin
                refresh_stall_active <= 1'b0;
            end else begin
                refresh_stall_remaining <= refresh_stall_remaining - 32'd1;
            end
        end else if (refresh_counter >= (REFRESH_INTERVAL_CYCLES - 32'd1)) begin
            refresh_counter         <= 32'd0;
            refresh_stall_active    <= 1'b1;
            refresh_stall_remaining <= REFRESH_STALL_CYCLES;
        end else begin
            refresh_counter <= refresh_counter + 32'd1;
        end
    end

    assign Sdr_busy = refresh_stall_active;

    // ---- stage 1: fixed latency shift pipe (drops commands during stall) ----
    reg [FIXED_LATENCY-1:0]        en_pipe;
    reg [ADDR_BITS-1:0]            addr_pipe [0:FIXED_LATENCY-1];
    integer i;

    wire app_rd_en_gated = App_rd_en && !refresh_stall_active;

    always @(posedge mem_clk or posedge rst) begin
        if (rst)
            en_pipe <= {FIXED_LATENCY{1'b0}};
        else
            en_pipe <= {en_pipe[FIXED_LATENCY-2:0], app_rd_en_gated};
    end

    always @(posedge mem_clk) begin
        addr_pipe[0] <= App_rd_addr;
        for (i = 1; i < FIXED_LATENCY; i = i + 1)
            addr_pipe[i] <= addr_pipe[i-1];
    end

    wire                     stage1_valid = en_pipe[FIXED_LATENCY-1];
    wire [ADDR_BITS-1:0]     stage1_addr  = addr_pipe[FIXED_LATENCY-1];

    // ---- stage 2: bounded queue + chunk-boundary gap ----
    localparam QDEPTH = 512;
    localparam AW     = 9; // 2^9 = 512

    reg [ADDR_BITS-1:0] q [0:QDEPTH-1];
    reg [AW:0]          wp;
    reg [AW:0]          rp;
    reg [15:0]          burst_word_count;
    reg [15:0]          gap_remaining;
    reg                 Sdr_rd_en_r;
    reg [31:0]          Sdr_rd_dout_r;

    wire empty = (wp == rp);

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            wp <= {(AW+1){1'b0}};
        end else if (stage1_valid) begin
            q[wp[AW-1:0]] <= stage1_addr;
            wp <= wp + 1'b1;
        end
    end

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            rp               <= {(AW+1){1'b0}};
            burst_word_count <= 16'd0;
            gap_remaining    <= 16'd0;
            Sdr_rd_en_r      <= 1'b0;
            Sdr_rd_dout_r    <= 32'd0;
        end else begin
            if (gap_remaining != 16'd0) begin
                gap_remaining <= gap_remaining - 16'd1;
                Sdr_rd_en_r   <= 1'b0;
            end else if (!empty) begin
                Sdr_rd_en_r   <= 1'b1;
                Sdr_rd_dout_r <= {q[rp[AW-1:0]][7:0], q[rp[AW-1:0]][7:0],
                                  q[rp[AW-1:0]][7:0], 8'd0};
                rp <= rp + 1'b1;
                if (burst_word_count == (MAX_BURST - 1)) begin
                    burst_word_count <= 16'd0;
                    if (GAP_CYCLES != 0)
                        gap_remaining <= GAP_CYCLES;
                end else begin
                    burst_word_count <= burst_word_count + 16'd1;
                end
            end else begin
                Sdr_rd_en_r <= 1'b0;
            end
        end
    end

    assign Sdr_rd_en   = Sdr_rd_en_r;
    assign Sdr_rd_dout = Sdr_rd_dout_r;
endmodule
