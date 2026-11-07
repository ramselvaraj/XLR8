`timescale 1ns/1ps
// tb_decoder.sv -- unit test for decoder.sv. Run: make unit TEST=tb_decoder
module tb_decoder;
    logic [15:0] instr;
    logic [3:0]  opcode, rd, rs1, rs2;
    logic [7:0]  imm8;
    logic        legal;
    int errors = 0;

    decoder dut(.instr(instr), .opcode(opcode), .rd(rd), .rs1(rs1),
                .rs2(rs2), .imm8(imm8), .legal(legal));

    task automatic expect_bits(input [3:0] e_op, e_rd, e_rs1, e_rs2, input [7:0] e_imm);
        #1;
        if (opcode !== e_op || rd !== e_rd || rs1 !== e_rs1 || rs2 !== e_rs2 || imm8 !== e_imm) begin
            $display("FAIL fields: got op=%h rd=%h rs1=%h rs2=%h imm=%h",
                     opcode, rd, rs1, rs2, imm8);
            errors++;
        end else $display("PASS fields op=%h", opcode);
    endtask

    task automatic expect_legal(input logic e);
        #1;
        if (legal !== e) begin
            $display("FAIL legal: expected %0b got %0b", e, legal);
            errors++;
        end else $display("PASS legal=%0b", e);
    endtask

    initial begin
        // ADD r3, r1, r2  -> 0x0_3_1_2
        instr = 16'h0312; expect_bits(4'h0, 4'h3, 4'h1, 4'h2, 8'h12); expect_legal(1'b1);
        // CONST r5, 0x7F -> 0x1_5_7F
        instr = 16'h157F; expect_bits(4'h1, 4'h5, 4'h7, 4'hF, 8'h7F); expect_legal(1'b1);
        // SUB r2, r3, r4 -> 0x2_2_3_4
        instr = 16'h2234; expect_bits(4'h2, 4'h2, 4'h3, 4'h4, 8'h34); expect_legal(1'b1);
        // LDR r2, r14, r0 -> 0x3_2_E_0
        instr = 16'h32E0; expect_bits(4'h3, 4'h2, 4'hE, 4'h0, 8'hE0); expect_legal(1'b1);
        // STR r3, r15, r0 -> 0x4_3_F_0
        instr = 16'h43F0; expect_bits(4'h4, 4'h3, 4'hF, 4'h0, 8'hF0); expect_legal(1'b1);
        // RET -> 0x5000
        instr = 16'h5000; expect_bits(4'h5, 4'h0, 4'h0, 4'h0, 8'h00); expect_legal(1'b1);
        // MUL r3, r1, r2 -> 0x6_3_1_2
        instr = 16'h6312; expect_bits(4'h6, 4'h3, 4'h1, 4'h2, 8'h12); expect_legal(1'b1);
        // SRL r4, r3, r7 -> 0xC_4_3_7
        instr = 16'hC437; expect_bits(4'hC, 4'h4, 4'h3, 4'h7, 8'h37); expect_legal(1'b1);
        // CMP r1, r2 -> 0xD_0_1_2
        instr = 16'hD012; expect_bits(4'hD, 4'h0, 4'h1, 4'h2, 8'h12); expect_legal(1'b1);
        // BRnzp (opcode 0xE) is legal
        instr = 16'hE0FF; #1; expect_legal(1'b1);
        // illegal 0xF000
        instr = 16'hF000; #1; expect_legal(1'b0);
        if (errors == 0) $display("TB_DECODER PASS");
        else $fatal(1, "TB_DECODER FAIL: %0d errors", errors);
        $finish;
    end
endmodule
