`timescale 1ns/1ps
// Behavioral SDRAM read-side stand-in, single mem_clk domain.
//
// Stage 1: fixed access latency pipe (models CAS-like latency; commands are
//          accepted unconditionally every cycle, matching the fact that
//          frame_slide_fifo_read's S_ISSUE state drives App_rd_en with no
//          read-side backpressure input at all).
// Stage 2: a small in-order queue that emits one word per cycle as long as
//          GAP_CYCLES==0 (the "ideal" model). When GAP_CYCLES!=0, after every
//          MAX_BURST consecutive emitted words the model inserts GAP_CYCLES
//          idle cycles before resuming emission -- representing a
//          row-activate/precharge style overhead on the *physical* burst
//          stream. Command issuance is not blocked by this queue: the real
//          scheduler naturally stops issuing once a chunk's addresses are
//          all sent (S_ISSUE -> S_WAIT_RETURN) and does not issue the next
//          chunk until it sees the last return of the current one, so the
//          queue never needs to backpressure the command side for the
//          traffic patterns used in this steady-state (no-slide) testbench.
module sdram_model #(
    parameter ADDR_BITS      = 21,
    parameter MAX_BURST      = 128,
    parameter FIXED_LATENCY  = 4,
    parameter GAP_CYCLES     = 0
) (
    input                       mem_clk,
    input                       rst,
    input                       App_rd_en,
    input      [ADDR_BITS-1:0]  App_rd_addr,
    output                      Sdr_rd_en,
    output     [31:0]           Sdr_rd_dout
);
    // ---- stage 1: fixed latency shift pipe ----
    reg [FIXED_LATENCY-1:0]        en_pipe;
    reg [ADDR_BITS-1:0]            addr_pipe [0:FIXED_LATENCY-1];
    integer i;

    always @(posedge mem_clk or posedge rst) begin
        if (rst)
            en_pipe <= {FIXED_LATENCY{1'b0}};
        else
            en_pipe <= {en_pipe[FIXED_LATENCY-2:0], App_rd_en};
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
