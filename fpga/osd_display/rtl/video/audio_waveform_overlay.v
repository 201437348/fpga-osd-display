// ============================================================================
// audio_waveform_overlay
// 音频可视化：32 点时域波形 + 峰值条（参考第十二讲 promax_audio_waveform）。
//
//   * 每帧采 SAMPLE_COUNT 个样本（每 DECIMATE 个音频样本取 1 个），
//     取 pcm 高 8 位（有符号），同时记录本帧 |sample| 峰值；
//   * ping-pong 两组样本：写满的那组在下一帧起始整组切换去显示，
//     显示期间不会被改写 -> 波形不撕裂；
//   * 波形：sample_y = CENTER_Y - sample/4，线宽 3 行；每段起始列画一条
//     竖线连到上一个样本，波形是连续折线而不是断开的台阶；
//   * 峰值条：波形右侧 8 像素宽，高度 = peak/2（满幅 128 -> 64 行）。
//
// 与 video_osd_overlay 一样用 vs 上升沿作帧起始、de 计数 x/y，纯组合输出，
// 0 拍延迟，de/vs 不需要重新对齐。只覆盖亮起的像素，其余透明（图片可见）。
// 与参考实现的区别：SPACING 固定为 2 的幂（移位代替除法）、加了折线连接、
// 峰值条满量程改为 H。
// ============================================================================
module audio_waveform_overlay #(
    parameter integer WAVE_X      = 64,
    parameter integer WAVE_Y      = 360,
    parameter integer WAVE_WIDTH  = 512,   // = SAMPLE_COUNT * 16
    parameter integer WAVE_HEIGHT = 64,
    parameter integer DECIMATE    = 12
) (
    input  wire        video_clk,
    input  wire        rst,
    input  wire        vs,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        enable,
    input  wire        audio_valid,       // video_clk 域，每个音频样本 1 拍
    input  wire [23:0] audio_left_data,   // {pcm[15:0], 8'd0}
    output wire [23:0] rgb_out
);

localparam integer SAMPLE_COUNT = 32;
localparam integer SPACING_LOG2 = 4;                 // 512 / 32 = 16
localparam integer CENTER_Y     = WAVE_Y + WAVE_HEIGHT / 2;
localparam integer PEAK_X0      = WAVE_X + WAVE_WIDTH + 8;
localparam integer PEAK_X1      = WAVE_X + WAVE_WIDTH + 16;

localparam [23:0] WAVE_RGB = 24'h20FF90;
localparam [23:0] PEAK_RGB = 24'hFFB020;
localparam [23:0] AXIS_RGB = 24'h406060;

// ---------------------------------------------------------------------------
// 像素坐标（与 video_osd_overlay 完全相同的计数方式）
// ---------------------------------------------------------------------------
reg [9:0] x, y;
reg       de_d, vs_d;
wire      frame_start = vs && !vs_d;

// ---------------------------------------------------------------------------
// 采样：ping-pong
// ---------------------------------------------------------------------------
reg [7:0] bank0 [0:SAMPLE_COUNT-1];
reg [7:0] bank1 [0:SAMPLE_COUNT-1];
reg       write_bank;
reg       display_bank;
reg       display_valid;
reg [5:0] capture_count;
reg [7:0] decimate_count;
reg [7:0] peak_w;                  // 正在采集那组的峰值
reg [7:0] display_peak;

wire [7:0] sample_s   = audio_left_data[23:16];
wire [7:0] sample_abs = sample_s[7] ? (~sample_s + 8'd1) : sample_s;  // -128 -> 128

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        x              <= 10'd0;
        y              <= 10'd0;
        de_d           <= 1'b0;
        vs_d           <= 1'b0;
        write_bank     <= 1'b0;
        display_bank   <= 1'b1;
        display_valid  <= 1'b0;
        capture_count  <= 6'd0;
        decimate_count <= 8'd0;
        peak_w         <= 8'd0;
        display_peak   <= 8'd0;
    end else begin
        de_d <= de;
        vs_d <= vs;

        if (frame_start) begin
            x <= 10'd0;
            y <= 10'd0;
        end else if (de) begin
            x <= x + 10'd1;
        end else if (de_d) begin
            x <= 10'd0;
            y <= y + 10'd1;
        end

        if (frame_start) begin
            if (capture_count == SAMPLE_COUNT) begin
                display_bank  <= write_bank;
                display_valid <= 1'b1;
                display_peak  <= peak_w;
                write_bank    <= ~write_bank;
            end
            capture_count  <= 6'd0;
            decimate_count <= 8'd0;
            peak_w         <= 8'd0;
        end else if (audio_valid && capture_count < SAMPLE_COUNT) begin
            if (decimate_count == 8'd0) begin
                capture_count  <= capture_count + 6'd1;
                decimate_count <= DECIMATE - 1;
                if (sample_abs > peak_w)
                    peak_w <= sample_abs;
            end else begin
                decimate_count <= decimate_count - 8'd1;
            end
        end
    end
end

// 样本存储单独成块（无复位），便于综合成分布式 RAM
always @(posedge video_clk) begin
    if (!frame_start && audio_valid && capture_count < SAMPLE_COUNT &&
        decimate_count == 8'd0) begin
        if (write_bank)
            bank1[capture_count[4:0]] <= sample_s;
        else
            bank0[capture_count[4:0]] <= sample_s;
    end
end

// ---------------------------------------------------------------------------
// 绘制（组合）
// ---------------------------------------------------------------------------
wire [9:0] wx       = x - WAVE_X[9:0];
wire [4:0] s_idx    = wx[SPACING_LOG2 +: 5];
wire [4:0] s_prev   = s_idx - 5'd1;
wire       seg_head = (wx[SPACING_LOG2-1:0] == 0) && (s_idx != 5'd0);

wire in_wave = (x >= WAVE_X) && (x < WAVE_X + WAVE_WIDTH) &&
               (y >= WAVE_Y) && (y < WAVE_Y + WAVE_HEIGHT);
wire in_peak_col = (x >= PEAK_X0) && (x < PEAK_X1);

wire [7:0] cur_s  = display_bank ? bank1[s_idx]  : bank0[s_idx];
wire [7:0] prev_s = display_bank ? bank1[s_prev] : bank0[s_prev];

// sample/4 取算术右移，范围 -32..31；y 用 11 位有符号比较
wire signed [10:0] y_s     = {1'b0, y};
wire signed [10:0] cur_y   = CENTER_Y - {{5{cur_s[7]}},  cur_s[7:2]};
wire signed [10:0] prev_y  = CENTER_Y - {{5{prev_s[7]}}, prev_s[7:2]};
wire signed [10:0] lo_y    = seg_head ? ((cur_y < prev_y) ? cur_y : prev_y) : cur_y;
wire signed [10:0] hi_y    = seg_head ? ((cur_y < prev_y) ? prev_y : cur_y) : cur_y;

wire wave_pixel = enable && de && in_wave && display_valid &&
                  (y_s >= lo_y - 11'sd1) && (y_s <= hi_y + 11'sd1);
wire axis_pixel = enable && de && in_wave && (y == CENTER_Y);

wire [7:0] peak_h = display_peak >> 1;             // 0..64
wire peak_pixel = enable && de && in_peak_col && display_valid &&
                  (y <  WAVE_Y + WAVE_HEIGHT) &&
                  ({1'b0, y} + {3'd0, peak_h} >= WAVE_Y + WAVE_HEIGHT);

assign rgb_out = wave_pixel ? WAVE_RGB :
                 peak_pixel ? PEAK_RGB :
                 axis_pixel ? AXIS_RGB : rgb_in;

endmodule
