`timescale 1ns/1ps
// dispatcher.sv -- maps a wave's threads onto warps and lanes.
//
// `block_base` is the global tid of the first thread in the current wave (it
// advances by WARPS*LANES each wave; see dcr.sv). Within a wave:
//
//   tid                  = block_base + w*LANES + l
//   warp_tid_base[w]     = block_base + w*LANES
//   warp_lane_mask[w][l] = (tid < thread_count)
//
// `warp_start` follows the per-wave `start` pulse. Pure combinational.
module dispatcher #(parameter int WARPS = 2, parameter int LANES = 4)(
    input  logic                        start,
    input  logic [31:0]                 thread_count,
    input  logic [31:0]                 block_base,
    output logic [WARPS-1:0]            warp_start,
    output logic [WARPS-1:0][31:0]      warp_tid_base,
    output logic [WARPS-1:0][LANES-1:0] warp_lane_mask
);
    always_comb begin
        warp_start     = '0;
        warp_tid_base  = '0;
        warp_lane_mask = '0;

        for (int w = 0; w < WARPS; w++) begin
            warp_start[w]    = start;
            warp_tid_base[w] = block_base + w * LANES;
            for (int l = 0; l < LANES; l++)
                warp_lane_mask[w][l] = ((block_base + w * LANES + l) < thread_count);
        end
    end
endmodule
