`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// osd_font_rom -- OSD 字库，2048 x 16 bit，双口只读，同步读，1 拍延迟
//
// 内容由 tools/gen_osd_font.py 生成到 rtl/video/osd_font16.dat：
//   addr = {gid[6:0], row[3:0]}
//   gid  0..31  : 16x16 汉字（宋体点阵），bit15 = 最左像素
//   gid 32..127 : 8x16 ASCII，gid 就是 ASCII 码；字形在 bit15..8
// ASCII 码 0x20..0x7F 恰好落在 32..127，所以汉字和 ASCII 共用同一个地址公式。
//
// A 口给设置面板（osd_settings_panel），B 口给顶栏/字幕/状态栏（video_osd_overlay），
// 两口同在 video_clk。
//
// 综合：EG_LOGIC_BRAM 放进一块 32K BRAM（工程原来一块 32K 都没用；9K 只剩 13 块）。
// 仿真：iverilog 预定义 __ICARUS__，走 $readmemb 行为模型，内容与综合完全相同。
// INIT_FILE：TD 按 .v 源文件所在目录解析（实测日志 "Reading BRAM ... init file
// ..\..\rtl\video\osd_font16.dat"），所以字库文件必须和本文件放在同一目录。
// 同样内容用 $readmemb 推断会占 4 块 9K BRAM，所以这里直接例化原语。
// ---------------------------------------------------------------------------
module osd_font_rom #(
`ifdef __ICARUS__
    parameter INIT_FILE = "rtl/video/osd_font16.dat"   // iverilog 在 fpga/osd_display 下运行
`else
    parameter INIT_FILE = "osd_font16.dat"             // TD：.v 源文件同目录
`endif
)(
    input  wire        clk,
    input  wire [10:0] addr_a,
    output wire [15:0] dout_a,
    input  wire [10:0] addr_b,
    output wire [15:0] dout_b
);

`ifdef __ICARUS__
reg [15:0] mem [0:2047];
reg [15:0] qa, qb;
initial $readmemb(INIT_FILE, mem);
always @(posedge clk) begin
    qa <= mem[addr_a];
    qb <= mem[addr_b];
end
assign dout_a = qa;
assign dout_b = qb;
`else
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A (16),
    .DATA_WIDTH_B (16),
    .ADDR_WIDTH_A (11),
    .ADDR_WIDTH_B (11),
    .DATA_DEPTH_A (2048),
    .DATA_DEPTH_B (2048),
    .MODE         ("DP"),
    .REGMODE_A    ("NOREG"),
    .REGMODE_B    ("NOREG"),
    .WRITEMODE_A  ("NORMAL"),
    .WRITEMODE_B  ("NORMAL"),
    .RESETMODE    ("SYNC"),
    .INIT_FILE    (INIT_FILE),
    .FILL_ALL     ("NONE"),
    .IMPLEMENT    ("32K")
) u_bram (
    .doa   (dout_a),
    .dob   (dout_b),
    .dia   (16'd0),
    .dib   (16'd0),
    .cea   (1'b1),
    .ocea  (1'b0),
    .clka  (clk),
    .wea   (1'b0),
    .rsta  (1'b0),
    .ceb   (1'b1),
    .oceb  (1'b0),
    .clkb  (clk),
    .web   (1'b0),
    .rstb  (1'b0),
    .bea   (1'b0),
    .beb   (1'b0),
    .addra (addr_a),
    .addrb (addr_b)
);
`endif

endmodule
