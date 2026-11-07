`timescale 1ns/1ps
// seq_div.sv -- 32-bit unsigned restoring divider, one quotient bit per clock (32 cycles).
//
// Same result as the combinational `a / b` in alu.sv (b == 0 gives 0), but with a short
// critical path: one 32-bit compare/subtract per cycle. Used when FAST_DIV = 0 so the design
// meets timing on an FPGA (the combinational divider is a roughly 100 ns carry chain).
//
//   start (1 cycle, while idle) latches a and b
//   done  (1 cycle) pulses with `result` valid, 32 cycles after start (1 cycle if b == 0)
module seq_div(
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        done,
    output logic [31:0] result
);
    logic        busy;
    logic [5:0]  cnt;
    logic [31:0] quo, rem, divisor;

    // The shifted remainder needs 33 bits: with a divisor above 2^31 the remainder can reach 2^32-1.
    logic [32:0] rem_sh;
    logic [33:0] diff;
    assign rem_sh = {rem, quo[31]};
    assign diff   = {1'b0, rem_sh} - {2'b00, divisor};
    logic unused;
    assign unused = &{1'b0, diff[32]};       // bit 32 is only a carry-through of the subtraction

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            busy    <= 1'b0;
            done    <= 1'b0;
            cnt     <= 6'd0;
            quo     <= 32'b0;
            rem     <= 32'b0;
            divisor <= 32'b0;
            result  <= 32'b0;
        end else begin
            done <= 1'b0;
            if (start) begin
                divisor <= b;
                quo     <= a;
                rem     <= 32'b0;
                cnt     <= 6'd32;
                busy    <= (b != 32'b0);
                if (b == 32'b0) begin       // divide by zero: result 0
                    result <= 32'b0;
                    done   <= 1'b1;
                end
            end else if (busy) begin
                if (diff[33]) begin         // rem_sh < divisor
                    rem <= rem_sh[31:0];
                    quo <= {quo[30:0], 1'b0};
                end else begin
                    rem <= diff[31:0];
                    quo <= {quo[30:0], 1'b1};
                end
                cnt <= cnt - 6'd1;
                if (cnt == 6'd1) begin
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    result <= diff[33] ? {quo[30:0], 1'b0} : {quo[30:0], 1'b1};
                end
            end
        end
    end
endmodule
