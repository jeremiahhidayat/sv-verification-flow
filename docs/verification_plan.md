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
| F7 | `test_simultaneous_rw_at_full` (write dropped, `count`→`DEPTH-1`) | `cx_wr_rd_full_empty` bin `wr&rd, full`; `a_no_overflow` |
| F8 | `test_simultaneous_rw_at_empty` | `cx_wr_rd_full_empty` bin `wr&rd, empty`; `a_no_underflow` |
| F9 | `test_pointer_wrap` (≥2 wraps) | `cp_occupancy` crossed with wrap count |
| F10 | `test_almost_full_threshold` | `cp_occupancy` threshold-1/threshold/threshold+1 bins; `cp_af_vs_full` |
| F11 | `test_random_stress` (sustained full) | `a_no_overflow` (assertion, not just coverage) |
| F12 | `test_random_stress` (sustained empty) | `a_no_underflow` |
| F13 | every test's scoreboard timing check (2-cycle latency); `test_back_to_back_reads` | `a_read_latency` (2-cycle, see §3) |
| F14 | `test_random_stress` vs. Python reference model | n/a (data-integrity is a simulation-only check) |
| F15 | `test_reset_mid_burst` | `a_ptr_reset_stable` |
| F16 | `test_read_pipeline_bubble` | `a_read_pipeline_no_bubble` |

This is the matrix that should be included in the coverage report. This helps track the functionalities that were checked. 

## 2. Fast tier — cocotb (`tb/cocotb/`)

Reference model: a plain Python `collections.deque` mirroring `count`/`full`/
`empty`/`almost_full` every cycle (no `almost_empty` — removed from the DUT),
plus a 2-entry pipeline model that mirrors the DUT's RAM-output-register +
output-register stages so the reference `rd_data` becomes valid on the same
cycle as the DUT's, not one cycle early. This matters — a scoreboard that only
checks `rd_data` ordering will pass even if the flag logic or the latency is
wrong (e.g., a model that computes `almost_full` as `count >= THRESHOLD` when
the DUT is exact-match `count == THRESHOLD`, or one still assuming 1-cycle read
latency), and both are exactly the class of bug this revision's interface
changes (renamed threshold parameter, dropped `almost_empty`, added pipeline
stage) tend to introduce. The `almost_full` case in particular is invisible at
the `ALMOST_FULL_THRESHOLD == DEPTH` default — see §4.

Tests (each asserts against the reference model every cycle, not just at checkpoints):
1. `test_reset` — F1
2. `test_fill_to_full` — F2, F4, F10
3. `test_drain_to_empty` — F3, F5, F10
4. `test_pointer_wrap` — F9 (drive ≥2×`DEPTH` writes/reads)
5. `test_simultaneous_rw_mid` / `_at_full` / `_at_empty` — F6/F7/F8 (the three cases
   the prep plan calls out as "real corner cases" — don't let these collapse into
   one generic "simultaneous r/w" test, they exercise different logic paths)
6. `test_write_while_full_no_read`, `test_read_while_empty_no_write` — F11, F12
7. `test_reset_mid_burst` — reset asserted with nonzero occupancy and/or data
   in flight in the read pipeline — F15
8. `test_back_to_back_reads` — assert `rd_en` every cycle while non-empty and
   confirm one read is accepted per cycle with each `rd_data` arriving exactly
   2 cycles after its read was accepted, i.e. no throughput loss from the extra
   pipeline stage — F13
9. `test_read_pipeline_bubble` — interleave accepted reads with cycles where
   `rd_en` is deasserted or dropped (F5/F8) and confirm `rd_data` never shows a
   bubble/garbage value 2 cycles after a non-accepted read — F16
10. `test_almost_full_threshold` — walk occupancy one entry at a time from `0`
    up to `DEPTH` and back down, checking `almost_full` at every step. Because
    the flag is exact-match, the walk must confirm it **deasserts again above**
    the threshold, not just that it asserts at it. Parameterize over
    `ALMOST_FULL_THRESHOLD` in `{1, DEPTH/2, DEPTH}` — the `DEPTH` default
    (coincides with `full`) cannot distinguish `==` from `>=`, so at least one
    sub-`DEPTH` value is mandatory here, not optional — F10
11. `test_random_stress` — randomized `wr_en`/`rd_en`/data vs. reference model,
    run with a fixed seed logged on failure for reproducibility

