module image_load_manager #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer LOAD_TIMEOUT_SECONDS = 10,
    parameter integer LOAD_ABS_TIMEOUT_SECONDS = 60,
    parameter integer MAX_LOAD_RETRIES = 2,
    parameter integer STORAGE_INIT_TIMEOUT_SECONDS = 10
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       storage_ready,
    input  wire       scan_done,
    input  wire [3:0] scan_found_count,
    input  wire       source_done_pulse,
    input  wire       source_error_pulse,
    input  wire       storage_fault_pulse,
    input  wire       write_done_pulse,
    input  wire       load_progress_pulse,
    input  wire       next_request,
    input  wire       auto_request,
    input  wire       prev_request,   // 长按 KEY1：上一张
    // 视频域已经切到 display_buffer_index 且没有过渡在进行：此时被滑出的旧槽
    // 不再被读，才允许预加载去覆盖它。
    input  wire       display_settled,

    output reg        scan_start,
    output reg        load_start,
    output reg        load_abort,
    output reg        storage_reinit,
    output reg [2:0]  target_image_index,
    output reg [2:0]  write_buffer_index,     // 槽号 0..5
    output reg [2:0]  display_buffer_index,
    output reg [2:0]  current_image_index,
    output reg        display_valid,
    output reg        display_test_pattern,
    output reg [2:0]  state,
    output reg [1:0]  retry_count,
    output reg [3:0]  error_code,
    output reg        pending_next,
    output reg        source_done_seen,
    output reg        write_done_seen,
    output reg [3:0]  image_count,
    output wire       load_in_progress,
    output wire       idle,
    output reg        commit_pulse,   // display_buffer_index 刚切到新图
    output reg        preloading      // 当前的 LOAD/VERIFY 是后台预加载
);

// ---------------------------------------------------------------------------
// 多槽 SDRAM 缓存（第8课：每张图一个 bank，后台预加载，完成位图，零延迟切换）
//
// 6 个槽 x 307200 字 = 1,843,200 字 < 2M（21 位地址），槽号 3 位（0..5）。
// slot_tags 记录槽里是第几张图，slot_valid 是完成位图。
// 显示空闲且过渡结束后，按 current+1、+2、-1、+3、-2 的顺序把未缓存的图
// 预加载进不在窗口内的槽；按键/自动切换命中缓存时直接改 display_buffer_index，
// 不再等 TF 读盘。扫描最多 6 张图（SCAN_TARGET_COUNT），窗口 = 当前图以外的
// 全部 5 张，所以第一轮读完后所有图都常驻 SDRAM，之后不再读卡。
// ---------------------------------------------------------------------------

localparam [2:0] ST_RESET_WAIT = 3'd0;
localparam [2:0] ST_SCAN       = 3'd1;
localparam [2:0] ST_LOAD       = 3'd2;
localparam [2:0] ST_VERIFY     = 3'd3;
localparam [2:0] ST_COMMIT     = 3'd4;
localparam [2:0] ST_IDLE       = 3'd5;
localparam [2:0] ST_RECOVER    = 3'd6;
localparam [2:0] ST_SELECT     = 3'd7;   // 查缓存：命中直接提交，未命中选牺牲槽

localparam [3:0] ERR_NONE       = 4'd0;
localparam [3:0] ERR_SCAN_EMPTY = 4'd1;
localparam [3:0] ERR_TIMEOUT    = 4'd2;
localparam [3:0] ERR_ALL_FAILED = 4'd3;
localparam [3:0] ERR_STORAGE_INIT = 4'd4;
localparam [3:0] ERR_SOURCE = 4'd5;

localparam [31:0] LOAD_TIMEOUT_CYCLES = CLK_FREQ_HZ * LOAD_TIMEOUT_SECONDS;
localparam [31:0] STORAGE_INIT_TIMEOUT_CYCLES =
    CLK_FREQ_HZ * STORAGE_INIT_TIMEOUT_SECONDS;
// 绝对上限：即使一直在"有进度"，也不能无限拖
localparam [31:0] LOAD_ABS_TIMEOUT_CYCLES =
    CLK_FREQ_HZ * LOAD_ABS_TIMEOUT_SECONDS;

