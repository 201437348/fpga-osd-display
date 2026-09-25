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
    parameter FEATHER_WIDTH    = 32,
    parameter FEATHER_ENABLE   = 1,
    parameter SLIDE_FIFO_UNIFORM_DIAGNOSTIC = 0,
    parameter SLIDE_SDRAM_UNIFORM_DIAGNOSTIC = 0,
    parameter SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC = 0,
    parameter SLIDE_PHASE_COLOR_DIAGNOSTIC = 0,
    parameter READ_CHUNK_PREROLL_WORDS = 0,
    parameter FIXED_READ_BURST_ENABLE = 0
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
    input  wire [ADDR_BITS-1:0]         read_addr_4,       // 6 槽缓存：槽 4、5
    input  wire [ADDR_BITS-1:0]         read_addr_5,
    input  wire [2:0]                   old_buffer_index,
    input  wire [2:0]                   new_buffer_index,
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
localparam [3:0] S_PREROLL_ISSUE = 4'd7;
localparam [3:0] S_PREROLL_WAIT  = 4'd8;

localparam [1:0] P_OLD_DIRECT = 2'd0;
localparam [1:0] P_OLD_CACHE  = 2'd1;
localparam [1:0] P_NEW_BLEND  = 2'd2;
localparam [1:0] P_NEW_DIRECT = 2'd3;

localparam integer FEATHER_HALF = FEATHER_WIDTH / 2;
localparam integer OUTPUT_PIPELINE_RESERVE = 4;
localparam integer FIFO_START_LEVEL = FIFO_DEPTH - MAX_BURST -
                                      OUTPUT_PIPELINE_RESERVE;
localparam integer FRAME_PIXEL_COUNT = FRAME_WIDTH * FRAME_HEIGHT;

reg [3:0] state;
reg [1:0] phase;

reg read_req_d0;
reg read_req_d1;
reg read_req_d2;
reg [2:0] old_index_d0;
reg [2:0] old_index_d1;
reg [2:0] old_index_d2;
reg [2:0] new_index_d0;
reg [2:0] new_index_d1;
reg [2:0] new_index_d2;
reg slide_active_d0;
reg slide_active_d1;
reg slide_active_d2;
reg [9:0] slide_position_d0;
reg [9:0] slide_position_d1;
reg [9:0] slide_position_d2;

reg [ADDR_BITS-1:0] old_row_base;
reg [ADDR_BITS-1:0] new_row_base;
reg [9:0] position_latched;
reg feather_enabled_latched;
reg uniform_diagnostic_latched;
reg sdram_uniform_diagnostic_latched;
reg address_pattern_diagnostic_latched;
reg phase_color_diagnostic_latched;

reg [15:0] row_index;
reg [15:0] segment_remaining;
reg [ADDR_BITS-1:0] segment_addr;
reg [15:0] phase_offset;
reg [15:0] chunk_phase_offset;
reg [15:0] chunk_length;
reg [15:0] command_length;
reg [15:0] issue_count;
// 时序（125 MHz）：issue_count == command_length-1 原来直接驱动 segment_* 等
// 一大片寄存器的 ce。改为提前一拍算好的“本拍是最后一个命令”标志。
reg        issue_last;
wire [15:0] command_length_start =
    (FIXED_READ_BURST_ENABLE || (segment_remaining > MAX_BURST)) ?
    MAX_BURST : segment_remaining;
reg [15:0] return_count;
reg [15:0] preroll_issue_count;
reg [15:0] preroll_return_count;
// 时序（125 MHz）：预读计数与常数的比较提前一拍算成标志，状态机只看 1 位
reg        preroll_issue_last;
reg        preroll_return_last;
reg [ADDR_BITS:0] output_count;
reg [ADDR_BITS-1:0] diagnostic_chunk_base;

reg [23:0] overlap_cache [0:FEATHER_WIDTH-1];

