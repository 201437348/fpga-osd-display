`ifndef FRAME_SLIDE_FIFO_READ_V
`define FRAME_SLIDE_FIFO_READ_V
`timescale 1ns/1ps

// Serializes the visible old/new line segments into one output FIFO. During
// the central feathered region, old overlap pixels are cached and combined
// only when the matching new pixels return from SDRAM.
module frame_slide_fifo_read #(
    parameter ADDR_BITS        = 21,
    parameter FRAME_WIDTH      = 640,
    parameter FRAME_HEIGHT     = 480,
    parameter FIFO_DEPTH       = 512,
    parameter FIFO_LEVEL_BITS  = 9,
    parameter MAX_BURST        = 128,
    parameter FEATHER_WIDTH    = 32
) (
    input  wire                         mem_clk,
    input  wire                         rst,
    input  wire                         Sdr_init_done,
    input  wire                         Sdr_busy,
    input  wire                         App_wr_busy,
    input  wire                         Sdr_rd_en,
    input  wire [31:0]                  Sdr_rd_dout,
    input  wire                         read_req,
    output reg                          read_req_ack,
    output reg                          read_finish,
    input  wire [ADDR_BITS-1:0]         read_addr_0,
    input  wire [ADDR_BITS-1:0]         read_addr_1,
    input  wire [ADDR_BITS-1:0]         read_addr_2,
    input  wire [ADDR_BITS-1:0]         read_addr_3,
    input  wire [1:0]                   old_buffer_index,
    input  wire [1:0]                   new_buffer_index,
    input  wire                         slide_active,
    input  wire [9:0]                   slide_position,
    output reg                          fifo_aclr,
    input  wire [FIFO_LEVEL_BITS-1:0]   wrusedw,
    output reg                          fifo_write_en,
    output reg  [31:0]                  fifo_write_data,
    output wire                         App_rd_en,
    output reg  [ADDR_BITS-1:0]         App_rd_addr,
    output wire                         read_busy,
    output reg                          read_fault
);

localparam [3:0] S_IDLE        = 4'd0;
localparam [3:0] S_ACK         = 4'd1;
localparam [3:0] S_SETUP_ROW   = 4'd2;
localparam [3:0] S_SELECT      = 4'd3;
localparam [3:0] S_ISSUE       = 4'd4;
localparam [3:0] S_WAIT_RETURN = 4'd5;
localparam [3:0] S_END         = 4'd6;

localparam [1:0] P_OLD_DIRECT = 2'd0;
localparam [1:0] P_OLD_CACHE  = 2'd1;
localparam [1:0] P_NEW_BLEND  = 2'd2;
localparam [1:0] P_NEW_DIRECT = 2'd3;

localparam integer FEATHER_HALF = FEATHER_WIDTH / 2;
localparam integer FIFO_START_LEVEL = FIFO_DEPTH - MAX_BURST;
localparam integer FRAME_PIXEL_COUNT = FRAME_WIDTH * FRAME_HEIGHT;

reg [3:0] state;
reg [1:0] phase;

reg read_req_d0;
reg read_req_d1;
reg read_req_d2;
reg [1:0] old_index_d0;
reg [1:0] old_index_d1;
reg [1:0] old_index_d2;
reg [1:0] new_index_d0;
reg [1:0] new_index_d1;
reg [1:0] new_index_d2;
reg slide_active_d0;
reg slide_active_d1;
reg slide_active_d2;
reg [9:0] slide_position_d0;
reg [9:0] slide_position_d1;
reg [9:0] slide_position_d2;

reg [ADDR_BITS-1:0] old_base_latched;
reg [ADDR_BITS-1:0] new_base_latched;
reg [9:0] position_latched;
reg feather_enabled_latched;

reg [15:0] row_index;
reg [ADDR_BITS-1:0] row_offset;
reg [15:0] segment_remaining;
reg [ADDR_BITS-1:0] segment_addr;
reg [15:0] phase_offset;
reg [15:0] chunk_phase_offset;
reg [15:0] chunk_length;
reg [15:0] issue_count;
reg [15:0] return_count;
reg [ADDR_BITS:0] output_count;

reg [23:0] overlap_cache [0:FEATHER_WIDTH-1];

wire phase_writes_fifo;
wire fifo_has_chunk_room;
wire can_start_chunk;
wire [4:0] response_overlap_index;

assign phase_writes_fifo = (phase != P_OLD_CACHE);
assign fifo_has_chunk_room = (wrusedw < FIFO_START_LEVEL);
assign can_start_chunk = (segment_remaining != 16'd0) &&
                         (!phase_writes_fifo || fifo_has_chunk_room) &&
                         !App_wr_busy;
assign response_overlap_index = chunk_phase_offset[4:0] + return_count[4:0];
assign App_rd_en = (state == S_ISSUE);

// Match the existing write-priority arbitration: the write scheduler
// pre-asserts App_wr_busy before a burst, while read_busy covers issued read
// commands and every outstanding return from that chunk.
assign read_busy = (state == S_ISSUE) || (state == S_WAIT_RETURN);

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

function [6:0] feather_alpha;
    input [15:0] index;
    begin
        if (FEATHER_WIDTH == 4) begin
            case (index[1:0])
                2'd0: feather_alpha = 7'd0;
                2'd1: feather_alpha = 7'd21;
                2'd2: feather_alpha = 7'd43;
                default: feather_alpha = 7'd64;
            endcase
        end else if (FEATHER_WIDTH == 32) begin
            case (index[4:0])
                5'd0:  feather_alpha = 7'd0;
                5'd1:  feather_alpha = 7'd2;
                5'd2:  feather_alpha = 7'd4;
                5'd3:  feather_alpha = 7'd6;
                5'd4:  feather_alpha = 7'd8;
                5'd5:  feather_alpha = 7'd10;
                5'd6:  feather_alpha = 7'd12;
                5'd7:  feather_alpha = 7'd14;
                5'd8:  feather_alpha = 7'd17;
                5'd9:  feather_alpha = 7'd19;
                5'd10: feather_alpha = 7'd21;
                5'd11: feather_alpha = 7'd23;
                5'd12: feather_alpha = 7'd25;
                5'd13: feather_alpha = 7'd27;
                5'd14: feather_alpha = 7'd29;
                5'd15: feather_alpha = 7'd31;
                5'd16: feather_alpha = 7'd33;
                5'd17: feather_alpha = 7'd35;
                5'd18: feather_alpha = 7'd37;
                5'd19: feather_alpha = 7'd39;
                5'd20: feather_alpha = 7'd41;
                5'd21: feather_alpha = 7'd43;
                5'd22: feather_alpha = 7'd45;
                5'd23: feather_alpha = 7'd47;
                5'd24: feather_alpha = 7'd50;
                5'd25: feather_alpha = 7'd52;
                5'd26: feather_alpha = 7'd54;
                5'd27: feather_alpha = 7'd56;
                5'd28: feather_alpha = 7'd58;
                5'd29: feather_alpha = 7'd60;
                5'd30: feather_alpha = 7'd62;
                default: feather_alpha = 7'd64;
            endcase
        end else begin
            feather_alpha = 7'd64;
        end
    end
endfunction

function [7:0] blend_channel;
    input [7:0] source;
    input [7:0] target;
    input [6:0] alpha;
    reg [7:0] difference;
    reg [14:0] scaled;
    begin
        if (target >= source) begin
            difference = target - source;
            scaled = difference * alpha;
            blend_channel = source + (scaled >> 6);
        end else begin
            difference = source - target;
            scaled = difference * alpha;
            blend_channel = source - (scaled >> 6);
        end
    end
endfunction

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        read_req_d0       <= 1'b0;
        read_req_d1       <= 1'b0;
        read_req_d2       <= 1'b0;
        old_index_d0      <= 2'd0;
        old_index_d1      <= 2'd0;
        old_index_d2      <= 2'd0;
        new_index_d0      <= 2'd0;
        new_index_d1      <= 2'd0;
        new_index_d2      <= 2'd0;
        slide_active_d0   <= 1'b0;
        slide_active_d1   <= 1'b0;
        slide_active_d2   <= 1'b0;
        slide_position_d0 <= 10'd0;
        slide_position_d1 <= 10'd0;
        slide_position_d2 <= 10'd0;
    end else begin
        read_req_d0       <= read_req;
        read_req_d1       <= read_req_d0;
        read_req_d2       <= read_req_d1;
        old_index_d0      <= old_buffer_index;
        old_index_d1      <= old_index_d0;
        old_index_d2      <= old_index_d1;
        new_index_d0      <= new_buffer_index;
        new_index_d1      <= new_index_d0;
        new_index_d2      <= new_index_d1;
        slide_active_d0   <= slide_active;
        slide_active_d1   <= slide_active_d0;
        slide_active_d2   <= slide_active_d1;
        slide_position_d0 <= slide_position;
        slide_position_d1 <= slide_position_d0;
        slide_position_d2 <= slide_position_d1;
    end
end

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        state                    <= S_IDLE;
        phase                    <= P_OLD_DIRECT;
        read_req_ack             <= 1'b0;
        read_finish              <= 1'b0;
        fifo_aclr                <= 1'b1;
        fifo_write_en            <= 1'b0;
        fifo_write_data          <= 32'd0;
        App_rd_addr              <= {ADDR_BITS{1'b0}};
        read_fault               <= 1'b0;
        old_base_latched         <= {ADDR_BITS{1'b0}};
        new_base_latched         <= {ADDR_BITS{1'b0}};
        position_latched         <= 10'd0;
        feather_enabled_latched  <= 1'b0;
        row_index                <= 16'd0;
        row_offset               <= {ADDR_BITS{1'b0}};
        segment_remaining        <= 16'd0;
        segment_addr             <= {ADDR_BITS{1'b0}};
        phase_offset             <= 16'd0;
        chunk_phase_offset       <= 16'd0;
        chunk_length             <= 16'd0;
        issue_count              <= 16'd0;
        return_count             <= 16'd0;
        output_count             <= {(ADDR_BITS + 1){1'b0}};
    end else begin
        read_req_ack  <= 1'b0;
        read_finish   <= 1'b0;
        fifo_aclr     <= 1'b0;
        fifo_write_en <= 1'b0;

        if (read_req_d2 && (state != S_IDLE) && (state != S_ACK) &&
            (state != S_END))
            read_fault <= 1'b1;

        // Count only real SDRAM return-valid cycles. The selected phase stays
        // unchanged until all words in the current command chunk return.
        if (((state == S_ISSUE) || (state == S_WAIT_RETURN)) && Sdr_rd_en) begin
            return_count <= return_count + 16'd1;
            case (phase)
                P_OLD_DIRECT, P_NEW_DIRECT: begin
                    fifo_write_en   <= 1'b1;
                    fifo_write_data <= Sdr_rd_dout;
                    output_count    <= output_count + 1'b1;
                end

                P_OLD_CACHE: begin
                    overlap_cache[response_overlap_index] <= Sdr_rd_dout[31:8];
                end

                P_NEW_BLEND: begin
                    fifo_write_en <= 1'b1;
                    fifo_write_data <= {
                        blend_channel(
                            overlap_cache[response_overlap_index][23:16],
                            Sdr_rd_dout[31:24],
                            feather_alpha({11'd0, response_overlap_index})),
                        blend_channel(
                            overlap_cache[response_overlap_index][15:8],
                            Sdr_rd_dout[23:16],
                            feather_alpha({11'd0, response_overlap_index})),
                        blend_channel(
                            overlap_cache[response_overlap_index][7:0],
                            Sdr_rd_dout[15:8],
                            feather_alpha({11'd0, response_overlap_index})),
                        8'd0
                    };
                    output_count <= output_count + 1'b1;
                end

                default: begin
                    fifo_write_en <= 1'b0;
                end
            endcase
        end

        case (state)
            S_IDLE: begin
                if (read_req_d2 && Sdr_init_done)
                    state <= S_ACK;
            end

            S_ACK: begin
                fifo_aclr       <= 1'b1;
                old_base_latched <= slide_active_d2 ?
                                    buffer_base(old_index_d2) :
                                    buffer_base(new_index_d2);
                new_base_latched <= buffer_base(new_index_d2);
                if (!slide_active_d2)
                    position_latched <= 10'd0;
                else if (slide_position_d2 > FRAME_WIDTH)
                    position_latched <= FRAME_WIDTH;
                else
                    position_latched <= slide_position_d2;
                feather_enabled_latched <= slide_active_d2 &&
                    (slide_position_d2 >= FEATHER_HALF) &&
                    (slide_position_d2 <= (FRAME_WIDTH - FEATHER_HALF));
                row_index      <= 16'd0;
                row_offset     <= {ADDR_BITS{1'b0}};
                output_count   <= {(ADDR_BITS + 1){1'b0}};
                if (read_req_d2) begin
                    read_req_ack <= 1'b1;
                end else begin
                    state <= S_SETUP_ROW;
                end
            end

            S_SETUP_ROW: begin
                phase        <= P_OLD_DIRECT;
                phase_offset <= 16'd0;
                if (feather_enabled_latched) begin
                    segment_remaining <= FRAME_WIDTH - position_latched -
                                         FEATHER_HALF;
                    segment_addr <= old_base_latched + row_offset +
                                    position_latched - FEATHER_HALF;
                end else begin
                    segment_remaining <= FRAME_WIDTH - position_latched;
                    segment_addr <= old_base_latched + row_offset +
                                    position_latched;
                end
                state <= S_SELECT;
            end

            S_SELECT: begin
                if (segment_remaining == 16'd0) begin
                    phase_offset <= 16'd0;
                    case (phase)
                        P_OLD_DIRECT: begin
                            phase <= P_OLD_CACHE;
                            if (feather_enabled_latched) begin
                                segment_remaining <= FEATHER_WIDTH;
                                segment_addr <= old_base_latched + row_offset +
                                                FRAME_WIDTH - FEATHER_WIDTH;
                            end else begin
                                segment_remaining <= 16'd0;
                            end
                        end

                        P_OLD_CACHE: begin
                            phase <= P_NEW_BLEND;
                            if (feather_enabled_latched) begin
                                segment_remaining <= FEATHER_WIDTH;
                                segment_addr <= new_base_latched + row_offset;
                            end else begin
                                segment_remaining <= 16'd0;
                            end
                        end

                        P_NEW_BLEND: begin
                            phase <= P_NEW_DIRECT;
                            if (feather_enabled_latched) begin
                                segment_remaining <= position_latched -
                                                     FEATHER_HALF;
                                segment_addr <= new_base_latched + row_offset +
                                                FEATHER_WIDTH;
                            end else begin
                                segment_remaining <= position_latched;
                                segment_addr <= new_base_latched + row_offset;
                            end
                        end

                        default: begin
                            if (row_index == (FRAME_HEIGHT - 1)) begin
                                if (output_count != FRAME_PIXEL_COUNT)
                                    read_fault <= 1'b1;
                                state <= S_END;
                            end else begin
                                row_index  <= row_index + 16'd1;
                                row_offset <= row_offset + FRAME_WIDTH;
                                state      <= S_SETUP_ROW;
                            end
                        end
                    endcase
                end else if (can_start_chunk) begin
                    if (segment_remaining > MAX_BURST)
                        chunk_length <= MAX_BURST;
                    else
                        chunk_length <= segment_remaining;
                    issue_count        <= 16'd0;
                    return_count       <= 16'd0;
                    chunk_phase_offset <= phase_offset;
                    App_rd_addr        <= segment_addr;
                    state              <= S_ISSUE;
                end
            end

            S_ISSUE: begin
                if (issue_count == (chunk_length - 1'b1)) begin
                    segment_remaining <= segment_remaining - chunk_length;
                    segment_addr      <= segment_addr + chunk_length;
                    phase_offset      <= phase_offset + chunk_length;
                    if (Sdr_rd_en && (return_count == (chunk_length - 1'b1)))
                        state <= S_SELECT;
                    else
                        state <= S_WAIT_RETURN;
                end else begin
                    issue_count <= issue_count + 16'd1;
                    App_rd_addr <= App_rd_addr + 1'b1;
                end
            end

            S_WAIT_RETURN: begin
                if (Sdr_rd_en && (return_count == (chunk_length - 1'b1)))
                    state <= S_SELECT;
            end

            S_END: begin
                read_finish <= 1'b1;
                state       <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
`endif