reg [3:0]  skipped_image_count;
reg [31:0] load_timeout_count;
reg [31:0] load_abs_count;
reg [31:0] storage_init_wait_count;
reg        scan_active_seen;
reg        resume_next_after_reinit;
reg        preserve_display_after_reinit;

reg [17:0] slot_tags;        // {tag5, ..., tag0}，每个 3 位
reg [5:0]  slot_valid;
reg [7:0]  preload_failed;   // 本次扫描内预加载失败过的图，不再反复预加载
reg        pending_prev;     // 挂起的请求方向是上一张
reg        load_dir_prev;    // 当前前台加载的方向（失败跳过时沿同方向）

assign load_in_progress = (state == ST_LOAD) || (state == ST_VERIFY);
// 预加载期间对播放控制来说仍是空闲：按键/自动请求照常发出，由本模块
// 命中则立即切换，未命中则挂起到预加载结束。
assign idle             = (state == ST_IDLE) || preloading;

wire fwd_request = next_request || auto_request;
wire request     = fwd_request || prev_request;

// 图片索引 0..7，最多 8 张；在 0..count-1 之间循环
function [2:0] next_image_index;
    input [2:0] current;
    input [3:0] count;
    reg [3:0] nxt;
    begin
        nxt = {1'b0, current} + 4'd1;
        if ((count == 4'd0) || (nxt >= count))
            next_image_index = 3'd0;
        else
            next_image_index = nxt[2:0];
    end
endfunction

function [2:0] prev_image_index;
    input [2:0] current;
    input [3:0] count;
    begin
        if (count == 4'd0)
            prev_image_index = 3'd0;
        else if (current == 3'd0)
            prev_image_index = count[2:0] - 3'd1;   // count=8 -> 7
        else
            prev_image_index = current - 3'd1;
    end
endfunction

function [2:0] slot_tag;
    input [17:0] tags;
    input [2:0]  slot;
    begin
        case (slot)
            3'd0: slot_tag = tags[2:0];
            3'd1: slot_tag = tags[5:3];
            3'd2: slot_tag = tags[8:6];
            3'd3: slot_tag = tags[11:9];
            3'd4: slot_tag = tags[14:12];
            default: slot_tag = tags[17:15];
        endcase
    end
endfunction

// (current + d) mod count，要求 current < count、d < count
function [2:0] add_mod;
    input [2:0] current;
    input [2:0] d;
    input [3:0] count;
    reg [3:0] sum;
    begin
        sum = {1'b0, current} + {1'b0, d};
        if (sum >= count)
            sum = sum - count;
        add_mod = sum[2:0];
    end
endfunction

// 从 current 往后数到 tag 的距离，(tag - current) mod count
function [2:0] fwd_dist;
    input [2:0] tag;
    input [2:0] current;
    input [3:0] count;
    reg [3:0] diff;
    begin
        if (tag >= current)
            diff = {1'b0, tag} - {1'b0, current};
        else
            diff = {1'b0, tag} + count - {1'b0, current};
        fwd_dist = diff[2:0];
    end
endfunction

// 缓存窗口：current 的 +1、+2、+3、-1、-2（6 个槽减去显示槽正好 5 个）。
// 用往后距离表示就是 d = 1..3、count-1、count-2；图不多于 6 张时
// 窗口覆盖全部其余图片。
function in_window;
    input [2:0] tag;
    input [2:0] current;
    input [3:0] count;
    reg [2:0] d;
    begin
        d = fwd_dist(tag, current, count);
        in_window = (d != 3'd0) &&
                    ((d <= 3'd3) || ({1'b0, d} >= (count - 4'd2)));
    end
endfunction

wire [2:0] next_of_current  = next_image_index(current_image_index, image_count);
wire [2:0] prev_of_current  = prev_image_index(current_image_index, image_count);

// 时序（100 MHz）：预加载候选用的 +1/+2/+3/-1/-2 先寄存一拍，而且各自直接
// 用 add_mod 并行算，不再 +1 -> +2 -> +3 串联（原来是 -1.69ns 的最差路径）。
// 只在对应的 image_count 条件成立时才用，所以 add_mod 的 d < count 要求满足。
// 晚一拍没关系：ST_IDLE 停满两拍才启动预加载（见 state_held2）。
reg [2:0] pl_next_r;
reg [2:0] pl_prev_r;
reg [2:0] pl_plus2_r;
reg [2:0] pl_plus3_r;
reg [2:0] pl_minus2_r;
wire [3:0] count_minus2 = image_count - 4'd2;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        pl_next_r   <= 3'd0;
        pl_prev_r   <= 3'd0;
        pl_plus2_r  <= 3'd0;
        pl_plus3_r  <= 3'd0;
        pl_minus2_r <= 3'd0;
    end else begin
        pl_next_r   <= next_of_current;
        pl_prev_r   <= prev_of_current;
        pl_plus2_r  <= add_mod(current_image_index, 3'd2, image_count);
        pl_plus3_r  <= add_mod(current_image_index, 3'd3, image_count);
        pl_minus2_r <= add_mod(current_image_index, count_minus2[2:0], image_count);
    end
end

reg [7:0] cached_map;
reg       target_hit;
reg [2:0] target_slot;
reg       next_hit;
reg [2:0] next_slot;
reg       prev_hit;
reg [2:0] prev_slot;
reg [2:0] victim_slot;
reg       preload_candidate_valid;
reg [2:0] preload_candidate;
integer ci;

always @(*) begin
    cached_map  = 8'd0;
    target_hit  = 1'b0;
    target_slot = 3'd0;
    next_hit    = 1'b0;
    next_slot   = 3'd0;
    prev_hit    = 1'b0;
    prev_slot   = 3'd0;
    victim_slot = (display_buffer_index == 3'd5) ? 3'd0 : (display_buffer_index + 3'd1);
    for (ci = 5; ci >= 0; ci = ci - 1) begin
        if (slot_valid[ci]) begin
            cached_map[slot_tag(slot_tags, ci)] = 1'b1;
            if (slot_tag(slot_tags, ci) == target_image_index) begin
                target_hit  = 1'b1;
                target_slot = ci;
            end
            if (slot_tag(slot_tags, ci) == next_of_current) begin
                next_hit  = 1'b1;
                next_slot = ci;
            end
            if (slot_tag(slot_tags, ci) == prev_of_current) begin
                prev_hit  = 1'b1;
                prev_slot = ci;
            end
        end
        // 牺牲槽：不是显示槽，且空或已落到缓存窗口之外
        if ((ci != display_buffer_index) &&
            (!slot_valid[ci] ||
             !in_window(slot_tag(slot_tags, ci), current_image_index, image_count)))
            victim_slot = ci;
    end
    // 还没有显示图时所有槽都可用，沿用原来"首图写 0 号槽"的行为
    if (!display_valid)
        victim_slot = 3'd0;

    // 按优先级从低到高覆盖：-2、+3、-1、+2、+1，最后留下的优先级最高。
    // 向前翻（按键/自动轮播）是主要用法，先把 +1、+2 备好，-1 随后；
    // 否则 -1 恰好是一张读得慢的大图时，向前的请求会被它拖住。
    preload_candidate_valid = 1'b0;
    preload_candidate       = 3'd0;
    if ((image_count > 4'd4) &&
        !cached_map[pl_minus2_r] && !preload_failed[pl_minus2_r]) begin
        preload_candidate_valid = 1'b1;
        preload_candidate       = pl_minus2_r;
    end
    if ((image_count > 4'd3) &&
        !cached_map[pl_plus3_r] && !preload_failed[pl_plus3_r]) begin
        preload_candidate_valid = 1'b1;
        preload_candidate       = pl_plus3_r;
    end
    if ((image_count > 4'd1) &&
        !cached_map[pl_prev_r] && !preload_failed[pl_prev_r]) begin
        preload_candidate_valid = 1'b1;
        preload_candidate       = pl_prev_r;
    end
    if ((image_count > 4'd2) &&
        !cached_map[pl_plus2_r] && !preload_failed[pl_plus2_r]) begin
        preload_candidate_valid = 1'b1;
        preload_candidate       = pl_plus2_r;
    end
    if ((image_count > 4'd1) &&
        !cached_map[pl_next_r] && !preload_failed[pl_next_r]) begin
        preload_candidate_valid = 1'b1;
        preload_candidate       = pl_next_r;
    end
end

// 时序（100 MHz）：上面的缓存查找是 4 槽 x 多个比较的大组合块，结果先打一拍。
// 用到它们的地方都保证输入已稳定至少一拍：ST_SELECT 进入后先空等一拍，
// ST_IDLE 进入后的第一拍不启动预加载；VERIFY 里的命中切换只由相隔很久的
// 按键/自动请求触发，而且用的是同一拍寄存的一组值（槽号与图号一致）。
reg       target_hit_q;
reg [2:0] target_slot_q;
reg [2:0] victim_slot_q;
reg       next_hit_q;
reg [2:0] next_slot_q;
reg       prev_hit_q;
reg [2:0] prev_slot_q;
reg [2:0] next_of_current_q;
reg [2:0] prev_of_current_q;
reg       preload_candidate_valid_q;
reg [2:0] preload_candidate_q;
reg [2:0] state_d;
reg [2:0] state_d2;
wire      state_held  = (state_d == state);                  // 已在当前状态停留至少一拍
wire      state_held2 = state_held && (state_d2 == state);   // 至少两拍（预加载候选多一级寄存）

// 预加载进行中的切换请求（本拍新请求优先于挂起的请求）。命中缓存立即切换；
// 未命中且预加载的源数据还没读完，就中止预加载、改为前台加载目标图，
// 不再等一张大图（6MB 要好几秒）读完才响应。源数据已读完只剩写尾时照旧挂起：
// 马上就完，而且中止它可能让旧帧的 write_finish 混进下一次加载。
wire      pl_req      = preloading && (request || pending_next);
wire      pl_req_prev = request ? (prev_request && !fwd_request) : pending_prev;
wire      pl_req_hit  = pl_req_prev ? prev_hit_q : next_hit_q;
wire      pl_preempt  = pl_req && !pl_req_hit &&
                        !source_done_seen && !source_done_pulse && !source_error_pulse;

// 时序（100 MHz）：两个 32 位超时比较先打一拍，不再和 VERIFY 里的切换逻辑
// 串在同一拍（原来是 target_image_index / display_buffer_index 的违例路径）。
// 只在 VERIFY 里计算；ST_LOAD 清计数的那一拍这里同时清零，重试后的第一拍
// 不会拿到上一次的超时结果。10 s 超时晚一拍无所谓。
reg load_timeout_hit_q;
always @(posedge clk or posedge rst) begin
    if (rst)
        load_timeout_hit_q <= 1'b0;
    else if (state != ST_VERIFY)
        load_timeout_hit_q <= 1'b0;
    else
        load_timeout_hit_q <= (load_timeout_count >= (LOAD_TIMEOUT_CYCLES - 2'd2)) ||
                              (load_abs_count    >= (LOAD_ABS_TIMEOUT_CYCLES - 2'd2));
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        target_hit_q              <= 1'b0;
        target_slot_q             <= 3'd0;
        victim_slot_q             <= 3'd0;
        next_hit_q                <= 1'b0;
        next_slot_q               <= 3'd0;
        prev_hit_q                <= 1'b0;
        prev_slot_q               <= 3'd0;
        next_of_current_q         <= 3'd0;
        prev_of_current_q         <= 3'd0;
        preload_candidate_valid_q <= 1'b0;
        preload_candidate_q       <= 3'd0;
        state_d                   <= ST_RESET_WAIT;
        state_d2                  <= ST_RESET_WAIT;
    end else begin
        target_hit_q              <= target_hit;
        target_slot_q             <= target_slot;
        victim_slot_q             <= victim_slot;
        next_hit_q                <= next_hit;
        next_slot_q               <= next_slot;
        prev_hit_q                <= prev_hit;
        prev_slot_q               <= prev_slot;
        next_of_current_q         <= next_of_current;
        prev_of_current_q         <= prev_of_current;
        preload_candidate_valid_q <= preload_candidate_valid;
        preload_candidate_q       <= preload_candidate;
        state_d                   <= state;
        state_d2                  <= state_d;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_start          <= 1'b0;
        load_start          <= 1'b0;
        load_abort          <= 1'b0;
        storage_reinit      <= 1'b0;
        target_image_index  <= 2'd0;
        write_buffer_index  <= 3'd0;
        display_buffer_index <= 3'd0;
        current_image_index <= 2'd0;
        display_valid       <= 1'b0;
        display_test_pattern <= 1'b0;
        state               <= ST_RESET_WAIT;
        retry_count         <= 2'd0;
        error_code          <= ERR_NONE;
        pending_next        <= 1'b0;
        pending_prev        <= 1'b0;
        load_dir_prev       <= 1'b0;
        image_count         <= 3'd0;
        skipped_image_count <= 3'd0;
        load_timeout_count  <= 32'd0;
        load_abs_count      <= 32'd0;
        storage_init_wait_count <= 32'd0;
        source_done_seen    <= 1'b0;
        write_done_seen     <= 1'b0;
        scan_active_seen    <= 1'b0;
        resume_next_after_reinit <= 1'b0;
        preserve_display_after_reinit <= 1'b0;
        slot_tags           <= 18'd0;
        slot_valid          <= 6'd0;
        preload_failed      <= 8'd0;
        preloading          <= 1'b0;
        commit_pulse        <= 1'b0;
    end else begin
        scan_start <= 1'b0;
        load_start <= 1'b0;
        load_abort <= 1'b0;
        storage_reinit <= 1'b0;
        commit_pulse <= 1'b0;

        if (storage_fault_pulse) begin
            storage_reinit      <= 1'b1;
            load_abort          <= (state == ST_LOAD) || (state == ST_VERIFY);
            state               <= ST_RESET_WAIT;
            pending_next        <= 1'b0;
        pending_prev        <= 1'b0;
        load_dir_prev       <= 1'b0;
            image_count         <= 3'd0;
            retry_count         <= 2'd0;
            skipped_image_count <= 3'd0;
            load_timeout_count  <= 32'd0;
            load_abs_count      <= 32'd0;
            source_done_seen    <= 1'b0;
            write_done_seen     <= 1'b0;
            scan_active_seen    <= 1'b0;
            resume_next_after_reinit <= 1'b0;
            preserve_display_after_reinit <= display_valid;
            // 卡可能被换过，只保留正在显示的槽
            slot_valid          <= display_valid ? (6'b000001 << display_buffer_index) : 6'd0;
            preload_failed      <= 8'd0;
            preloading          <= 1'b0;
        end else if (!storage_ready) begin
            // The vendor SD core stays uninitialized when no card is present.
            // Keep a prior frame, but make a no-card startup visible after a guard period.
            if (!display_valid) begin
                if (storage_init_wait_count >= (STORAGE_INIT_TIMEOUT_CYCLES - 1'b1)) begin
                    display_test_pattern <= 1'b1;
                    error_code           <= ERR_STORAGE_INIT;
                end else begin
                    storage_init_wait_count <= storage_init_wait_count + 1'b1;
                end
            end else begin
                storage_init_wait_count <= 32'd0;
            end

            if ((state == ST_LOAD) || (state == ST_VERIFY))
                load_abort <= 1'b1;

            state              <= ST_RESET_WAIT;
            pending_next       <= 1'b0;
            image_count        <= 3'd0;
            retry_count        <= 2'd0;
            skipped_image_count <= 3'd0;
            load_timeout_count <= 32'd0;
            source_done_seen   <= 1'b0;
            write_done_seen    <= 1'b0;
            scan_active_seen   <= 1'b0;
            slot_valid         <= display_valid ? (6'b000001 << display_buffer_index) : 6'd0;
            preload_failed     <= 8'd0;
            preloading         <= 1'b0;
        end else begin
            storage_init_wait_count <= 32'd0;

            // 预加载期间 idle 为高，请求可能落在任何状态；VERIFY 里另行处理
            // （命中立即切换），其余状态先挂起。
            if (preloading && request && (state != ST_VERIFY)) begin
                pending_next <= 1'b1;
                pending_prev <= prev_request && !fwd_request;
            end

            case (state)
                ST_RESET_WAIT: begin
                    scan_start       <= 1'b1;
                    scan_active_seen <= 1'b0;
                    state            <= ST_SCAN;
                end

                ST_SCAN: begin
                    // A prior scan_done level must fall after scan_start before it is accepted.
                    if (!scan_done) begin
                        scan_active_seen <= 1'b1;
                    end else if (scan_active_seen) begin
                        image_count <= scan_found_count;
                        if (scan_found_count != 3'd0) begin
                            target_image_index <= (resume_next_after_reinit && display_valid) ?
                                                  next_image_index(current_image_index, scan_found_count) :
                                                  2'd0;
                            retry_count         <= 2'd0;
                            preload_failed      <= 8'd0;
                            skipped_image_count <= 3'd0;
                            resume_next_after_reinit <= 1'b0;
                            if (preserve_display_after_reinit && display_valid) begin
                                preserve_display_after_reinit <= 1'b0;
                                state                         <= ST_IDLE;
                            end else begin
                                state <= ST_SELECT;
                            end
                        end else begin
                            error_code <= ERR_SCAN_EMPTY;
                            resume_next_after_reinit <= 1'b0;
                            preserve_display_after_reinit <= 1'b0;
                            if (!display_valid)
                                display_test_pattern <= 1'b1;
                            state <= ST_RECOVER;
                        end
                    end
                end

                ST_SELECT: begin
                    if (!state_held) begin
                        // 等一拍，让寄存的查找结果对应新的 target_image_index
                    end else if (target_hit_q) begin
                        if (preloading) begin
                            preloading <= 1'b0;
                        end else begin
                            // 缓存命中：零延迟切换
                            display_buffer_index <= target_slot_q;
                            current_image_index  <= target_image_index;
                            display_valid        <= 1'b1;
                            display_test_pattern <= 1'b0;
                            retry_count          <= 2'd0;
                            skipped_image_count  <= 3'd0;
                            error_code           <= ERR_NONE;
                            commit_pulse         <= 1'b1;
                        end
                        state <= ST_IDLE;
                    end else begin
                        write_buffer_index        <= victim_slot_q;
                        slot_valid[victim_slot_q] <= 1'b0;
                        state                   <= ST_LOAD;
                    end
                end

                ST_LOAD: begin
                    load_start         <= 1'b1;
                    load_timeout_count <= 32'd0;
                    load_abs_count     <= 32'd0;
                    source_done_seen   <= 1'b0;
                    write_done_seen    <= 1'b0;
                    state              <= ST_VERIFY;
                end

                ST_VERIFY: begin
                    if (source_done_pulse)
                        source_done_seen <= 1'b1;
                    if (write_done_pulse)
                        write_done_seen <= 1'b1;

                    // 预加载进行中来了切换请求：目标已缓存就立即切过去（预加载
                    // 继续写它自己的槽，不受影响）；未命中则中止预加载改为前台加载
                    // （pl_preempt），源已读完的话挂起到预加载结束。
                    if (pl_req && pl_req_hit) begin
                        display_buffer_index <= pl_req_prev ? prev_slot_q : next_slot_q;
                        current_image_index  <= pl_req_prev ? prev_of_current_q : next_of_current_q;
                        commit_pulse         <= 1'b1;
                        pending_next         <= 1'b0;
                        pending_prev         <= 1'b0;
                    end else if (pl_req && !pl_preempt) begin
                        pending_next <= 1'b1;
                        pending_prev <= pl_req_prev;
                    end

                    if (pl_preempt) begin
                        // 被中止的槽在 ST_SELECT 已标成 invalid，写了一半的数据不会被显示；
                        // adapter 会把紧跟着的 load_start 锁存到 abort 收尾完成再执行。
                        load_abort          <= 1'b1;
                        preloading          <= 1'b0;
                        target_image_index  <= pl_req_prev ? prev_of_current_q : next_of_current_q;
                        load_dir_prev       <= pl_req_prev;
                        pending_next        <= 1'b0;
                        pending_prev        <= 1'b0;
                        retry_count         <= 2'd0;
                        skipped_image_count <= 3'd0;
                        state               <= ST_SELECT;
                    end else if (source_error_pulse ||
                        (!((source_done_seen || source_done_pulse) &&
                           (write_done_seen || write_done_pulse)) &&
                         load_timeout_hit_q)) begin
                        load_abort <= 1'b1;
                        if (!preloading)
                            error_code <= source_error_pulse ? ERR_SOURCE : ERR_TIMEOUT;

                        if (retry_count < MAX_LOAD_RETRIES) begin
                            retry_count <= retry_count + 2'd1;
                            state       <= ST_LOAD;
                        end else if (preloading) begin
                            // 预加载失败不影响当前显示，只记下来不再预加载它
                            retry_count                        <= 2'd0;
                            preload_failed[target_image_index] <= 1'b1;
                            preloading                         <= 1'b0;
                            state                              <= ST_IDLE;
                        end else if (!display_valid) begin
                            retry_count         <= 2'd0;
                            display_test_pattern <= 1'b1;
                            state               <= ST_RECOVER;
                        end else if ((image_count > 3'd1) &&
                                     (skipped_image_count < (image_count - 4'd1)) &&
                                     // 绕回当前显示的图（它一定在缓存里）= 其余图全部失败，
                                     // 按 ALL_FAILED 处理，保留"再按一次重新初始化存储"的恢复路径
                                     ((load_dir_prev ?
                                       prev_image_index(target_image_index, image_count) :
                                       next_image_index(target_image_index, image_count)) !=
                                      current_image_index)) begin
                            retry_count         <= 2'd0;
                            skipped_image_count <= skipped_image_count + 3'd1;
                            target_image_index  <= load_dir_prev ?
                                prev_image_index(target_image_index, image_count) :
                                next_image_index(target_image_index, image_count);
                            state               <= ST_SELECT;
                        end else begin
                            retry_count <= 2'd0;
                            error_code  <= ERR_ALL_FAILED;
                            state       <= ST_IDLE;
                        end
                    end else if ((source_done_seen || source_done_pulse) &&
                        (write_done_seen || write_done_pulse)) begin
                        state <= ST_COMMIT;
                    end else begin
                        // 每读完一个源扇区就把"无进展"计时清零；
                        // 只有真的卡住（连续 10s 一个扇区都没读完）才判超时。
                        if (load_progress_pulse)
                            load_timeout_count <= 32'd0;
                        else
                            load_timeout_count <= load_timeout_count + 32'd1;
                        load_abs_count <= load_abs_count + 32'd1;
                    end
                end

                ST_COMMIT: begin
                    slot_valid[write_buffer_index] <= 1'b1;
                    case (write_buffer_index)
                        3'd0:    slot_tags[2:0]   <= target_image_index;
                        3'd1:    slot_tags[5:3]   <= target_image_index;
                        3'd2:    slot_tags[8:6]   <= target_image_index;
                        3'd3:    slot_tags[11:9]  <= target_image_index;
                        3'd4:    slot_tags[14:12] <= target_image_index;
                        default: slot_tags[17:15] <= target_image_index;
                    endcase
                    retry_count <= 2'd0;
                    if (preloading) begin
                        preloading <= 1'b0;
                    end else begin
                        display_buffer_index <= write_buffer_index;
                        current_image_index  <= target_image_index;
                        display_valid        <= 1'b1;
                        display_test_pattern <= 1'b0;
                        skipped_image_count  <= 3'd0;
                        error_code           <= ERR_NONE;
                        commit_pulse         <= 1'b1;
                    end
                    state <= ST_IDLE;
                end

                ST_IDLE: begin
                    if ((error_code == ERR_ALL_FAILED) && (next_request || prev_request)) begin
                        storage_reinit    <= 1'b1;
                        pending_next      <= 1'b0;
                        pending_prev      <= 1'b0;
                        retry_count       <= 2'd0;
                        skipped_image_count <= 3'd0;
                        resume_next_after_reinit <= 1'b1;
                        state             <= ST_RESET_WAIT;
                    end else if ((error_code != ERR_ALL_FAILED) &&
                                 (request || pending_next)) begin
                        // 本拍的新请求优先于挂起的请求
                        if (request ? (prev_request && !fwd_request) : pending_prev) begin
                            target_image_index <= prev_of_current;
                            load_dir_prev      <= 1'b1;
                        end else begin
                            target_image_index <= next_of_current;
                            load_dir_prev      <= 1'b0;
                        end
                        pending_next       <= 1'b0;
                        pending_prev       <= 1'b0;
                        retry_count        <= 2'd0;
                        skipped_image_count <= 3'd0;
                        state              <= ST_SELECT;
                    end else if (state_held2 && display_valid && display_settled &&
                                 (error_code != ERR_ALL_FAILED) &&
                                 preload_candidate_valid_q) begin
                        target_image_index <= preload_candidate_q;
                        preloading         <= 1'b1;
                        retry_count        <= 2'd0;
                        state              <= ST_SELECT;
                    end
                end

                ST_RECOVER: begin
                    scan_start       <= 1'b1;
                    scan_active_seen <= 1'b0;
                    state            <= ST_SCAN;
                end

                default: begin
                    state <= ST_RESET_WAIT;
                end
            endcase
        end
    end
end

endmodule
