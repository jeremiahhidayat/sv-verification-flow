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
| `ALMOST_FULL_THRESHOLD` | `DEPTH` | Occupancy at/above which `almost_full` asserts. Default of `DEPTH` makes `almost_full` coincide with `full` unless a caller overrides it — see open question in `verification_plan.md` §4. |

`almost_empty` and `ALMOST_EMPTY_THRESH` have been **removed** in this revision —
the module no longer exposes an almost-empty indicator.

## 2. Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock. All activity is synchronous to the rising edge. |
| `rst` | in | 1 | **Active-high**, synchronous reset (assumed — see §4 open question; polarity flipped from `rst_n` in earlier revisions of this spec). |
| `wr_en` | in | 1 | Write request. Qualified by `full`. |
| `wr_data` | in | `WIDTH` | Write data. |
| `rd_en` | in | 1 | Read request. Qualified by `empty`. |
| `rd_data` | out | `WIDTH` | Read data, registered through two pipeline stages; valid **two cycles** after a successful read is accepted (F13) — latency increased from one cycle in earlier revisions. |
| `full` | out | 1 | Asserted when occupancy == `DEPTH`. |
| `empty` | out | 1 | Asserted when occupancy == 0. |
| `almost_full` | out | 1 | Asserted when occupancy >= `ALMOST_FULL_THRESHOLD`. |
| `count` | out | `$clog2(DEPTH+1)` | Current occupancy (debug/verification visibility, not required by any consumer). |

Reset is **synchronous** (sampled on the clock edge) to keep the fast-tier and Questa
tier behaviorally identical without needing a separate async-reset check; if the RTL
later grows an async reset path, this section must be updated before the async case
is added to the corner-case list in §4.

## 3. Reset Behavior

- While `rst == 1`: on the next rising edge, write pointer, read pointer, and
  `count` are cleared to 0. This also flushes the two-stage read pipeline (see
  F16) so no stale data can reach `rd_data` post-reset.
- After reset deasserts: `empty == 1`, `full == 0`, `almost_full == 0`, `rd_data`
  is undefined until the first successful read reaches the second pipeline stage
  (two cycles after acceptance, per F13).
- `wr_en`/`rd_en` asserted during reset are ignored — no write or read is committed.
- Reset may assert at any point, including mid-burst with entries stored or
  in-flight in the read pipeline; pointers, count, and both read pipeline stages
  must clear regardless of prior occupancy (see F15, "pointer stability under
  reset").

## 4. Numbered Behaviors

- **F1** — Reset clears `count`, write pointer, read pointer, and both read
  pipeline stages to 0; `empty=1`, `full=0`.
- **F2** — A write is committed iff `wr_en==1 && full==0`. Data is stored at the
  write pointer; the write pointer increments and wraps modulo `DEPTH`.
- **F3** — A read is committed iff `rd_en==1 && empty==0`; the read pointer
  increments and wraps modulo `DEPTH`, and `count` decrements, in the cycle the
  read is accepted. The corresponding data does not reach `rd_data` until two
  cycles later (F13) — occupancy accounting (F4–F12) is independent of that
  output pipeline delay.
- **F4** — `full` is asserted iff `count == DEPTH`. A write attempted while `full`
  and no simultaneous read is committed (dropped) and does not corrupt stored data
  or advance the write pointer.
- **F5** — `empty` is asserted iff `count == 0`. A read attempted while `empty` and
  no simultaneous write is committed (dropped); the read pointer does not advance
  and no data enters the read pipeline (see F16); `rd_data` holds its previous
  value.
- **F6** — Simultaneous `wr_en && rd_en` while neither full nor empty: both commit
  in the same cycle; `count` is unchanged; both pointers advance.
- **F7** — Simultaneous `wr_en && rd_en` while `full`: the read commits (frees a
  slot) and the write commits into that freed slot in the same cycle; `count`
  remains `DEPTH`; no overflow occurs.
- **F8** — Simultaneous `wr_en && rd_en` while `empty`: the write commits; the read
  is dropped (there is nothing valid to dequeue this cycle); `count` becomes 1.
- **F9** — Write and read pointers wrap modulo `DEPTH` independently; occupancy is
  tracked correctly across any number of wraps (verify at least 2 full wrap cycles).
- **F10** — `almost_full` asserts and deasserts exactly at its configured
  threshold, including at the extremes (`ALMOST_FULL_THRESHOLD == DEPTH`, the
  default, and `ALMOST_FULL_THRESHOLD == 1`).
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
- **F15** — Reset asserted mid-burst (nonzero occupancy, and/or data in flight in
  the read pipeline) clears pointers, `count`, and both pipeline stages
  regardless of prior state (see §3).
- **F16** — Read pipeline bubbles: in any cycle where no read is accepted (F5) or
  reset is asserted, no data advances into either read-pipeline stage; a stage
  with no valid data flowing into it holds rather than propagating a bubble that
  could show up as spurious/garbage data on `rd_data` two cycles later.
