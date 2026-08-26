# FIFO Verification Specification

## 1. Overview

Synchronous, single-clock FIFO: `fifo_almost_full_2cycle_read`. Read data is
registered through **two** pipeline stages (RAM output register + a second FIFO
output register) rather than one — still "standard"/non-FWFT, but with an extra
cycle of read latency versus earlier revisions of this spec, traded for higher
achievable clock frequency (see F13). Parameterizable width and depth.

| Parameter | Default | Description |
|---|---|---|
| `WIDTH` | 8 | Data width in bits |
| `DEPTH` | 32 | Number of entries. Must be a power of 2. |
| `ALMOST_FULL_THRESHOLD` | `DEPTH` | The exact occupancy at which `almost_full` asserts — `count == ALMOST_FULL_THRESHOLD`, **not** `>=` (see F10). Legal range `[1, DEPTH]`. Default of `DEPTH` makes `almost_full` coincide with `full` unless a caller overrides it — see open question in `verification_plan.md` §4. |

`almost_empty` and `ALMOST_EMPTY_THRESH` have been **removed** in this revision —
the module no longer exposes an almost-empty indicator.

## 2. Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock. All activity is synchronous to the rising edge. |
| `rst` | in | 1 | **Active-high, synchronous** reset (confirmed in RTL; polarity flipped from `rst_n` in earlier revisions of this spec). |
| `wr_en` | in | 1 | Write request. Qualified by `full`. |
| `wr_data` | in | `WIDTH` | Write data. |
| `rd_en` | in | 1 | Read request. Qualified by `empty`. |
| `rd_data` | out | `WIDTH` | Read data, registered through two pipeline stages; valid **two cycles** after a successful read is accepted (F13) — latency increased from one cycle in earlier revisions. |
| `full` | out | 1 | Asserted when occupancy == `DEPTH`. |
| `empty` | out | 1 | Asserted when occupancy == 0. |
| `almost_full` | out | 1 | Asserted when occupancy **equals** `ALMOST_FULL_THRESHOLD` exactly. It is a point flag, not a threshold-and-above flag — it deasserts again as occupancy rises past the threshold (F10). |
| `count` | out | `$clog2(DEPTH+1)` | Current occupancy (debug/verification visibility, not required by any consumer). |

Reset is **synchronous** (sampled on the clock edge) to keep the fast-tier and Questa
tier behaviorally identical without needing a separate async-reset check; if the RTL
later grows an async reset path, this section must be updated before the async case
is added to the corner-case list in §4.

## 3. Reset Behavior

- While `rst == 1`: on the next rising edge, write pointer, read pointer, and
  `count` are cleared to 0.
- **Neither read-pipeline stage (`rd_data_ram` nor the externally-visible
  `rd_data`) is reset**, by design. `rd_data_ram` models a real memory macro's
  registered read output, which has no reset pin in silicon; `rd_data` is a
  plain flop and technically could be reset, but the contract with the
  consumer makes it unnecessary — see below.
- The consumer contract: this FIFO exposes no explicit "data valid" signal on
  the read side. A consumer is expected to know the fixed 2-cycle latency (F13)
  and only sample `rd_data` on the cycle its own accepted-read count says data
  has arrived. Under that contract, `rd_data`'s value is never sampled before
  the first legitimate post-reset read matures, so its reset-time value is
  irrelevant to correctness — it can hold stale or unknown (`X` in simulation)
  data indefinitely without being observed. Both pipeline registers are
  data-plane only (neither feeds back into `valid_wr`/`valid_rd`/pointers/
  `count`), so unlike the pointer/count reset, there is no risk of undefined
  state propagating into control logic.
- After reset deasserts: `empty == 1`, `full == 0`, `almost_full == 0`.
  `rd_data`/`rd_data_ram` remain whatever they held pre-reset until the first
  successful post-reset read overwrites them (two cycles after acceptance, per
  F13) — this is the same "undefined until first successful read" behavior as
  a cold power-up, just re-triggered by any `rst` pulse, not only the initial
  one.
- `wr_en`/`rd_en` asserted during reset are ignored — no write or read is committed.
- Reset may assert at any point, including mid-burst with entries stored or
  in-flight in the read pipeline; pointers and count must clear regardless of
  prior occupancy (see F15, "pointer stability under reset").

## 4. Numbered Behaviors

- **F1** — Reset clears `count`, write pointer, and read pointer to 0;
  `empty=1`, `full=0`. `rd_data`/`rd_data_ram` are deliberately **not** cleared
  by reset (see §3) — the fixed-latency, no-valid-signal consumer contract
  means their reset-time value is never observed.
- **F2** — A write is committed iff `wr_en==1 && full==0`. Data is stored at the
  write pointer; the write pointer increments and wraps modulo `DEPTH`.
- **F3** — A read is committed iff `rd_en==1 && empty==0`; the read pointer
  increments and wraps modulo `DEPTH`, and `count` decrements, in the cycle the
  read is accepted. The corresponding data does not reach `rd_data` until two
  cycles later (F13) — occupancy accounting (F4–F12) is independent of that
  output pipeline delay.
