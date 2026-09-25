
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       key3,           // 亮度/对比度：短按 +步长，长按 -步长
    input  [3:0]                sw,             // SW1..SW4，低有效（PULLUP，合上=0）

	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
// 多槽缓存（第8课）：6 个槽 x 307200 字 = 1,843,200 字，SDRAM 共 2M 字（21 位地址）
parameter BUF2_ADDR     = FRAME_PIXELS * 2;
parameter BUF3_ADDR     = FRAME_PIXELS * 3;
parameter BUF4_ADDR     = FRAME_PIXELS * 4;
parameter BUF5_ADDR     = FRAME_PIXELS * 5;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] vout_data_osd;
wire        display_valid;
wire        display_valid_sd;
wire        display_test_pattern_sd;
wire        display_test_pattern;
wire [23:0] fallback_rgb;

wire [3:0]  state_code;
wire [3:0]  seg_digit_s;
wire [3:0]  seg_digit_c;
wire [3:0]  seg_digit_l;
wire [3:0]  seg_digit_r;
wire [3:0]  seg_digit_w;
wire [3:0]  seg_digit_x;
wire [6:0]  seg_decode_s;
wire [6:0]  seg_decode_c;
wire [6:0]  seg_decode_l;
wire [6:0]  seg_decode_r;
wire [6:0]  seg_decode_w;
wire [6:0]  seg_decode_x;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;
wire        video_read_data_valid;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_fifo_afull;
wire        frame_write_finish;
// 上板诊断总线（来自 image_storage_adapter，只读）
wire [3:0]  load_diag_state;
wire [3:0]  load_diag_sector;
wire [3:0]  load_diag_flags;
reg         frame_write_toggle_mem;
reg [2:0]   frame_write_toggle_sync;
wire        frame_write_done_pulse;

wire [2:0]  write_buf_idx;       // 槽号 0..5
wire [2:0]  disp_buf_idx_sd;
wire [2:0]  current_image_index_sd;
reg [2:0]   disp_buf_idx_video_meta;
reg [2:0]   disp_buf_idx_video_prev;
reg [2:0]   disp_buf_idx_video_sync;
wire [2:0]  active_buffer_index;
wire [2:0]  slide_old_buffer_index;
wire [2:0]  slide_new_buffer_index;
wire        slide_active;
wire [9:0]  slide_position;
wire        transition_busy;
wire        frame_read_fault;
wire [3:0]  frame_read_fifo_underflow_count_per_frame;
reg [1:0]   frame_read_fault_video_sync;
reg [3:0]   read_underflow_count_meta;
reg [3:0]   read_underflow_count_sd_sync;
reg [3:0]   axis_backpressure_count_meta;
reg [3:0]   axis_backpressure_count_sd_sync;
reg [1:0]   transition_busy_sd_sync;
reg [2:0]   active_buf_sd_meta;
reg [2:0]   active_buf_sd_prev;
reg [2:0]   active_buf_sd_sync;
wire        playback_manager_idle;
wire        display_settled_sd;
wire        manager_commit_pulse;
wire        manager_preloading;
reg         display_valid_video_meta;
reg         display_valid_video_sync;
reg         display_test_pattern_video_meta;
reg         display_test_pattern_video_sync;
wire [14:0] osd_status_sd;
reg [14:0]  osd_status_video_meta;
reg [14:0]  osd_status_video_sync;
wire        osd_storage_ready;
wire [2:0]  osd_manager_state;
wire        osd_load_in_progress;
wire [2:0]  osd_target_image_index;
wire [2:0]  osd_current_image_index;
wire [3:0]  osd_image_count;

wire        storage_ready;
wire        scan_done;
wire [3:0]  scan_found_count;
wire        source_done_pulse;
wire        source_error_pulse;
wire        load_progress_pulse;
wire        storage_fault_pulse;
wire        scan_start;
wire        load_start;
wire        load_abort;
wire        storage_reinit;
wire [2:0]  target_image_index;
wire [3:0]  storage_state_code;
wire [2:0]  manager_state;
wire [1:0]  retry_count;
wire [3:0]  error_code;
wire        pending_next;
wire        source_done_seen;
wire        write_done_seen;
wire [3:0]  image_count;
wire        load_in_progress;
wire        manager_idle;
wire        next_request;
wire        prev_request;
wire        auto_request;
wire        auto_play_enabled;
wire [2:0]  auto_period_sec;
wire [3:0]  cfg_volume;

