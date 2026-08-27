# sv-verification-flow

Verification-first development of a small synchronous FIFO. The spec and the
verification plan are written before the RTL, every test traces back to a
numbered requirement, and two toolchains check the design at different speeds.

## What it's for

| | Fast tier | Questa tier |
|---|---|---|
| Tools | cocotb + Verilator | Questa (SVA + functional coverage) |
| Where | Every push, GitHub Actions | Department license server |
| Runtime | ~45 s (3 elaborations) | Minutes, multi-seed |
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
make check        # lint + sim-sweep, the pre-push gate, no license needed
make sim          # fast tier, one elaboration -- the inner loop
make sim-sweep    # fast tier over ALMOST_FULL_THRESHOLD {1, DEPTH/2, DEPTH}
make lint         # Verilator syntax check of RTL + SV testbench

make questa       # Questa tier, a single run
make regress      # seeds x elaborations, vcover merge, HTML report
make coverage     # re-report from an existing merged UCDB

make clean-questa # Questa artifacts only; needs no cocotb
make clean-force  # same, killing processes still holding files open (NFS)
```

On a Questa-only machine, `make clean` skips the fast tier rather than failing:
`tb/cocotb/Makefile` includes cocotb's `Makefile.sim`, so it cannot be parsed at
all without cocotb installed.

Parameters forward to the Questa tier:

```bash
make regress DEPTH=8 SEEDS="1 2 3 4 5"
make questa SEED=7 ALMOST_FULL_THRESHOLD=16
```

`make regress` sweeps `ALMOST_FULL_THRESHOLD` over `{1, DEPTH/2, DEPTH}` as well
as seeds. That is not optional: the parameter is elaboration-time, and at its
`DEPTH` default `almost_full` is indistinguishable from `full`, so the default
configuration alone cannot close `F10`.

## Coverage

`make regress` (3 seeds x 3 `ALMOST_FULL_THRESHOLD` elaborations) closes
`cg_fifo` at 98.14% (45/46 bins), with every coverpoint — including
`cp_af_vs_full`, the one that needs the sub-`DEPTH` sweep to be reachable at
all — at 100%:

![Questa covergroup coverage report](docs/images/questa_coverage_report.png)

Full report: `tb/sv/out/covhtml/index.html` (regenerate with `make coverage`).

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
- **Verilator's VPI reports a parameter's declared default, not the elaborated
  `-G` override.** `dut.DEPTH.value` reads `32` in a build whose `almost_full`
  compare folded to `4U == count_r`, because Verilator constant-folds parameters
  out of the model entirely. A testbench that cross-checks its configuration by
  reading parameters will produce false failures; `tb/cocotb/test_fifo.py`
  checks signal *widths* instead, which survive the folding.
- **`SIM_BUILD ?=` cannot override cocotb's exported value.** `Makefile.inc`
  exports `SIM_BUILD` and `COCOTB_RESULTS_FILE`, so under a recursive `make`
  they are already set in the sub-make's environment and `?=` leaves them alone.
  Every iteration of a parameter sweep then shares the first one's build
  directory, finds `Vtop.mk` present with unchanged sources, skips the rebuild,
  and silently re-runs the first elaboration's binary against the next
  elaboration's expectations -- a sweep that looks like it ran and did not. Use
  `:=`, which still loses to a command-line override.
- **Questa exits `0` even when `$error` fired.** `tb/sv/Makefile`'s `check-log`
  requires the testbench's own pass banner *and* the absence of `** Error` or
  `** Fatal`.
- **`vsim -c` needs `-onfinish stop` or no coverage is ever saved.** The default
  is `-onfinish exit`, so the testbench's `$finish` tears the simulator down
  before the `-do` script reaches `coverage save`. Runs look green and the UCDB
  directory stays empty. `check-log` now fails a run whose UCDB is missing, so
  this surfaces at the run rather than at the merge.
- **On NFS home directories, `rm` cannot unlink a file another process still has
  open.** It renames it to `.nfsXXXXXX` and reports "Device or resource busy",
  usually because a vsim from an aborted run, a GUI vsim, or a `tail -f` is
  still holding a log. Use `make clean-force`, or keep the output off NFS with
  `make regress OUT=/tmp/$USER-fifo-out`.

## Status

- [x] Spec, verification plan, RTL
- [x] CI green, ~45 s per run (three elaborations)
- [x] Questa tier: testbench, covergroups and 5 SVA written and run against a
      real license. Its first run found a spec/RTL mismatch on `F7`, since
      corrected in the spec. `make regress` (3 seeds x 3 `ALMOST_FULL_THRESHOLD`
      elaborations) now runs clean: `cg_fifo` at 98.14%, see Coverage above.
- [x] Fast tier: all 14 tests from `docs/verification_plan.md` §2, same names
      as the Questa tier, each checking the DUT against a spec-derived reference
      model every cycle. 14/14 pass at each of the three elaborations in
      `make sim-sweep`.
- [x] Fast tier validated by mutation: seven injected RTL bugs (`>=` for `==` on
      `almost_full`, a write committing into a read's freed slot, a shortened
      read pipeline, reset missing `count`, `full` one entry early, a read that
      does not decrement `count`, unqualified write data) are each caught. The
      F7 mutation is caught by only two tests, one of them the directed
      `test_simultaneous_rw_at_full` — the same asymmetry that let the real bug
      hide from the Questa tier's per-cycle checks.

### Open question

`ALMOST_FULL_THRESHOLD` defaults to `DEPTH`, making `almost_full` identical to
`full` unless a caller overrides it. Whether that is an intentional safe default
is unresolved. See `docs/verification_plan.md` §4.

## Next steps

1. Root-cause the one missed bin in `cg_fifo` (45/46, see Coverage above) and
   either close it with a targeted seed/directed test or document why it's
   unreachable.
2. Cross-check the two tiers on the same failing configuration now that they
   share parameter names, and reconcile any behavior only one of them sees.
3. Resolve the open question above. When the spec and RTL disagree, fix the spec
   if the RTL is right; that has already happened twice here, on `almost_full`
   and on `F7`.
