# sv-verification-flow

A verification-first take on a synchronous FIFO: the spec and verification plan
are written before any RTL exists, and every test traces back to a numbered spec
requirement.

Two toolchains cover different needs. A fast tier (cocotb + Verilator) runs on
every push in CI in under 30 seconds and catches functional regressions
immediately. A Questa tier provides SystemVerilog assertions and merged
functional coverage across multiple seeds. That's signoff evidence CI can't
produce, since Questa licenses are floating seats on a department server, not
something GitHub Actions can reach.

## Status

- [x] Spec written (`docs/fifo_spec.md`): synchronous FIFO, registered
      (non-FWFT) read data, numbered behaviors F1–F14
- [x] Verification plan written (`docs/verification_plan.md`): traceability
      matrix from spec ID to fast-tier test to Questa covergroup/assertion
- [ ] RTL (`rtl/fifo.sv`)
- [ ] Fast tier: cocotb tests (`tb/cocotb/`)
- [ ] CI (`.github/workflows/ci.yml`)
- [ ] Questa tier: SVA + coverage (`tb/sv/`)

## Repo layout

```
rtl/fifo.sv          RTL under verification
docs/fifo_spec.md    Interface, reset behavior, numbered spec (F1–F14)
docs/verification_plan.md   Spec-ID -> test -> coverage/assertion traceability
tb/cocotb/           Fast tier: cocotb + Verilator, PR-gated
tb/sv/               Questa tier: SVA + functional coverage, run on department
                     license servers (not reachable from CI)
.github/workflows/ci.yml
Makefile
```

## Design under test

A parameterizable synchronous FIFO (`WIDTH`, `DEPTH`) with registered read data,
almost-full/almost-empty flags, and defined behavior for the corner cases that
actually break FIFOs in practice: simultaneous read+write at full, simultaneous
read+write at empty, and pointer wrap-around. See `docs/fifo_spec.md` for the
full numbered behavior list.

## Running the tests

```bash
make sim          # fast tier: cocotb + Verilator
make questa       # Questa tier (requires department license server / VPN)
make questa-cov   # Questa tier with coverage, merges across seeds
```

*(Targets land alongside the RTL and testbenches; see Status above.)*