wire        audio_fifo_wr_en;
wire [31:0] audio_fifo_wr_data;
wire [9:0]  audio_fifo_wrusedw;
wire        audio_fifo_full;
wire        audio_fifo_rst;
wire        audio_fifo_re;
wire [31:0] audio_fifo_dout;
wire        audio_fifo_valid;
wire        audio_fifo_empty;
wire [9:0]  audio_fifo_rdusedw;
wire        hdmi_audio_valid;
wire [23:0] hdmi_audio_left_data;
wire [23:0] hdmi_audio_right_data;
wire        hdmi_acr_valid;
wire [19:0] hdmi_acr_cts;
wire [19:0] hdmi_acr_n;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;
wire [3:0]  axis_backpressure_count;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

always @(posedge clk) begin
    if (!rst_n) begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end else if (!rst_all_reg) begin
        // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
        rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = rst_all_reg;

// 每个时钟域一份复位：rst_all 到来立即异步置位，撤销时在本域时钟沿上
// 经两级寄存器同步释放（第六讲 reset_sync 思路，高有效版本）。
// 单时钟域模块全部改用本域复位，消除 clk(50M) -> 各域的恢复时间违例；
// frame_read_write / 音频 FIFO / HDMI PHY 这类多时钟模块仍用 rst_all，
// 其释放路径在 SDC 里 false_path（只在上电时发生一次，之后长时间空闲）。
reg [1:0] rst_sd_sr  = 2'b11;
reg [1:0] rst_mem_sr = 2'b11;
reg [1:0] rst_vid_sr = 2'b11;

always @(posedge sd_card_clk or posedge rst_all)
    if (rst_all) rst_sd_sr  <= 2'b11; else rst_sd_sr  <= {rst_sd_sr[0],  1'b0};
always @(posedge ext_mem_clk or posedge rst_all)
    if (rst_all) rst_mem_sr <= 2'b11; else rst_mem_sr <= {rst_mem_sr[0], 1'b0};
always @(posedge video_clk or posedge rst_all)
    if (rst_all) rst_vid_sr <= 2'b11; else rst_vid_sr <= {rst_vid_sr[0], 1'b0};

wire rst_sd  = rst_sd_sr[1];
wire rst_mem = rst_mem_sr[1];
wire rst_vid = rst_vid_sr[1];

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd)
        frame_write_toggle_sync <= 3'b000;
    else
        frame_write_toggle_sync <= {frame_write_toggle_sync[1:0], frame_write_toggle_mem};
end

assign frame_write_done_pulse = frame_write_toggle_sync[2] ^ frame_write_toggle_sync[1];

// 当前显示图片的源尺寸/缩放比（sd_card_clk 域，给 OSD 信息行）
// 加载完成时 adapter 给出这张图的信息；有了预加载，完成的图不一定马上显示，
// 所以按写入槽号存表，display 真正切到某个槽（commit_pulse）时再取出。
wire [15:0] loaded_img_width;
wire [15:0] loaded_img_height;
wire [15:0] loaded_scale_x100;
wire        loaded_info_pulse;
reg  [47:0] slot_info [0:5];
reg  [15:0] shown_img_width;
reg  [15:0] shown_img_height;
reg  [15:0] shown_scale_x100;
reg         shown_info_toggle;
integer     slot_info_i;

always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        for (slot_info_i = 0; slot_info_i < 6; slot_info_i = slot_info_i + 1)
            slot_info[slot_info_i] <= 48'd0;
        shown_img_width   <= 16'd0;
        shown_img_height  <= 16'd0;
        shown_scale_x100  <= 16'd0;
        shown_info_toggle <= 1'b0;
    end else begin
        if (loaded_info_pulse)
            slot_info[write_buf_idx] <= {loaded_img_width, loaded_img_height,
                                         loaded_scale_x100};
        // commit_pulse 与新的 disp_buf_idx_sd 同拍出现
        if (manager_commit_pulse) begin
            {shown_img_width, shown_img_height, shown_scale_x100} <=
                slot_info[disp_buf_idx_sd];
            shown_info_toggle <= ~shown_info_toggle;
        end
    end
end

