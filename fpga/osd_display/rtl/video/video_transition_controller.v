`ifndef VIDEO_TRANSITION_CONTROLLER_V
`define VIDEO_TRANSITION_CONTROLLER_V
`timescale 1ns/1ps

// Frame-level controller for the line-buffer horizontal slide. All state
// changes happen on the rising edge of a video frame read request.
module video_transition_controller (
    input  wire       video_clk,
    input  wire       rst,
    input  wire       video_read_req,
    input  wire       display_valid,
    input  wire [1:0] committed_buffer_index,
    input  wire       read_fault,
    output reg  [1:0] active_buffer_index,
    output reg  [1:0] slide_old_buffer_index,
    output reg  [1:0] slide_new_buffer_index,
    output reg        slide_active,
    output reg        transition_busy,
    output reg  [9:0] slide_position
);

reg [1:0] observed_buffer_index;
reg [1:0] target_buffer_index;
reg [4:0] phase_step;
reg       transition_pending;
reg       first_frame_seen;
reg       video_read_req_d;
reg       fault_latched;

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
            5'd27: slide_curve = 10'd638;
            5'd28: slide_curve = 10'd640;
            default: slide_curve = 10'd640;
        endcase
    end
endfunction

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        active_buffer_index    <= 2'd0;
        slide_old_buffer_index <= 2'd0;
        slide_new_buffer_index <= 2'd0;
        observed_buffer_index  <= 2'd0;
        target_buffer_index    <= 2'd0;
        phase_step             <= 5'd0;
        transition_pending     <= 1'b0;
        first_frame_seen       <= 1'b0;
        video_read_req_d       <= 1'b0;
        fault_latched          <= 1'b0;
        slide_active           <= 1'b0;
        transition_busy        <= 1'b0;
        slide_position         <= 10'd0;
    end else begin
        video_read_req_d <= video_read_req;

        // Keep the current frame and block new playback commits after a
        // scheduler fault has observed an incomplete memory transaction.
        if (read_fault && !fault_latched) begin
            fault_latched      <= 1'b1;
            transition_pending <= 1'b0;
            slide_active       <= 1'b0;
            transition_busy    <= 1'b1;
        end

        if (!fault_latched && !read_fault) begin
            if (display_valid &&
                (committed_buffer_index != observed_buffer_index) &&
                !slide_active) begin
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
                end else if (transition_pending && !slide_active) begin
                    slide_old_buffer_index <= active_buffer_index;
                    slide_new_buffer_index <= target_buffer_index;
                    phase_step             <= 5'd0;
                    transition_pending     <= 1'b0;
                    slide_active           <= 1'b1;
                    transition_busy        <= 1'b1;
                    slide_position         <= 10'd0;
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
