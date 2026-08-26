# FIFO Verification Plan

Two-tier plan: fast tier (cocotb + Verilator, PR-gated) catches functional bugs in
seconds; Questa tier (SVA + functional coverage) proves closure with a defensible,
mergeable metric. Every row below traces to a spec ID in `docs/fifo_spec.md`.

## 1. Traceability matrix

| Spec ID | Fast-tier test (`tb/cocotb/`) | Questa coverage/assertion (`tb/sv/`) |
|---|---|---|
| F1 | `test_reset` | `cp_occupancy` bin 0 hit post-reset; `a_ptr_reset_stable` |
| F2 | `test_fill_to_full` | `cp_occupancy` all bins; `cx_wr_rd_full_empty` |
| F3 | `test_drain_to_empty` | `cp_occupancy`; `cx_wr_rd_full_empty` |
| F4 | `test_fill_to_full`, `test_write_while_full_no_read` | `a_no_overflow` |
| F5 | `test_drain_to_empty`, `test_read_while_empty_no_write` | `a_no_underflow` |
| F6 | `test_simultaneous_rw_mid` | `cx_wr_rd_full_empty` bin `wr&rd, !full, !empty` |
| F7 | `test_simultaneous_rw_at_full` | `cx_wr_rd_full_empty` bin `wr&rd, full`; `a_no_overflow` |
| F8 | `test_simultaneous_rw_at_empty` | `cx_wr_rd_full_empty` bin `wr&rd, empty`; `a_no_underflow` |
| F9 | `test_pointer_wrap` (≥2 wraps) | `cp_occupancy` crossed with wrap count |
| F10 | `test_almost_full_empty_thresholds` | `cp_occupancy` almost-full/-empty bins |
| F11 | `test_random_stress` (sustained full) | `a_no_overflow` (assertion, not just coverage) |
| F12 | `test_random_stress` (sustained empty) | `a_no_underflow` |
| F13 | every test's scoreboard timing check | n/a (checked structurally in TB, not worth an SVA) |
| F14 | `test_random_stress` vs. Python reference model | n/a (data-integrity is a simulation-only check) |
| reset-under-load (not yet numbered — add as F15) | `test_reset_mid_burst` | `a_ptr_reset_stable` |

This is the matrix that should get screenshotted alongside the coverage report —
it's the thing that answers "how do you know you're done" in one glance.

## 2. Fast tier — cocotb (`tb/cocotb/`)

Reference model: a plain Python `collections.deque` mirroring `count`/`full`/
`empty`/`almost_full`/`almost_empty` every cycle, not just data on read. This
matters — a scoreboard that only checks `rd_data` ordering will pass even if the
flag logic is wrong (e.g., off-by-one on `almost_full`), and flag bugs are exactly
the class of bug DEPTH/threshold parameterization tends to introduce.

Tests (each asserts against the reference model every cycle, not just at checkpoints):
1. `test_reset` — F1
2. `test_fill_to_full` — F2, F4, F10
3. `test_drain_to_empty` — F3, F5, F10
4. `test_pointer_wrap` — F9 (drive ≥2×`DEPTH` writes/reads)
5. `test_simultaneous_rw_mid` / `_at_full` / `_at_empty` — F6/F7/F8 (the three cases
   the prep plan calls out as "real corner cases" — don't let these collapse into
   one generic "simultaneous r/w" test, they exercise different logic paths)
6. `test_write_while_full_no_read`, `test_read_while_empty_no_write` — F11, F12
7. `test_reset_mid_burst` — reset asserted with nonzero occupancy
8. `test_random_stress` — randomized `wr_en`/`rd_en`/data vs. reference model,
   run with a fixed seed logged on failure for reproducibility

Target: `make sim` clean under 30s (per prep plan Step 3), all 8+ tests, each
tagged with the spec IDs it covers in its docstring so the traceability matrix
above stays checkable by grep, not by memory.

## 3. Questa tier — coverage + assertions (`tb/sv/`)

**Covergroups:**
- `cp_occupancy`: bins for `0`, `1..ALMOST_EMPTY_THRESH`, mid-range,
  `ALMOST_FULL_THRESH..DEPTH-1`, `DEPTH` — plus explicit bins at the exact
  threshold boundaries (F10 requires hitting the boundary, not just "near" it).
- `cx_wr_rd_full_empty`: cross of `(wr_en, rd_en, full, empty)`, with illegal
  combinations (`full && empty` when `DEPTH>1`) excluded and documented as an
  exclusion, not silently dropped — an unexplained exclusion is worse than no
  exclusion when someone reviews the UCDB later.

**SVA (3, matching the prep plan's cut-order priority):**
- `a_no_overflow`: `full && wr_en && !rd_en |=> count == DEPTH` (count never
  exceeds DEPTH, stored data unchanged) — covers F4/F11.
- `a_no_underflow`: `empty && rd_en && !wr_en |=> count == 0` — covers F5/F12.
- `a_ptr_reset_stable`: `!rst_n |=> wr_ptr == 0 && rd_ptr == 0 && count == 0` —
  covers F1 and reset-mid-burst.

If time forces a cut per the prep plan's order (Step 8 → SVA → Step 7), cut
`a_ptr_reset_stable` last — it's the cheapest to write and the one most likely to
catch a real bug (reset logic touching pointers but missing `count`, or vice
versa) since it exercises a path the cocotb reset test only checks at rest, not
mid-burst.

**Run/merge** (already in the prep plan, repeated here for the traceability):
3–5 seeds → `vcover merge` → `vcover report -html`. Signoff target: 100% of
`cp_occupancy` and `cx_wr_rd_full_empty` bins hit, all 3 assertions pass across
every seed, zero unjustified exclusions.

## 4. Gaps to close before writing RTL

- **Read latency (F13): confirmed registered/standard, not FWFT.** `rd_data` is
  valid one cycle after the read that dequeues it is accepted. This must stay
  consistent across both testbenches — the cocotb scoreboard should sample
  `rd_data` a cycle after `rd_en` was accepted, not combinationally, and any SVA
  written later that references `rd_data` should use `##1`, not `|->`, relative
  to the accepted read.
- **`DEPTH` should be small enough to hit F9 (pointer wrap) cheaply** in a
  directed test but a power of 2 to keep pointer/count logic simple to reason
  about in code review. `DEPTH=16` is in the spec; `DEPTH=4` in a second parallel
  instance is a cheap way to make wrap-around trivially frequent in the random
  stress test if coverage on `cp_occupancy`'s extreme bins is hard to close.