image_storage_adapter #(
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (4'd6)   // 最多 6 张 = 缓存槽数，读完一轮后全部常驻 SDRAM
) image_storage_adapter_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .scan_start        (scan_start),
    .load_start        (load_start),
    .load_abort        (load_abort),
    .storage_reinit    (storage_reinit),
    .target_image_index(target_image_index),
    .storage_ready     (storage_ready),
    .scan_done         (scan_done),
    .scan_found_count  (scan_found_count),
    .load_progress_pulse(load_progress_pulse),
    .source_done_pulse (source_done_pulse),
    .source_error_pulse(source_error_pulse),
    .storage_fault_pulse(storage_fault_pulse),
    .state_code        (storage_state_code),
    .shown_img_width   (loaded_img_width),
    .shown_img_height  (loaded_img_height),
    .shown_scale_x100  (loaded_scale_x100),
    .shown_info_pulse  (loaded_info_pulse),
    .load_diag_state   (load_diag_state),
    .load_diag_sector  (load_diag_sector),
    .load_diag_flags   (load_diag_flags),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_fifo_afull  (frame_write_fifo_afull),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .audio_fifo_wr_en  (audio_fifo_wr_en),
    .audio_fifo_wr_data(audio_fifo_wr_data),
    .audio_fifo_wrusedw(audio_fifo_wrusedw),
    .audio_fifo_full   (audio_fifo_full),
    .audio_fifo_rst    (audio_fifo_rst),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

// BGM.WAV crosses from the TF clock to the HDMI pixel clock through the
// generated asynchronous FIFO.  Show-ahead mode lets each sample pulse use
// the current PCM frame while advancing the FIFO for the following pulse.
wfifo_32_32_512 #(
    .DATA_WIDTH_W  (32),
    .DATA_WIDTH_R  (32),
    .ADDR_WIDTH_W  (10),
    .ADDR_WIDTH_R  (10),
    .AL_FULL_NUM   (10'd980),
    .AL_EMPTY_NUM  (11'd2),
    .SHOW_AHEAD_EN (1'b1),
    .OUTREG_EN     ("NOREG")
) u_audio_async_fifo (
    .rst        (audio_fifo_rst),
    .clkw       (sd_card_clk),
    .clkr       (video_clk),
    .we         (audio_fifo_wr_en),
    .di         (audio_fifo_wr_data),
    .re         (audio_fifo_re),
    .dout       (audio_fifo_dout),
    .valid      (audio_fifo_valid),
    .full_flag  (audio_fifo_full),
    .empty_flag (audio_fifo_empty),
    .afull      (),
    .aempty     (),
    .wrusedw    (audio_fifo_wrusedw),
    .rdusedw    (audio_fifo_rdusedw)
);

audio_pcm_player u_audio_pcm_player (
    .clk              (video_clk),
    .rst              (rst_vid),
    .enable           (display_valid),
    .volume           (cfg_volume),       // sd 域慢变量，模块内两次采样一致才用
    .fifo_empty       (audio_fifo_empty),
    .fifo_valid       (audio_fifo_valid),
    .fifo_rdusedw     (audio_fifo_rdusedw),
    .fifo_dout        (audio_fifo_dout),
    .fifo_re          (audio_fifo_re),
    .audio_valid      (hdmi_audio_valid),
    .audio_left_data  (hdmi_audio_left_data),
    .audio_right_data (hdmi_audio_right_data)
);

hdmi_audio_acr u_hdmi_audio_acr (
    .clk          (video_clk),
    .rst          (rst_vid),
    .audio_valid  (hdmi_audio_valid),
    .acr_valid    (hdmi_acr_valid),
    .acr_cts      (hdmi_acr_cts),
    .acr_n        (hdmi_acr_n)
);

image_load_manager #(
    .CLK_FREQ_HZ          (100_000_000),
    .LOAD_TIMEOUT_SECONDS (10),
    .MAX_LOAD_RETRIES     (2)
) image_load_manager_m0(
    .clk                  (sd_card_clk),
    .rst                  (rst_sd),
    .storage_ready        (storage_ready),
    .scan_done            (scan_done),
    .scan_found_count     (scan_found_count),
    .source_done_pulse    (source_done_pulse),
    .source_error_pulse   (source_error_pulse),
    .load_progress_pulse  (load_progress_pulse),
    .storage_fault_pulse  (storage_fault_pulse),
    .write_done_pulse     (frame_write_done_pulse),
    .next_request         (next_request),
    .auto_request         (auto_request),
    .prev_request         (prev_request),
    .display_settled      (display_settled_sd),
    .scan_start           (scan_start),
    .load_start           (load_start),
    .load_abort           (load_abort),
    .storage_reinit       (storage_reinit),
    .target_image_index   (target_image_index),
    .write_buffer_index   (write_buf_idx),
    .display_buffer_index (disp_buf_idx_sd),
    .current_image_index  (current_image_index_sd),
    .display_valid        (display_valid_sd),
    .display_test_pattern (display_test_pattern_sd),
    .state                (manager_state),
    .retry_count          (retry_count),
    .error_code           (error_code),
    .pending_next         (pending_next),
    .source_done_seen     (source_done_seen),
    .write_done_seen      (write_done_seen),
    .image_count          (image_count),
    .load_in_progress     (load_in_progress),
    .idle                 (manager_idle),
    .commit_pulse         (manager_commit_pulse),
    .preloading           (manager_preloading)
);

image_playback_control #(
    .CLK_FREQ_HZ           (100_000_000),
    .AUTO_INTERVAL_SECONDS (3)   // 上电默认 3 s；长按 KEY2 在 1/2/3/5 s 间循环
) image_playback_control_m0(
    .clk                   (sd_card_clk),
    .rst                   (rst_sd),
    .key_next              (key1),
    .key_auto              (key2),
    .display_valid         (display_valid_sd),
    .image_count           (image_count),
    .manager_idle          (playback_manager_idle),
    .next_request          (next_request),
    .prev_request          (prev_request),
    .auto_request          (auto_request),
    .auto_play_enabled     (auto_play_enabled),
    .auto_period_sec       (auto_period_sec)
);

