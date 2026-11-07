`timescale 1ns/1ps
// tb_dispatcher.sv -- unit test for dispatcher.sv.
// Run: make unit TEST=tb_dispatcher
module tb_dispatcher;
    localparam int WARPS = 2, LANES = 4;
    logic                        start;
    logic [31:0]                 thread_count, block_base;
    logic [WARPS-1:0]            warp_start;
    logic [WARPS-1:0][31:0]      warp_tid_base;
    logic [WARPS-1:0][LANES-1:0] warp_lane_mask;
    int errors = 0;

    dispatcher #(.WARPS(WARPS), .LANES(LANES)) dut(
        .start(start), .thread_count(thread_count), .block_base(block_base),
        .warp_start(warp_start),
        .warp_tid_base(warp_tid_base),
        .warp_lane_mask(warp_lane_mask)
    );

    task automatic check(input logic got, exp, input string name);
        if (got !== exp) begin
            $display("FAIL %0s", name); errors++;
        end else $display("PASS %0s", name);
    endtask

    initial begin
        // First wave, 6 threads: warp0 full, warp1 half.
        start = 1'b1; thread_count = 32'd6; block_base = 32'd0; #1;
        check(warp_start[0], 1'b1, "warp0 start");
        check(warp_start[1], 1'b1, "warp1 start");
        check(warp_tid_base[0] === 32'd0, 1'b1, "wave0 warp0 tid_base 0");
        check(warp_tid_base[1] === 32'd4, 1'b1, "wave0 warp1 tid_base 4");
        check(warp_lane_mask[0] === 4'b1111, 1'b1, "wave0 warp0 all lanes");
        check(warp_lane_mask[1] === 4'b0011, 1'b1, "wave0 warp1 lanes 0,1");

        // Second wave (block_base = 8), 12 threads total: warp0 tids 8..11
        // active, warp1 tids 12..15 inactive.
        block_base = 32'd8; thread_count = 32'd12; #1;
        check(warp_tid_base[0] === 32'd8, 1'b1, "wave1 warp0 tid_base 8");
        check(warp_tid_base[1] === 32'd12, 1'b1, "wave1 warp1 tid_base 12");
        check(warp_lane_mask[0] === 4'b1111, 1'b1, "wave1 warp0 all lanes");
        check(warp_lane_mask[1] === 4'b0000, 1'b1, "wave1 warp1 no lanes");

        // 1 thread, base 0 -> only lane 0 of warp 0.
        block_base = 32'd0; thread_count = 32'd1; #1;
        check(warp_lane_mask[0] === 4'b0001, 1'b1, "1 thread -> lane0");
        check(warp_lane_mask[1] === 4'b0000, 1'b1, "1 thread -> warp1 none");

        // start low -> no warp starts.
        start = 1'b0; block_base = 32'd0; thread_count = 32'd8; #1;
        check(warp_start === 2'b00, 1'b1, "start low -> no starts");

        if (errors == 0) $display("TB_DISPATCHER PASS");
        else $fatal(1, "TB_DISPATCHER FAIL: %0d errors", errors);
        $finish;
    end
endmodule
