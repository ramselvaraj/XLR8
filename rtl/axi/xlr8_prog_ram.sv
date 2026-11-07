`timescale 1ns/1ps
// xlr8_prog_ram.sv -- GPU instruction RAM, 16-bit instructions, byte-writable from the host.
//
// Host side is 32 bits wide: word w holds instruction 2w in [15:0] and 2w+1 in [31:16].
// The GPU fetch port is a combinational (asynchronous) read, as simt_gpu requires.
module xlr8_prog_ram #(
    parameter int DEPTH = 1024                  // instructions
)(
    input  logic                     clk,
    // GPU fetch port
    input  logic [$clog2(DEPTH)-1:0] fetch_addr,
    output logic [15:0]              fetch_data,
    // Host write port (word addressed)
    input  logic                     we,
    input  logic [$clog2(DEPTH)-2:0] waddr,
    input  logic [31:0]              wdata,
    input  logic [3:0]               wstrb,
    // Host read port (word addressed, combinational)
    input  logic [$clog2(DEPTH)-2:0] raddr,
    output logic [31:0]              rdata
);
    logic [15:0] mem [DEPTH];

    initial begin
        for (int i = 0; i < DEPTH; i++) mem[i] = 16'h0000;
    end

    assign fetch_data = mem[fetch_addr];
    assign rdata      = {mem[{raddr, 1'b1}], mem[{raddr, 1'b0}]};

    always_ff @(posedge clk) begin
        if (we) begin
            if (wstrb[0]) mem[{waddr, 1'b0}][7:0]  <= wdata[7:0];
            if (wstrb[1]) mem[{waddr, 1'b0}][15:8] <= wdata[15:8];
            if (wstrb[2]) mem[{waddr, 1'b1}][7:0]  <= wdata[23:16];
            if (wstrb[3]) mem[{waddr, 1'b1}][15:8] <= wdata[31:24];
        end
    end
endmodule
