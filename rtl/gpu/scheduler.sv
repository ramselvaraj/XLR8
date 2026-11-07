`timescale 1ns/1ps
// scheduler.sv -- round-robin warp scheduler.
//
// Grants exactly one ready warp per cycle, rotating so no ready warp starves.
// When no warp is ready, grant == 0.
//
// TODO(Person A): implement round-robin.
//   Suggested: keep a `last` pointer (0..WARPS-1). Scan from `last` forward for
//   the first ready warp; grant it one-hot. Advance `last` past the granted
//   warp on the next edge.
module scheduler #(parameter int WARPS = 2)(
    input  logic             clk,
    input  logic             reset,
    input  logic [WARPS-1:0] ready,
    output logic [WARPS-1:0] grant
);
    int last;
    int winner;

    always_comb begin
        logic found;
        grant  = '0;
        found  = 0;
        winner = 0;
        for (int i = 0; i < WARPS; i++) begin
            int w;
            w = (last + i) % WARPS;      // scan starting just after `last`
            if (!found && ready[w]) begin
                grant[w] = 1'b1;         // one-hot win
                found    = 1;
                winner   = w;
            end
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset)          last <= 0;
        else if (|grant)    last <= (winner + 1) % WARPS;
    end
endmodule
