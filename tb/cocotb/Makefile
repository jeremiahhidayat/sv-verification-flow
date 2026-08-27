# Fast tier: cocotb + Verilator (docs/verification_plan.md Sec.2).
#
#   make            one elaboration at the defaults -- the inner-loop gate
#   make sweep      ALMOST_FULL_THRESHOLD in {1, DEPTH/2, DEPTH}
#
# The sweep is not optional for F10: ALMOST_FULL_THRESHOLD defaults to DEPTH,
# and at that value an exact-match almost_full is indistinguishable from a
# threshold-and-above one, so the default elaboration alone cannot close it.
# Same reasoning as the Questa tier's threshold sweep in tb/sv/Makefile.

SIM ?= verilator
TOPLEVEL_LANG ?= verilog

WIDTH                 ?= 8
DEPTH                 ?= 32
ALMOST_FULL_THRESHOLD ?= $(DEPTH)
NUM_TESTS             ?= 2000
SEED                  ?= 1

VERILOG_SOURCES = $(PWD)/../../rtl/fifo_almost_full_2cycle_read.sv
TOPLEVEL = fifo_almost_full_2cycle_read
MODULE = test_fifo

# Elaboration-time parameters. These and the FIFO_* environment variables below
# must agree; test_fifo.py cross-checks them against the DUT's own parameters
# and fails loudly if a -G override is ever forgotten here.
COMPILE_ARGS += -GWIDTH=$(WIDTH) -GDEPTH=$(DEPTH) -GALMOST_FULL_THRESHOLD=$(ALMOST_FULL_THRESHOLD)

# cocotb already passes --public-flat-rw to Verilator, which is what makes
# wr_addr_r/rd_addr_r visible for the pointer checks (F2/F3/F9). Note that
# EXTRA_ARGS goes to *both* the compile and the run, so Verilator-only switches
# belong in COMPILE_ARGS.

# Runtime configuration for the testbench.
export FIFO_WIDTH        := $(WIDTH)
export FIFO_DEPTH        := $(DEPTH)
export FIFO_AF_THRESHOLD := $(ALMOST_FULL_THRESHOLD)
export FIFO_NUM_TESTS    := $(NUM_TESTS)
export FIFO_SEED         := $(SEED)

# One build tree and one results file per elaboration, so a sweep does not
# rebuild over itself or overwrite the previous configuration's XML.
#
# `:=`, not `?=`. cocotb's Makefile.inc *exports* SIM_BUILD and
# COCOTB_RESULTS_FILE, so under `make sweep` the parent's values are already in
# the sub-make's environment -- and `?=` treats an environment variable as
# "already defined" and leaves it alone. Every sweep iteration would then share
# the first one's build directory, find Vtop.mk already present with unchanged
# sources, skip the rebuild, and silently re-run the first elaboration's binary
# against the next elaboration's expectations. `:=` overrides the environment
# while still losing to a command-line SIM_BUILD=..., which is what we want.
CONFIG := w$(WIDTH)_d$(DEPTH)_af$(ALMOST_FULL_THRESHOLD)
SIM_BUILD := sim_build/$(CONFIG)
COCOTB_RESULTS_FILE := results_$(CONFIG).xml

include $(shell cocotb-config --makefiles)/Makefile.sim

# Thresholds the sweep covers: the DEPTH default (almost_full coincides with
# full) and the two sub-DEPTH values that make the exact-match behavior
# observable. DEPTH/2 is deduped when DEPTH is 2.
THRESHOLDS ?= 1 $(shell echo $$(( $(DEPTH) / 2 ))) $(DEPTH)

.PHONY: sweep
sweep:
	@rc=0; \
	for th in $$(echo $(THRESHOLDS) | tr ' ' '\n' | sort -nu | tr '\n' ' '); do \
	    echo "=== fast tier: WIDTH=$(WIDTH) DEPTH=$(DEPTH) ALMOST_FULL_THRESHOLD=$$th ==="; \
	    $(MAKE) --no-print-directory ALMOST_FULL_THRESHOLD=$$th || rc=1; \
	done; \
	exit $$rc
