# Questa tier -- SVA + functional coverage for fifo_almost_full_2cycle_read.
#
# Implements the run/merge flow in docs/verification_plan.md Sec.3: N seeds
# across >= 2 elaborations -> vcover merge -> vcover report -html.
#
# The multi-elaboration part is not optional. almost_full is an exact-match
# flag (count == ALMOST_FULL_THRESHOLD), and at the ALMOST_FULL_THRESHOLD ==
# DEPTH default that is indistinguishable from count >= THRESHOLD, so the
# default instantiation alone cannot close F10 or cp_af_vs_full's
# af_only/full_only bins. Hence THRESHOLDS below sweeps {1, DEPTH/2, DEPTH}.
#
# Requires a POSIX shell (Questa's own bin dir on PATH). On Windows, run this
# from WSL or Git Bash, or from a Questa command prompt with GNU make.
#
# Common invocations:
#   make comp                     compile only
#   make sim                      one run, default params, SEED=1
#   make sim SEED=7 DEPTH=8       one run, different seed/depth
#   make gui                      same but interactive, with waves
#   make regress                  full signoff regression + merged HTML report
#   make regress SEEDS="1 2 3 4 5"
#   make lint                     Verilator syntax check (no Questa needed)

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------
RTL_DIR ?= ../../rtl
RTL     ?= $(RTL_DIR)/fifo_almost_full_2cycle_read.sv
TB      ?= fifo_almost_full_2cycle_read_tb.sv
TOP     ?= fifo_almost_full_2cycle_read_tb

# ---------------------------------------------------------------------------
# DUT / TB parameters (overridable on the command line)
# ---------------------------------------------------------------------------
WIDTH                 ?= 8
DEPTH                 ?= 32
ALMOST_FULL_THRESHOLD ?= $(DEPTH)
NUM_TESTS             ?= 1000

# Elaborations the regression sweeps. DEPTH and 1 are the two extremes called
# out in F10; DEPTH/2 is an ordinary mid-range threshold. Anything other than
# DEPTH is what makes the exact-match behaviour observable at all.
THRESHOLDS ?= 1 $(shell expr $(DEPTH) / 2) $(DEPTH)

# Seeds per elaboration. verification_plan.md Sec.3 asks for 3-5.
SEEDS ?= 1 2 3
SEED  ?= 1

# ---------------------------------------------------------------------------
# Tools / output layout
# ---------------------------------------------------------------------------
VLIB   ?= vlib
VMAP   ?= vmap
VLOG   ?= vlog
VSIM   ?= vsim
VCOVER ?= vcover

WORK     ?= work
OUT      ?= out
UCDB_DIR := $(OUT)/ucdb
LOG_DIR  := $(OUT)/log
MERGED   := $(OUT)/merged.ucdb
HTML_DIR := $(OUT)/covhtml

# Code coverage on the RTL only -- collecting statement/branch coverage on the
# testbench itself just inflates the denominator with unreachable error paths.
VLOG_RTL_FLAGS ?= -sv +cover=bcesxf
VLOG_TB_FLAGS  ?= -sv

# +acc keeps DUT internals visible to the testbench. The SVA and the pointer
# cross-check reference DUT.wr_addr_r / DUT.rd_addr_r / DUT.ram hierarchically,
# and vopt would otherwise be free to collapse them.
VOPTARGS ?= +acc

PARAMS = -gWIDTH=$(WIDTH) -gDEPTH=$(DEPTH) -gNUM_TESTS=$(NUM_TESTS)

.PHONY: all comp sim gui regress merge report lint clean help

all: regress

help:
	@echo "Questa tier targets:"
	@echo "  comp     compile RTL + TB into ./$(WORK)"
	@echo "  sim      single run (SEED=$(SEED), ALMOST_FULL_THRESHOLD=$(ALMOST_FULL_THRESHOLD))"
	@echo "  gui      single run, interactive, with waves"
	@echo "  regress  $(words $(SEEDS)) seeds x $(words $(THRESHOLDS)) elaborations, merge, HTML report"
	@echo "  report   re-generate the report from an existing merged UCDB"
	@echo "  lint     Verilator syntax check (no Questa license needed)"
	@echo "  clean    remove $(WORK)/ and $(OUT)/"

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------
comp: $(WORK)/_info

$(WORK)/_info: $(RTL) $(TB)
	$(VLIB) $(WORK)
	$(VMAP) work $(WORK)
	$(VLOG) $(VLOG_RTL_FLAGS) $(RTL)
	$(VLOG) $(VLOG_TB_FLAGS) $(TB)

# ---------------------------------------------------------------------------
# Single run
# ---------------------------------------------------------------------------
# $(1) = run name, $(2) = almost-full threshold, $(3) = seed
define run_one
	@mkdir -p $(UCDB_DIR) $(LOG_DIR)
	$(VSIM) -c -coverage -voptargs="$(VOPTARGS)" \
	    -sv_seed $(3) $(PARAMS) -gALMOST_FULL_THRESHOLD=$(2) \
	    -l $(LOG_DIR)/$(1).log \
	    work.$(TOP) \
	    -do "run -all; coverage save $(UCDB_DIR)/$(1).ucdb; quit -f"
	@$(MAKE) --no-print-directory check-log LOG=$(LOG_DIR)/$(1).log
