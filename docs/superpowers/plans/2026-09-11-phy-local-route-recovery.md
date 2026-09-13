# PHY Local Route Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the repeatedly failing default physical solution with TD's congestion-focused implementation strategy.

**Architecture:** Change only the active physical run strategy in the project XML. Preserve synthesis output and all functional sources, then let TD regenerate placement, routing, and bitstream.

**Tech Stack:** Tang Dynasty 6.2.168116, XML project configuration, EG4S20BG256

**Spec:** `docs/superpowers/specs/2026-09-11-phy-local-route-recovery-design.md`

## Global Constraints

- Do not change RTL, constraints, device, package, or synthesis strategy.
- Use the installed official `CongestionHigh` physical strategy.
- Rebuild only `phy_1` after reopening TD.
- Reject any run that retains a `PHY-8023` routing violation.

---

### Task 1: Select congestion-focused PHY strategy

**Files:**
- Modify: `fpga/osd_display/osd_display.al`

**Interfaces:**
- Consumes: TD run `phy_1` linked to `syn_1`.
- Produces: `<Strategy Name="CongestionHigh">` for physical implementation.

- [x] **Step 1:** Record the repeated location and net names from `phy_1/run.log`.
- [x] **Step 2:** Replace only the physical strategy name.
- [x] **Step 3:** Parse the project as XML and inspect the scoped diff.

### Task 2: Regenerate physical implementation

**Files:**
- Generated: `fpga/osd_display/osd_display_Runs/phy_1/run.log`
- Generated: `fpga/osd_display/osd_display_Runs/phy_1/osd_display.bit`

**Interfaces:**
- Consumes: current `syn_1` result and `CongestionHigh` parameters.
- Produces: routed database and current bitstream.

- [ ] **Step 1:** Open TD and confirm `phy_1` shows `CongestionHigh`.
- [ ] **Step 2:** Reset and run only `phy_1` through bit generation.
- [ ] **Step 3:** Check the new log for routing success and report timing before JTAG testing.
