# 音频频谱与亮度/对比度移植验证记录

日期：2026-09-23。器件 EG4S20BG256，TD 6.2.168116；仿真 Icarus Verilog。

## 交付范围

亮度/对比度和参数菜单已移植，默认像素恒等、帧边界提交和按键操作均有回归测试。底部旧 DFT 替换为 512 点 FFT（hop 256），48 个独立频带；每根亮 2 像素、间隔 2 像素，范围 x=224..415、最大高 80 像素。固定冰蓝白渐变，静音保留 y=415/416 柔边与白线。

文件逐字节比较确认：brightness_contrast_adjust、param_menu_controller 与更新版参考工程一致；audio_pcm_player、hdmi_audio_acr 也与该参考一致。

采用 prompt 允许的 512 点降级方案，频率分辨率 93.75 Hz。接口为 24 位左对齐容器，当前 WAV 的有效音频精度为 16 位。幅度保留 16 位至对数映射，避免提前压成 8 位饱和。静音门限 58/32768（约 −55 dBFS），唤醒门限 82；持续 18 帧低电平归零。

## 仿真结果

运行 `fpga/osd_display/tools/run_audio_bars_tests.ps1`，11 项测试及顶层展开通过。末尾保留实际输出。顶层展开使用厂商黑盒，只证明接口连接，不替代硬件验证。

1 kHz 三档输入输出 4247 → 424 → 42，幅度单调且无旧版饱和。峰值 bin 为 11，4 kHz 为 43；512 点下位置正确。直流稳定后的最大残留为 4，纯静音为 0，反相左右声道混合为 0。测试检查 1024 个样本产生两组频谱，无 overrun。

48 个频带经过 170 次单 bin 探测；三音端到端验证通过。柱处理检查独立交错频带顺序、AGC、18 帧静音和阈值回差。释放 11 帧由 234 降至 71，约 30.3%。像素测试遍历 921600 个像素，另与亮度版参考 OSD 比较菜单开/关两帧，保护标题、状态和字幕。

## 资源对比

基线为同一亮度/对比度移植版本，仅断开底部频谱消费者，保留顶部音量条；不是 prompt 中较早版本的历史占用。两次均使用同一 TD 综合设置。

| 综合资源 | 基线 baseline_syn | 最终 syn_7 | 增量 |
| --- | ---: | ---: | ---: |
| 设备 LUT | 14090 | 16513 | 2423 |
| Total_luts（逻辑统计） | 8458 | 10019 | 1561 |
| REG | 8040 | 9269 | 1229 |
| BRAM9K | 48 | 54 | 6 |
| DSP | 25 | 26 | 1 |
| PLL | 2 | 2 | 0 |

综合增量满足 ≤2500 LUT、≤6 BRAM9K、推荐 ≤2 DSP。设备 LUT 与 Total_luts 为不同口径，不混用。布局布线会继续复制/优化逻辑，最终物理总量另列，不能拿物理总量减综合基线。

## TD 构建与时序

最终 `syn_7` 综合、`phy_3` 布局布线与 bitgen 均完成，存在 `.bitgen.end.f` 和非空 bit 文件，无 ERROR。最终物理总量为 LUT 16898/19600、REG 9379/19600、BRAM9K 54/64、DSP 26/29、PLL 2/4。

实际时序：SWNS **−6.565 ns**，不差于指定基线；STNS **−1020.595 ns**；HWNS **−0.020 ns**，HTNS **−0.079 ns**。video_clk 的 setup WNS 为 **+2.548 ns**，hold WNS 为 **−0.020 ns**。仍有负裕量，不能宣称全工程时序收敛；STNS 与各路径裕量也不能由 SWNS 一项代表。没有放宽时序约束。

最终日志保留三条 critical warning：PHY-7002 两条（U3/sdram 两处位置约束未采用）、PHY-5079 一条（一个时钟网使用局部布线）。这些代码、对象及位置在原工程 `osd_display_Runs/phy_1/seed_2/td_20260911_224237.logw` 中均已有对应记录，本次未出现新的 critical warning 类型。普通 warning 仍包括厂商加密 SDRAM/HDMI 及已有端口位宽警告，并非零警告构建。

下载文件：[osd_display.bit](../../../fpga/osd_display/audio_bars_Runs/phy_3/osd_display.bit)。SHA256：

```text
7c68420025e4c15fb35bb5ab663214f40be52d36f636ab9cb1805a5d0d2c84be
```