reg        output_pipe_valid_raw;
reg        output_pipe_blend_raw;
reg [31:0] output_pipe_direct_raw;
reg [7:0]  output_pipe_source_r_raw;
reg [7:0]  output_pipe_source_g_raw;
reg [7:0]  output_pipe_source_b_raw;
reg [7:0]  output_pipe_target_r_raw;
reg [7:0]  output_pipe_target_g_raw;
reg [7:0]  output_pipe_target_b_raw;
reg [6:0]  output_pipe_alpha_raw;

reg        output_pipe_valid_0;
reg        output_pipe_blend_0;
reg [31:0] output_pipe_direct_0;
reg [7:0]  output_pipe_source_r_0;
reg [7:0]  output_pipe_source_g_0;
reg [7:0]  output_pipe_source_b_0;
reg [7:0]  output_pipe_difference_r_0;
reg [7:0]  output_pipe_difference_g_0;
reg [7:0]  output_pipe_difference_b_0;
reg        output_pipe_add_r_0;
reg        output_pipe_add_g_0;
reg        output_pipe_add_b_0;
reg [6:0]  output_pipe_alpha_0;

reg        output_pipe_valid_1;
reg        output_pipe_blend_1;
reg [31:0] output_pipe_direct_1;
reg [7:0]  output_pipe_source_r_1;
reg [7:0]  output_pipe_source_g_1;
reg [7:0]  output_pipe_source_b_1;
reg [14:0] output_pipe_scaled_r_1;
reg [14:0] output_pipe_scaled_g_1;
reg [14:0] output_pipe_scaled_b_1;
reg        output_pipe_add_r_1;
reg        output_pipe_add_g_1;
reg        output_pipe_add_b_1;

wire phase_writes_fifo;
reg  fifo_has_chunk_room;
wire can_start_chunk;
wire [4:0] response_overlap_index;
wire output_pipeline_pending;
wire [31:0] scheduler_return_data;
wire [ADDR_BITS-1:0] diagnostic_return_address;

assign phase_writes_fifo = (phase != P_OLD_CACHE);
// Registered to cut the read_buf wrusedw -> scheduler path (125 MHz).  The
// value is one cycle old, so the threshold keeps 2 extra words of margin.
always @(posedge mem_clk or posedge rst) begin
    if (rst)
        fifo_has_chunk_room <= 1'b0;
    else
        fifo_has_chunk_room <= (wrusedw < (FIFO_START_LEVEL - 2));
