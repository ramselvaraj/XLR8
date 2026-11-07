`timescale 1ns/1ps
// decoder.sv -- 16-bit GPU instruction decoder.
//
// Field layout (docs/GPU_ISA.md):
//   opcode = instr[15:12]
//   rd     = instr[11:8]
//   rs1    = instr[7:4]
//   rs2    = instr[3:0]
//   imm8   = instr[7:0]
//
// The field slices below are already wired (they are pure bit selection).
//
// legal is high for opcodes 0x0..0xE (Phase 2), else 0.
module decoder(
    input  logic [15:0] instr,
    output logic [3:0]  opcode,
    output logic [3:0]  rd,
    output logic [3:0]  rs1,
    output logic [3:0]  rs2,
    output logic [7:0]  imm8,
    output logic        legal
);
    always_comb begin
        opcode = instr[15:12];
        rd     = instr[11:8];
        rs1    = instr[7:4];
        rs2    = instr[3:0];
        imm8   = instr[7:0];
        legal  = (opcode <= 4'hE);  // Phase 2: 0x0..0xE legal
    end
endmodule
