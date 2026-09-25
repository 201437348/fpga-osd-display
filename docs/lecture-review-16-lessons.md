# 参考资料十六讲评审报告 —— 对 `D:\fpga\project` 的优化建议与差距清单

评审对象：`D:\fpga\02 FPGA创新设计赛道安路赛项（完赛系列）\02 FPGA创新设计赛道安路赛项（完赛系列）`
（16 个讲次，含官方 ProMax 完赛工程 RTL 与逐课文档）
评审目标工程：`D:\fpga\project\fpga\osd_display`
日期：2026-09-09 之后

---

## 〇、总体结论

**资料 ProMax 不是全面强于本工程。** 逐讲对照后的真实画像是：

| 维度 | 判定 |
|---|---|
| 像素处理算法 | **本工程明显领先**（双线性、保比例、对比度、完整 WAV 解析、滚动字幕、多簇根目录遍历） |
| 系统可靠性 / 工程化 | **本工程明显落后**（复位同步器、SDC 约束、Flash 持久化、结构化错误码、UART 上报） |
| 交互设计 | **本工程明显落后**（上一张、组合键、音量/周期菜单、缩略图交互） |
| 资源分配 | **本工程过度**（512 点 FFT 吃满 DSP/BRAM，资料明确警告过） |
| 场景包装 / 答辩 | **本工程基本空白**（无四段式场景章节、无功能动机链、无答辩话术） |

**一句话**：算法功底强于资料作者，但缺"产品级"那一层 —— 复位、约束、持久化、可观测性、错误码、交互、场景叙事。

---

## 一、十六讲覆盖与逐讲判定

| 讲 | 主题 | 判定 | 关键依据 |
|---|---|---|---|
| 1 | 赛题介绍和赛题解读 | 已消化 | `docs/competition-requirements.md` 已是完整摘要 |
| 2 | 官方架构与设计思维 | 缺 | 缺"证据强度 1–5 级"台账；README 存在与实测不符的结论 |
| 3 | 按键切换与自动轮播 | **落后** | 无"上一张"、轮播周期写死 1s、无组合键、数码管每管仅 1 bit |
| 4 | HDMI 音频输出基础 | **落后** | `hdmi_audio_acr` CTS 计数缺陷；无测试音 / 音源 mux / 媒体音调 |
| 5 | 系统稳定性 | 相当 | 已有超时/重试/`storage_ready`；缺 UART 上报、BMP 校验缺 4 项、无像素完整性校验 |
| 6 | Flash 固化与上电自启 | **落后** | 无 `reset_sync`、PLL `.reset(1'b0)`、SDC 缺 5 条约束、无 Flash 持久化 |
| 7 | FAT32 文件系统升级 | **领先** | 本工程有 MBR + 完整 BPB + **多簇根目录遍历**；资料只读根目录第一簇 |
| 8 | 四 bank 帧缓存架构 | **落后** | `frame_read_write` 读写仍耦合；错误码只有 1 bit `read_fault` |
| 9 | OSD 字幕叠加 | **领先** | 本工程有滚动字幕（资料 ProMax 自认没做）；缺 Alpha 混合 |
| 10 | 图片转场特效 | 相当 | 有水平 Wipe；纯交叉淡化上板花屏未解决；文档过期 + 孤儿文件 |
| 11 | WAV 音频播放 | 各半 | 本工程完整解析 WAV 头（资料用 PC 预处理）；**缺音量 / 音画同步淡入淡出 / 音源切换** |
| 12 | 音频波形可视化 | **过度** | 资料明确因 EG4S20 资源不足而拒绝 FFT，本工程做了 512 点 FFT |
| 13 | 图片缩放与缩略图 | **领先** | 资料 `bilinear_8q8.v` 是 TODO 骨架；本工程 728 行完整实现 + 保比例 letterbox |
| 14 | 亮度对比度调节 | **领先** | 资料明说"完赛工程只实现了亮度，grep 不到任何 contrast 信号"；本工程两者都有 |
| 15 | 缩略图交互选择 | **完全缺失** | 全工程 grep `thumbnail/focus_index/view_mode` 零命中 |
| 16 | 产品包装与应用场景 | **基本空白** | 仅 `roadmap.md` 一句话场景描述 |

