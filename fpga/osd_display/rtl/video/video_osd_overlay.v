module video_osd_overlay (
    input  wire        video_clk,
    input  wire        rst,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        display_valid,
    input  wire        display_test_pattern,
    input  wire [1:0]  display_buffer_index,
    output wire [23:0] rgb_out
);

localparam [9:0] TOP_BAR_HEIGHT = 10'd24;
localparam [9:0] BOTTOM_BAR_Y   = 10'd456;
localparam [9:0] TITLE_X        = 10'd16;
localparam [9:0] TITLE_Y        = 10'd4;
localparam [9:0] STATUS_X       = 10'd24;
localparam [9:0] STATUS_Y       = 10'd460;

localparam [23:0] BAR_RGB      = 24'h10213A;
localparam [23:0] TITLE_RGB    = 24'hF4F7FB;
localparam [23:0] READY_RGB    = 24'h54E3E3;
localparam [23:0] FALLBACK_RGB = 24'hFFD166;
localparam [23:0] WAIT_RGB     = 24'hFF6B6B;

reg [9:0] x;
reg [9:0] y;
reg       de_d;
reg       vs_d;
reg [23:0] rgb_out_r;

wire [9:0] title_x_offset;
wire [9:0] title_y_offset;
wire [9:0] status_x_offset;
wire [9:0] status_y_offset;
wire [3:0] title_char_index;
wire [3:0] status_char_index;
wire [2:0] title_row;
wire [2:0] status_row;
wire [7:0] title_glyph;
wire [7:0] status_glyph;
wire       title_pixel;
wire       status_pixel;
wire       title_active;
wire       status_active;
wire       indicator_active;
wire [23:0] status_rgb;

assign title_x_offset = x - TITLE_X;
assign title_y_offset = y - TITLE_Y;
assign status_x_offset = x - STATUS_X;
assign status_y_offset = y - STATUS_Y;
assign title_char_index = title_x_offset[6:3];
assign status_char_index = status_x_offset[6:3];
assign title_row = title_y_offset[3:1];
assign status_row = status_y_offset[3:1];