Target: `make sim` clean under 30s (per prep plan Step 3), all 11+ tests, each
tagged with the spec IDs it covers in its docstring so the traceability matrix
above stays checkable by grep, not by memory.

## 3. Questa tier — coverage + assertions (`tb/sv/`)

**Covergroups:**
- `cp_occupancy`: bins for `0`, the mid-range spread, and `DEPTH`, plus three
  explicit single-value bins around the threshold —
  `ALMOST_FULL_THRESHOLD-1`, `ALMOST_FULL_THRESHOLD`, `ALMOST_FULL_THRESHOLD+1`
  (each clamped into `[0, DEPTH]`). All three are required, not just the middle
  one: `almost_full` is an **exact-match** flag (F10), so the bin *above* the
  threshold is what proves it deasserts again as the FIFO keeps filling. A
  range bin like `ALMOST_FULL_THRESHOLD..DEPTH-1` would have been the right
  shape for a `>=` flag and is the wrong shape here — it can close without ever
  landing on the threshold itself.
- `cp_af_vs_full`: the `{almost_full, full}` pair, with all four combinations
  binned. At the `ALMOST_FULL_THRESHOLD == DEPTH` default only `neither` and
  `af_and_full` are reachable, which is the "coincides with full" case. The
  other two — `af_only` (occupancy sitting exactly on a sub-`DEPTH` threshold)
  and `full_only` (occupancy above it, flag already dropped) — are reachable
  only from a second elaboration with `ALMOST_FULL_THRESHOLD < DEPTH`, so they
  are the bins that force that instantiation to actually be run rather than
  assumed (see §4).
- `cx_wr_rd_full_empty`: cross of `(wr_en, rd_en, full, empty)`, with illegal
  combinations (`full && empty` when `DEPTH>1`) excluded and documented as an
  exclusion, not silently dropped — an unexplained exclusion is worse than no
  exclusion when someone reviews the UCDB later.