---

## 二、必须先纠正的两处事实错误

### 2.1 `README.md` 对 SDRAM 时序失败的归因是错的

README 声称：

> SDRAM DQ 建立裕量 `SWNS = -6.565 ns`，与 2026-06-05 官方 `lab_ex4_tf` 基线一致，属官方底座固有行为，**禁止用 `false_path` 屏蔽**。

**实测证据**（`audio_bars_Runs/phy_1/final_timing.rpt` 第 16805 行）：

```
Path Group: sys_pll_m0/pll_inst.clkc[2] -> ext_mem_clk
Type: Same Domain
Min Period: 21.130ns   Fmax: 47.326MHz
Max: SWNS -6.565ns  STNS -210.080ns  32 Viol Endpoints / 32 Total Endpoints
```

这是 **`ext_mem_clk_sft` → `ext_mem_clk` 的移位时钟跨越**，不是 DQ 建立裕量。而**第六讲 §2.3 明确授权对这条路径加 `false_path`**，理由正是"SDRAM 控制器用了一个移位时钟来采样数据，这个路径是硬 IP 的 I/O 窗口，不需要做 fabric 时序分析"。

### 2.2 README 完全未记录的两组独立时序失败

| 时钟域 | SWNS | 违例端点 | Fmax | 要求 |
|---|---|---|---|---|
| `sd_card_clk` 自域 | **-5.060 ns** | **630** | **66.401 MHz** | 100 MHz |
| `ext_mem_clk` 自域 | -0.399 ns | 12 | 119.062 MHz | 125 MHz |
| `clk → ext_mem_clk` | -0.621 ns | 30 | — | — |
| `clkc[2]` 自域 | -3.302 ns | — | — | — |
| 保持（全局） | HWNS -0.020 ns | 7 | — | — |

`sd_card_clk` 最差路径：

```
起点 image_storage_adapter_m0/u_fat32_bmp_loader/u_file_sector_reader/mux47_syn_1680 (clock pin)
终点 image_storage_adapter_m0/u_fat32_wav_loader/data_bytes_remaining_reg[1]_syn_4.ce
数据路径 14.708 ns（单元 5.782 / 39%，走线 8.926 / 61%），逻辑 12 级 LUT5，扇出 20
```

根因：TD 把 `fat32_wav_loader.v` 的 `ST_STREAM_SECTOR` 单周期巨型嵌套 case（`parser_state × riff_byte_index × chunk_byte_index`）加上约 20 个组合 `parser_error` 比较，展平成了 12 级 LUT5 链，末端驱动一个时钟使能。**走线占 61% 说明根子是拥塞**（slices 97.72%）。

---

## 三、优化项清单（按性价比排序）

### 第一梯队：约 65 行改动，清掉约 62 个违例端点 + 全部保持违例

| # | 项目 | 位置 | 改动量 |
|---|---|---|---|
| 1 | `rename_clock` 命名 `clkc[2]` 为 `ext_mem_clk_sft` | `constraints/timing.sdc` | 1 行 |
| 2 | `set_false_path -from ext_mem_clk -to ext_mem_clk_sft` 及反向 | 同上 | 2 行 |
| 3 | `set_false_path -from [get_ports {rst_n}]` | 同上 | 1 行 |
| 4 | `set_false_path -to [get_regs -hier {*/s1}]` | 同上 | 1 行 |
| 5 | `set_max_delay -from hdmi_5x_clk -to HDMI_* 8.000 -datapath_only` | 同上 | 1 行 |
| 6 | `set_clock_uncertainty -hold 0.050` | 同上 | 1 行 |
| 7 | `reset_sync` 模块 × N 个时钟域 | 新建 `rtl/control/reset_sync.v` | ~30 行 |
| 8 | 两个 PLL 的 `.reset(1'b0)` → `~rst_n` | `rtl/top/top.v` | 2 行 |

### 第二梯队：正确性缺陷