assign title_active = (y >= TITLE_Y) && (y < (TITLE_Y + 10'd16)) &&
                      (x >= TITLE_X) && (x < (TITLE_X + 10'd88));
assign status_active = (y >= STATUS_Y) && (y < (STATUS_Y + 10'd16)) &&
                       (x >= STATUS_X) && (x < (STATUS_X + 10'd64));
assign indicator_active = (y >= (STATUS_Y + 10'd4)) &&
                          (y < (STATUS_Y + 10'd12)) &&
                          (x >= 10'd8) && (x < 10'd16);

assign title_glyph = glyph_row(title_char(title_char_index), title_row);
assign status_glyph = glyph_row(status_char(status_char_index,
                                             display_valid,
                                             display_test_pattern,
                                             display_buffer_index), status_row);
assign title_pixel = title_active && title_glyph[7 - title_x_offset[2:0]];
assign status_pixel = status_active && status_glyph[7 - status_x_offset[2:0]];
assign status_rgb = display_test_pattern ? FALLBACK_RGB :
                    display_valid ? READY_RGB : WAIT_RGB;
assign rgb_out = rgb_out_r;

function [7:0] title_char;
    input [3:0] char_index;
    begin
        case (char_index)
            4'd0: title_char = 8'h4F; // O
            4'd1: title_char = 8'h53; // S
            4'd2: title_char = 8'h44; // D
            4'd3: title_char = 8'h20; // space
            4'd4: title_char = 8'h44; // D
            4'd5: title_char = 8'h49; // I
            4'd6: title_char = 8'h53; // S
            4'd7: title_char = 8'h50; // P
            4'd8: title_char = 8'h4C; // L
            4'd9: title_char = 8'h41; // A
            4'd10: title_char = 8'h59; // Y
            default: title_char = 8'h20;
        endcase
    end
endfunction

function [7:0] status_char;
    input [3:0] char_index;
    input       valid;
    input       fallback;
    input [1:0] buffer_index;
    begin
        status_char = 8'h20;
        if (fallback) begin
            case (char_index)
                4'd0: status_char = 8'h46; // F
                4'd1: status_char = 8'h41; // A
                4'd2: status_char = 8'h4C; // L
                4'd3: status_char = 8'h4C; // L
                4'd4: status_char = 8'h42; // B
                4'd5: status_char = 8'h41; // A
                4'd6: status_char = 8'h43; // C
                4'd7: status_char = 8'h4B; // K
            endcase
        end else if (valid) begin
            case (char_index)
                4'd0: status_char = 8'h49; // I
                4'd1: status_char = 8'h4D; // M
                4'd2: status_char = 8'h41; // A
                4'd3: status_char = 8'h47; // G
                4'd4: status_char = 8'h45; // E
                4'd5: status_char = 8'h20; // space
                4'd6: status_char = 8'h42; // B
                4'd7: status_char = buffer_index[0] ? 8'h31 : 8'h30;
            endcase
        end else begin
            case (char_index)
                4'd0: status_char = 8'h57; // W
                4'd1: status_char = 8'h41; // A
                4'd2: status_char = 8'h49; // I
                4'd3: status_char = 8'h54; // T
                4'd4: status_char = 8'h20; // space
                4'd5: status_char = 8'h54; // T
                4'd6: status_char = 8'h46; // F
            endcase
        end
    end
endfunction

function [7:0] glyph_row;
    input [7:0] char_code;
    input [2:0] row;
    begin
        glyph_row = 8'h00;
        case (char_code)
            8'h30: case (row) // 0
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000110;
                3'd3: glyph_row = 8'b01001010;
                3'd4: glyph_row = 8'b01010010;
                3'd5: glyph_row = 8'b01100010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h31: case (row) // 1
                3'd0: glyph_row = 8'b00010000;
                3'd1: glyph_row = 8'b00110000;
                3'd2: glyph_row = 8'b00010000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00111000;
            endcase
            8'h41: case (row) // A
                3'd0: glyph_row = 8'b00011000;
                3'd1: glyph_row = 8'b00100100;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01111110;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h42: case (row) // B
                3'd0: glyph_row = 8'b01111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b01111100;
            endcase
            8'h43: case (row) // C
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01000000;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h44: case (row) // D
                3'd0: glyph_row = 8'b01111000;
                3'd1: glyph_row = 8'b01000100;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000100;
                3'd6: glyph_row = 8'b01111000;
            endcase
            8'h45: case (row) // E
                3'd0: glyph_row = 8'b01111110;
                3'd1: glyph_row = 8'b01000000;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01111110;
            endcase
            8'h46: case (row) // F
                3'd0: glyph_row = 8'b01111110;
                3'd1: glyph_row = 8'b01000000;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01000000;
            endcase
            8'h47: case (row) // G
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01001110;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h49: case (row) // I
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b00010000;
                3'd2: glyph_row = 8'b00010000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h4B: case (row) // K
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01000100;
                3'd2: glyph_row = 8'b01001000;
                3'd3: glyph_row = 8'b01110000;
                3'd4: glyph_row = 8'b01001000;
                3'd5: glyph_row = 8'b01000100;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h4C: case (row) // L
                3'd0: glyph_row = 8'b01000000;
                3'd1: glyph_row = 8'b01000000;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b01000000;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01111110;
            endcase
            8'h4D: case (row) // M
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01100110;
                3'd2: glyph_row = 8'b01011010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h4F: case (row) // O
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01000010;
                3'd4: glyph_row = 8'b01000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h50: case (row) // P
                3'd0: glyph_row = 8'b01111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01000000;
                3'd5: glyph_row = 8'b01000000;
                3'd6: glyph_row = 8'b01000000;
            endcase
            8'h52: case (row) // R
                3'd0: glyph_row = 8'b01111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01111100;
                3'd4: glyph_row = 8'b01001000;
                3'd5: glyph_row = 8'b01000100;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h53: case (row) // S
                3'd0: glyph_row = 8'b00111100;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000000;
                3'd3: glyph_row = 8'b00111100;
                3'd4: glyph_row = 8'b00000010;
                3'd5: glyph_row = 8'b01000010;
                3'd6: glyph_row = 8'b00111100;
            endcase
            8'h54: case (row) // T
                3'd0: glyph_row = 8'b01111110;
                3'd1: glyph_row = 8'b00010000;
                3'd2: glyph_row = 8'b00010000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00010000;
            endcase
            8'h57: case (row) // W
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b01000010;
                3'd2: glyph_row = 8'b01000010;
                3'd3: glyph_row = 8'b01011010;
                3'd4: glyph_row = 8'b01011010;
                3'd5: glyph_row = 8'b01100110;
                3'd6: glyph_row = 8'b01000010;
            endcase
            8'h59: case (row) // Y
                3'd0: glyph_row = 8'b01000010;
                3'd1: glyph_row = 8'b00100100;
                3'd2: glyph_row = 8'b00011000;
                3'd3: glyph_row = 8'b00010000;
                3'd4: glyph_row = 8'b00010000;
                3'd5: glyph_row = 8'b00010000;
                3'd6: glyph_row = 8'b00010000;
            endcase
            default: glyph_row = 8'h00;
        endcase
    end
endfunction

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        x    <= 10'd0;
        y    <= 10'd0;
        de_d <= 1'b0;
        vs_d <= 1'b0;
    end else begin
        de_d <= de;
        vs_d <= vs;

        if (vs && !vs_d) begin
            x <= 10'd0;
            y <= 10'd0;
        end else if (de) begin
            x <= x + 10'd1;
        end else if (de_d) begin
            x <= 10'd0;
            y <= y + 10'd1;
        end
    end
end

always @* begin
    rgb_out_r = rgb_in;

    if (de) begin
        if (y < TOP_BAR_HEIGHT) begin
            rgb_out_r = BAR_RGB;
            if (title_pixel)
                rgb_out_r = TITLE_RGB;
        end else if (y >= BOTTOM_BAR_Y) begin
            rgb_out_r = BAR_RGB;
            if (indicator_active || status_pixel)
                rgb_out_r = status_rgb;
        end
    end
end

endmodule
