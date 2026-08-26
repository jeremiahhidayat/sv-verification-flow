# sv-verification-flow

Verification-first development of a small synchronous FIFO. The spec and the
verification plan are written before the RTL, every test traces back to a
numbered requirement, and two toolchains check the design at different speeds.

## What it's for

| | Fast tier | Questa tier |
|---|---|---|
| Tools | cocotb + Verilator | Questa (SVA + functional coverage) |
| Where | Every push, GitHub Actions | Department license server |
| Runtime | ~36 s | Minutes, multi-seed |
| Answers | "Did I break something?" | "Am I done?" |

The fast tier is a regression net. It runs on every push and fails while you
still remember what you changed.

The Questa tier produces signoff evidence. Verilator implements neither SVA with
local variables nor covergroups, and those are what a defensible closure
argument needs. The split follows a licensing constraint: Questa seats live on
an internal server that GitHub Actions cannot reach.

Holding the two together is the traceability matrix in
`docs/verification_plan.md` §1: one row per spec ID (`F1`–`F16`), naming the
fast-tier test and the Questa assertion or covergroup that cover it. Every test
carries its spec IDs in its name or docstring, so the matrix is checkable by
`grep`. A blank cell is a visible hole.

## Layout

```
docs/fifo_spec.md              Interface, reset behavior, behaviors F1-F16
docs/verification_plan.md      Traceability matrix, test list, covergroups, SVA
rtl/                           The design under verification
tb/cocotb/                     Fast tier: tests + Python reference model
tb/sv/                         Questa tier: testbench, covergroups, 5 SVA, Makefile
.github/workflows/ci.yml       Builds Verilator, installs cocotb, runs the fast tier
Makefile                       Top-level entry point; run `make` for the target list
```

## Setup

Everything runs in WSL2 (Ubuntu). Verilator's native Windows support is patchy,
and WSL matches the GitHub Actions runner.

### 1. Verilator, from source

cocotb 2.0.1 needs Verilator ≥ 5.036; Ubuntu's package is 5.020.

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  git help2man perl python3 make autoconf g++ flex bison \
  libgoogle-perftools-dev numactl perl-doc libfl2 libfl-dev zlib1g-dev ccache

git clone --depth 1 --branch v5.050 https://github.com/verilator/verilator.git
cd verilator && autoconf && ./configure && make -j"$(nproc)" && sudo make install
```

Two traps: the `zlibc` package that several install guides list does not exist
on Ubuntu 24.04, and `ccache` is needed on every simulation run, not just when
building Verilator, because Verilator bakes `ccache g++` into the generated
`Vtop.mk`.

### 2. cocotb

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt      # cocotb==2.0.1
```

The venv is not optional on Ubuntu 24.04; PEP 668 blocks system-wide `pip
install`. If you hit `cocotb-config: Permission denied`, WSL's Windows PATH
interop found a Windows-side `cocotb-config` first: re-activate the venv and run
`hash -r`.

### 3. Questa (optional)

Needs `vlog`, `vsim` and `vcover` on `PATH`, usually via your site's setup
script and a VPN. Without it, everything except `make questa` and `make regress`
still works.

## Commands

```bash
make check        # lint + fast tier, the pre-push gate, no license needed
make sim          # fast tier only
make lint         # Verilator syntax check of RTL + SV testbench

make questa       # Questa tier, a single run
make regress      # seeds x elaborations, vcover merge, HTML report
make coverage     # re-report from an existing merged UCDB
```

Parameters forward to the Questa tier:

```bash
make regress DEPTH=8 SEEDS="1 2 3 4 5"
make questa SEED=7 ALMOST_FULL_THRESHOLD=16
```

`make regress` sweeps `ALMOST_FULL_THRESHOLD` over `{1, DEPTH/2, DEPTH}` as well
as seeds. That is not optional: the parameter is elaboration-time, and at its
`DEPTH` default `almost_full` is indistinguishable from `full`, so the default
configuration alone cannot close `F10`.

## Gotchas

- **`almost_full` is exact-match** (`count == ALMOST_FULL_THRESHOLD`), not
  threshold-and-above. It deasserts again as occupancy rises past the threshold,
  so `almost_full == 0` does not mean "there is room". Invisible at the `DEPTH`
  default.
- **A write attempted while `full` is dropped even if a read commits in the same
  cycle** (`F7`). Occupancy settles at `DEPTH-1` under sustained simultaneous
  read/write. That costs one slot of effective depth, not throughput.
- **Reset does not clear `rd_data` or `rd_data_ram`.** A test asserting
  `rd_data == 0` after reset would be checking a guarantee the design does not
  make. See `docs/fifo_spec.md` §3.
- **Model timing, not just ordering.** A scoreboard that only checks the order
  of `rd_data` passes a design whose latency is wrong. Both reference models
  mirror the DUT cycle by cycle, including the two-stage read pipeline.
- **Derive the reference model from the spec, not the RTL.** The SV model's
  write-acceptance rule was copied from the RTL, so it agreed with the DUT and
  stayed silent while F7 was wrong. Only a directed test's hardcoded expectation
  caught it.
- **Questa exits `0` even when `$error` fired.** `tb/sv/Makefile`'s `check-log`
  requires the testbench's own pass banner *and* the absence of `** Error` or
  `** Fatal`.

## Status

- [x] Spec, verification plan, RTL
- [x] CI green, ~36 s per run
- [x] Questa tier: testbench, covergroups and 5 SVA written; the flow runs
      against a real license. Its first run found a spec/RTL mismatch on `F7`,
      since corrected in the spec. Not yet re-run to completion, and
      `make regress` (the multi-threshold sweep) has never run.
- [ ] Fast tier: 4 of the 11 planned tests written. `test_write_then_read`,
      `test_reset`, `test_fill_to_full` and `test_drain_to_empty` pass. The
      corner cases that matter most (`F6`–`F8` simultaneous read/write, `F9`
      pointer wrap, `F15` reset mid-burst, `F16` pipeline bubbles) are planned
      but not implemented.

### Open question

`ALMOST_FULL_THRESHOLD` defaults to `DEPTH`, making `almost_full` identical to
`full` unless a caller overrides it. Whether that is an intentional safe default
is unresolved. See `docs/verification_plan.md` §4.

## Next steps

1. Re-run the Questa tier now that `F7` is corrected, then `make regress` for
   the threshold sweep. The sub-`DEPTH` elaborations have never run.
2. Finish the fast tier from the list in `docs/verification_plan.md` §2,
   starting with `test_simultaneous_rw_at_full` and `_at_empty`.
3. Resolve the open question above. When the spec and RTL disagree, fix the spec
   if the RTL is right; that has already happened twice here, on `almost_full`
   and on `F7`.
