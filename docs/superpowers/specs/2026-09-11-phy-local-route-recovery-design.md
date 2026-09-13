# PHY Local Route Recovery Design

## Goal

Recover physical implementation after two deterministic default-strategy
failures at the same single local routing resource.

## Evidence

Both runs fail with `PHY-8023` at `x2y50_local2` between two synthesized mux
nets in `fat32_wav_loader`. Placement uses 58.70% of slices, no tile exceeds
100% utilization, and the most congested one-percent tile average is below
50%. This is a failed physical solution rather than device capacity overflow.

## Design

Change only the `phy_1` strategy in the active `osd_display.al` project from
`Default_PhysicalDesign_Strategy` to the TD 6.2 built-in `CongestionHigh`
strategy. The installed official strategy definition applies higher placement
effort, lower target density, congestion recovery, and post-route
optimization. Synthesis settings, RTL, constraints, device, and package stay
unchanged.

## Verification And Rollback

Parse the edited project as XML and verify the scoped diff before reopening
TD. Reset and rerun only `phy_1`. Success requires no routing violation and a
new bitstream from the current synthesis result. If it still fails, restore
the default strategy and use a dedicated multi-seed physical run; do not alter
functional RTL to perturb placement.
