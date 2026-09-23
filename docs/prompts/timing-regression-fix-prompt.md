# 时序回退（SWNS −6.565 → −8.131）定位与修复 Prompt

本文件是给 AI 编码代理使用的任务 Prompt。把 `===== PROMPT 开始 =====` 与
`===== PROMPT 结束 =====` 之间的内容整段复制给代理即可。

结论摘要（供你判断要不要做）：**新功能不是原因**。−8.131 这条路径在
`sd_card_clk`（100 MHz）的 WAV 解析器里，同一份源码在另一个构建目录里只跑出
−3.647；历史那条 −6.565 的 SDRAM 路径一点没变。真正的长杆是一个 **32 次串行
迭代的模 3 归约循环**，可以低风险修掉。详见下面的证据。

---

===== PROMPT 开始 =====

## 任务

定位并（可选地）修复本工程最近一次 TD 构建的时序回退：

- 全局 `SWNS` 从 `−6.565 ns` 变成 `−8.131 ns`；
- 全局 `HWNS` 从 `−0.020 ns` 变成 `−0.012 ns`。

工作目录 `D:\fpga\project`，主工程 `fpga/osd_display/osd_display.al`，
器件 EG4S20BG256，工具 TD 6.2.1（`D:/Anlogic/TD_6.2.1_Engineer_6.2.168.116`），
仿真 Icarus Verilog。

**先读结论，再动手。不要重新做一遍完整调研。**

## 一、已经查清的事实（不要推翻，直接采信）

### 1.1 两次构建的源码逐字节相同

`fpga/osd_display/audio_bars_Runs/source-manifest.sha256`（生成于 2026-09-23
19:06:24）记录了 `phy_3` 构建所用的全部 73 个源文件哈希。我逐个与当前工作区
比对：**73/73 全部一致，0 个变化，0 个缺失**。

也就是说，`audio_bars_Runs/phy_3`（SWNS −6.565）和
`osd_display_Runs/phy_1`（SWNS −8.131）是**同一份 RTL、同一份 pin.adc、
同一份 timing.sdc** 的两个构建结果。

**所以 −8.131 不是新功能（音频柱、亮度/对比度菜单、图片缩放）改出来的。**

### 1.2 必须看分时钟表，不能只看汇总行

只读报告顶部的 `SWNS:` 汇总行会得出错误结论。逐时钟对比（单位 ns）：

| 时钟 | 域 / 频率 | `audio_bars_Runs/phy_2` | `audio_bars_Runs/phy_3` | `osd_display_Runs/phy_1`（现在） |
| --- | --- | ---: | ---: | ---: |
| clk0 | `sd_card_clk` 100 MHz | −3.049 | −3.647 | **−8.131** ← 唯一真正变差的 |
| clk1 | `video_clk` 25 MHz | +4.746 | +2.548 | +4.545 |
| clk2 | 125 MHz（SDRAM 硬核） | −6.565 | −6.565 | **−6.565** ← 完全没变 |
| clk3 | 50 MHz | +0.802 | +0.597 | +1.239 |
| clk4 | 125 MHz（HDMI 5x） | +0.271 | +0.559 | +0.263 |
| clk5 | 125 MHz | −3.709 | −3.781 | −3.492 |
| 全局 | SWNS / HWNS | −6.565 / — | −6.565 / −0.020 | −8.131 / **−0.012** |

两条关键澄清：

1. **历史那条 −6.565 的 SDRAM 路径（clk2）没有任何退化**，两次构建都是
   −6.565，一模一样。汇总行从 −6.565 变成 −8.131，是因为另一个时钟域
   （clk0）冒出了一条更差的路径，把最差值顶掉了，不是原来那条变差。
2. **HWNS 其实变好了**：phy_3 是 −0.020（clk1），现在是 −0.012（clk2）。
   "hold 从没有变成 −0.012"是误读——它之前就是负的。

真正的问题只有一个：**clk0（100 MHz 存储域）从 −3.6 掉到 −8.1。**

### 1.3 最差路径的精确位置

`osd_display_Runs/phy_1/final_timing.rpt` 第 85–185 行：

```text
Slack           : -8.131ns
Begin Point     : image_storage_adapter_m0/u_fat32_wav_loader/u_file_sector_reader/file_sec_data_reg[6]_syn_4.clk
End Point       : image_storage_adapter_m0/u_fat32_wav_loader/parser_state_reg[1]_syn_10.a[0]
Budget          : 10.000ns
Data Path Delay : 17.779ns (cell 7.184ns (40%), net 10.595ns (60%))
Logic Level     : 16 ( LUT5=10 LUT4=5 LUT2=1 )
```

对比 `audio_bars_Runs/phy_3/final_timing.rpt` 同一条锥：

```text
Slack           : -3.647ns
End Point       : image_storage_adapter_m0/u_fat32_wav_loader/parser_error_reg_syn_462.ce
Data Path Delay : 13.367ns (cell 5.596ns (41%), net 7.771ns (59%))
Logic Level     : 12 ( LUT5=11 LUT4=1 )
```

