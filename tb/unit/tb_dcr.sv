`timescale 1ns/1ps
// tb_dcr.sv -- unit test for dcr.sv (wave launch sequencer).
// Run: make unit TEST=tb_dcr
module tb_dcr;
    localparam int TB = 8;
    logic        clk = 0, reset = 1, start, all_halted;
    logic [31:0] thread_count, src_addr, dst_addr;
    logic [31:0] tc_q, src_q, dst_q, block_base;
    logic        busy, done, launch;
    int errors = 0;

    dcr #(.TB(TB)) dut(
        .clk(clk), .reset(reset), .start(start),
        .thread_count(thread_count), .src_addr(src_addr), .dst_addr(dst_addr),
        .all_halted(all_halted),
        .busy(busy), .done(done), .launch(launch), .block_base(block_base),
        .thread_count_q(tc_q), .src_addr_q(src_q), .dst_addr_q(dst_q)
    );

    always #5 clk = ~clk;

    task automatic check(input logic got, exp, input string name);
        if (got !== exp) begin
            $display("FAIL %0s: got %0b expected %0b", name, got, exp);
            errors++;
        end else $display("PASS %0s", name);
    endtask

    task automatic start_launch(input [31:0] tcount);
        thread_count = tcount; all_halted = 0;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
    endtask

    task automatic wait_launch; while (!launch) @(negedge clk); endtask
    task automatic wait_done;   while (!done)   @(negedge clk); endtask

    initial begin
        start = 0; all_halted = 0;
        thread_count = 0; src_addr = 32'h2000; dst_addr = 32'h6000;
        repeat (2) @(posedge clk);
        reset = 0;

        // --- single wave: thread_count == TB → one launch, then done ---
        start_launch(32'd8);
        wait_launch;
        check(busy, 1'b1, "busy during launch");
        check(block_base === 32'd0, 1'b1, "first wave base 0");
        check(tc_q === 32'd8, 1'b1, "thread_count latched");
        check(src_q === 32'h2000, 1'b1, "src latched");
        check(dst_q === 32'h6000, 1'b1, "dst latched");

        @(negedge clk); all_halted = 1;
        wait_done;
        check(busy, 1'b0, "busy clears after done");
        @(negedge clk); all_halted = 0;

        // --- multi-wave: 16 threads == 2 waves ---
        start_launch(32'd16);
        wait_launch;
        check(block_base === 32'd0, 1'b1, "wave0 base 0");
        @(negedge clk); all_halted = 1;          // wave 0 halts

        wait_launch;                             // should relaunch, not finish
        check(block_base === 32'd8, 1'b1, "wave1 base 8");
        check(done, 1'b0, "no done between waves");
        @(negedge clk); all_halted = 0;
        @(negedge clk); all_halted = 1;          // wave 1 halts

        wait_done;
        check(busy, 1'b0, "busy clears after last wave");

        if (errors == 0) $display("TB_DCR PASS");
        else $fatal(1, "TB_DCR FAIL: %0d errors", errors);
        $finish;
    end
endmodule
