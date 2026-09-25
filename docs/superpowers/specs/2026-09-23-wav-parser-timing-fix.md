# WAV 头解析时序回退修复

日期：2026-09-23。器件 EG4S20BG256，TD 6.2.168116，Icarus Verilog。

## 目标

消除 `sd_card_clk`（100 MHz）的 WAV chunk size 校验长组合链，使 clk0
setup WNS 回到不差于 −3.647 ns、全局不差于 −6.565 ns、hold WNS
不差于 −0.020 ns。保持合法/非法 WAV 判定、PCM 字节顺序和接收节拍。

## 选择范围与根因

只修改生产 RTL `fat32_wav_loader.v`。主工程 `.al`、引脚、SDC、PLL、
音频播放/频谱/OSD、SDRAM、BMP 与缩放 RTL 均未修改。

已核对 `audio_bars_Runs/phy_2`、`phy_3`、`osd_display_Runs/phy_1` 的
分时钟报告，数值与任务文档一致。进一步检查发现原文档关于综合设置的推断
不成立：真正生效的参数并不相同。

- `audio_bars_Runs/syn_7/build_console.log:370`：`infer_fsm=auto`，推断出
  16 个 FSM；其 `.prj` 把 `infer_fsm=off` 放在嵌套 `Runs/Run/Strategy`
  内，直接 `open_project .prj` 的构建未应用该嵌套策略。
- 主工程 `osd_display.al` 的综合策略实际包含 `infer_fsm=off`；GUI 导出的
  `osd_display_Runs/syn_1/osd_display.prj` 将它放到顶层 `Property`。
  `run.log:364,371` 确认执行 `set_param rtl infer_fsm off`。
- 两份 `.prj` 还存在编译顺序和路径表达差异。因此不能声称已用单变量实验
  证明 FSM 设置解释全部差异，但“相同有效综合设置”已被日志排除。

`timing_fix_Runs/repro_syn` 使用主工程现有 `.prj` 和设置，重新综合的
`osd_display_gate.db` SHA256 与问题构建逐字节一致：
`71e8996691d9f4f5ab7130bae76d7f2b1381dbfbe6721b7edd070bc7c900ac34`。
`repro_phy` 完整布线/bitgen 后各时钟裕量也完全复现，包括 clk0 −8.131 ns。
本次修复保留 `infer_fsm=off`，改善来自 RTL，不靠切换综合策略。

## 架构

利用 `256 ≡ 1 (mod 3)`，四个 little-endian 长度字节的模 3 余数可以
逐字节累积。增加 2 位寄存器 `chunk_size_mod3`，只在真实接收长度字节时
更新；首字节从零开始，复位和文件重读也清零。

单字节归约将四个 2 位组两两相加，再相加得到 0..12，查表得到 0..2；
与旧余数相加仅需一次条件减 3。所有中间位宽显式保留进位。
第四字节到达时，使用新余数和已保存的最低位判定 6 的整除性。
16 位 PCM 的 4 字节对齐检查、大小上限、padding 和状态跳转保持原样。

未采用建议中的额外 `P_CHUNK_CHECK` 空转周期：文件读取器没有逐字节
ready/反压接口，且仿真支持连续有效字节，直接插入状态会漏掉 payload
首字节。逐字节流水累积切断 32 位串行运算，且无需缓存或改变接口。

## 接口与资源

外部接口、时钟和吞吐量不变；RTL 新增 2 位余数寄存器，移除 32 次串行
模 3 归约链。最终资源以同设置的综合/物理报告分别比较。

## 异常策略

保留原有零长度、未见 fmt、非整帧、超出文件剩余长度等错误处理。
40 字节 24-bit stereo data 拒绝，42 字节接受，41 字节和 0 字节拒绝；
fmt chunk 的 40 字节长度仍可正常解析。abort、循环重读与音频 FIFO
水位策略保持不变。

## 验证

构建证据位于 `fpga/osd_display/timing_fix_Runs/`：

- `repro_syn` / `repro_phy`：修改前主工程设置的独立重建。
- `fix_syn` / `fix_phy`：修改后同设置的独立重建。
- `original_fat32_wav_loader.v`：修改前 RTL。
- `source-manifest.sha256`：修复版本的 73 个源文件散列。
- `tests_before/wav.txt`、`adapter.txt`：新边界用例及音频适配器场景在
  修改前 RTL 上通过。
- `tests_after`：运行 `tools/run_audio_bars_tests.ps1` 的最终日志。

复现命令（在各独立 run 目录执行，先 syn 后 phy；settings.cfg 中 phy 的
parent 指向对应 syn）：

