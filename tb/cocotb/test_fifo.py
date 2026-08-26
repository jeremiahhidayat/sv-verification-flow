import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from collections import deque

async def reset_dut(dut):
    dut.rst.value = 1
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

@cocotb.test()
async def test_write_then_read(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    ref = deque()          # data actually stored, FIFO order
    pending = deque()      # (cycles_remaining, expected_value) in the read pipeline

    dut.wr_en.value = 0
    dut.rd_en.value = 0

    # Write one word
    dut.wr_en.value = 1
    dut.wr_data.value = 0xA5
    await RisingEdge(dut.clk)
    dut.wr_en.value = 0
    ref.append(0xA5)

    # Issue a read
    dut.rd_en.value = 1
    await RisingEdge(dut.clk)
    dut.rd_en.value = 0
    pending.append([2, ref.popleft()])   # expect rd_data 2 cycles after acceptance

    # Advance and check when pending reads mature
    for _ in range(4):
        await RisingEdge(dut.clk)
        for p in pending:
            p[0] -= 1
        while pending and pending[0][0] == 0:
            _, expected = pending.popleft()
            assert int(dut.rd_data.value) == expected