| # | 项目 | 位置 | 说明 |
|---|---|---|---|
| 9 | `hdmi_audio_acr` 的 `cts_count` 未按 `audio_valid` 门控 | `rtl/audio/hdmi_audio_acr.v:29` | 每拍无条件累加；WAV FIFO 欠读时 CTS 虚增，接收端音频时钟算错；20 位可回绕。改为门控计数并断言 `acr_cts === 20'd25000` |
| 10 | `tb_hdmi_audio_acr.sv` 无法捕获上述缺陷 | `tests/` | 只断言 `acr_cts != 0`，注释还声称"Deliberate gaps prove that the divider counts samples"——**断言与注释都不成立** |
| 11 | BMP 严格校验补 4 项 | `rtl/storage/fat32_bmp_loader.v:155-164` | 缺 `dib_size >= 40`、`planes == 1`、`pixel_offset >= 54`、`file_len >= pixel_offset + w*h*3`；`dib_size`/`planes` 目前根本没解析 |
| 12 | 像素完整性校验 | `rtl/storage/*.v` | 无 `pixel_count`/`expected_pixel`，无法检出截断帧 |
| 13 | `fat32_file_sector_reader` 错误码 | `rtl/storage/fat32_file_sector_reader.v` | 只有 1 bit `error`；缺 `ERR_FAT_LOOP`(下一簇==当前簇)、`ERR_EARLY_EOF`、`final_chain_check` |
| 14 | `top.v` 的 `error_code` 位宽 | `rtl/top/top.v` | 只有 `[3:0]`；资料错误码在 0x51/0x52/0x53 量级，需 ≥7 bit |

### 第三梯队：资源与时序结构性整改

| # | 项目 | 说明 |
|---|---|---|
| 15 | **拆分 `fat32_wav_loader` 的 `ST_STREAM_SECTOR` 巨型组合块** | 加一级寄存化的字节分类流水级，把组合路径从 12 级降到 ≤6 级。这是 `sd_card_clk` 630 个违例端点的直接来源 |
| 16 | **`fifo_has_chunk_room` 改为余量计数** | `frame_slide_fifo_read` 中"FIFO 是否有 128 字空间"的比较器被综合成 4 级串联 ADDER；改为预计算的 `space_remaining` 寄存器，清掉 `ext_mem_clk` 12 个违例端点 |
| 17 | **把 512 点 FFT 换成波形 + 峰值条** | 见 §四，这是唯一"做减法同时改善时序、资源、可扩展性"的改动 |
| 18 | `frame_read_write` 拆分 loader / reader | 架构级，见 §五 |
| 19 | `video_transition_blender` 的 3 个乘法器改移位 | `difference * amount` → `>>1`/`>>2`（`accent_channel` 已是此风格） |

### 第四梯队：功能补齐

| # | 项目 | 来源讲次 |
|---|---|---|
| 20 | Flash 配置持久化 + 上电自启 | 第六讲（**赛题硬性要求**） |
| 21 | 音量 5 档 + 轮播周期 4 档菜单 | 第三、十一、十四讲 |
| 22 | `sync_fade_gain` 音画同步淡入淡出 | 第十一讲 |
| 23 | 缩略图交互（`thumbnail_layout` + `thumbnail_controller`） | 第十三、十五讲 |
| 24 | "上一张" + 组合键 + 统一按键事件层 | 第三讲 |
| 25 | 数码管 8 位 3 页面（PIC/VOL/PRD） | 第三讲 |
| 26 | Alpha 混合（移位近似） | 第九讲 |
| 27 | 抗混叠 + 整数倍退化修复 + 半像素对齐 | 第十三讲 |
| 28 | OSD 显示分辨率 / 缩放比 / 参数进度条 | 第十三、十四讲 |
| 29 | UART 状态上报 | 第五讲 |
| 30 | 应用场景章节（四段式）+ 答辩话术 | 第十六讲 |

### 清理项

| # | 项目 |
|---|---|
| 31 | 删除孤儿文件 `rtl/vendor/SD/frame_dual_fifo_read.v`（全工程零引用） |
| 32 | `docs/superpowers/specs/2026-09-09-clean-dual-frame-crossfade-design.md` 与 RTL 不一致，且引用了不存在的 KEY4 —— 标注为未落地或更新 |
| 33 | `docs/competition-requirements.md` 第 79 行"拉伸铺满导致变形"已过时（RTL 已实现 letterbox） |

---

## 四、最关键的单点结论：FFT 资源超支

第十二讲开篇即拒绝 FFT：

