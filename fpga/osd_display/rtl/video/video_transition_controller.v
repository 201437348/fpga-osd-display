`ifndef VIDEO_TRANSITION_CONTROLLER_V
`define VIDEO_TRANSITION_CONTROLLER_V
`timescale 1ns/1ps

// Frame-level controller for the line-buffer horizontal slide. All state
// changes happen on the rising edge of a video frame read request.
//
// 两种切图效果（transition_mode，每次切图开始时锁存，切图中途改不影响本次）：
//   0 = 左右滑动（行缓存滑动，原效果）
//   1 = 淡出到黑 -> 切图 -> 淡入（fade_gain 64..0..64，交给 brightness_contrast_adjust
//       做逐帧增益）。只读一帧缓存，SDRAM 带宽/调度与静态显示完全一样。
//       真正的双帧交叉淡化需要每像素读新旧两帧（2 倍读带宽），以前上板花屏，不做。
//   淡出 16 帧 + 全黑 2 帧（缓冲区在两帧全黑之间切换）+ 淡入 16 帧 ≈ 0.57 s @60Hz。
//   两帧全黑是刻意的：缓冲区号在帧请求沿切换，frame_read_write 即使晚一帧才换读地址，
//   旧图最后一帧/新图第一帧也都落在增益 0 上，不会闪一帧旧图。
module video_transition_controller (
    input  wire       video_clk,
    input  wire       rst,
    input  wire       video_read_req,
    input  wire       display_valid,
    input  wire [2:0] committed_buffer_index,   // 槽号 0..5
    input  wire       read_fault,
    input  wire       transition_mode,          // 0 滑动，1 淡入淡出（以后由串口屏选择）
    output reg  [2:0] active_buffer_index,
    output reg  [2:0] slide_old_buffer_index,
    output reg  [2:0] slide_new_buffer_index,
    output reg        slide_active,
    output reg        transition_busy,
    output reg  [9:0] slide_position,
    output reg  [6:0] fade_gain                 // 0..64，64 = 原亮度；只在帧请求沿变化
);

reg [2:0] observed_buffer_index;
reg [2:0] target_buffer_index;
reg [4:0] phase_step;
reg       transition_pending;
reg       first_frame_seen;
reg       video_read_req_d;
reg       fault_latched;
reg       fade_active;
reg [1:0] fade_phase;
reg [4:0] fade_step;

localparam [1:0] FADE_OUT = 2'd0, FADE_HOLD = 2'd1, FADE_IN = 2'd2;

wire frame_request;
assign frame_request = video_read_req && !video_read_req_d;

function [9:0] slide_curve;
    input [4:0] step;
    begin
        case (step)
            5'd0:  slide_curve = 10'd0;
            5'd1:  slide_curve = 10'd2;
            5'd2:  slide_curve = 10'd9;
            5'd3:  slide_curve = 10'd20;
            5'd4:  slide_curve = 10'd35;
            5'd5:  slide_curve = 10'd54;
            5'd6:  slide_curve = 10'd76;
            5'd7:  slide_curve = 10'd100;
            5'd8:  slide_curve = 10'd127;
            5'd9:  slide_curve = 10'd156;
            5'd10: slide_curve = 10'd187;
            5'd11: slide_curve = 10'd219;
            5'd12: slide_curve = 10'd252;
            5'd13: slide_curve = 10'd286;
            5'd14: slide_curve = 10'd320;
            5'd15: slide_curve = 10'd354;
            5'd16: slide_curve = 10'd388;
            5'd17: slide_curve = 10'd421;
            5'd18: slide_curve = 10'd453;
            5'd19: slide_curve = 10'd484;
            5'd20: slide_curve = 10'd513;
            5'd21: slide_curve = 10'd540;
            5'd22: slide_curve = 10'd564;
            5'd23: slide_curve = 10'd586;
            5'd24: slide_curve = 10'd605;
            5'd25: slide_curve = 10'd620;
            5'd26: slide_curve = 10'd631;
            5'd27: slide_curve = 10'd640;
            5'd28: slide_curve = 10'd640;
            default: slide_curve = 10'd640;
        endcase
    end
endfunction

// smoothstep(k/16) * 64，k = 0..16，四舍五入
function [6:0] fade_curve;
    input [4:0] k;
    begin
        case (k)
            5'd0:  fade_curve = 7'd0;
            5'd1:  fade_curve = 7'd1;
            5'd2:  fade_curve = 7'd3;
            5'd3:  fade_curve = 7'd6;
            5'd4:  fade_curve = 7'd10;
            5'd5:  fade_curve = 7'd15;
            5'd6:  fade_curve = 7'd20;
            5'd7:  fade_curve = 7'd25;
            5'd8:  fade_curve = 7'd32;
            5'd9:  fade_curve = 7'd39;
            5'd10: fade_curve = 7'd44;
            5'd11: fade_curve = 7'd49;
            5'd12: fade_curve = 7'd54;
            5'd13: fade_curve = 7'd58;
            5'd14: fade_curve = 7'd61;
            5'd15: fade_curve = 7'd63;
            default: fade_curve = 7'd64;
        endcase
    end
endfunction

wire [4:0] fade_step_nx = fade_step + 5'd1;
wire       busy_now     = slide_active || fade_active;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        active_buffer_index    <= 3'd0;
        slide_old_buffer_index <= 3'd0;
        slide_new_buffer_index <= 3'd0;
        observed_buffer_index  <= 3'd0;
        target_buffer_index    <= 3'd0;
        phase_step             <= 5'd0;
        transition_pending     <= 1'b0;
        first_frame_seen       <= 1'b0;
        video_read_req_d       <= 1'b0;
        fault_latched          <= 1'b0;
        slide_active           <= 1'b0;
        transition_busy        <= 1'b0;
        slide_position         <= 10'd0;
        fade_active            <= 1'b0;
        fade_phase             <= FADE_OUT;
        fade_step              <= 5'd0;
        fade_gain              <= 7'd64;
    end else begin
        video_read_req_d <= video_read_req;

        // Keep the current frame and block new playback commits after a
        // scheduler fault has observed an incomplete memory transaction.
        if (read_fault && !fault_latched) begin
            fault_latched      <= 1'b1;
            transition_pending <= 1'b0;
            slide_active       <= 1'b0;
            transition_busy    <= 1'b1;
            fade_active        <= 1'b0;
            fade_gain          <= 7'd64;   // 故障时别停在黑屏上
        end

        if (!fault_latched && !read_fault) begin
            if (display_valid &&
                (committed_buffer_index != observed_buffer_index) &&
                !busy_now) begin
                observed_buffer_index <= committed_buffer_index;
                target_buffer_index   <= committed_buffer_index;
                if (first_frame_seen)
                    transition_pending <= 1'b1;
                else
                    active_buffer_index <= committed_buffer_index;
            end

            if (frame_request) begin
                if (display_valid && !first_frame_seen) begin
                    active_buffer_index    <= committed_buffer_index;
                    observed_buffer_index  <= committed_buffer_index;
                    target_buffer_index    <= committed_buffer_index;
                    slide_old_buffer_index <= committed_buffer_index;
                    slide_new_buffer_index <= committed_buffer_index;
                    first_frame_seen       <= 1'b1;
                    transition_pending     <= 1'b0;
                    slide_active           <= 1'b0;
                    transition_busy        <= 1'b0;
                    slide_position         <= 10'd0;
                    fade_active            <= 1'b0;
                    fade_gain              <= 7'd64;
                end else if (transition_pending && !busy_now) begin
                    slide_old_buffer_index <= active_buffer_index;
                    slide_new_buffer_index <= target_buffer_index;
                    phase_step             <= 5'd0;
                    transition_pending     <= 1'b0;
                    transition_busy        <= 1'b1;
                    slide_position         <= 10'd0;
                    if (transition_mode) begin
                        fade_active <= 1'b1;
                        fade_phase  <= FADE_OUT;
                        fade_step   <= 5'd0;
                        fade_gain   <= 7'd64;
                    end else begin
                        slide_active <= 1'b1;
                    end
                end else if (fade_active) begin
                    case (fade_phase)
                        FADE_OUT: begin
                            fade_step <= fade_step_nx;
                            fade_gain <= 7'd64 - fade_curve(fade_step_nx);
                            if (fade_step_nx == 5'd16)
                                fade_phase <= FADE_HOLD;
                        end
                        FADE_HOLD: begin
                            // 第 2 帧全黑：从这一帧起读新缓冲区
                            active_buffer_index <= slide_new_buffer_index;
                            fade_step           <= 5'd0;
                            fade_gain           <= 7'd0;
                            fade_phase          <= FADE_IN;
                        end
                        default: begin
                            fade_step <= fade_step_nx;
                            fade_gain <= fade_curve(fade_step_nx);
                            if (fade_step_nx == 5'd16) begin
                                fade_active     <= 1'b0;
                                transition_busy <= 1'b0;
                            end
                        end
                    endcase
                end else if (slide_active) begin
                    if (phase_step < 5'd27) begin
                        phase_step     <= phase_step + 5'd1;
                        slide_position <= slide_curve(phase_step + 5'd1);
                    end else begin
                        phase_step          <= 5'd28;
                        slide_position      <= 10'd640;
                        active_buffer_index <= slide_new_buffer_index;
                        slide_active        <= 1'b0;
                        transition_busy     <= 1'b0;
                    end
                end
            end
        end
    end
end

endmodule
`endif