// ---------------------------------------------------------------------------
// 亮度/对比度参数菜单（第13课）—— 控制域 sd_card_clk (100 MHz)
//
// 拨码开关极性，依据《HX4S20开发板手册-HDL版2410.pdf》2.19 节原文：
//   "SW1-SW4 作为与FPGA的IO输入信号，拨上为'1'，拨下为'0'"
//   同节引脚表：SW1=C8  SW2=C7  SW3=C6  SW4=C5
// 即引脚电平本身就是逻辑值，不做取反：sw_act[i] = 1 表示第 i 个开关拨上。
// （早期版本按 PULLUP 推断成"合上=0"并取了反，方向与手册相反，已修正。）
// ---------------------------------------------------------------------------
wire [3:0] sw_act = sw;

wire [7:0] cfg_brightness;
wire [7:0] cfg_contrast;
wire [1:0] cfg_menu_channel;
wire       cfg_menu_active;
wire       cfg_toggle_sd;

param_menu_controller #(
    .CLK_FREQ_HZ   (100_000_000),
    .DEBOUNCE_MS   (20),
    .LONG_PRESS_MS (1000),
    .MENU_HOLD_MS  (5000)
) param_menu_controller_m0(
    .clk           (sd_card_clk),
    .rst           (rst_sd),
    .key           (key3),
    .sw            (sw_act),
    .brightness    (cfg_brightness),
    .contrast      (cfg_contrast),
    .menu_channel  (cfg_menu_channel),
    .menu_active   (cfg_menu_active),
    .cfg_toggle    (cfg_toggle_sd),
    .volume        (cfg_volume)
);

// Hold new playback requests while the video-domain fade owns the display
// handoff.  The image manager remains unchanged, preserving TF recovery and
// load-state behavior.
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        transition_busy_sd_sync <= 2'b00;
        active_buf_sd_meta      <= 3'b000;
        active_buf_sd_prev      <= 3'b000;
        active_buf_sd_sync      <= 3'b000;
    end else begin
        transition_busy_sd_sync <= {transition_busy_sd_sync[0], transition_busy};
        // 多槽缓存后槽号可能两位同时变（如 1->2），跨域采样可能拿到混合值；
        // 源端每次变化后都保持很久，所以只接受连续两拍相同的采样。
        active_buf_sd_meta      <= active_buffer_index;
        active_buf_sd_prev      <= active_buf_sd_meta;
        if (active_buf_sd_prev == active_buf_sd_meta)
            active_buf_sd_sync  <= active_buf_sd_prev;
    end
end

// commit 之后到 transition_busy 在本域可见之间有一帧以上的空窗；
// 这时放行按键会立刻开始下一张的加载，写进正在被滑出的旧缓冲区。
// 所以还要求视频域已经真正切到了 commit 的缓冲区。
assign display_settled_sd    = !transition_busy_sd_sync[1] &&
                               (active_buf_sd_sync == disp_buf_idx_sd);
assign playback_manager_idle = manager_idle && display_settled_sd;

// Diagnostic only: surfaces frame_read_write's per-frame read-FIFO-empty
// episode count (video_delay.read_en has no empty gating, so an underflow
// shows up as raw FIFO data on screen). The value updates once per video
// frame (~16.8ms) and holds steady for the whole next frame, so unlike a
// forever-sticky counter it shows whether the SAME high count recurs every
// single frame (a chronic per-frame throughput problem) or only appears
// for the first frame or two after the image commits (a one-time startup
// transient) -- watch it over several seconds, not just its first value.
// A plain double-register sync of the whole bus, matching this file's
// existing multi-bit diagnostic buses (disp_buf_idx_video_sync,
// osd_status_video_sync) — acceptable here because the value only changes
// once per frame, and a transient wrong digit during a rare crossing is
// harmless for a board-visible diagnostic.
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        read_underflow_count_meta    <= 4'd0;
        read_underflow_count_sd_sync <= 4'd0;
        axis_backpressure_count_meta    <= 4'd0;
        axis_backpressure_count_sd_sync <= 4'd0;
    end else begin
        read_underflow_count_meta    <= frame_read_fifo_underflow_count_per_frame;
        read_underflow_count_sd_sync <= read_underflow_count_meta;
        axis_backpressure_count_meta    <= axis_backpressure_count;
        axis_backpressure_count_sd_sync <= axis_backpressure_count_meta;
    end
