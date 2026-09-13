# SDRAM Busy Read Backpressure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the active frame read scheduler honor SDRAM refresh busy without losing commands.

**Architecture:** Gate `App_rd_en` with `!Sdr_busy` and advance the issue counter/address/state only on accepted command cycles. Preserve asynchronous return handling, then validate locally and through the seven-case refresh matrix.

**Tech Stack:** Verilog-2001, SystemVerilog testbench, Icarus Verilog 14.0, PowerShell

**Spec:** `docs/superpowers/specs/2026-09-11-sdram-busy-read-backpressure-design.md`

## Global Constraints

- Modify only the active `frame_slide_fifo_read` production module.
- Do not change the SDRAM controller interface or simulated drop-on-busy behavior.
- Require contiguous, non-duplicated accepted addresses through busy pulses.
- Require all seven refresh cases to complete 24 frames without drops, deadlock, or underflow.

---

### Task 1: Reproduce busy-cycle command loss

**Files:**
- Modify: `fpga/osd_display/tests/tb_frame_slide_fifo_read.sv`
- Test: `fpga/osd_display/tests/tb_frame_slide_fifo_read.sv`

**Interfaces:**
- Consumes: `Sdr_busy`, `App_rd_en`, `App_rd_addr`, and DUT `issue_count`.
- Produces: assertions that busy suppresses requests and freezes issue state.

- [x] **Step 1:** Add deterministic busy pulses during first, middle, and final issue positions.
- [x] **Step 2:** Compile and run the unchanged RTL; verify the new busy assertion fails.

### Task 2: Honor SDRAM busy in the read scheduler

**Files:**
- Modify: `fpga/osd_display/rtl/vendor/SD/frame_slide_fifo_read.v`
- Test: `fpga/osd_display/tests/tb_frame_slide_fifo_read.sv`

**Interfaces:**
- Consumes: synchronous `Sdr_busy` backpressure.
- Produces: `App_rd_en = (state == S_ISSUE) && !Sdr_busy` and accepted-command-only state advancement.

- [x] **Step 1:** Gate `App_rd_en` with `!Sdr_busy`.
- [x] **Step 2:** Hold `issue_count` and `App_rd_addr` in `S_ISSUE` while busy.
- [x] **Step 3:** Run the scheduler unit test and require `PASS tb_frame_slide_fifo_read`.

### Task 3: Refresh regression matrix

**Files:**
- Generated: `tmp_investigate2/results/*.log`
- Generated: `tmp_investigate2/results/summary.csv`

**Interfaces:**
- Consumes: `tmp_investigate2/run_refresh_sweep.ps1` and the fixed production RTL.
- Produces: seven `OK` rows completing 24 frames with zero drops/deadlocks/underflows.

- [x] **Step 1:** Run all seven matrix cases with a sufficient wall-clock timeout.
- [x] **Step 2:** Validate all CSV invariants and exactly one `RESULT` per log.
- [x] **Step 3:** Compile existing related read-path tests and run `git diff --check`.
