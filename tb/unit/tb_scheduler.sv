`timescale 1ns/1ps
// tb_scheduler.sv -- unit test for scheduler.sv. Run: make unit TEST=tb_scheduler
module tb_scheduler;
    localparam int WARPS = 2;
    logic             clk = 0, reset = 1;
    logic [WARPS-1:0] ready, grant;
    int errors = 0;
    int g0, g1;

    scheduler #(.WARPS(WARPS)) dut(.clk(clk), .reset(reset), .ready(ready), .grant(grant));

    always #5 clk = ~clk;

    task automatic check(input logic got, exp, input string name);
        if (got !== exp) begin $display("FAIL %0s", name); errors++; end
        else $display("PASS %0s", name);
    endtask

    initial begin
        ready = 2'b00;
        repeat (2) @(posedge clk);
        reset = 0;

        // No ready -> no grant.
        @(negedge clk); ready = 2'b00; #1;
        check(grant === 2'b00, 1'b1, "no ready -> no grant");

        // Only warp 0 ready -> always warp 0.
        @(negedge clk); ready = 2'b01;
        repeat (4) begin @(negedge clk); #1; check(grant === 2'b01, 1'b1, "solo warp0"); end

        // Only warp 1 ready -> always warp 1.
        @(negedge clk); ready = 2'b10;
        repeat (4) begin @(negedge clk); #1; check(grant === 2'b10, 1'b1, "solo warp1"); end

        // Both ready -> must alternate and never grant both.
        @(negedge clk); ready = 2'b11;
        g0 = 0; g1 = 0;
        repeat (8) begin
            @(negedge clk); #1;
            if (grant === 2'b01) g0++;
            else if (grant === 2'b10) g1++;
            else begin $display("FAIL grant not one-hot: %b", grant); errors++; end
        end
        check(g0 == 4, 1'b1, "fair count warp0 (4/8)");
        check(g1 == 4, 1'b1, "fair count warp1 (4/8)");

        if (errors == 0) $display("TB_SCHEDULER PASS");
        else $fatal(1, "TB_SCHEDULER FAIL: %0d errors", errors);
        $finish;
    end
endmodule