**SVA (5, matching the prep plan's cut-order priority):**
- `a_no_overflow`: `full && wr_en && !rd_en |=> count == DEPTH` (count never
  exceeds DEPTH, stored data unchanged) — covers F4/F11.
- `a_no_underflow`: `empty && rd_en && !wr_en |=> count == 0` — covers F5/F12.
- `a_ptr_reset_stable`: `rst |=> wr_ptr == 0 && rd_ptr == 0 && count == 0` —
  covers F1 and F15 (reset-mid-burst); note the polarity flip to active-high
  `rst` from the earlier active-low `rst_n`.
- `a_read_latency`: an accepted read (`rd_en && !empty`) implies `rd_data` two
  cycles later equals the dequeued entry's stored data — covers F13. The
  first-priority new addition to cut under time pressure if the fast-tier
  `test_back_to_back_reads` already gives enough confidence here.
- `a_read_pipeline_no_bubble`: no read accepted **and no reset in the
  intervening window** implies `rd_data` does not change two cycles later —
  covers F16. Deliberately excludes reset: since `rd_addr_r` resets to 0,
  reset can change what `rd_data_ram`/`rd_data` pick up even with no accepted
  read (F15) — that's expected, not a bubble, and is inconsequential under the
  consumer contract in `fifo_spec.md` §3, not something to assert stability on.

If time forces a cut per the prep plan's order (Step 8 → SVA → Step 7), cut
`a_read_pipeline_no_bubble` first, then `a_read_latency` (both new, both
partially redundant with fast-tier coverage of F13/F16), then
`a_ptr_reset_stable` last — it's the cheapest to write and the one most likely to
catch a real bug (reset logic touching pointers but missing `count`, or vice
versa) since it exercises a path the cocotb reset test only checks at rest, not
mid-burst.

**Run/merge** (already in the prep plan, repeated here for the traceability):
3–5 seeds → `vcover merge` → `vcover report -html`. The merge must span at least
two elaborations — the `ALMOST_FULL_THRESHOLD == DEPTH` default and one
sub-`DEPTH` threshold — or `cp_af_vs_full` cannot close (§4). Signoff target:
100% of `cp_occupancy`, `cx_wr_rd_full_empty` and `cp_af_vs_full` bins hit, all
5 assertions pass across every seed, zero unjustified exclusions.

## 4. Gaps to close before writing RTL

- **Read latency (F13): now 2-cycle registered/standard, not FWFT** (increased
  from 1 cycle in the previous revision, per the `fifo_almost_full_2cycle_read`
  RTL header comment — trading latency for clock frequency by registering the
  RAM output and adding a second output register). This must stay consistent
  across both testbenches — the cocotb scoreboard should sample `rd_data` two
  cycles after `rd_en` was accepted, not one, and any SVA that references
  `rd_data` should use `##2`, not `##1` or `|->`, relative to the accepted read.
- **Resolved — reset polarity/type: active-high, synchronous**, confirmed in
  `rtl/fifo_almost_full_2cycle_read.sv` (`always_ff @(posedge clk) if (rst) ...`).
  `a_ptr_reset_stable` and any other reset-referencing SVA should use `rst |=>`
  with no separate async-deassertion test needed in cocotb, since there's no
  async reset path in the RTL to race.
- **Resolved — the entire read-data pipeline is intentionally excluded from
  reset.** Neither `rd_data_ram` (RAM's own registered read output — real
  memory macros have no reset pin) nor `rd_data` (the FIFO's own second
  pipeline register, a plain flop that *could* be reset) is cleared by `rst`.
  This is a deliberate consumer-contract decision, not an oversight: the FIFO
  exposes no read-side "valid" signal, so a correct consumer only samples
  `rd_data` on the cycle its own latency counter says data is real, and never
  observes its reset-time value. `a_ptr_reset_stable` should therefore assert
  only on `wr_ptr`/`rd_ptr`/`count`, and must **not** assert anything about
  `rd_data`/`rd_data_ram` post-reset — a fast-tier test that checked
  `rd_data == 0` right after `test_reset` would be asserting a guarantee the
  design does not make. F16's bubble-holding behavior on `rd_data_ram` comes
  for free from the unmoved read address, not from a reset or enable — worth a
  targeted test (`test_read_pipeline_bubble`) rather than an SVA, since it's a
  consequence of address stability, not an explicit rule.
- **Resolved — F7: a write attempted while `full` is dropped even when a read
  commits in the same cycle.** `valid_wr = wr_en && !full` is unconditional, so
  the slot the read frees is not available to the write until the next cycle;
  `count` goes to `DEPTH-1` and settles there under sustained simultaneous
  read/write. Earlier revisions of `fifo_spec.md` described the write committing
  into the freed slot. The RTL is authoritative and F7 has been corrected.
  **Both reference models must derive write acceptance from the spec rule, not
  by copying `valid_wr` out of the RTL.** This was found by the Questa tier's
  directed `test_simultaneous_rw_at_full`, and *only* by it: the SV reference
  model had `acc_wr = wr_en && !full` copied from the RTL, so its every-cycle
  `count` check agreed with the DUT and stayed silent, and `a_no_overflow` is
  qualified on `!rd_en` so it never evaluated this case. A model that inherits
  the implementation's acceptance rule cannot detect a bug in that rule.
- **Resolved — `almost_full` is exact-match (`count == ALMOST_FULL_THRESHOLD`),
  not `count >= ALMOST_FULL_THRESHOLD`.** The RTL (`rtl/...sv`) is authoritative
  here; earlier revisions of `fifo_spec.md` worded F10 as `>=` and have been
  corrected. Both reference models must use `==`. The flag deasserts again as
  occupancy rises past the threshold, so `almost_full == 0` does not mean "there
  is room" — F10 in `fifo_spec.md` spells out the consumer consequences.
- **Open question — `ALMOST_FULL_THRESHOLD` *defaulting* to `DEPTH`.** Separate
  from the settled `==` question above. The default makes `almost_full`
  functionally identical to `full` unless a caller overrides the parameter.
  Confirm this is intentional (e.g., a "safe" out-of-box default that callers
  are expected to override) rather than an oversight. Either way it has a
  verification cost: at the default, `==` and `>=` are indistinguishable, so
  **the default instantiation alone cannot close F10**. At least one elaboration
  with `ALMOST_FULL_THRESHOLD < DEPTH` must be in the regression, which is what
  `cp_af_vs_full`'s `af_only`/`full_only` bins exist to force (§3).
- **`DEPTH` should be small enough to hit F9 (pointer wrap) cheaply** in a
  directed test but a power of 2 to keep pointer/count logic simple to reason
  about in code review. `DEPTH=32` is now the spec default; `DEPTH=4` or `8` in
  a second parallel instance is a cheap way to make wrap-around trivially
  frequent in the random stress test if coverage on `cp_occupancy`'s extreme
  bins is hard to close.