```powershell
& D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe `
  D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/doc/scripts/DefaultFlow.tcl
```

`source-manifest.sha256` 与旧 `audio_bars_Runs` manifest 对比，73 个条目中
仅 WAV loader 一个源文件变化；约束和所有其他生产源文件保持相同。

原脚本仅覆盖 11 个音频/显示测试和顶层展开，未覆盖 WAV。此次加入 WAV、
4097-cluster 长文件读取、SD 仲裁器、模 3 算术和真实音频适配器场景。
算术测试穷举全部 768 个合法余数/字节组合，再检查 75540 个 32 位数值，
用测试端 `% 3` / `% 6` 作独立判据。WAV 测试检查连续字节下 42 字节
payload 的全部 7 帧及循环首帧，防止丢字节或帧错位。

旧 `tb_fat32_image_storage_adapter` 使用迁移前的元数据标量名，直接展开
失败；改为当前数组接口并提供 `AUDIO_ONLY` 场景，检查真实扫描、PCM、
水位暂停/恢复、循环与 storage reinit。原 BMP 场景未纳入本次通过声明，
它的短 BMP fixture 早于缩放迁移，仍需单独维护。

## 非目标

本次不追求全工程时序收敛。历史 clk2/clk5 SDRAM/HDMI 路径仍有负裕量，
不更改它们的逻辑或约束，也不能把生成 bit 当作上板验收。

## 最终构建结果

16 项仿真全部通过，顶层展开通过（厂商黑盒，不代表硬件仿真）。实际输出：

```text
PASS tb_audio_band_processor
PASS tb_audio_bars_overlay: 921600 pixels, 48 indices, gradient, silence, blanking
PASS tb_audio_pcm_player
PASS tb_audio_spectrum_bands: 170 single-bin probes, 48 unique bands, multi-bin peaks
PASS tb_audio_spectrum_fft
PASS tb_audio_spectrum_pipeline
PASS tb_brightness_contrast_adjust: 4096 RGB cases, identity, frame commit
PASS tb_fat32_wav_loader
PASS tb_fat32_wav_long_file_reader
PASS tb_hdmi_audio_acr
PASS tb_param_menu_controller: short/long, saturation, select, restore
PASS tb_sd_sector_arbiter
PASS tb_video_osd_overlay
PASS tb_video_osd_regression: two full frames, title/status/ticker/menu unchanged
PASS tb_wav_chunk_mod3: 768 byte/residue pairs, 75540 full-width sizes
PASS tb_wav_storage_adapter: scan, PCM, watermark, loop, reinit
PASS top elaboration (vendor black boxes; not hardware simulation)
```

同设置综合资源：

| 资源 | repro_syn | fix_syn | 增量 |
| --- | ---: | ---: | ---: |
| 设备 LUT | 16462 | 16499 | +37 |
| Total_luts | 9986 | 10017 | +31 |
| REG | 9187 | 9189 | +2 |
| BRAM9K | 54 | 54 | 0 |
| DSP | 26 | 26 | 0 |
| PLL | 2 | 2 | 0 |

最终 `fix_syn` / `fix_phy` 已完成布局、布线和 bitgen，无 ERROR；保留的
critical warning 仍是原工程已有的两条 PHY-7002 SDRAM 位置约束和一条
PHY-5079 局部时钟布线。

最终时序（`fix_phy/final_timing.rpt`）：

| 时钟 | setup WNS | hold WNS |
| --- | ---: | ---: |
| clk0 sd_card_clk 100 MHz | −2.930 ns | −0.004 ns |
| clk1 video_clk 25 MHz | +5.399 ns | −0.011 ns |
| clk2 SDRAM 125 MHz | −6.565 ns | +0.086 ns |
| clk3 50 MHz | +0.046 ns | +0.586 ns |
| clk4 HDMI 5x 125 MHz | +0.357 ns | +0.214 ns |
| clk5 125 MHz | −3.951 ns | +3.874 ns |
| **全局** | **SWNS −6.565 ns** | **HWNS −0.011 ns** |

clk2 和 clk5 仍为工程长期接受的 SDRAM/HDMI 负裕量，本次没有修改。
clk0 的最差路径已不再来自 WAV parser，报告显示为 scaler 的 9 级路径。

最终物理资源（`fix_phy/osd_display_phy.area`）：LUT 16930/19600、REG
9292/19600、BRAM9K 54/64、DSP 26/29、PLL 2/4。bit 文件为 629624 字节，
SHA256 `F6E58A62A307ED068DE7F914AD2C3E835314551D5310E4329ADD0B8D2E4E7F20`。