end

// Sdr_init_done 来自 ext_mem_clk(125MHz) 域，数码管诊断要跨域读，先同步两拍，
// 免得给布局布线新增一条跨时钟的组合路径。
reg [1:0] sdr_init_done_sd_sync;

always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd)
        sdr_init_done_sd_sync <= 2'b00;
    else
        sdr_init_done_sd_sync <= {sdr_init_done_sd_sync[0], Sdr_init_done};
end

assign state_code = {1'b0, manager_state};
assign seg_digit_s = state_code;
// ---- 上板诊断：加载/校验期间（load_in_progress）借用 C/L/W 三位 ----
//   C = fat32_bmp_loader 状态码（5 = 卡在 ST_WRITE_WAIT，等 write_req_ack；
//       8 = STREAM_WAIT 正常在收数据；9 = STREAM_PAUSE 被反压挂住）
//   L = 已读完扇区数的低 4 位（在跳 = 有进度，冻结 = 卡死）
//   W = {write_req_ack, Sdr_init_done, 缩放器 out_stall, 缩放器输入 FIFO afull}
// 正常显示（非加载期）时这三位含义不变，仍然可读 image_count / 加载中 / 写完成。
assign seg_digit_c = load_in_progress ? load_diag_state : image_count;
assign seg_digit_l = load_in_progress ? load_diag_sector : {3'b000, load_in_progress};
assign seg_digit_r = {3'b000, source_done_seen};
assign seg_digit_w = load_in_progress ?
                     {load_diag_flags[3], sdr_init_done_sd_sync[1],
                      load_diag_flags[1], load_diag_flags[0]} :
                     {3'b000, write_done_seen};
assign seg_digit_x = (read_underflow_count_sd_sync != 4'd0) ?
                     read_underflow_count_sd_sync : error_code;

seg_decoder seg_decoder_s(
    .bin_data          (seg_digit_s),
    .seg_data          (seg_decode_s)
);

seg_decoder seg_decoder_c(
    .bin_data          (seg_digit_c),
    .seg_data          (seg_decode_c)
);

seg_decoder seg_decoder_l(
    .bin_data          (seg_digit_l),
    .seg_data          (seg_decode_l)
);

seg_decoder seg_decoder_r(
    .bin_data          (seg_digit_r),
    .seg_data          (seg_decode_r)
);

seg_decoder seg_decoder_w(
    .bin_data          (seg_digit_w),
    .seg_data          (seg_decode_w)
);

seg_decoder seg_decoder_x(
    .bin_data          (seg_digit_x),
    .seg_data          (seg_decode_x)
);

// ---- 数码管分页（sd_card_clk 域算好后寄存，seg_scan 只是慢速扫描显示）----
//   参数页：KEY3/拨码操作后 5 秒内（cfg_menu_active）
//       亮度/对比度档： b H L C H L   （十六进制，如 b F F C 8 0）
//       11 档（音量）：  U _ _ _ _ v   （v = 0..8）
//   诊断页：sw = 1011 时（原来的 S C L R W X 六位诊断）
//   播放页：其余情况   n N _ P _ v
//       n = 当前第几张（1 起），N = 总张数，P = 自动间隔秒数（自动关时显示 -），
//       v = 音量；出错时第 3、5 位显示 E 和错误码
localparam [6:0] SEG_BLANK = 7'b111_1111;
localparam [6:0] SEG_DASH  = 7'b011_1111;
localparam [6:0] SEG_U     = 7'b100_0001;

function [6:0] seg_hex;
    input [3:0] v;
    begin
        case (v)
            4'h0: seg_hex = 7'b100_0000;
            4'h1: seg_hex = 7'b111_1001;
            4'h2: seg_hex = 7'b010_0100;
            4'h3: seg_hex = 7'b011_0000;
            4'h4: seg_hex = 7'b001_1001;
            4'h5: seg_hex = 7'b001_0010;
            4'h6: seg_hex = 7'b000_0010;
            4'h7: seg_hex = 7'b111_1000;
            4'h8: seg_hex = 7'b000_0000;
            4'h9: seg_hex = 7'b001_0000;
            4'ha: seg_hex = 7'b000_1000;
            4'hb: seg_hex = 7'b000_0011;
            4'hc: seg_hex = 7'b100_0110;
            4'hd: seg_hex = 7'b010_0001;
            4'he: seg_hex = 7'b000_0110;
            default: seg_hex = 7'b000_1110;
        endcase
    end
endfunction

reg [6:0] seg_page_0, seg_page_1, seg_page_2, seg_page_3, seg_page_4, seg_page_5;

always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        seg_page_0 <= SEG_BLANK; seg_page_1 <= SEG_BLANK; seg_page_2 <= SEG_BLANK;
        seg_page_3 <= SEG_BLANK; seg_page_4 <= SEG_BLANK; seg_page_5 <= SEG_BLANK;
    end else if (cfg_menu_active && (cfg_menu_channel == 2'b11)) begin
        seg_page_0 <= SEG_U;     seg_page_1 <= SEG_BLANK; seg_page_2 <= SEG_BLANK;
        seg_page_3 <= SEG_BLANK; seg_page_4 <= SEG_BLANK; seg_page_5 <= seg_hex(cfg_volume);
    end else if (cfg_menu_active) begin
        seg_page_0 <= seg_hex(4'hb);
        seg_page_1 <= seg_hex(cfg_brightness[7:4]);
        seg_page_2 <= seg_hex(cfg_brightness[3:0]);
        seg_page_3 <= seg_hex(4'hc);
        seg_page_4 <= seg_hex(cfg_contrast[7:4]);
        seg_page_5 <= seg_hex(cfg_contrast[3:0]);
    end else if (sw_act == 4'b1011) begin
        seg_page_0 <= seg_decode_s; seg_page_1 <= seg_decode_c; seg_page_2 <= seg_decode_l;
        seg_page_3 <= seg_decode_r; seg_page_4 <= seg_decode_w; seg_page_5 <= seg_decode_x;
    end else begin
        seg_page_0 <= display_valid_sd ? seg_hex({1'b0, current_image_index_sd} + 4'd1) : SEG_DASH;
        seg_page_1 <= seg_hex(image_count);
        seg_page_2 <= (error_code != 4'd0) ? seg_hex(4'he) : SEG_BLANK;
        seg_page_3 <= auto_play_enabled ? seg_hex({1'b0, auto_period_sec}) : SEG_DASH;
        seg_page_4 <= (error_code != 4'd0) ? seg_hex(error_code) : SEG_BLANK;
        seg_page_5 <= seg_hex(cfg_volume);
    end
end

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    // Board measurement: seg_data_0 through seg_data_5 are left to right.
    .seg_data_0        ({1'b1,seg_page_0}),
    .seg_data_1        ({1'b1,seg_page_1}),
    .seg_data_2        ({1'b1,seg_page_2}),
    .seg_data_3        ({1'b1,seg_page_3}),
    .seg_data_4        ({1'b1,seg_page_4}),
    .seg_data_5        ({1'b1,seg_page_5})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_vid),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_transition_controller video_transition_controller_m0(
    .video_clk              (video_clk),
    .rst                    (rst_vid),
    .video_read_req         (video_read_req),
    .display_valid          (display_valid_video_sync),
    .committed_buffer_index (disp_buf_idx_video_sync),
    .read_fault             (frame_read_fault_video_sync[1]),
    .active_buffer_index    (active_buffer_index),
    .slide_old_buffer_index (slide_old_buffer_index),
    .slide_new_buffer_index (slide_new_buffer_index),
    .slide_active           (slide_active),
    .transition_busy        (transition_busy),
    .slide_position         (slide_position)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_vid),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .read_data_valid   (video_read_data_valid),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
always @(posedge video_clk or posedge rst_vid) begin
    if (rst_vid) begin
        disp_buf_idx_video_meta         <= 3'd0;
        disp_buf_idx_video_prev         <= 3'd0;
        disp_buf_idx_video_sync         <= 3'd0;
        display_valid_video_meta        <= 1'b0;
        display_valid_video_sync        <= 1'b0;
        display_test_pattern_video_meta <= 1'b0;
        display_test_pattern_video_sync <= 1'b0;
        osd_status_video_meta           <= 15'd0;
        osd_status_video_sync           <= 15'd0;
        frame_read_fault_video_sync     <= 2'b00;
    end else begin
        // 同 active_buf_sd：两拍一致才采纳，防止多位同时变化时的混合值
        // 被过渡控制器当成一次新的提交
        disp_buf_idx_video_meta         <= disp_buf_idx_sd;
        disp_buf_idx_video_prev         <= disp_buf_idx_video_meta;
        if (disp_buf_idx_video_prev == disp_buf_idx_video_meta)
            disp_buf_idx_video_sync     <= disp_buf_idx_video_prev;
        display_valid_video_meta        <= display_valid_sd;
        display_valid_video_sync        <= display_valid_video_meta;
        display_test_pattern_video_meta <= display_test_pattern_sd;
        display_test_pattern_video_sync <= display_test_pattern_video_meta;
        osd_status_video_meta           <= osd_status_sd;
        osd_status_video_sync           <= osd_status_video_meta;
        frame_read_fault_video_sync     <= {frame_read_fault_video_sync[0],
                                            frame_read_fault};
    end
end

assign display_valid        = display_valid_video_sync;
assign display_test_pattern = display_test_pattern_video_sync;
assign osd_status_sd = {storage_ready, manager_state, load_in_progress,
                        target_image_index, current_image_index_sd, image_count};
assign {osd_storage_ready, osd_manager_state, osd_load_in_progress,
        osd_target_image_index, osd_current_image_index, osd_image_count} =
       osd_status_video_sync;

video_fallback_pattern video_fallback_pattern_m0(
    .video_clk         (video_clk),
    .rst               (rst_vid),
    .vs                (vs),
    .de                (de),
    .rgb               (fallback_rgb)
);

assign vout_data = display_valid ? vout_data_raw :
                   display_test_pattern ? fallback_rgb : 24'd0;

// ---------------------------------------------------------------------------
// 亮度/对比度调节（第13课）
// 插在显示复用器与 OSD 之间：只调图片本身，OSD 标题/状态栏保持全亮。
// 纯组合、0 拍，de/vs 不需要重新对齐。
//
// 参数从控制域 sd_card_clk (100 MHz) 跨到 video_clk (25 MHz)：
//   1) 19 位配置包 {menu_channel, menu_active, contrast, brightness} 与
//      cfg_toggle 各过 2FF 同步器；
//   2) 模块内部在 cfg_toggle 边沿把整包挂起，在 vs 上升沿整体提交。
// 视频域比控制域慢 4 倍：等 cfg_toggle 的边沿被检出时，配置包早已稳定，
// 不会采到中间态；整包一起提交也避免各字段撕裂。
// ---------------------------------------------------------------------------
wire [23:0] vout_data_bc;

// 亮度/对比度模块在 vs 上升沿整包提交后的"已生效值"，送给 OSD 画进度条。
// 它们只在帧边界变化，所以 OSD 读到的一定是整帧一致的稳定值，不会撕裂。
wire [7:0]  bc_brightness_committed;
wire [7:0]  bc_contrast_committed;
wire [1:0]  bc_channel_committed;
wire        bc_active_committed;

wire [18:0] cfg_sd_bundle = {cfg_menu_channel, cfg_menu_active,
                             cfg_contrast, cfg_brightness};

reg [18:0] cfg_sync0;
reg [18:0] cfg_sync1;
reg        cfg_tgl_sync0;
reg        cfg_tgl_sync1;

always @(posedge video_clk or posedge rst_vid) begin
    if (rst_vid) begin
        cfg_sync0     <= 19'd0;
        cfg_sync1     <= 19'd0;
        cfg_tgl_sync0 <= 1'b0;
        cfg_tgl_sync1 <= 1'b0;
    end else begin
        cfg_sync0     <= cfg_sd_bundle;
        cfg_sync1     <= cfg_sync0;
        cfg_tgl_sync0 <= cfg_toggle_sd;
        cfg_tgl_sync1 <= cfg_tgl_sync0;
    end
end

wire [7:0] cfg_brightness_v = cfg_sync1[7:0];
wire [7:0] cfg_contrast_v   = cfg_sync1[15:8];
wire       cfg_active_v     = cfg_sync1[16];
wire [1:0] cfg_channel_v    = cfg_sync1[18:17];

brightness_contrast_adjust brightness_contrast_adjust_m0(
    .video_clk        (video_clk),
    .rst              (rst_vid),
    .vs               (vs),
    .brightness_in    (cfg_brightness_v),
    .contrast_in      (cfg_contrast_v),
    .menu_channel_in  (cfg_channel_v),
    .menu_active_in   (cfg_active_v),
    .cfg_toggle       (cfg_tgl_sync1),
    .rgb_in           (vout_data),
    .rgb_out          (vout_data_bc),
    .brightness_q     (bc_brightness_committed),
    .contrast_q       (bc_contrast_committed),
    .menu_channel_q   (bc_channel_committed),
    .menu_active_q    (bc_active_committed)
);

// 顶栏信息行 "OUT 640X480  IMG wwwwXhhhh  SCALE d.dd"
wire [319:0] osd_info_text;

osd_info_text #(
    .OUT_WIDTH  (640),
    .OUT_HEIGHT (480),
    .CHARS      (40)
) osd_info_text_m0(
    .video_clk       (video_clk),
    .rst             (rst_vid),
    .vs              (vs),
    .info_toggle     (shown_info_toggle),
    .info_width      (shown_img_width),
    .info_height     (shown_img_height),
    .info_scale_x100 (shown_scale_x100),
    .text_flat       (osd_info_text)
);

video_osd_overlay video_osd_overlay_m0(
    .video_clk            (video_clk),
    .rst                  (rst_vid),
    .vs                   (vs),
    .de                   (de),
    .rgb_in               (vout_data_bc),
    .display_valid        (display_valid),
    .display_test_pattern (display_test_pattern),
    .storage_ready        (osd_storage_ready),
    .manager_state        (osd_manager_state),
    .load_in_progress     (osd_load_in_progress),
    .target_image_index   (osd_target_image_index),
    .current_image_index  (osd_current_image_index),
    .image_count          (osd_image_count),
    .menu_active          (1'b1),  // 参数面板常驻显示
    .brightness_value     (bc_brightness_committed),
    .contrast_value       (bc_contrast_committed),
    .menu_channel         (bc_channel_committed),
    .info_text            (osd_info_text),
    .rgb_out              (vout_data_osd)
);

frame_read_write #(
    .WRITE_V_FLIP        (1),
    .WRITE_BUFFER_SOLID_DIAGNOSTIC(0),
    .FRAME_WIDTH         (640),
    .FRAME_HEIGHT        (480),
    .SLIDE_FEATHER_ENABLE(0),
    .SLIDE_FIFO_UNIFORM_DIAGNOSTIC(0),
    .SLIDE_SDRAM_UNIFORM_DIAGNOSTIC(0),
    .SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC(0),
    .SLIDE_PHASE_COLOR_DIAGNOSTIC(0),
    .READ_CHUNK_PREROLL_WORDS(4),
    .FIXED_READ_BURST_ENABLE(1),
    .READ_FIFO_MARKER_ENABLE(0),
    .READ_FIFO_MARKER_START (26),
    .READ_FIFO_MARKER_WIDTH (5)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_4       (BUF4_ADDR),
    .read_addr_5       (BUF5_ADDR),
    .read_addr_index   (slide_active ? slide_new_buffer_index :
                                       active_buffer_index),
    .read_addr_index_old(slide_old_buffer_index),
    .slide_active      (slide_active),
    .slide_position    (slide_position),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .display_valid     (display_valid),
    .read_data         (video_read_data),
    .read_data_valid   (video_read_data_valid),
    .read_fault        (frame_read_fault),
    .read_fifo_underflow_count_per_frame (frame_read_fifo_underflow_count_per_frame),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_4      (BUF4_ADDR),
    .write_addr_5      (BUF5_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_fifo_afull  (frame_write_fifo_afull)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频可视化：波形 + 峰值条 =====================
// 叠在 OSD 之后、图片区下部（y 360..423，避开 432 起的滚动字幕）。
// 纯组合 0 拍，de/vs 不需要重新对齐。
wire [23:0] vout_data_wave;

audio_waveform_overlay #(
    .WAVE_X      (64),
    .WAVE_Y      (360),
    .WAVE_WIDTH  (512),
    .WAVE_HEIGHT (64),
    .DECIMATE    (12)
) audio_waveform_overlay_m0(
    .video_clk       (video_clk),
    .rst             (rst_vid),
    .vs              (vs),
    .de              (de),
    .rgb_in          (vout_data_osd),
    .enable          (display_valid),
    .audio_valid     (hdmi_audio_valid),
    .audio_left_data (hdmi_audio_left_data),
    .rgb_out         (vout_data_wave)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_vid),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data_wave),
    .I_video_ready (axis_s_ready),
    .I_marker_enable(1'b0),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data),
    .O_backpressure_count(axis_backpressure_count)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_vid),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_vid),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (hdmi_audio_valid),
    .I_audio_left_data  (hdmi_audio_left_data),
    .I_audio_right_data (hdmi_audio_right_data),
    .I_acr_valid        (hdmi_acr_valid),
    .I_acr_cts          (hdmi_acr_cts),
    .I_acr_n            (hdmi_acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