- **F4** — `full` is asserted iff `count == DEPTH`. A write attempted while `full`
  is dropped, with or without a simultaneous read (see F7), and does not corrupt
  stored data or advance the write pointer.
- **F5** — `empty` is asserted iff `count == 0`. A read attempted while `empty` is
  dropped, with or without a simultaneous write (see F8); the read pointer does
  not advance and no data enters the read pipeline (see F16); `rd_data` holds its
  previous value.
- **F6** — Simultaneous `wr_en && rd_en` while neither full nor empty: both commit
  in the same cycle; `count` is unchanged; both pointers advance.
- **F7** — Simultaneous `wr_en && rd_en` while `full`: the read commits and the
  write is **dropped**; `count` becomes `DEPTH-1`. Writes are qualified by
  `!full` unconditionally (`valid_wr = wr_en && !full`), so a read freeing a
  slot in the same cycle does not open one for the write. Earlier revisions of
  this spec described the write committing into the freed slot; the RTL is
  authoritative and that wording has been corrected.
  What this costs: under sustained simultaneous read/write starting from full,
  occupancy settles at `DEPTH-1` and stays there. That is one slot of effective
  depth, not throughput, since after the first cycle the FIFO is no longer full
  and both accesses commit every cycle from then on. No data is lost either,
  because a producer sees `full` asserted and holds. The benefit is that the
  write-enable path stays a pure function of `count_r` and never depends on
  `valid_rd`.
- **F8** — Simultaneous `wr_en && rd_en` while `empty`: the write commits; the read
  is dropped (there is nothing valid to dequeue this cycle); `count` becomes 1.
- **F9** — Write and read pointers wrap modulo `DEPTH` independently; occupancy is
  tracked correctly across any number of wraps (verify at least 2 full wrap cycles).
- **F10** — `almost_full` is an **exact-match** occupancy flag: it asserts iff
  `count == ALMOST_FULL_THRESHOLD` and is deasserted at every other occupancy,
  *including occupancies above the threshold*. It is deliberately not a
  `count >= ALMOST_FULL_THRESHOLD` sticky/threshold-and-above flag — earlier
  revisions of this spec worded it that way, and the RTL is authoritative here.
  Consequences a consumer must account for:
  - With `ALMOST_FULL_THRESHOLD < DEPTH`, `almost_full` pulses for exactly the
    cycles occupancy sits on the threshold and drops again as the FIFO keeps
    filling — so `almost_full == 0` does **not** mean "there is room". A
    consumer using it as back-pressure must latch it, not level-sample it.
  - `almost_full && full` and `!almost_full && full` are both legal states:
    the former when `ALMOST_FULL_THRESHOLD == DEPTH`, the latter when
    `ALMOST_FULL_THRESHOLD < DEPTH`.
  - At the `ALMOST_FULL_THRESHOLD == DEPTH` default the exact-match and
    threshold-and-above readings are indistinguishable, since `count` can never
    exceed `DEPTH`. Verification must therefore exercise at least one
    sub-`DEPTH` threshold to cover the difference; `ALMOST_FULL_THRESHOLD == 1`
    is the other extreme worth pinning.
- **F11** — No overflow: stored data already in the FIFO is never corrupted or lost
  by a write attempted while full with no accompanying read (F4 holds under
  sustained back-pressure, not just a single cycle).
- **F12** — No underflow: `rd_data` never returns stale/garbage data distinct from
  its held value when a read is attempted while empty with no accompanying write.
- **F13** — Read latency: `rd_data` for entry N is valid exactly **two** cycles
  after the cycle in which the read that dequeues entry N was accepted (RAM
  output register + a second FIFO output register; registered/non-FWFT, latency
  increased from one cycle in earlier revisions of this spec). The FIFO must
  support back-to-back accepted reads (one per cycle) despite the 2-cycle
  latency — consumers pipeline around the extra delay rather than losing
  throughput.
- **F14** — Ordering: entries are returned in strict FIFO (first-in, first-out)
  order under any legal interleaving of writes and reads, including at the
  boundary conditions in F6–F8.
- **F15** — Reset asserted mid-burst (nonzero occupancy, and/or data in flight
  in the read pipeline) clears pointers and `count` regardless of prior state.
  Whatever was in flight in `rd_data_ram`/`rd_data` at the moment of reset is
  left as-is (see §3) — this is safe because the consumer contract means that
  data was never going to be sampled without the pointer/`count` state that
  reset also clears, so a consumer cannot mistake leftover in-flight data for a
  new valid read.
- **F16** — Read pipeline bubbles: in any cycle where no read is accepted (F5),
  `rd_data_ram` re-reads the same (unmoved) `ram` address rather than advancing,
  so it holds its value; `rd_data` likewise only updates when the prior cycle
  fed it real `rd_data_ram` content. Neither stage propagates a bubble that
  could show up as spurious/garbage data on `rd_data` — and per §3, even if it
  did, the consumer contract means it would go unobserved.
