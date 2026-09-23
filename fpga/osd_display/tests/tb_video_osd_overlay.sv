`timescale 1ns/1ps

module tb_video_osd_overlay;

reg video_clk = 1'b0;
reg rst = 1'b1;
reg vs = 1'b0;
reg de = 1'b0;
reg [23:0] rgb_in = 24'h123456;
reg display_valid = 1'b0;
reg display_test_pattern = 1'b0;
reg storage_ready = 1'b0;
reg [2:0] manager_state = 3'd0;
reg load_in_progress = 1'b0;
reg [2:0] target_image_index = 2'd0;
reg [2:0] current_image_index = 2'd0;
reg [3:0] image_count = 3'd0;
reg        menu_active = 1'b0;
reg  [7:0] brightness_value = 8'd255;
reg  [7:0] contrast_value = 8'd128;
reg  [1:0] menu_channel = 2'b00;
wire [23:0] rgb_out;

always #5 video_clk = ~video_clk;

video_osd_overlay dut (
    .video_clk           (video_clk),
    .rst                 (rst),
    .vs                  (vs),
    .de                  (de),
    .rgb_in              (rgb_in),
    .display_valid       (display_valid),
    .display_test_pattern(display_test_pattern),
    .storage_ready       (storage_ready),
    .manager_state       (manager_state),
    .load_in_progress    (load_in_progress),
    .target_image_index  (target_image_index),
    .current_image_index (current_image_index),
    .image_count         (image_count),
    .menu_active         (menu_active),
    .brightness_value    (brightness_value),
    .contrast_value      (contrast_value),
    .menu_channel        (menu_channel),
    .audio_level(8'd0), .audio_bands(384'd0),
    .rgb_out             (rgb_out)
);

task automatic expect_rgb;
    input [23:0] actual;
    input [23:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %h, got %h", checkpoint, expected, actual);
    end
endtask

task automatic drive_frame_boundary;
    begin
        @(negedge video_clk);
        vs = 1'b1;
        @(posedge video_clk);
        #1;
        @(negedge video_clk);
        vs = 1'b0;
        @(posedge video_clk);
        #1;
    end
endtask

initial begin
    repeat (2) @(posedge video_clk);
    rst = 1'b0;
    #1;

    // Blank pixels and picture-area pixels are transparent to the overlay.
    de = 1'b0;
    force dut.x = 10'd100;
    force dut.y = 10'd100;
    #1;
    expect_rgb(rgb_out, 24'h123456, "blanking remains transparent");

    de = 1'b1;
    #1;
    expect_rgb(rgb_out, 24'h123456, "picture area remains transparent");

    // A top-bar background pixel and an enabled title-font pixel are opaque.
    force dut.x = 10'd10;
    force dut.y = 10'd10;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "top bar background");
    force dut.x = 10'd18;
    force dut.y = 10'd4;
    #1;
    expect_rgb(rgb_out, 24'hF4F7FB, "title glyph pixel");

    // The ticker band is opaque, but only lit glyph bits use the ticker color.
    force dut.x = 10'd0;
    force dut.y = 10'd432;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "ticker band background");
    force dut.x = 10'd9;
    force dut.y = 10'd436;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "ticker F glyph pixel");
    force dut.x = 10'd8;
    force dut.y = 10'd436;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "ticker glyph transparent pixel");
    force dut.x = 10'd100;
    force dut.y = 10'd431;
    #1;
    expect_rgb(rgb_out, 24'h123456, "ticker upper boundary remains transparent");
    force dut.x = 10'd100;
    force dut.y = 10'd456;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "bottom bar remains above ticker priority");

    // Fallback has highest priority, then absent storage.
    display_valid = 1'b0;
    display_test_pattern = 1'b0;
    storage_ready = 1'b0;
    force dut.x = 10'd25;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'hFF6B6B, "wait status text");
    force dut.x = 10'd8;
    force dut.y = 10'd464;
    #1;
    expect_rgb(rgb_out, 24'hFF6B6B, "wait status indicator");

    display_test_pattern = 1'b1;
    force dut.x = 10'd25;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "fallback status text");

    // SCAN covers an active manager scan.
    display_test_pattern = 1'b0;
    storage_ready = 1'b1;
    manager_state = 3'd1;
    display_valid = 1'b1;
    force dut.x = 10'd26;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'hA7C7FF, "scan status text");
    force dut.x = 10'd49;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'hA7C7FF, "scan N glyph");

    // LOAD shows the target image number, rather than the buffer number.
    manager_state = 3'd0;
    load_in_progress = 1'b1;
    target_image_index = 2'd1;
    image_count = 3'd4;
    force dut.x = 10'd66;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h7EE787, "load target digit");
    force dut.x = 10'd78;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h7EE787, "load slash glyph");

    // IMAGE reports the committed image and the scanned image count.
    load_in_progress = 1'b0;
    current_image_index = 2'd3;
    force dut.x = 10'd77;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "image four digit");
    force dut.x = 10'd86;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "image slash glyph");
    force dut.x = 10'd93;
    force dut.y = 10'd460;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "image count digit");

    // The ticker moves only once for every three complete frame boundaries.
    expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000000,
               "ticker offset resets to zero");
    drive_frame_boundary;
    drive_frame_boundary;
    expect_rgb({22'd0, dut.ticker_frame_divider}, 24'h000002,
               "ticker waits for third frame");
    expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000000,
               "ticker offset holds before third frame");
    drive_frame_boundary;
    expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000001,
               "ticker advances one pixel on third frame");

    storage_ready = 1'b0;
    drive_frame_boundary;
    drive_frame_boundary;
    drive_frame_boundary;
    expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000002,
               "wait state does not reset ticker");
    storage_ready = 1'b1;

    dut.ticker_scroll_offset = 9'd439;
    dut.ticker_frame_divider = 2'd2;
    drive_frame_boundary;
    expect_rgb({15'd0, dut.ticker_scroll_offset}, 24'h000000,
               "ticker wraps after the 440-pixel period");

    // Image ownership changes are now handled before this OSD stage.  The
    // overlay must leave picture-area RGB untouched rather than injecting the
    // rejected black slide mask.
    current_image_index = 2'd3;
    @(posedge video_clk);
    current_image_index = 2'd0;
    @(posedge video_clk);
    force dut.x = 10'd100;
    force dut.y = 10'd100;
    #1;
    expect_rgb(rgb_out, 24'h123456, "image change leaves picture transparent");

    force dut.x = 10'd100;
    force dut.y = 10'd436;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "ticker remains stable after image change");
    force dut.x = 10'd8;
    force dut.y = 10'd464;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "status bar remains stable after image change");

    // -----------------------------------------------------------------------
    // 参数菜单（第13课）
    // 版面：面板 x 448..631 / y 24..59；亮度行 y 26..39、对比度行 y 44..57；
    //       标签 x 452..459；数值 x 464..487（3 位 x 8px）；
    //       进度条 x 492 起，段距 16、段宽 14，共 492..617
    // -----------------------------------------------------------------------
    menu_active = 1'b0;
    brightness_value = 8'd255;
    contrast_value = 8'd128;
    menu_channel = 2'b00;
    force dut.x = 10'd500;
    force dut.y = 10'd30;
    #1;
    expect_rgb(rgb_out, 24'h123456, "menu hidden while inactive");

    menu_active = 1'b1;
    force dut.x = 10'd450;   // 面板内、两行之间的空白处
    force dut.y = 10'd25;
    #1;
    expect_rgb(rgb_out, 24'h0B1526, "menu panel background");

    // 面板四边界
    force dut.x = 10'd447;
    force dut.y = 10'd30;
    #1;
    expect_rgb(rgb_out, 24'h123456, "one pixel left of panel is picture");
    force dut.x = 10'd448;
    #1;
    expect_rgb(rgb_out, 24'h0B1526, "panel left edge");
    force dut.x = 10'd631;
    #1;
    expect_rgb(rgb_out, 24'h0B1526, "panel right edge inside");
    force dut.x = 10'd632;
    #1;
    expect_rgb(rgb_out, 24'h123456, "one pixel right of panel is picture");
    force dut.x = 10'd500;
    force dut.y = 10'd59;
    #1;
    expect_rgb(rgb_out, 24'h0B1526, "panel bottom edge inside");
    force dut.y = 10'd60;
    #1;
    expect_rgb(rgb_out, 24'h123456, "one pixel below panel is picture");

    // ---- 进度条 ----
    menu_channel = 2'b10;   // 两行都高亮，先把条形解码单独验干净
    // 亮度 = 255：8 段全亮
    force dut.y = 10'd26;
    force dut.x = 10'd492;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "brightness segment 0 on at 255");
    force dut.x = 10'd604;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "brightness segment 7 on at 255");

    // 段间 2px 空隙露出面板底色
    force dut.x = 10'd506;
    #1;
    expect_rgb(rgb_out, 24'h0B1526, "gap between segments shows panel");

    // 阈值是 value > i*32（写成 >= 的话第 8 段要求 256，永远点不亮）
    brightness_value = 8'd224;
    force dut.x = 10'd604;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "brightness segment 7 off at 224");
    force dut.x = 10'd492;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "brightness segment 0 still on at 224");

    brightness_value = 8'd0;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "brightness all off at 0");

    brightness_value = 8'd128;
    force dut.x = 10'd540;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "brightness segment 3 on at 128");
    force dut.x = 10'd556;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "brightness segment 4 off at 128");

    // 对比度行独立解码
    contrast_value = 8'd255;
    force dut.y = 10'd44;
    force dut.x = 10'd604;
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "contrast segment 7 on at 255");
    contrast_value = 8'd0;
    #1;
    expect_rgb(rgb_out, 24'h10213A, "contrast all off at 0");

    // 非当前通道的已填充段要暗一档，这样"现在在调哪个"一眼可见
    contrast_value = 8'd255;
    menu_channel = 2'b00;    // 只高亮亮度 -> 对比度行应变暗
    force dut.y = 10'd44;
    force dut.x = 10'd604;
    #1;
    expect_rgb(rgb_out, 24'h2E6E6E, "inactive contrast bar is dimmed");
    menu_channel = 2'b01;    // 切到对比度 -> 应变亮
    #1;
    expect_rgb(rgb_out, 24'h54E3E3, "contrast bar bright when selected");
    menu_channel = 2'b10;

    // ---- 十进制读数 ----
    // 亮度 255 -> "255"：'2' row0=00111100（bit2 亮）、'5' row0=01111110（bit6 亮）
    brightness_value = 8'd255;
    force dut.x = 10'd469;
    force dut.y = 10'd26;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "hundreds digit 2 lit");
    force dut.x = 10'd473;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "tens digit 5 lit");
    force dut.x = 10'd481;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "units digit 5 lit");

    // 亮度 64 -> " 64"：百位是空格，一个像素都不画
    brightness_value = 8'd64;
    force dut.x = 10'd469;
    #1;
    expect_rgb(rgb_out, 24'h0B1526, "hundreds blank below 100");
    force dut.x = 10'd474;   // 十位 '6' row0=00111100，xoff[2:0]=2 -> bit5 亮
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "tens digit 6 lit");
    force dut.x = 10'd485;   // 个位 '4' row0=00000100，xoff[2:0]=5 -> bit2 亮
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "units digit 4 lit");

    // 对比度行读数独立：128 -> 十位 '2'
    menu_channel = 2'b01;
    contrast_value = 8'd128;
    force dut.y = 10'd44;
    force dut.x = 10'd477;   // xoff[2:0]=5 -> bit2 亮
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "contrast tens digit 2 lit");

    // ---- 标签与高亮 ----
    // 'B' row0 = 01111100（xoff=1 亮），'C' row0 = 00111100（xoff=2 亮）
    menu_channel = 2'b00;
    force dut.x = 10'd453;
    force dut.y = 10'd26;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "brightness label B highlighted");
    force dut.x = 10'd452;
    #1;
    expect_rgb(rgb_out, 24'h0B1526, "brightness label transparent pixel");

    // 高亮跟随通道
    menu_channel = 2'b01;
    force dut.x = 10'd453;
    force dut.y = 10'd26;
    #1;
    expect_rgb(rgb_out, 24'hA7C7FF, "brightness label dim when contrast selected");
    force dut.x = 10'd454;
    force dut.y = 10'd44;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "contrast label highlighted");

    // 两个一起调：两行都高亮
    menu_channel = 2'b10;
    force dut.x = 10'd453;
    force dut.y = 10'd26;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "both mode highlights brightness");
    force dut.x = 10'd454;
    force dut.y = 10'd44;
    #1;
    expect_rgb(rgb_out, 24'hFFD166, "both mode highlights contrast");

    menu_active = 1'b0;
    menu_channel = 2'b00;
    brightness_value = 8'd255;
    contrast_value = 8'd128;

    release dut.x;
    release dut.y;
    $display("PASS tb_video_osd_overlay");
    $finish;
end

endmodule
