// Module: fifo_almost_full_2cycle_read
// Description: FIFO with a 2 cycle read to improve performance

module fifo_almost_full_2cycle_read #(
    parameter WIDTH = 8,
    parameter DEPTH = 32,
    parameter int ALMOST_FULL_THRESHOLD = DEPTH
) (

    input  logic                       clk,
    input  logic                       rst,
    output logic                       full,
    output logic                       almost_full,
    output logic [$clog2(DEPTH+1)-1:0] count,
    input  logic                       wr_en,
    input  logic [          WIDTH-1:0] wr_data,
    output logic                       empty,
    input  logic                       rd_en,
    output logic [          WIDTH-1:0] rd_data
);


endmodule
