# Top-level entry point for the two-tier flow in docs/verification_plan.md.
#
#   Fast tier   cocotb + Verilator, seconds, PR-gated       -> tb/cocotb/
#   Questa tier SVA + functional coverage, signoff metric   -> tb/sv/
#
# `make` on its own prints this list. `make check` is the pre-push gate:
# lint + fast tier, no Questa license needed.

FAST_DIR   := tb/cocotb
QUESTA_DIR := tb/sv

# Forwarded to the Questa tier; see tb/sv/Makefile for the full set.
WIDTH                 ?= 8
DEPTH                 ?= 32
ALMOST_FULL_THRESHOLD ?= $(DEPTH)
NUM_TESTS             ?= 1000
SEED                  ?= 1
SEEDS                 ?= 1 2 3

QUESTA_ARGS = WIDTH=$(WIDTH) DEPTH=$(DEPTH) \
              ALMOST_FULL_THRESHOLD=$(ALMOST_FULL_THRESHOLD) \
              NUM_TESTS=$(NUM_TESTS) SEED=$(SEED) SEEDS="$(SEEDS)"

.PHONY: help sim lint questa questa-gui regress coverage check all \
        clean clean-fast clean-questa clean-force

help:
	@echo "fifo_almost_full_2cycle_read -- two-tier verification"
	@echo ""
	@echo "  make sim         fast tier: cocotb + Verilator (target: clean in <30s)"
	@echo "  make lint        Verilator syntax check of RTL + SV testbench"
	@echo "  make check       lint + sim -- the pre-push gate, no Questa needed"
	@echo ""
	@echo "  make questa      Questa tier: one run (SEED=$(SEED),"
	@echo "                   ALMOST_FULL_THRESHOLD=$(ALMOST_FULL_THRESHOLD))"
	@echo "  make questa-gui  same, interactive, with waves"
	@echo "  make regress     signoff regression: seeds x elaborations,"
	@echo "                   vcover merge, HTML report"
	@echo "  make coverage    re-report from the existing merged UCDB"
	@echo ""
	@echo "  make all         check + regress"
	@echo ""
	@echo "  make clean         both tiers (fast tier skipped if cocotb absent)"
	@echo "  make clean-questa  Questa tier only, no cocotb needed"
	@echo "  make clean-force   Questa clean, killing processes still holding"
	@echo "                     files open (NFS 'Device or resource busy')"
	@echo ""
	@echo "Parameter overrides (forwarded to the Questa tier):"
	@echo "  WIDTH DEPTH ALMOST_FULL_THRESHOLD NUM_TESTS SEED SEEDS"
	@echo "  e.g. make regress DEPTH=8 SEEDS=\"1 2 3 4 5\""

# --- Fast tier -------------------------------------------------------------
# tb/cocotb/Makefile includes cocotb's Makefile.sim via `cocotb-config`, so
# without cocotb installed the include itself fails with an obscure error.
# Check first and say something useful instead.
HAVE_COCOTB = command -v cocotb-config >/dev/null 2>&1

sim:
	@$(HAVE_COCOTB) || { \
	    echo "error: cocotb not found, so the fast tier cannot run here."; \
	    echo "  install it:  python3 -m venv .venv && . .venv/bin/activate \\"; \
	    echo "                 && pip install -r requirements.txt"; \
	    echo "  or, on a Questa-only machine, use 'make questa' / 'make regress'."; \
	    exit 1; }
	$(MAKE) -C $(FAST_DIR) SIM=verilator

# --- Questa tier -----------------------------------------------------------
questa:
	$(MAKE) -C $(QUESTA_DIR) sim $(QUESTA_ARGS)

questa-gui:
	$(MAKE) -C $(QUESTA_DIR) gui $(QUESTA_ARGS)

regress:
	$(MAKE) -C $(QUESTA_DIR) regress $(QUESTA_ARGS)

coverage:
	$(MAKE) -C $(QUESTA_DIR) report

# --- Gates -----------------------------------------------------------------
# lint covers both tiers' sources: the RTL, and the SV testbench that Verilator
# can parse but not execute. It is the only check that runs without a license.
lint:
	$(MAKE) -C $(QUESTA_DIR) lint

check: lint sim

all: check regress

# --- Clean -----------------------------------------------------------------
# Always cleans the Questa tier. The fast tier is skipped rather than failing
# when cocotb is absent, since its Makefile cannot even be parsed without it.
clean: clean-questa
	@$(HAVE_COCOTB) && $(MAKE) --no-print-directory clean-fast \
	    || echo "clean: skipping fast tier (cocotb not installed)"

clean-fast:
	$(MAKE) -C $(FAST_DIR) clean

clean-questa:
	$(MAKE) -C $(QUESTA_DIR) clean

# Questa clean that also kills processes still holding files open (NFS).
clean-force:
	$(MAKE) -C $(QUESTA_DIR) clean-force
