SIM ?= verilator
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES = $(PWD)/../../rtl/fifo_almost_full_2cycle_read.sv
TOPLEVEL = fifo_almost_full_2cycle_read
MODULE = test_fifo
EXTRA_ARGS += --public-flat-rw

include $(shell cocotb-config --makefiles)/Makefile.sim