原始证据：`audio_bars_Runs/syn_7/osd_display_gate.area`、`baseline_syn/osd_display_gate.area`、`phy_3/osd_display_phy.area`、`phy_3/final_timing.rpt` 和 `phy_3/build_console.log`。

构建目录在 `fpga/osd_display/audio_bars_Runs/`，保留原有 `osd_display_Runs`。最终综合为 `syn_7`，最终物理实现为 `phy_3`；`phy_1`、`phy_2` 是中间版本，不用于本次下载。源文件散列见 `audio_bars_Runs/source-manifest.sha256`。

主工程 `fpga/osd_display/osd_display.al` 已登记新模块，63 个 CompileOrder 连续且唯一，所有文件路径存在。`td_project/osd_display.al` 是过期列表，本次未修改；后续请打开主工程。

## 上板验收仍待完成

JTAG 下载最终文件后，用音乐确认 48 根细柱随频率和节拍起落；低电平或暂停约 300 ms 后落平、白线稳定。检查亮度/对比度调节与恢复默认、滚动字幕、图片轮播、手动切图、转场、TF 拔插和 HDMI 音频。仿真和 bitgen 成功不能代替这些实机观察。

## 实际测试输出

```text
attack=234
release11=71/234
silence=zero at 18 frames
AGC gain_shift=3 recovered=225
PCM gate: below 58 for 18 frames mutes; 58 holds; 81 stays muted; 82 wakes
PASS tb_audio_band_processor
D:\fpga\project\fpga\osd_display\tests\tb_audio_band_processor.sv:70: $finish called at 1049060000 (1ps)
PASS tb_audio_bars_overlay: 921600 pixels, 48 indices, gradient, silence, blanking
D:\fpga\project\fpga\osd_display\tests\tb_audio_bars_overlay.sv:30: $finish called at 921649000 (1ps)
PASS tb_audio_pcm_player
D:\fpga\project\fpga\osd_display\tests\tb_audio_pcm_player.sv:110: $finish called at 10017000 (1ps)
PASS tb_audio_spectrum_bands: 170 single-bin probes, 48 unique bands, multi-bin peaks
D:\fpga\project\fpga\osd_display\tests\tb_audio_spectrum_bands.sv:35: $finish called at 439500000 (1ps)
freq=1000.000000 amp=16384 peak_bin=11 magnitude=4247 frames=2
freq=1000.000000 amp=1638 peak_bin=11 magnitude=424 frames=2
freq=1000.000000 amp=164 peak_bin=11 magnitude=42 frames=2
freq=4000.000000 amp=16384 peak_bin=43 magnitude=4282 frames=2
freq=0.000000 amp=0 peak_bin=0 magnitude=0 frames=2
freq=0.000000 amp=0 peak_bin=0 magnitude=4 frames=2
freq=1000.000000 amp=16384 peak_bin=0 magnitude=0 frames=2
PASS tb_audio_spectrum_fft
D:\fpga\project\fpga\osd_display\tests\tb_audio_spectrum_fft.sv:43: $finish called at 149382240000 (1ps)
multi-tone band peaks: 1176 1278 1261
PASS tb_audio_spectrum_pipeline
D:\fpga\project\fpga\osd_display\tests\tb_audio_spectrum_pipeline.sv:27: $finish called at 32023240000 (1ps)
PASS tb_brightness_contrast_adjust: 4096 RGB cases, identity, frame commit
D:\fpga\project\fpga\osd_display\tests\tb_brightness_contrast_adjust.sv:29: $finish called at 5350000 (1ps)
PASS tb_hdmi_audio_acr
D:\fpga\project\fpga\osd_display\tests\tb_hdmi_audio_acr.sv:56: $finish called at 376000 (1ps)
PASS tb_param_menu_controller: short/long, saturation, select, restore
D:\fpga\project\fpga\osd_display\tests\tb_param_menu_controller.sv:19: $finish called at 3370000 (1ps)
PASS tb_video_osd_overlay
D:\fpga\project\fpga\osd_display\tests\tb_video_osd_overlay.sv:407: $finish called at 231000 (1ps)
PASS tb_video_osd_regression: two full frames, title/status/ticker/menu unchanged
D:\fpga\project\fpga\osd_display\tests\tb_video_osd_regression.sv:23: $finish called at 6172850000 (1ps)
PASS top elaboration (vendor black boxes; not hardware simulation)
```