endef

sim: comp
	$(call run_one,aft$(ALMOST_FULL_THRESHOLD)_seed$(SEED),$(ALMOST_FULL_THRESHOLD),$(SEED))

gui: comp
	$(VSIM) -gui -coverage -voptargs="$(VOPTARGS)" \
	    -sv_seed $(SEED) $(PARAMS) -gALMOST_FULL_THRESHOLD=$(ALMOST_FULL_THRESHOLD) \
	    work.$(TOP) \
	    -do "add wave -r /$(TOP)/*; run -all"

# A run is a failure if the testbench says so, or if any SVA / covergroup
# illegal_bin / $fatal fired. Both matter: the testbench's own report covers
# F1-F16 data and flag checks, the transcript errors cover the 5 assertions
# and the documented full && empty exclusion.
.PHONY: check-log
check-log:
	@if grep -q '\*\*\* TEST FAILED \*\*\*' $(LOG) 2>/dev/null; then \
	    echo "FAILED (testbench self-check): $(LOG)"; exit 1; \
	elif grep -qE '\*\* (Error|Fatal)' $(LOG) 2>/dev/null; then \
	    echo "FAILED (assertion or simulator error): $(LOG)"; \
	    grep -E '\*\* (Error|Fatal)' $(LOG) | head -20; exit 1; \
	elif ! grep -q '\*\*\* TEST PASSED \*\*\*' $(LOG) 2>/dev/null; then \
	    echo "FAILED (no pass banner -- run died early?): $(LOG)"; exit 1; \
	else \
	    echo "PASS: $(LOG)"; \
	fi

# ---------------------------------------------------------------------------
# Regression -- the signoff flow from docs/verification_plan.md Sec.3
# ---------------------------------------------------------------------------
regress: comp
	@rm -rf $(UCDB_DIR) $(LOG_DIR)
	@mkdir -p $(UCDB_DIR) $(LOG_DIR)
	@echo "=== regression: thresholds [$(THRESHOLDS)] x seeds [$(SEEDS)] ==="
	@fails=0; \
	for aft in $(THRESHOLDS); do \
	  for seed in $(SEEDS); do \
	    name="aft$${aft}_seed$${seed}"; \
	    echo "--- $$name ---"; \
	    $(VSIM) -c -coverage -voptargs="$(VOPTARGS)" \
	        -sv_seed $$seed $(PARAMS) -gALMOST_FULL_THRESHOLD=$$aft \
	        -l $(LOG_DIR)/$$name.log \
	        work.$(TOP) \
	        -do "run -all; coverage save $(UCDB_DIR)/$$name.ucdb; quit -f" \
	        > /dev/null 2>&1; \
	    if ! $(MAKE) --no-print-directory check-log LOG=$(LOG_DIR)/$$name.log; then \
	      fails=$$((fails + 1)); \
	    fi; \
	  done; \
	done; \
	echo ""; \
	if [ $$fails -ne 0 ]; then \
	  echo "=== $$fails run(s) FAILED -- logs in $(LOG_DIR)/ ==="; \
	  echo "=== merging coverage anyway so the report reflects what did run ==="; \
	fi; \
	$(MAKE) --no-print-directory merge report; \
	exit $$fails

merge:
	@ls $(UCDB_DIR)/*.ucdb >/dev/null 2>&1 || { echo "no UCDBs in $(UCDB_DIR) -- run 'make regress' first"; exit 1; }
	$(VCOVER) merge -out $(MERGED) $(UCDB_DIR)/*.ucdb

report:
	$(VCOVER) report -html -htmldir $(HTML_DIR) -details -assert -cvg $(MERGED)
	@echo ""
	@echo "=== coverage summary (signoff target: 100% of cp_occupancy,"
	@echo "===  cx_wr_rd_full_empty and cp_af_vs_full bins; all 5 assertions pass) ==="
	$(VCOVER) report -details -cvg $(MERGED)
	@echo ""
	@echo "HTML report: $(HTML_DIR)/index.html"

# ---------------------------------------------------------------------------
# Verilator syntax check -- catches typos without burning a Questa license.
# Verilator implements neither covergroups nor SVA local variables, so those
# constructs are waived here; this is a syntax gate, not a coverage run.
# ---------------------------------------------------------------------------
lint:
	verilator --lint-only --timing --top-module $(TOP) \
	    -Wno-COVERIGN -Wno-WIDTHTRUNC \
	    $(RTL) $(TB)
	@echo "lint: OK"

clean:
	rm -rf $(WORK) $(OUT) transcript vsim.wlf modelsim.ini *.ucdb