同一条 `file_sec_data → parser` 锥，**逻辑级数 12 → 16，单元延迟 +1.6 ns，
线延迟 +2.8 ns**。报告里的 `Netlist Info` 把中间级指向
`rtl/storage/fat32_wav_loader.v` 的 **第 94、114、154 行**。

### 1.4 长杆就是那个串行模 3 循环

`rtl/storage/fat32_wav_loader.v` 第 104–119 行：

```verilog
function is_divisible_by_six;
    input [31:0] value;
    integer bit_index;
    reg [2:0] remainder;
    begin
        remainder = 3'd0;
        for (bit_index = 31; bit_index >= 0; bit_index = bit_index - 1) begin
            remainder = {remainder[1:0], value[bit_index]};
            if (remainder >= 3'd3)          // <-- 报告指向的第 114 行
                remainder = remainder - 3'd3;
        end
        is_divisible_by_six = !value[0] && (remainder == 3'd0);
    end
endfunction
```

这是 **32 次串行迭代**的模 3 归约：每一位都要经过"移位 + 比较 + 条件减法"，
本身就是一条几十级的组合链。

它在第 350 行被调用，位于 `P_CHUNK_SIZE` 状态里：

```verilog
// rtl/storage/fat32_wav_loader.v 第 325-371 行附近
P_CHUNK_SIZE: begin
    ...
    if ({reader_file_sec_data, chunk_size[23:0]} < 32'd16) ...
    else if (... ({reader_file_sec_data, chunk_size[23:0]} == 32'd0) ||
             !is_divisible_by_six({reader_file_sec_data, chunk_size[23:0]}) ...
```

即：**收到 chunk size 第 4 个字节的那一拍，组合地做完
32 位拼接 → 32 位比较 → 32 次串行模 3 → 更多比较 → 写 `parser_state` /
`chunk_size`**，全部挤在一个 100 MHz 周期（10 ns）里。这就是那条 16 级、
17.8 ns 的路径。

### 1.5 尚未解释清楚的一点（需要你去查）

两次构建的 RTL 相同、`settings.cfg` 内容相同、`.al` 的策略块都是空的
（用 TD 默认），但综合网表确实不同：

| 综合结果 | syn_7（audio_bars） | syn_1（主工程） |
| --- | ---: | ---: |
| `#Total_luts` | 10019 | 9986 |
| `#lut4` | 8984 | 8765 |
| `#lut5` | 883 | 1069 |
| `#lut6` | 152 | 152 |
| `#lut`（设备） | 16513 | 16462 |
| `#reg` | 9269 | 9187 |

`audio_bars_Runs` 里有 `syn_1`..`syn_8` 共 8 次综合，说明当时很可能做过策略/参数
尝试（最后选了 syn_7）。**那次的非默认设置没有被记录进当前的 `.al`。**

所以你的第一步是：**查清 syn_7 与 syn_1 的差异来源**。查不到也没关系——第 1.4
节的 RTL 修复与构建无关，做了就稳。

## 二、动手顺序

### 第 0 步：先复现，别急着改

1. 按第 1.2 节的方法，把三个 `final_timing.rpt` 的分时钟表重新提一遍，确认
   数字对得上（提取方法见第四节）。
2. 在主工程重新跑一次 `syn` + `phy`（新 run），看 clk0 落在 −3 还是 −8。
   - 如果新 run 回到 −3.x：说明是构建波动，先记录再决定是否继续；
   - 如果仍然是 −8.x：进第 1 步做 RTL 修复。

### 第 1 步：RTL 修复（推荐，低风险，与构建无关）

改 `rtl/storage/fat32_wav_loader.v`，两处：

**(a) 把串行模 3 换成并行树。**
`n mod 3` 可以按 2 bit 一组并行归约：把 32 bit 拆成 16 个 2 bit 组相加
（2 bit 组的值 0..3，其中 3 ≡ 0、4 ≡ 1，所以直接相加即可），用**平衡加法树**
求和（最大 48），再对这个小和做模 3（最多两次条件减法）。
深度从 ~32 级降到 ~5 级。

也可以更省事：在 `P_CHUNK_SIZE` 的前三个字节状态里**增量维护**
`chunk_size[23:0]` 的模 3 余数，第 4 个字节到达时只剩一次小规模归约。

**(b) 把"采集"和"校验"拆成两个状态。**
现在是第 4 个字节到达当拍就校验。拆成
`P_CHUNK_SIZE`（收 4 字节）→ `P_CHUNK_CHECK`（校验并决定后续状态）：
多花 1 个 100 MHz 周期 = **10 ns**，WAV 头每文件只解析一次，对功能与吞吐
**完全无影响**，但把长组合链直接切断。

两处都做最好；(b) 单独做也足够把这条路径从关键路径上摘掉。

**行为必须逐位不变**：合法 chunk 的接受/拒绝判定、`chunk_pad_pending`、
`chunk_size` 语义、后续状态跳转、错误标志，全部保持等价。这是纯时序重构，
不是功能修改。