> **为什么不做 FFT 频谱？因为：** 1. FFT 在 FPGA 上实现复杂，**需要大量 DSP 乘法器和 BRAM，EG4S20 资源有限**…… 3. 波形+峰值条的视觉效果已经足够专业，**能满足拓展要求** 4. 实现简单，代码量小（`promax_audio_waveform.v` 只有约 140 行）
>
> 这又是一个工程思维：**够用就好，不要过度设计**。

资料选择：**波形 + 峰值条（140 行）**。

本工程实现：

| 模块 | 大小 |
|---|---|
| `rtl/audio/audio_spectrum_fft.v` | **43 KB** |
| `rtl/audio/audio_spectrum_bands.v` | 3.0 KB |
| `rtl/audio/audio_band_processor.v` | 4.6 KB |
| `rtl/video/audio_bars_overlay.v` | 9.9 KB |

实测资源对照：

| 资源 | 本工程 | 资料 ProMax | 器件上限 |
|---|---|---|---|
| DSP | **26 = 89.66%** | 18 = 62% | 29 |
| BRAM | **54 = 84.38%** | 10 = 16% | 64 |
| LUT | **17226 = 87.89%** | 15685 = 80% | 19600 |
| slices | **97.72%** | — | — |

**因果链**：

```
FFT 频谱（43KB RTL，可选扩展项）
   ↓ 吃掉 DSP 26/29、BRAM 54/64
slices 97.72%
   ↓ 拥塞
走线延迟占 61%
   ↓
sd_card_clk 66.4 MHz（需 100 MHz）、630 个违例端点
   ↓
README 把 -6.565ns 归错因、真问题被掩盖
   ↓
加不进"上一张 / 音量 / Flash 持久化 / 数码管面板 / Alpha 混合 / 复位同步器"
```

**评分角度的双重印证**（第十六讲 §6.3）：

> **"评测不依据资源大小，推荐优化逻辑和最低功耗"** → 文档不要拿资源占用当卖点；讲带宽预算反而加分。

**即：把资源用满不是加分项，是减分项。**

**替代方案同样满足要求**：波形 + 峰值条覆盖官方"音频可视化展示"，且本工程已有 `audio_visualizer.v`（峰值包络 + 衰减）可直接复用扩展为 32 点 ping-pong 波形。

---

## 五、架构级缺口：`frame_read_write` 读写未分离

资料第八讲 §1.2 第 2 条批评的正是"读写耦合在 `frame_read_write` 二合一桥接模块"。本工程该模块（284 行）内部：

```
wfifo_32_32_512  /  frame_fifo_write  /  rfifo_32_32_512  /  frame_slide_fifo_read
```

读写两侧仍关在同一 module 内。资料目标态是 `media_frame_loader`（写+FIFO+burst，6 个错误码 + `image_complete[3:0]`）与 `media_frame_reader`（mem_clk + pix_clk 双域，4 个错误码 + 独立 underflow）**完全分离**。

**这与 §三 第 16 项的时序热点直接相关** —— `ext_mem_clk` 最差路径就在这个耦合模块内部：

```
frame_read_write_m0/read_buf/rd_to_wr_cross_inst/secondary_addr_o_reg[0]
  → frame_read_write_m0/frame_slide_fifo_read_m0/App_rd_addr_reg[6].ce
数据路径 8.047 ns（单元 3.166 / 39%，走线 4.881 / 61%），逻辑 6 级，含 4 个串联 ADDER
```

**其他缺口**：错误码粒度（`read_fault` 1 bit vs 资料的 loader 6 + reader 4 + 独立 underflow）、缺 `image_complete[3:0]` 就绪位图。

---

## 六、场景包装缺口（第十六讲）

本工程现状：仅 `docs/roadmap.md` 第 13 行一句"作品面向数字广告牌和商业展示终端"。

资料要求的**四段式应用场景章节**全部缺失：

1. 总场景叙事（150 字以内）
2. 功能映射表（赛题要求 → 场景需求 → 系统实现 → 演示动作）
3. 平台化底座论证
4. 拓展场景列举（8–10 个）

**其他缺失**：

