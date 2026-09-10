`timescale 1ns/1ps

module sd_sector_arbiter(
    input  wire        clk,
    input  wire        rst,

    input  wire        scan_req,
    input  wire [31:0] scan_addr,
    input  wire        audio_req,
    input  wire [31:0] audio_addr,
    input  wire        image_req,
    input  wire [31:0] image_addr,

    output wire        scan_grant,
    output wire        audio_grant,
    output wire        image_grant,
    output wire        sd_sec_read,
    output wire [31:0] sd_sec_read_addr
);

localparam [2:0] ST_IDLE  = 3'd0;
localparam [2:0] ST_SCAN  = 3'd1;
localparam [2:0] ST_AUDIO = 3'd2;
localparam [2:0] ST_IMAGE = 3'd3;
localparam [2:0] ST_GAP   = 3'd4;

reg [2:0] state;

assign scan_grant  = (state == ST_SCAN);
assign audio_grant = (state == ST_AUDIO);
assign image_grant = (state == ST_IMAGE);

assign sd_sec_read = scan_grant  ? scan_req :
                     audio_grant ? audio_req :
                     image_grant ? image_req : 1'b0;

assign sd_sec_read_addr = scan_grant  ? scan_addr :
                          audio_grant ? audio_addr :
                          image_grant ? image_addr : 32'd0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= ST_IDLE;
    end else begin
        case (state)
            ST_IDLE: begin
                if (scan_req)
                    state <= ST_SCAN;
                else if (audio_req)
                    state <= ST_AUDIO;
                else if (image_req)
                    state <= ST_IMAGE;
            end

            ST_SCAN:
                if (!scan_req)
                    state <= ST_GAP;

            ST_AUDIO:
                if (!audio_req)
                    state <= ST_GAP;

            ST_IMAGE:
                if (!image_req)
                    state <= ST_GAP;

            ST_GAP:
                // The completed owner has held its request low for a full
                // clock before this state is entered.  Pick the next owner
                // here so exactly one explicit idle arbitration cycle is
                // inserted without weakening the SD-core low-level handoff.
                if (scan_req)
                    state <= ST_SCAN;
                else if (audio_req)
                    state <= ST_AUDIO;
                else if (image_req)
                    state <= ST_IMAGE;
                else
                    state <= ST_IDLE;

            default:
                state <= ST_IDLE;
        endcase
    end
end

endmodule