end
assign can_start_chunk = (segment_remaining != 16'd0) &&
                         (!phase_writes_fifo || fifo_has_chunk_room) &&
                         !App_wr_busy;
assign response_overlap_index = chunk_phase_offset[4:0] + return_count[4:0];
assign output_pipeline_pending = output_pipe_valid_raw ||
                                 output_pipe_valid_0 || output_pipe_valid_1;
assign diagnostic_return_address = diagnostic_chunk_base + return_count;
assign scheduler_return_data = sdram_uniform_diagnostic_latched ? {
    position_latched[7:0],
    ~position_latched[7:0],
    position_latched[6:0], 1'b0,
    8'h00
} : address_pattern_diagnostic_latched ? {
    diagnostic_return_address[6:0], 1'b0,
    ~{diagnostic_return_address[6:0], 1'b0},
    diagnostic_return_address[5:0], 2'b00,
    8'h00
} : phase_color_diagnostic_latched ?
    (((phase == P_OLD_DIRECT) || (phase == P_OLD_CACHE)) ?
        32'hE0202000 : 32'h20E04000)
  : Sdr_rd_dout;
// Sdr_busy is command-side backpressure. Already accepted reads may still
// return while it is high, but a new address must not be presented as valid.
assign App_rd_en = ((state == S_ISSUE) ||
                    (state == S_PREROLL_ISSUE)) && !Sdr_busy;

// Match the existing write-priority arbitration: the write scheduler
// pre-asserts App_wr_busy before a burst, while read_busy covers issued read
// commands and every outstanding return from that chunk.
assign read_busy = (state == S_ISSUE) || (state == S_WAIT_RETURN) ||
                   (state == S_PREROLL_ISSUE) ||
                   (state == S_PREROLL_WAIT);

function [ADDR_BITS-1:0] buffer_base;
    input [2:0] index;
    begin
        case (index)
            3'd0: buffer_base = read_addr_0;
            3'd1: buffer_base = read_addr_1;
            3'd2: buffer_base = read_addr_2;
            3'd3: buffer_base = read_addr_3;
            3'd4: buffer_base = read_addr_4;
            default: buffer_base = read_addr_5;
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

function [7:0] channel_difference;
    input [7:0] source;
    input [7:0] target;
    begin
        if (target >= source)
            channel_difference = target - source;
        else
            channel_difference = source - target;
    end
endfunction

function [7:0] apply_scaled_difference;
    input [7:0] source;
    input [14:0] scaled;
    input add_difference;
    begin
        if (add_difference)
            apply_scaled_difference = source + (scaled >> 6);
        else
            apply_scaled_difference = source - (scaled >> 6);
    end
endfunction

always @(posedge mem_clk or posedge rst) begin
    if (rst) begin
        read_req_d0       <= 1'b0;
        read_req_d1       <= 1'b0;
        read_req_d2       <= 1'b0;
        old_index_d0      <= 3'd0;
        old_index_d1      <= 3'd0;
        old_index_d2      <= 3'd0;
        new_index_d0      <= 3'd0;
        new_index_d1      <= 3'd0;
        new_index_d2      <= 3'd0;
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
        old_row_base             <= {ADDR_BITS{1'b0}};
        new_row_base             <= {ADDR_BITS{1'b0}};
        position_latched         <= 10'd0;
        feather_enabled_latched  <= 1'b0;
        uniform_diagnostic_latched <= 1'b0;
        sdram_uniform_diagnostic_latched <= 1'b0;
        address_pattern_diagnostic_latched <= 1'b0;
        phase_color_diagnostic_latched <= 1'b0;
        row_index                <= 16'd0;
        segment_remaining        <= 16'd0;
        segment_addr             <= {ADDR_BITS{1'b0}};
        phase_offset             <= 16'd0;
        chunk_phase_offset       <= 16'd0;
        chunk_length             <= 16'd0;
        command_length           <= 16'd0;
        issue_count              <= 16'd0;
        issue_last               <= 1'b0;
        return_count             <= 16'd0;
        preroll_issue_count      <= 16'd0;
        preroll_return_count     <= 16'd0;
        preroll_issue_last       <= 1'b0;
        preroll_return_last      <= 1'b0;
        output_count             <= {(ADDR_BITS + 1){1'b0}};
        diagnostic_chunk_base    <= {ADDR_BITS{1'b0}};
        output_pipe_valid_raw    <= 1'b0;
        output_pipe_blend_raw    <= 1'b0;
        output_pipe_direct_raw   <= 32'd0;
        output_pipe_source_r_raw <= 8'd0;
        output_pipe_source_g_raw <= 8'd0;
        output_pipe_source_b_raw <= 8'd0;
        output_pipe_target_r_raw <= 8'd0;
        output_pipe_target_g_raw <= 8'd0;
        output_pipe_target_b_raw <= 8'd0;
        output_pipe_alpha_raw    <= 7'd0;
        output_pipe_valid_0      <= 1'b0;
        output_pipe_blend_0      <= 1'b0;
        output_pipe_direct_0     <= 32'd0;
        output_pipe_source_r_0   <= 8'd0;
        output_pipe_source_g_0   <= 8'd0;
        output_pipe_source_b_0   <= 8'd0;
        output_pipe_difference_r_0 <= 8'd0;
        output_pipe_difference_g_0 <= 8'd0;
        output_pipe_difference_b_0 <= 8'd0;
        output_pipe_add_r_0      <= 1'b0;
        output_pipe_add_g_0      <= 1'b0;
        output_pipe_add_b_0      <= 1'b0;
        output_pipe_alpha_0      <= 7'd0;
        output_pipe_valid_1      <= 1'b0;
        output_pipe_blend_1      <= 1'b0;
        output_pipe_direct_1     <= 32'd0;
        output_pipe_source_r_1   <= 8'd0;
        output_pipe_source_g_1   <= 8'd0;
        output_pipe_source_b_1   <= 8'd0;
        output_pipe_scaled_r_1   <= 15'd0;
        output_pipe_scaled_g_1   <= 15'd0;
        output_pipe_scaled_b_1   <= 15'd0;
        output_pipe_add_r_1      <= 1'b0;
        output_pipe_add_g_1      <= 1'b0;
        output_pipe_add_b_1      <= 1'b0;
    end else begin
        read_req_ack  <= 1'b0;
        read_finish   <= 1'b0;
        fifo_aclr     <= 1'b0;
        fifo_write_en <= 1'b0;
        output_pipe_valid_raw <= 1'b0;
        output_pipe_valid_0 <= output_pipe_valid_raw;
        output_pipe_valid_1 <= output_pipe_valid_0;

        if (output_pipe_valid_raw) begin
            output_pipe_blend_0  <= output_pipe_blend_raw;
            output_pipe_direct_0 <= output_pipe_direct_raw;
            if (output_pipe_blend_raw) begin
                output_pipe_source_r_0 <= output_pipe_source_r_raw;
                output_pipe_source_g_0 <= output_pipe_source_g_raw;
                output_pipe_source_b_0 <= output_pipe_source_b_raw;
                output_pipe_difference_r_0 <= channel_difference(
                    output_pipe_source_r_raw, output_pipe_target_r_raw);
                output_pipe_difference_g_0 <= channel_difference(
                    output_pipe_source_g_raw, output_pipe_target_g_raw);
                output_pipe_difference_b_0 <= channel_difference(
                    output_pipe_source_b_raw, output_pipe_target_b_raw);
                output_pipe_add_r_0 <= output_pipe_target_r_raw >=
                                       output_pipe_source_r_raw;
                output_pipe_add_g_0 <= output_pipe_target_g_raw >=
                                       output_pipe_source_g_raw;
                output_pipe_add_b_0 <= output_pipe_target_b_raw >=
                                       output_pipe_source_b_raw;
                output_pipe_alpha_0 <= output_pipe_alpha_raw;
            end
        end

        if (output_pipe_valid_0) begin
            output_pipe_blend_1    <= output_pipe_blend_0;
            output_pipe_direct_1   <= output_pipe_direct_0;
            output_pipe_source_r_1 <= output_pipe_source_r_0;
            output_pipe_source_g_1 <= output_pipe_source_g_0;
            output_pipe_source_b_1 <= output_pipe_source_b_0;
            output_pipe_scaled_r_1 <= output_pipe_difference_r_0 *
                                      output_pipe_alpha_0;
            output_pipe_scaled_g_1 <= output_pipe_difference_g_0 *
                                      output_pipe_alpha_0;
            output_pipe_scaled_b_1 <= output_pipe_difference_b_0 *
                                      output_pipe_alpha_0;
            output_pipe_add_r_1    <= output_pipe_add_r_0;
            output_pipe_add_g_1    <= output_pipe_add_g_0;
            output_pipe_add_b_1    <= output_pipe_add_b_0;
        end

        if (output_pipe_valid_1) begin
            fifo_write_en <= 1'b1;
            if (uniform_diagnostic_latched) begin
                fifo_write_data <= {
                    position_latched[7:0],
                    ~position_latched[7:0],
                    position_latched[6:0], 1'b0,
                    8'h00
                };
            end else if (output_pipe_blend_1) begin
                fifo_write_data <= {
                    apply_scaled_difference(output_pipe_source_r_1,
                                            output_pipe_scaled_r_1,
                                            output_pipe_add_r_1),
                    apply_scaled_difference(output_pipe_source_g_1,
                                            output_pipe_scaled_g_1,
                                            output_pipe_add_g_1),
                    apply_scaled_difference(output_pipe_source_b_1,
                                            output_pipe_scaled_b_1,
                                            output_pipe_add_b_1),
                    8'd0
                };
            end else begin
                fifo_write_data <= output_pipe_direct_1;
            end
            output_count <= output_count + 1'b1;
        end

        if (read_req_d2 && (state != S_IDLE) && (state != S_ACK) &&
            (state != S_END))
            read_fault <= 1'b1;

        // Count only real SDRAM return-valid cycles. The selected phase stays
        // unchanged until all words in the current command chunk return.
        if (((state == S_ISSUE) || (state == S_WAIT_RETURN)) && Sdr_rd_en) begin
            return_count <= return_count + 16'd1;
            if (return_count < chunk_length) begin
              case (phase)
                P_OLD_DIRECT, P_NEW_DIRECT: begin
                    output_pipe_valid_raw  <= 1'b1;
                    output_pipe_blend_raw  <= 1'b0;
                    output_pipe_direct_raw <= scheduler_return_data;
                end

                P_OLD_CACHE: begin
                    overlap_cache[response_overlap_index] <=
                        scheduler_return_data[31:8];
                end

                P_NEW_BLEND: begin
                    output_pipe_valid_raw <= 1'b1;
                    output_pipe_blend_raw <= 1'b1;
                    output_pipe_source_r_raw <=
                        overlap_cache[response_overlap_index][23:16];
                    output_pipe_source_g_raw <=
                        overlap_cache[response_overlap_index][15:8];
                    output_pipe_source_b_raw <=
                        overlap_cache[response_overlap_index][7:0];
                    output_pipe_target_r_raw <=
                        scheduler_return_data[31:24];
                    output_pipe_target_g_raw <=
                        scheduler_return_data[23:16];
                    output_pipe_target_b_raw <=
                        scheduler_return_data[15:8];
                    output_pipe_alpha_raw <= feather_alpha(
                        {11'd0, response_overlap_index});
                end

                default: begin
                    fifo_write_en <= 1'b0;
                end
              endcase
            end
        end

        // Preroll responses deliberately do not enter the output pipeline.
        // Repeating the chunk's first address drains stale data left behind
        // by a discontinuous SDRAM address transition.
        if (((state == S_PREROLL_ISSUE) ||
             (state == S_PREROLL_WAIT)) && Sdr_rd_en) begin
            preroll_return_count <= preroll_return_count + 16'd1;
            preroll_return_last  <= (preroll_return_count == (READ_CHUNK_PREROLL_WORDS - 2));
        end

        case (state)
            S_IDLE: begin
                if (read_req_d2 && Sdr_init_done)
                    state <= S_ACK;
            end

            S_ACK: begin
                fifo_aclr       <= 1'b1;
                old_row_base <= slide_active_d2 ?
                                buffer_base(old_index_d2) :
                                buffer_base(new_index_d2);
                new_row_base <= buffer_base(new_index_d2);
                if (!slide_active_d2)
                    position_latched <= 10'd0;
                else if (slide_position_d2 > FRAME_WIDTH)
                    position_latched <= FRAME_WIDTH;
                else
                    position_latched <= slide_position_d2;
                feather_enabled_latched <= FEATHER_ENABLE && slide_active_d2 &&
                    (slide_position_d2 >= FEATHER_HALF) &&
                    (slide_position_d2 <= (FRAME_WIDTH - FEATHER_HALF));
                uniform_diagnostic_latched <=
                    SLIDE_FIFO_UNIFORM_DIAGNOSTIC && slide_active_d2;
                sdram_uniform_diagnostic_latched <=
                    SLIDE_SDRAM_UNIFORM_DIAGNOSTIC && slide_active_d2;
                address_pattern_diagnostic_latched <=
                    SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC && slide_active_d2;
                phase_color_diagnostic_latched <=
                    SLIDE_PHASE_COLOR_DIAGNOSTIC && slide_active_d2;
                row_index      <= 16'd0;
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
                    segment_addr <= old_row_base +
                                    (position_latched - FEATHER_HALF);
                end else begin
                    segment_remaining <= FRAME_WIDTH - position_latched;
                    segment_addr <= old_row_base + position_latched;
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
                                segment_addr <= old_row_base +
                                                FRAME_WIDTH - FEATHER_WIDTH;
                            end else begin
                                segment_remaining <= 16'd0;
                            end
                        end

                        P_OLD_CACHE: begin
                            phase <= P_NEW_BLEND;
                            if (feather_enabled_latched) begin
                                segment_remaining <= FEATHER_WIDTH;
                                segment_addr <= new_row_base;
                            end else begin
                                segment_remaining <= 16'd0;
                            end
                        end

                        P_NEW_BLEND: begin
                            phase <= P_NEW_DIRECT;
                            if (feather_enabled_latched) begin
                                segment_remaining <= position_latched -
                                                     FEATHER_HALF;
                                segment_addr <= new_row_base + FEATHER_WIDTH;
                            end else begin
                                segment_remaining <= position_latched;
                                segment_addr <= new_row_base;
                            end
                        end

                        default: begin
                            if ((row_index == (FRAME_HEIGHT - 1)) &&
                                !output_pipeline_pending) begin
                                if (output_count != FRAME_PIXEL_COUNT)
                                    read_fault <= 1'b1;
                                state <= S_END;
                            end else if (row_index != (FRAME_HEIGHT - 1)) begin
                                row_index  <= row_index + 16'd1;
                                old_row_base <= old_row_base + FRAME_WIDTH;
                                new_row_base <= new_row_base + FRAME_WIDTH;
                                state      <= S_SETUP_ROW;
                            end
                        end
                    endcase
                end else if (can_start_chunk) begin
                    if (segment_remaining > MAX_BURST)
                        chunk_length <= MAX_BURST;
                    else
                        chunk_length <= segment_remaining;
                    if (FIXED_READ_BURST_ENABLE)
                        command_length <= MAX_BURST;
                    else if (segment_remaining > MAX_BURST)
                        command_length <= MAX_BURST;
                    else
                        command_length <= segment_remaining;
                    issue_count        <= 16'd0;
                    issue_last         <= (command_length_start == 16'd1);
                    return_count       <= 16'd0;
                    preroll_issue_count  <= 16'd0;
                    preroll_return_count <= 16'd0;
                    preroll_issue_last   <= (READ_CHUNK_PREROLL_WORDS == 1);
                    preroll_return_last  <= (READ_CHUNK_PREROLL_WORDS == 1);
                    chunk_phase_offset <= phase_offset;
                    App_rd_addr        <= segment_addr;
                    diagnostic_chunk_base <= segment_addr;
                    if (READ_CHUNK_PREROLL_WORDS == 0)
                        state <= S_ISSUE;
                    else
                        state <= S_PREROLL_ISSUE;
                end
            end

            S_PREROLL_ISSUE: begin
                // Keep App_rd_addr fixed at the payload's first address.
                if (!Sdr_busy) begin
                    if (preroll_issue_last) begin
                        if (Sdr_rd_en && preroll_return_last)
                            state <= S_ISSUE;
                        else
                            state <= S_PREROLL_WAIT;
                    end else begin
                        preroll_issue_count <= preroll_issue_count + 16'd1;
                        preroll_issue_last  <= (preroll_issue_count == (READ_CHUNK_PREROLL_WORDS - 2));
                    end
                end
            end

            S_PREROLL_WAIT: begin
                if (Sdr_rd_en && preroll_return_last)
                    state <= S_ISSUE;
            end

            S_ISSUE: begin
                // Advance only for a command the SDRAM interface can accept.
                // Holding address/count during refresh keeps expected returns
                // exactly aligned with accepted requests.
                if (!Sdr_busy) begin
                    if (issue_last) begin
                        segment_remaining <= segment_remaining - chunk_length;
                        segment_addr      <= segment_addr + chunk_length;
                        phase_offset      <= phase_offset + chunk_length;
                        if (Sdr_rd_en &&
                            (return_count == (command_length - 1'b1)))
                            state <= S_SELECT;
                        else
                            state <= S_WAIT_RETURN;
                    end else begin
                        issue_count <= issue_count + 16'd1;
                        issue_last  <= (issue_count == (command_length - 16'd2));
                        App_rd_addr <= App_rd_addr + 1'b1;
                    end
                end
            end

            S_WAIT_RETURN: begin
                if (Sdr_rd_en &&
                    (return_count == (command_length - 1'b1)))
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
