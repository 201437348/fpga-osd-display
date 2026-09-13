# SDRAM Refresh FIFO Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and execute a repeatable seven-run SDRAM refresh-stall and FIFO-depth simulation matrix.

**Architecture:** Keep production RTL unchanged and put all configuration in a parameterized testbench, a configurable behavioral FIFO, and a PowerShell runner. Each run produces a full log plus a structured summary row.

**Tech Stack:** Verilog-2001, Icarus Verilog 14.0, PowerShell 7/Windows PowerShell

**Spec:** `docs/superpowers/specs/2026-09-11-sdram-refresh-fifo-sweep-design.md`

## Global Constraints

- Use `mem_clk=125 MHz`, `video_clk=25 MHz`, `REFRESH_INTERVAL_CYCLES=977`, `GAP_CYCLES=15`, and at most 24 frames; terminate early on a proven unrecoverable missing return.
- Run stall cycles 1, 2, 4, 8, and 16 at FIFO depth 512.
- Run FIFO depths 1024 and 4096 at stall cycles 16.
- Do not modify synthesizable production RTL or vendor IP.

---

### Task 1: Parameterized behavioral FIFO

**Files:**
- Modify: `tmp_investigate2/rfifo_32_32_512.v`

**Interfaces:**
- Consumes: vendor-compatible `rfifo_32_32_512` signals.
- Produces: module parameters `DEPTH` and `AW`, with `wrusedw/rdusedw` width `AW`.

- [x] **Step 1:** Parameterize depth, pointer width, memory indexing, and saturated full count.
- [x] **Step 2:** Compile a 512-word refresh testbench smoke case to verify compatibility.

### Task 2: Refresh sweep testbench

**Files:**
- Create: `tmp_investigate2/tb_refresh_sweep.v`

**Interfaces:**
- Consumes: `FIFO_DEPTH`, `FIFO_LEVEL_BITS`, `REFRESH_STALL_CYCLES`, and fixed matrix timing parameters.
- Produces: `[FRAME ...]` diagnostic lines and one `RESULT` line.

- [x] **Step 1:** Instantiate the video timing, DUT, and refresh SDRAM model with connected `Sdr_busy`.
- [x] **Step 2:** Add per-frame underflow statistics, dropped-command counting, scheduler-stall detection, and safety timeout.
- [x] **Step 3:** Compile and run one 512-word smoke case; require exactly one `RESULT` line.

### Task 3: Matrix runner and results

**Files:**
- Create: `tmp_investigate2/run_refresh_sweep.ps1`
- Create: `tmp_investigate2/results/*.log` (generated)
- Create: `tmp_investigate2/results/summary.csv` (generated)

**Interfaces:**
- Consumes: the seven matrix rows and testbench `RESULT` line.
- Produces: per-run logs, CSV fields for completion/underflow/drop/deadlock, and a console table.

- [x] **Step 1:** Compile each row with top-level parameter overrides and an explicit source list.
- [x] **Step 2:** Run each image with a bounded process timeout and capture stdout/stderr.
- [x] **Step 3:** Parse the final `RESULT`, write `summary.csv`, and fail only on infrastructure errors.
- [x] **Step 4:** Execute all seven rows and inspect the logs and summary for consistency.
- [x] **Step 5:** Run `git diff --check` and report findings without changing production RTL.
