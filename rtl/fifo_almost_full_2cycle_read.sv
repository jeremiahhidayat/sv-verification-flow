// Module: fifo_almost_full_2cycle_read
// Description: FIFO with a 2 cycle read to improve performance

module fifo_almost_full_2cycle_read #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 32,
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

localparam int READ_LATENCY = 2;

logic [WIDTH-1:0] ram[DEPTH];
logic [WIDTH-1:0] rd_data_ram;
logic [$clog2(DEPTH)-1:0] wr_addr_r, rd_addr_r;

localparam int COUNT_WIDTH = $clog2(DEPTH) + 1;
logic [COUNT_WIDTH-1:0] count_r, next_count, count_update;
logic valid_wr, valid_rd;

assign count = count_r;

// Infer the RAM
always_ff @(posedge clk) begin
    if (valid_wr) ram[wr_addr_r] <= wr_data;
    rd_data_ram <= ram[rd_addr_r];

    // Register the RAM output for faster clocks.
    rd_data <= rd_data_ram;
end

always_ff @(posedge clk) begin
    if (rst) begin
        rd_addr_r <= '0;
        wr_addr_r <= '0;
        count_r   <= '0;
    end else begin
        count_r <= next_count;
        if (valid_wr) wr_addr_r <= wr_addr_r + 1'b1;
        if (valid_rd) rd_addr_r <= rd_addr_r + 1'b1;
    end
end

    // Update the count by 1, -1, or 0.
    // Using the optimization given by Stitt for counters
always_comb begin
    case ({
        valid_wr, valid_rd
    })
        2'b10:   count_update = COUNT_WIDTH'(1);
        2'b01:   count_update = '1; // negative 1
        default: count_update = '0;
    endcase
    next_count = count_r + count_update;
end

assign valid_wr = wr_en && !full;
assign valid_rd = rd_en && !empty;
assign almost_full = count_r == ALMOST_FULL_THRESHOLD;
assign full = count_r == DEPTH;
assign empty = count_r == 0;

endmodule
