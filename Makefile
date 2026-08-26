.PHONY: sim clean

sim:
	$(MAKE) -C tb/cocotb SIM=verilator

clean:
	$(MAKE) -C tb/cocotb clean