| 项 | 说明 |
|---|---|
| 功能动机链四问 | 谁在用 / 删掉会怎样 / 评委拨码那一刻故事还在吗 / 这个信息的来源在板上吗 |
| 板卡边界四问 | 合法来源只有：TF 卡预置 / 板上时钟时序 / 板上输入（4 按键 + 空闲拨码 SW3/SW4 + UART）/ FPGA 自产内容 |
| 答辩话术公式 | 场景痛点 → 该功能如何消解痛点 → 现场演示动作 |
| FPGA 三优势话术 | 更确定的时序（帧边界原子生效）/ 更低的显示延迟（按键到画面以帧为单位）/ 更高的可靠性（上电即播，看门狗自恢复） |
| 单系统多模式设计 | 赛题硬约束"不能多次加载镜像分别实现基础和扩展"；本工程目前所有功能同时在线，无"常态/应急/调光"模式切换 |
| 数码管状态口径 | 官方扩展框图要求显示"空闲/搜索BMP/写入SDRAM/OSD叠加，以及分辨率、缩放比、亮度、对比度、频谱模式"；本工程每管仅 1 bit 信息，远不达标 |
| 断电再上电演示 | 依赖 Flash 固化（第六讲，未做） |

**第十六讲点名的翻车点 #3 与本工程直接相关**：

> **为炫技而扩展**：频谱可视化做了，但场景里没有人需要"看到声音"。

资料给出的正例话术（必须采用）：

> "应急插播时板上告警音持续鸣响，嘈杂现场或听障人员可能听不到。我们对这路 24-bit PCM 实时计算频谱能量并叠加到画面——**声音信息变成视觉信息，这是无障碍设计，不是特效**。"

**同时暴露一个功能缺口**：被问"可视化的是哪路音频"必须秒答"板上 24-bit PCM（测试音/WAV）"。本工程**无测试音兜底**，拔掉 TF 卡即无音频可分析、频谱全黑。这正是第四讲 `pcm_test_tone` 缺失的场景级后果。

---

## 七、本工程相对资料的领先项（应保留并写进文档）

| 能力 | 本工程证据 | 资料状态 |
|---|---|---|
| 双线性插值 | `image_bilinear_scaler.v` 728 行，单乘法器 lerp（18→9 DSP） | `bilinear_8q8.v` 是 TODO 骨架，"完赛工程未实现" |
| 保宽高比 + letterbox | `aspect_43/169/1610/32` 分类 + `fit_*` + `bar_pixel ? 24'h000000` | "完赛工程当前用的是拉伸填充" |
| 对比度调节 | `brightness_contrast_adjust.v`，`c=128` 逐位旁路，不用 `$signed` | "整个完赛工程 grep 不到任何 contrast 信号" |
| 完整 WAV 头解析 | `fat32_wav_loader.v` 31.9 KB，解析 fmt/data chunk | "不做完整的 WAV 头解析"，用 PC 工具预处理成裸 PCM |
| 滚动字幕 OSD | `video_osd_overlay.v` 有 `ticker_scroll_offset`/`ticker_char_index` | "当前 OSD 是静态的 4 个字符状态显示，**没有实现滚动字幕**" |
| 多簇根目录遍历 | `fat32_directory_scan.v` 14 状态，含 `ST_CALC_NEXT_DIR_OFFSET`/`ST_START_NEXT_DIR` | "完赛工程的卷扫描器只读根目录的**第一个簇**" |
| 帧边界原子提交 | `video_transition_controller.v` 在 `frame_read_req` 上升沿提交 | 相当 |

**这些是本工程的真实技术优势，应在文档与答辩中明确主张。**

---

## 八、建议执行顺序

```
阶段 1（约 65 行，1–2 天）   SDC 7 条约束 + reset_sync + PLL reset
                            → 清掉约 62 个违例端点 + 全部保持违例

阶段 2（约 40 行，1–2 天）   ACR cts_count 门控 + tb 强化断言
                            BMP 严格校验 4 项 + 像素完整性校验
                            → 修掉 2 个正确性缺陷

阶段 3（结构性，3–5 天）     fat32_wav_loader 组合链拆分（寄存化字节分类级）
                            fifo_has_chunk_room 改余量计数
                            → 解决 sd_card_clk 66.4 MHz 的根因

阶段 4（做减法，2–3 天）     FFT → 波形 + 峰值条
                            → 释放 DSP/BRAM/LUT，为阶段 5 腾出空间

阶段 5（功能补齐）           Flash 固化 + 上电自启（硬性要求）
                            音量/周期菜单 + sync_fade_gain
                            缩略图交互 + image_complete[3:0]
                            上一张 + 组合键 + 数码管 3 页面
                            Alpha 混合 + 抗混叠 + OSD 参数进度条

阶段 6（交付）               场景四段式章节 + 答辩话术 + 长稳测试证据台账
```

