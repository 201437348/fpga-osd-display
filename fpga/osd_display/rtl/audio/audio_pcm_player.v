`timescale 1ns/1ps

module audio_pcm_player #(
    parameter integer CLK_FREQ_HZ       = 25_000_000,
    parameter integer SAMPLE_RATE_HZ    = 48_000,
    parameter [9:0]  PREFILL_FRAMES     = 10'd512,
    // 提示音（单位：48 kHz 采样点）
    parameter integer BEEP_SAMPLES          = 2880,     // 按键音 60 ms，2 kHz
    parameter integer ALARM_HOLDOFF_SAMPLES = 144000    // 无卡持续 3 s 后开始输出 1 kHz 测试音（避开上电扫卡）
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire [3:0]  volume,       // 音乐音量：0 = 静音，1..8 每档 6 dB，8 = 原音量
    input  wire [3:0]  tone_volume,  // 提示音音量：同上，8 = 正弦表满幅（-9 dBFS）
    input  wire        key_down,     // 任一按键已消抖按下（sd 域电平），按下沿响一声
    input  wire        no_card,      // TF 卡未就绪（电平，异步），持续一段时间后连续输出测试音
    input  wire        fifo_empty,
    input  wire        fifo_valid,
    input  wire [9:0]  fifo_rdusedw,
    input  wire [31:0] fifo_dout,
    output reg         fifo_re,
    output reg         audio_valid,
    output reg [23:0]  audio_left_data,
    output reg [23:0]  audio_right_data
);

// 音量：算术右移 (8 - volume) 位。音乐 / 提示音各一档，互不影响，先各自衰减再混音。
// 两个音量都来自 sd_card_clk 域，变化极慢；连续两拍采到同一个值才采用，
// 避开多位总线跨域时的中间值。
reg [3:0] volume_s0, volume_s1, volume_q;
reg [3:0] tone_vol_s0, tone_vol_s1, tone_vol_q;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        volume_s0   <= 4'd8;
        volume_s1   <= 4'd8;
        volume_q    <= 4'd8;
        tone_vol_s0 <= 4'd8;
        tone_vol_s1 <= 4'd8;
        tone_vol_q  <= 4'd8;
    end else begin
        volume_s0   <= volume;
        volume_s1   <= volume_s0;
        if (volume_s0 == volume_s1)
            volume_q <= volume_s1;
        tone_vol_s0 <= tone_volume;
        tone_vol_s1 <= tone_vol_s0;
        if (tone_vol_s0 == tone_vol_s1)
            tone_vol_q <= tone_vol_s1;
    end
end

function [15:0] apply_volume;
    input [15:0] x;
    input [3:0]  v;
    begin
        case (v)
            4'd0:    apply_volume = 16'd0;
            4'd1:    apply_volume = {{7{x[15]}}, x[15:7]};
            4'd2:    apply_volume = {{6{x[15]}}, x[15:6]};
            4'd3:    apply_volume = {{5{x[15]}}, x[15:5]};
            4'd4:    apply_volume = {{4{x[15]}}, x[15:4]};
            4'd5:    apply_volume = {{3{x[15]}}, x[15:3]};
            4'd6:    apply_volume = {{2{x[15]}}, x[15:2]};
            4'd7:    apply_volume = {x[15], x[15:1]};
            default: apply_volume = x;
        endcase
    end
endfunction

// ---------------------------------------------------------------------------
// 提示音：48 点正弦表（满幅 11585 = -9 dBFS，tone_volume = 8 时），相位每个采样点走 1 格 = 1 kHz，
// 走 2 格 = 2 kHz。提示音叠加在音乐上（饱和），不停 FIFO，音画同步不受影响。
//   按键音：2 kHz，BEEP_SAMPLES 个采样；
//   测试音：无卡（没有 WAV 可播）持续 ALARM_HOLDOFF_SAMPLES 后，连续输出 48 kHz 采样的
//           1 kHz 正弦（赛题基础要求 3 的 HDMI 音频测试音），插卡后立即停止。
// key_down / no_card 都是慢变电平，2FF 同步后使用。
// ---------------------------------------------------------------------------
function [13:0] sine_q;          // sin(2*pi*i/48) * 11585，i = 0..12
    input [3:0] i;
    begin
        case (i)
            4'd0:    sine_q = 14'd0;
            4'd1:    sine_q = 14'd1512;
            4'd2:    sine_q = 14'd2998;
            4'd3:    sine_q = 14'd4433;
            4'd4:    sine_q = 14'd5792;
            4'd5:    sine_q = 14'd7053;
            4'd6:    sine_q = 14'd8192;
            4'd7:    sine_q = 14'd9191;
            4'd8:    sine_q = 14'd10033;
            4'd9:    sine_q = 14'd10703;
            4'd10:   sine_q = 14'd11190;
            4'd11:   sine_q = 14'd11486;
            default: sine_q = 14'd11585;
        endcase
    end
endfunction

function [15:0] sine48;
    input [5:0] p;               // 0..47
    reg   [5:0] i;
    begin
        if (p < 6'd12)       i = p;
        else if (p < 6'd24)  i = 6'd24 - p;
        else if (p < 6'd36)  i = p - 6'd24;
        else                 i = 6'd48 - p;
        sine48 = {2'b00, sine_q(i[3:0])};
        if (p >= 6'd24)
            sine48 = -sine48;
    end
endfunction

function [15:0] sat_add;
    input [15:0] a;
    input [15:0] b;
    reg   [16:0] sum;
    begin
        sum = {a[15], a} + {b[15], b};
        if (sum[16] != sum[15])
            sat_add = sum[16] ? 16'h8000 : 16'h7FFF;
        else
            sat_add = sum[15:0];
    end
endfunction

localparam integer BEEP_W  = $clog2(BEEP_SAMPLES + 1);
localparam integer HOLD_W  = $clog2(ALARM_HOLDOFF_SAMPLES + 1);

reg               key_s0, key_s1, key_s2;
reg               card_s0, card_s1;
reg [BEEP_W-1:0]  beep_left;
reg [HOLD_W-1:0]  nocard_hold;
reg [5:0]         tone_phase;
reg [15:0]        tone_sample;

wire       beep_on     = (beep_left != {BEEP_W{1'b0}});
wire       alarm_armed = (nocard_hold == ALARM_HOLDOFF_SAMPLES);
wire       alarm_on    = alarm_armed;   // 连续测试音
wire [6:0] tone_phase_sum = {1'b0, tone_phase} + (beep_on ? 7'd2 : 7'd1);

// ---------------------------------------------------------------------------
// 第 1 级：48 kHz 采样节拍、FIFO 读取、提示音采样；第 2 级：各自音量 + 混音。
// 输出比原来晚 1 个 clk，采样节拍不变。
// ---------------------------------------------------------------------------
reg [31:0] sample_phase;
reg        playback_active;
reg        pcm_valid;
reg [15:0] pcm_left;
reg [15:0] pcm_right;
wire       sample_tick = (sample_phase >= (CLK_FREQ_HZ - SAMPLE_RATE_HZ));

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_s0      <= 1'b0;
        key_s1      <= 1'b0;
        key_s2      <= 1'b0;
        card_s0     <= 1'b0;
        card_s1     <= 1'b0;
        beep_left   <= {BEEP_W{1'b0}};
        nocard_hold <= {HOLD_W{1'b0}};
        tone_phase  <= 6'd0;
        tone_sample <= 16'd0;
    end else begin
        key_s0  <= key_down;
        key_s1  <= key_s0;
        key_s2  <= key_s1;
        card_s0 <= no_card;
        card_s1 <= card_s0;

        if (key_s1 && !key_s2) begin
            beep_left  <= BEEP_SAMPLES;
            tone_phase <= 6'd0;
        end else if (sample_tick) begin
            if (beep_on)
                beep_left <= beep_left - 1'b1;

            if (!card_s1)
                nocard_hold <= {HOLD_W{1'b0}};
            else if (!alarm_armed)
                nocard_hold <= nocard_hold + 1'b1;

            if (beep_on || alarm_on) begin
                tone_sample <= sine48(tone_phase);
                tone_phase  <= (tone_phase_sum >= 7'd48) ? tone_phase_sum - 7'd48
                                                         : tone_phase_sum[5:0];
            end else begin
                tone_sample <= 16'd0;
                tone_phase  <= 6'd0;
            end
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sample_phase    <= 32'd0;
        playback_active <= 1'b0;
        fifo_re         <= 1'b0;
        pcm_valid       <= 1'b0;
        pcm_left        <= 16'd0;
        pcm_right       <= 16'd0;
    end else begin
        fifo_re   <= 1'b0;
        pcm_valid <= 1'b0;

        if (sample_tick) begin
            sample_phase <= sample_phase + SAMPLE_RATE_HZ - CLK_FREQ_HZ;
            pcm_valid    <= 1'b1;

            if (!enable) begin
                playback_active <= 1'b0;
                pcm_left        <= 16'd0;
                pcm_right       <= 16'd0;
            end else if (!playback_active) begin
                if (fifo_valid && (fifo_rdusedw >= PREFILL_FRAMES))
                    playback_active <= 1'b1;
                pcm_left  <= 16'd0;
                pcm_right <= 16'd0;
            end else if (!fifo_empty && fifo_valid) begin
                fifo_re   <= 1'b1;
                pcm_left  <= fifo_dout[31:16];
                pcm_right <= fifo_dout[15:0];
            end else begin
                playback_active <= 1'b0;
                pcm_left        <= 16'd0;
                pcm_right       <= 16'd0;
            end
        end else begin
            sample_phase <= sample_phase + SAMPLE_RATE_HZ;
        end
    end
end

// HDMI/I2S PCM samples are left-justified in the 24-bit interface. Scale the
// 16-bit media sample to that format by appending eight zero LSBs; sign
// extension would attenuate the signal by 48 dB.
// tone_sample 与 pcm_* 在同一个 sample_tick 更新，这里同拍混合。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        audio_valid      <= 1'b0;
        audio_left_data  <= 24'd0;
        audio_right_data <= 24'd0;
    end else begin
        audio_valid <= pcm_valid;
        if (pcm_valid) begin
            audio_left_data  <= {sat_add(apply_volume(pcm_left,  volume_q),
                                         apply_volume(tone_sample, tone_vol_q)), 8'd0};
            audio_right_data <= {sat_add(apply_volume(pcm_right, volume_q),
                                         apply_volume(tone_sample, tone_vol_q)), 8'd0};
        end
    end
end

endmodule