### 第 2 步（可选）：如果只想尽快出货

`audio_bars_Runs/phy_3/osd_display.bit` 是用**逐字节相同的源码**构建的，
SWNS −6.565，且当时 11 项 Icarus 测试全过。可以直接用它下载验证。
但要注意：它是另一次综合的网表（`#lut5` 分布不同），功能等价但实现不同；
如果要长期维护，还是把第 1 步做掉，让主工程自己的构建就干净。

## 三、硬约束

- **不得修改**音频数据通路：`audio_pcm_player.v`、`hdmi_audio_acr.v`、
  `wfifo_32_32_512` 实例、`audio_spectrum_*`、`audio_band_processor.v`、
  `audio_bars_overlay.v`。它们全部在 `video_clk`（clk1 = +4.545 ns，健康），
  与本次问题无关。
- **不得修改** SDRAM 双缓冲、`frame_*_fifo_read/write`、`sd_sector_arbiter`、
  转场、ticker、按键逻辑。
- **不得修改** `constraints/pin.adc`、`constraints/timing.sdc`，**不得放宽或
  新增时序例外**来"修"数字。数字必须靠逻辑变浅或布局改善来拿。
- 不得引入新的时钟、PLL 或跨时钟域路径。
- 不得改动 `fat32_bmp_loader.v` / `image_bilinear_scaler.v` 的功能行为。
- 不得删除 `audio_bars_Runs/` 下的证据目录（`syn_7`、`phy_3`、
  `source-manifest.sha256`）——它们是本次对比的基线。

## 四、验证要求

### 4.1 提取分时钟表（每次构建都要贴）

```powershell
# 全局汇总 + 分时钟表（前 52 行就够）
Get-Content <run>\final_timing.rpt | Select-Object -First 52 |
  Select-String -Pattern 'SWNS:|HWNS:|clk[0-9]\s+local'
# 最差路径细节
Get-Content <run>\final_timing.rpt | Select-Object -Skip 84 -First 20
```

### 4.2 功能回归（RTL 改动后必须全绿）

```powershell
fpga/osd_display/tools/run_audio_bars_tests.ps1
```

重点是 WAV 相关：`tb_fat32_wav_loader.sv`、`tb_fat32_wav_long_file_reader.sv`
（以及适配器/仲裁器测试）。**新增一个针对性用例**：喂入 chunk size 为
`40`（偶、不被 3 整除）与 `42`（偶、被 3 整除）两种头，断言改动前后
**接受/拒绝结果完全一致**——这是防止"把串行循环改坏"的唯一有效保护。

### 4.3 构建

- TD `syn` + `phy` 完整跑完，bitgen 有非空 `.bit`，无 ERROR。
- 贴出新的分时钟表与资源表（`osd_display_phy.area`）。

## 五、验收标准

1. **clk0（`sd_card_clk`）的 SWNS ≥ −3.647 ns**（即回到或好于 phy_3 的水平），
   理想情况 ≥ −2 ns。
2. **全局 SWNS 不差于 −6.565 ns**，并且全局最差路径重新回到 clk2/clk5
   （历史已接受的 SDRAM 路径），而不是 clk0。
3. **不出现新的 hold 违例**：全局 HWNS 不差于 −0.020 ns。
4. 资源增量在预算内（≤2500 LUT、≤6 BRAM9K、≤2 DSP），不新增 PLL。
5. 全部 Icarus 测试通过，含 4.2 新增的 chunk size 边界用例。
6. 报告里必须**如实写明**：clk2（−6.565）和 clk5（−3.492）仍然是负裕量，
   这是本工程长期存在的、已接受的 SDRAM/HDMI 路径基线，**本次不解决也不掩饰**。
   不允许用"SWNS 不差于基线"一句话带过全工程时序状态。

## 六、非目标

- 不追求全工程时序收敛。clk2/clk5 的 SDRAM 硬核 DQ 路径是长期接受的负裕量，
  本次不动。
- 不做 SDRAM 时钟降频、不改 PLL 相位、不改 HDMI 5x 时钟。
- 不为"让数字好看"而删逻辑、改约束、加时序例外。
- 不改音频可视化的任何参数或外观（已通过验收，不要回退）。
- 不动 `td_project/osd_display.al`（过期副本）。

## 七、交付物

1. 修改后的 `rtl/storage/fat32_wav_loader.v`（若做 RTL 修复）。
2. 新增/扩展的 Icarus 测试 + 实际输出。
3. 新的 TD 构建目录，附分时钟时序表、资源表、bit 文件哈希。
4. 一段结论：clk0 修好没有、靠的是重建还是 RTL、syn_7/syn_1 差异是否查明。
5. 更新 `docs/superpowers/specs/` 下的一份中文记录（沿用仓库既有 spec 结构：
   目标 / 选择范围 / 架构 / 接口与资源 / 异常策略 / 验证 / 非目标），并在
   `docs/project-roadmap.md` 补一条。

===== PROMPT 结束 =====