**阶段 4 必须在阶段 5 之前** —— 资源不释放，阶段 5 的功能加不进去。

---

## 九、证据强度台账（第二讲框架）

第二讲给出的证据强度 1–5 级：1 仿真通过 → 5 六十小时长稳 + 冷启动 + 多 sink。

本工程现状：

| 结论 | 当前证据强度 | 缺口 |
|---|---|---|
| SDRAM 时序 | 1–2（仅综合报告，且归因错误） | 需板测波形 + 正确归因 |
| 音频 CTS 正确性 | **0**（断言不成立） | 需精确值断言 + 上板示波器验证 |
| 复位可靠性 | 1（仿真） | 需冷启动 10 次 |
| 长稳 | 未记录 | 需 30 分钟无卡死/撕裂、100 次按键无丢失、10 次冷启动全通过、1 小时温度正常 |
| 缩略图/音量/Flash | — | 功能未实现 |

**本工程最大的工程化短板不是功能数量，而是"出问题时无法定位根因"**：

| 位置 | 本工程 | 资料要求 |
|---|---|---|
| FAT32 文件读取 | `error` 1 bit | 5 个错误码 |
| 帧缓存 | `read_fault` 1 bit | loader 6 + reader 4 + underflow |
| `image_load_manager` | `error_code` 4 bit | 0x51/0x52/0x53 量级，需 ≥7 bit |
| 数码管 | 每管 1 bit | 3 页面 BCD + 字母 |
| 音频 ACR | tb 只断言 `cts != 0` | 断言精确值 25000 |

---

## 十、文档维护清单

| 文档 | 问题 |
|---|---|
| `README.md` | SDRAM `SWNS=-6.565ns` 归因错误；未记录 `sd_card_clk` 66.4 MHz / 630 违例端点 |
| `docs/competition-requirements.md` | 第 79 行"拉伸铺满导致变形"已过时（RTL 已 letterbox）；第 3 项优先级需重排 |
| `docs/superpowers/specs/2026-09-09-clean-dual-frame-crossfade-design.md` | 描述的目标态未落地；引用不存在的 KEY4 |
| `rtl/vendor/SD/frame_dual_fifo_read.v` | 孤儿文件，零引用 |
| `tests/tb_hdmi_audio_acr.sv` | 注释声称的"deliberate gaps"证明不成立 |

---

## 附：资料中值得直接引用的关键数字与结论

- 第六讲：`set_clock_uncertainty -hold 0.050`（默认 0.100）
- 第六讲：`player_config_persistence` — `SLOT0_ADDRESS=24'h7fe000`、`SLOT1_ADDRESS=24'h7ff000`、`ERASE_TIMEOUT_CYCLES=250000000`、`PROGRAM_TIMEOUT_CYCLES=5000000`，7 状态
- 第七讲：FAT 扇区 = `fat_start_lba + (cluster >> 7)`，表项偏移 = `(cluster & 0x7F) << 2`
- 第四讲：`N = 128 × f_s(kHz) = 6144`，`CTS = f_pixel × N / (128 × f_s) = 25000` @25 MHz/48 kHz；DDS 440 Hz → `phase_inc = 39370534`
- 第十二讲：`DECIMATE=12`、`SAMPLE_COUNT=32`、`sample_y = CENTER_Y - sample_value/4`、峰值 `abs(>>8)`
- 第十三讲：`inv_wx` 必须用 `9'd256`（`8'd256` 截成 0）；行加权结果必须先取 `[15:8]` 再做列加权（否则 16 位静默截断）
- 第十五讲：2×2 布局每格 160×120；焦点移动方案 C（两键换行 + 确认 + 模式切换）
- 第十六讲：`A(20) × B(15) × C(15) = 4500` 种场景方向；严选 12 例
