`timescale 1ns/1ps
// tb_alu.sv -- unit test for alu.sv. Run: make unit TEST=tb_alu
module tb_alu;
    logic [31:0] a, b, result;
    logic [3:0]  op;
    int errors = 0;

    alu dut(.a(a), .b(b), .op(op), .result(result));

    task automatic check(input [31:0] exp, input string name);
        if (result !== exp) begin
            $display("FAIL %0s: got %0d (%h) expected %0d (%h)", name, result, result, exp, exp);
            errors++;
        end else $display("PASS %0s", name);
    endtask

    initial begin
        // Phase 1
        op = 4'd0; a = 32'd10; b = 32'd3; #1; check(32'd13, "ADD basic");
        op = 4'd0; a = 32'd0;  b = 32'd0; #1; check(32'd0,  "ADD zero");
        op = 4'd1; a = 32'd10; b = 32'd3; #1; check(32'd7,  "SUB basic");
        op = 4'd0; a = 32'hFFFFFFFF; b = 32'd1; #1; check(32'd0, "ADD overflow wraps");

        // Phase 2
        op = 4'd2; a = 32'd6;  b = 32'd7; #1; check(32'd42, "MUL basic");
        op = 4'd3; a = 32'd20; b = 32'd3; #1; check(32'd6,  "DIV truncates");
        op = 4'd3; a = 32'd20; b = 32'd0; #1; check(32'd0,  "DIV by zero -> 0");
        op = 4'd4; a = 32'hF0; b = 32'h0F; #1; check(32'h00, "AND");
        op = 4'd5; a = 32'hF0; b = 32'h0F; #1; check(32'hFF, "OR");
        op = 4'd6; a = 32'hFF; b = 32'h0F; #1; check(32'hF0, "XOR");
        op = 4'd7; a = 32'd1;  b = 32'd16; #1; check(32'h00010000, "SLL by 16");
        op = 4'd8; a = 32'h00010000; b = 32'd16; #1; check(32'd1, "SRL by 16");

        if (errors == 0) $display("TB_ALU PASS");
        else $fatal(1, "TB_ALU FAIL: %0d errors", errors);
        $finish;
    end
endmodule
