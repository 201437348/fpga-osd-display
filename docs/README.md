# 文档索引

整理日期：2026-09-24。本目录是 `D:\fpga\project` 的文档主区，工程代码在 `fpga/osd_display`。

## 从这里开始

| 文档 | 内容 |
| --- | --- |
| [`handoff-2026-09-25.md`](handoff-2026-09-25.md) | **最新交接**：当前状态、明天先做什么、给新 AI 的约束 |
| [`roadmap.md`](roadmap.md) | **项目路线**：目标、资源审查、风险、阶段划分、当前状态、稳定基线 |
| [`history/board-log.md`](history/board-log.md) | 上板调试流水账（阶段 0～2026-09-23，含已否决/已回退实验） |
| [`history/migration.md`](history/migration.md) | 英文迁移记录（归档，内容停在 2026-09-13） |

## 操作手册（给人看的）

| 文档 | 内容 |
| --- | --- |
| [`brightness-contrast-and-keys-guide.md`](brightness-contrast-and-keys-guide.md) | 按键 / 亮度对比度上板操作手册 |
| [`new-features-usage.md`](new-features-usage.md) | 图片缩放、亮度/对比度菜单使用说明 |
| [`portable-monitor-setup.md`](portable-monitor-setup.md) | 便携 2.5K 显示器设置指南 |
| [`contest-delivery-guide.md`](contest-delivery-guide.md) | 现场交付 / 演示指南 |

## 赛题对照

| 文档 | 内容 |
| --- | --- |
| [`competition-requirements.md`](competition-requirements.md) | 选题一官方要求 vs 当前实现 逐条对照（含待办：Flash 固化验收） |

## 设计与计划（superpowers）

- [`superpowers/specs/`](superpowers/specs/) — 设计规格（62 个，按日期命名）
- [`superpowers/plans/`](superpowers/plans/) — 实施计划（33 个，按日期命名）

近期关键设计：

| 文档 | 内容 |
| --- | --- |
| `specs/2026-09-22-audio-bars-visualizer-design.md` | 音频频谱可视化设计 |
| `specs/2026-09-23-audio-bars-verification.md` | 音频频谱验收 |
| `specs/2026-09-23-wav-parser-timing-fix.md` | WAV 解析时序修复 |

> 09-12 一天产出的 11 个 `*-diagnostic*` 设计文档，是当时定位花屏的临时诊断规格，问题已解决（结论见 `roadmap.md` §5 稳定基线）。保留作复盘用，阅读时不要当现行设计。

## 提示词与移植记录

| 文档 | 状态 |
| --- | --- |
| [`prompts/image-scaling-and-osd-layout-v3-prompt.md`](prompts/image-scaling-and-osd-layout-v3-prompt.md) | ✅ **现行任务书**（合并缩放 v2 + 显示比例 + OSD 布局重构 + 串口屏时钟） |
| `prompts/image-scaling-v2-prompt.md` | 已被 v3 取代（历史） |
| `prompts/display-aspect-resolution-plan-prompt.md` | 已被 v3 取代（历史；其 800×480 方案已否决） |
| `prompts/audio-bars-visualizer-prompt.md` | 现行 |
| `prompts/timing-regression-fix-prompt.md` | 现行 |
| `prompts/brightness-contrast-port-report.md` | 移植记录（非提示词） |

## 外部资料

| 文档 | 内容 |
| --- | --- |
| [`anlogic-eg4s20-sdram-support-request.md`](anlogic-eg4s20-sdram-support-request.md) | 安路 FAE 支持请求草稿（已标注勿发） |

赛题原文提取文本在 `tmp_competition/`（`pdf_text.txt`、`pptx_text.txt`），被 `competition-requirements.md` 引用。

## 已迁移 / 归档

- `project-roadmap.md` → 已拆分为 `roadmap.md` + `history/board-log.md`（原文件保留为跳转说明）
- `osd-display-migration.md` → `history/migration.md`（原文件保留为跳转说明）