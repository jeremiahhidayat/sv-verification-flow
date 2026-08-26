import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly
from collections import deque

async def reset_dut(dut):
    dut.rst.value = 1
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

async def write_dut(dut, value):
    dut.wr_en.value = 1
    dut.wr_data.value = value
    await RisingEdge(dut.clk)
    dut.wr_en.value = 0

async def read_dut(dut):
    dut.rd_en.value = 1
    await RisingEdge(dut.clk)      # accept edge
    dut.rd_en.value = 0
    await RisingEdge(dut.clk)      # rd_data's update for this read lands here
    await ReadOnly()
    value = int(dut.rd_data.value) # settled, correct
    await RisingEdge(dut.clk)      # leave the ReadOnly phase so the next call can drive again
    return value

@cocotb.test()
async def test_write_then_read(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
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

@cocotb.test()
async def test_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    assert bool(dut.empty.value) == 1
    assert bool(dut.full.value) == 0
    assert bool(dut.count.value) == 0


@cocotb.test()
async def test_fill_to_full(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    # fill up the dut, default depth is 32 right now
    for txn_count in range(int(dut.DEPTH.value)):
        await write_dut(dut, 0xFF)

    # nothing drives after the loop, so it's safe to settle here before reading
    await ReadOnly()
    assert int(dut.count.value) == dut.DEPTH.value
    assert int(dut.full.value) == 1
    assert int(dut.empty.value) == 0

@cocotb.test()
async def test_drain_to_empty(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    # fill up the dut, default depth is 32 right now
    for txn_count in range(int(dut.DEPTH.value)):
        await write_dut(dut, 0xFF)

    for txn_count in range(int(dut.DEPTH.value)):
        await read_dut(dut)

    await ReadOnly()
    assert int(dut.count.value) == 0
    assert int(dut.full.value) == 0
    assert int(dut.empty.value) == 1

