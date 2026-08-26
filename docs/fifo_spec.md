# FIFO Verification Specification

## 1. Overview

Synchronous, single-clock FIFO with registered ("standard", not first-word-fall-through)
read data. Parameterizable width and depth.

| Parameter | Default | Description |
|---|---|---|
| `WIDTH` | 8 | Data width in bits |
| `DEPTH` | 16 | Number of entries. Must be a power of 2. |
| `ALMOST_FULL_THRESH` | `DEPTH-2` | Occupancy at/above which `almost_full` asserts |
| `ALMOST_EMPTY_THRESH` | 2 | Occupancy at/below which `almost_empty` asserts |

## 2. Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock. All activity is synchronous to the rising edge. |
| `rst_n` | in | 1 | Active-low synchronous reset. |
| `wr_en` | in | 1 | Write request. Qualified by `full`. |
| `wr_data` | in | `WIDTH` | Write data. |
| `rd_en` | in | 1 | Read request. Qualified by `empty`. |
| `rd_data` | out | `WIDTH` | Read data, registered, valid the cycle after a successful read (F13). |
| `full` | out | 1 | Asserted when occupancy == `DEPTH`. |
| `empty` | out | 1 | Asserted when occupancy == 0. |
| `almost_full` | out | 1 | Asserted when occupancy >= `ALMOST_FULL_THRESH`. |
| `almost_empty` | out | 1 | Asserted when occupancy <= `ALMOST_EMPTY_THRESH`. |
| `count` | out | `$clog2(DEPTH)+1` | Current occupancy (debug/verification visibility, not required by any consumer). |

Reset is **synchronous** (sampled on the clock edge) to keep the fast-tier and Questa
tier behaviorally identical without needing a separate async-reset check; if the RTL
later grows an async reset path, this section must be updated before the async case
is added to the corner-case list in §4.

## 3. Reset Behavior

- While `rst_n == 0`: on the next rising edge, write pointer, read pointer, and
  `count` are cleared to 0.
- After reset deasserts: `empty == 1`, `full == 0`, `almost_empty == 1`,
  `almost_full == 0`, `rd_data` is undefined until the first successful read.
- `wr_en`/`rd_en` asserted during reset are ignored — no write or read is committed.
- Reset may assert at any point, including mid-burst with entries stored; pointers
  and count must clear regardless of prior occupancy (see F-list assertion "pointer
  stability under reset").

## 4. Numbered Behaviors

- **F1** — Reset clears `count`, write pointer, and read pointer to 0; `empty=1`, `full=0`.
- **F2** — A write is committed iff `wr_en==1 && full==0`. Data is stored at the
  write pointer; the write pointer increments and wraps modulo `DEPTH`.
- **F3** — A read is committed iff `rd_en==1 && empty==0`. `rd_data` is driven from
  the read pointer's entry the following cycle; the read pointer increments and
  wraps modulo `DEPTH`.
- **F4** — `full` is asserted iff `count == DEPTH`. A write attempted while `full`
  and no simultaneous read is committed (dropped) and does not corrupt stored data
  or advance the write pointer.
- **F5** — `empty` is asserted iff `count == 0`. A read attempted while `empty` and
  no simultaneous write is committed (dropped); `rd_data` holds its previous value
  and the read pointer does not advance.
- **F6** — Simultaneous `wr_en && rd_en` while neither full nor empty: both commit
  in the same cycle; `count` is unchanged; both pointers advance.
- **F7** — Simultaneous `wr_en && rd_en` while `full`: the read commits (frees a
  slot) and the write commits into that freed slot in the same cycle; `count`
  remains `DEPTH`; no overflow occurs.
- **F8** — Simultaneous `wr_en && rd_en` while `empty`: the write commits; the read
  is dropped (there is nothing valid to read this cycle since reads are registered,
  see F3); `count` becomes 1.
- **F9** — Write and read pointers wrap modulo `DEPTH` independently; occupancy is
  tracked correctly across any number of wraps (verify at least 2 full wrap cycles).
- **F10** — `almost_full`/`almost_empty` assert and deassert exactly at their
  configured thresholds, including thresholds at the extremes (`DEPTH-1`, `1`).
- **F11** — No overflow: stored data already in the FIFO is never corrupted or lost
  by a write attempted while full with no accompanying read (F4 holds under
  sustained back-pressure, not just a single cycle).
- **F12** — No underflow: `rd_data` never returns stale/garbage data distinct from
  its held value when a read is attempted while empty with no accompanying write.
- **F13** — Read latency: `rd_data` for entry N is valid exactly one cycle after
  the cycle in which the read that dequeues entry N was accepted (registered
  output, not FWFT).
- **F14** — Ordering: entries are returned in strict FIFO (first-in, first-out)
  order under any legal interleaving of writes and reads, including at the
  boundary conditions in F6–F8.
