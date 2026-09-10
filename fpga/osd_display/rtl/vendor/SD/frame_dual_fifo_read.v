`ifndef FRAME_DUAL_FIFO_READ_V
`define FRAME_DUAL_FIFO_READ_V
`timescale 1ns/1ps

// Frame reader for a normal single stream or a paired old/new frame stream.
// In paired mode complete bursts alternate between the two FIFO destinations.
// SDRAM return latency is not fixed, so route_old_fifo remains stable until
// all words from the selected burst have asserted Sdr_rd_en.
module frame_dual_fifo_read #(
    parameter ADDR_BITS       = 21,
    parameter BURST_SIZE      = 64,
    parameter FIFO_DEPTH      = 1024,
    parameter FIFO_LEVEL_BITS = 10
) (
    input                       mem_clk,
    input                       rst,
    input                       Sdr_init_done,
    input                       App_wr_busy,
    input                       Sdr_rd_en,
    input                       read_req,
    input                       dual_read_mode,
    input [1:0]                 new_buffer_index,
    input [1:0]                 old_buffer_index,
    input [ADDR_BITS-1:0]       read_addr_0,
    input [ADDR_BITS-1:0]       read_addr_1,
    input [ADDR_BITS-1:0]       read_addr_2,
    input [ADDR_BITS-1:0]       read_addr_3,
    input [ADDR_BITS-1:0]       read_len,
    input [FIFO_LEVEL_BITS-1:0] new_wrusedw,
    input [FIFO_LEVEL_BITS-1:0] old_wrusedw,
    output reg                  read_req_ack,
    output                      read_finish,
    output reg                  new_fifo_aclr,
    output reg                  old_fifo_aclr,
    output                      O_rd_busy,
    output                      App_rd_en,
    output [ADDR_BITS-1:0]      App_rd_addr,
    output                      route_old_fifo,
    output reg                  frame_overrun_seen
);

localparam S_IDLE       = 3'd0;
localparam S_ACK        = 3'd1;
localparam S_CHECK_FIFO = 3'd2;
localparam S_READ_BURST = 3'd3;
localparam S_WAIT_RETURN = 3'd4;
localparam S_END        = 3'd5;

reg [2:0] state;

// The read request originates in the pixel clock domain.  Keep its metadata
// on the same three-stage path so the values latched at acknowledgement match
// the request that caused it.
reg       read_req_d0;
reg       read_req_d1;
reg       read_req_d2;
reg       dual_mode_d0;
reg       dual_mode_d1;
reg       dual_mode_d2;
reg [1:0] new_index_d0;
reg [1:0] new_index_d1;
reg [1:0] new_index_d2;
reg [1:0] old_index_d0;
reg [1:0] old_index_d1;
reg [1:0] old_index_d2;
reg [ADDR_BITS-1:0] read_len_d0;
reg [ADDR_BITS-1:0] read_len_d1;
reg [ADDR_BITS-1:0] read_len_d2;

reg                     dual_mode_latched;
reg [1:0]               new_index_latched;
reg [1:0]               old_index_latched;
reg [ADDR_BITS-1:0]     read_len_latched;
reg [ADDR_BITS-1:0]     new_read_count;
reg [ADDR_BITS-1:0]     old_read_count;
reg [ADDR_BITS-1:0]     burst_count;
reg [ADDR_BITS-1:0]     app_rd_addr_r;
reg [ADDR_BITS-1:0]     burst_return_count;
reg                     selected_old;
reg                     next_target_old;

wire new_fifo_room;
wire old_fifo_room;
wire new_remaining;
wire old_remaining;

function [ADDR_BITS-1:0] buffer_base;
    input [1:0] index;
    begin
        case (index)
            2'd0: buffer_base = read_addr_0;
            2'd1: buffer_base = read_addr_1;
            2'd2: buffer_base = read_addr_2;
            default: buffer_base = read_addr_3;
        endcase
    end
endfunction

assign new_fifo_room = (new_wrusedw < (FIFO_DEPTH - BURST_SIZE));
assign old_fifo_room = (old_wrusedw < (FIFO_DEPTH - BURST_SIZE));
assign new_remaining = (new_read_count < read_len_latched);
assign old_remaining = (old_read_count < read_len_latched);

assign App_rd_en = (state == S_READ_BURST);
assign App_rd_addr = app_rd_addr_r;
assign route_old_fifo = selected_old;
assign read_finish = (state == S_END);
assign O_rd_busy = (state == S_READ_BURST) || (state == S_WAIT_RETURN);

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        read_req_d0 <= 1'b0;
        read_req_d1 <= 1'b0;
        read_req_d2 <= 1'b0;
        dual_mode_d0 <= 1'b0;
        dual_mode_d1 <= 1'b0;
        dual_mode_d2 <= 1'b0;
        new_index_d0 <= 2'd0;
        new_index_d1 <= 2'd0;
        new_index_d2 <= 2'd0;
        old_index_d0 <= 2'd0;
        old_index_d1 <= 2'd0;
        old_index_d2 <= 2'd0;
        read_len_d0 <= {ADDR_BITS{1'b0}};
        read_len_d1 <= {ADDR_BITS{1'b0}};
        read_len_d2 <= {ADDR_BITS{1'b0}};
    end else begin
        read_req_d0 <= read_req;
        read_req_d1 <= read_req_d0;
        read_req_d2 <= read_req_d1;
        dual_mode_d0 <= dual_read_mode;
        dual_mode_d1 <= dual_mode_d0;
        dual_mode_d2 <= dual_mode_d1;
        new_index_d0 <= new_buffer_index;
        new_index_d1 <= new_index_d0;
        new_index_d2 <= new_index_d1;
        old_index_d0 <= old_buffer_index;
        old_index_d1 <= old_index_d0;
        old_index_d2 <= old_index_d1;
        read_len_d0 <= read_len;
        read_len_d1 <= read_len_d0;
        read_len_d2 <= read_len_d1;
    end
end

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        state               <= S_IDLE;
        read_req_ack        <= 1'b0;
        new_fifo_aclr       <= 1'b0;
        old_fifo_aclr       <= 1'b0;
        dual_mode_latched   <= 1'b0;
        new_index_latched   <= 2'd0;
        old_index_latched   <= 2'd0;
        read_len_latched    <= {ADDR_BITS{1'b0}};
        new_read_count      <= {ADDR_BITS{1'b0}};
        old_read_count      <= {ADDR_BITS{1'b0}};
        burst_count         <= {ADDR_BITS{1'b0}};
        app_rd_addr_r       <= {ADDR_BITS{1'b0}};
        burst_return_count  <= {ADDR_BITS{1'b0}};
        selected_old        <= 1'b0;
        next_target_old     <= 1'b1;
        frame_overrun_seen  <= 1'b0;
    end else begin
        read_req_ack  <= 1'b0;
        new_fifo_aclr <= 1'b0;
        old_fifo_aclr <= 1'b0;

        if (read_req_d2 &&
            (state != S_IDLE) && (state != S_ACK) && (state != S_END) &&
            (new_remaining || (dual_mode_latched && old_remaining)))
            frame_overrun_seen <= 1'b1;

        case (state)
            S_IDLE: begin
                if (read_req_d2 && Sdr_init_done)
                    state <= S_ACK;
            end

            S_ACK: begin
                // The video controller updates mode and buffer indexes while
                // retiring the acknowledged request.  Capture metadata on
                // every ACK cycle, including the first cycle with read_req_d2
                // low, so mode and indexes form one settled transaction.
                new_fifo_aclr       <= 1'b1;
                old_fifo_aclr       <= dual_mode_d2;
                dual_mode_latched   <= dual_mode_d2;
                new_index_latched   <= new_index_d2;
                old_index_latched   <= old_index_d2;
                read_len_latched    <= read_len_d2;
                new_read_count      <= {ADDR_BITS{1'b0}};
                old_read_count      <= {ADDR_BITS{1'b0}};
                next_target_old     <= 1'b1;
                if (read_req_d2) begin
                    read_req_ack <= 1'b1;
                end else begin
                    state <= S_CHECK_FIFO;
                end
            end

            S_CHECK_FIFO: begin
                if (read_req_d2) begin
                    state <= S_ACK;
                end else if (!dual_mode_latched) begin
                    if (!new_remaining) begin
                        state <= S_END;
                    end else if (new_fifo_room && !App_wr_busy) begin
                        selected_old  <= 1'b0;
                        burst_count   <= {ADDR_BITS{1'b0}};
                        burst_return_count <= {ADDR_BITS{1'b0}};
                        app_rd_addr_r <= buffer_base(new_index_latched) + new_read_count;
                        state         <= S_READ_BURST;
                    end
                end else if (!new_remaining && !old_remaining) begin
                    state <= S_END;
                end else if (!App_wr_busy) begin
                    // Refill the lower eligible watermark first.  Equal
                    // watermarks alternate so both streams remain aligned.
                    if (old_remaining && old_fifo_room &&
                        new_remaining && new_fifo_room &&
                        ((old_wrusedw < new_wrusedw) ||
                         ((old_wrusedw == new_wrusedw) && next_target_old))) begin
                        selected_old  <= 1'b1;
                        burst_count   <= {ADDR_BITS{1'b0}};
                        burst_return_count <= {ADDR_BITS{1'b0}};
                        app_rd_addr_r <= buffer_base(old_index_latched) + old_read_count;
                        state         <= S_READ_BURST;
                    end else if (old_remaining && old_fifo_room &&
                                 (!new_remaining || !new_fifo_room)) begin
                        selected_old  <= 1'b1;
                        burst_count   <= {ADDR_BITS{1'b0}};
                        burst_return_count <= {ADDR_BITS{1'b0}};
                        app_rd_addr_r <= buffer_base(old_index_latched) + old_read_count;
                        state         <= S_READ_BURST;
                    end else if (new_remaining && new_fifo_room) begin
                        selected_old  <= 1'b0;
                        burst_count   <= {ADDR_BITS{1'b0}};
                        burst_return_count <= {ADDR_BITS{1'b0}};
                        app_rd_addr_r <= buffer_base(new_index_latched) + new_read_count;
                        state         <= S_READ_BURST;
                    end else if (old_remaining && old_fifo_room) begin
                        selected_old  <= 1'b1;
                        burst_count   <= {ADDR_BITS{1'b0}};
                        burst_return_count <= {ADDR_BITS{1'b0}};
                        app_rd_addr_r <= buffer_base(old_index_latched) + old_read_count;
                        state         <= S_READ_BURST;
                    end
                end
            end

            S_READ_BURST: begin
                if (Sdr_rd_en)
                    burst_return_count <= burst_return_count + 1'b1;
                if (burst_count == (BURST_SIZE - 1)) begin
                    if (selected_old)
                        old_read_count <= old_read_count + BURST_SIZE;
                    else
                        new_read_count <= new_read_count + BURST_SIZE;
                    if (Sdr_rd_en && (burst_return_count == (BURST_SIZE - 1))) begin
                        next_target_old <= ~selected_old;
                        state <= S_CHECK_FIFO;
                    end else begin
                        state <= S_WAIT_RETURN;
                    end
                end else begin
                    burst_count   <= burst_count + 1'b1;
                    app_rd_addr_r <= app_rd_addr_r + 1'b1;
                end
            end

            S_WAIT_RETURN: begin
                if (Sdr_rd_en) begin
                    burst_return_count <= burst_return_count + 1'b1;
                    if (burst_return_count == (BURST_SIZE - 1)) begin
                        next_target_old <= ~selected_old;
                        state <= S_CHECK_FIFO;
                    end
                end
            end

            S_END: begin
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
`endif
