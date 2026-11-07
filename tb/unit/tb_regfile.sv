`timescale 1ns/1ps
// tb_regfile.sv -- unit test for regfile.sv. Run: make unit TEST=tb_regfile
module tb_regfile;
    localparam int LANES = 4;
    logic              clk = 0, reset = 1, we;
    logic [LANES-1:0]  wmask;
    logic [3:0]        waddr, ra1, ra2, ra3;
    logic [31:0]       wdata [LANES];
    logic [31:0]       rd1 [LANES], rd2 [LANES], rd3 [LANES];
    logic [31:0]       tid_base, src_addr, dst_addr;
    int errors = 0;

    regfile #(.LANES(LANES)) dut(
        .clk(clk), .reset(reset), .write_enable(we), .write_mask(wmask),
        .write_addr(waddr), .write_data(wdata),
        .read_addr1(ra1), .read_addr2(ra2), .read_addr3(ra3),
        .read_data1(rd1), .read_data2(rd2), .read_data3(rd3),
        .tid_base(tid_base), .src_addr(src_addr), .dst_addr(dst_addr)
    );

    always #5 clk = ~clk;

    task automatic check(input [31:0] got, exp, input string name);
        if (got !== exp) begin
            $display("FAIL %0s: got %0d expected %0d", name, got, exp);
            errors++;
        end else $display("PASS %0s", name);
    endtask

    initial begin
        wdata[0]=32'd100; wdata[1]=32'd101; wdata[2]=32'd102; wdata[3]=32'd103;
        we=0; wmask='0; waddr=0; ra1=0; ra2=0; ra3=0;
        tid_base=32'd1000; src_addr=32'h2000; dst_addr=32'h6000;

        repeat (2) @(posedge clk);
        reset = 0;

        // Write r5 across all lanes.
        @(negedge clk); we=1; wmask=4'b1111; waddr=5;
        @(negedge clk); we=0;

        ra1=5; #1;
        check(rd1[0], 100, "r5 lane0");
        check(rd1[1], 101, "r5 lane1");
        check(rd1[2], 102, "r5 lane2");
        check(rd1[3], 103, "r5 lane3");

        // Special registers.
        ra1=0; #1;
        check(rd1[0], 1000, "r0 = tid_base+0");
        check(rd1[3], 1003, "r0 = tid_base+3");
        ra1=14; #1; check(rd1[0], 32'h2000, "r14 = SRC");
        ra1=15; #1; check(rd1[0], 32'h6000, "r15 = DST");

        // Writes to special registers must be ignored.
        @(negedge clk); we=1; waddr=0; wmask=4'b1111;
        wdata[0]=32'd999; wdata[1]=32'd999; wdata[2]=32'd999; wdata[3]=32'd999;
        @(negedge clk); we=0;
        ra1=0; #1; check(rd1[0], 1000, "write r0 ignored");

        if (errors == 0) $display("TB_REGFILE PASS");
        else $fatal(1, "TB_REGFILE FAIL: %0d errors", errors);
        $finish;
    end
endmodule
