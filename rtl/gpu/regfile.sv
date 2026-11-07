`timescale 1ns/1ps
// regfile.sv -- per-warp register file: 16 registers x LANES lanes.
//
// Special registers (read-only, per lane):
//   r0  -> tid_base + lane index
//   r14 -> src_addr
//   r15 -> dst_addr
// Writes to r0/r14/r15 are ignored. A lane only commits a write when its bit
// in `write_mask` is set.
//
// TODO(Person B):
//   - storage: logic [31:0] regs [0:15][0:LANES-1]; reset to 0.
//   - write: on posedge, if write_enable and write_mask[l] and
//     write_addr not in {0,14,15}: regs[write_addr][l] <= write_data[l].
//   - read: read_dataN[l] = special-reg mux for addr in {0,14,15},
//     else regs[read_addrN][l].
module regfile #(parameter int LANES = 4)(
    input  logic              clk,
    input  logic              reset,
    input  logic              write_enable,
    input  logic [LANES-1:0]  write_mask,
    input  logic [3:0]        write_addr,
    input  logic [31:0]       write_data [LANES],
    input  logic [3:0]        read_addr1,
    input  logic [3:0]        read_addr2,
    input  logic [3:0]        read_addr3,
    output logic [31:0]       read_data1 [LANES],
    output logic [31:0]       read_data2 [LANES],
    output logic [31:0]       read_data3 [LANES],
    input  logic [31:0]       tid_base,
    input  logic [31:0]       src_addr,
    input  logic [31:0]       dst_addr
);
    logic [31:0] regs [0:15][0:LANES-1];

    function automatic logic [31:0] read_one(input logic [3:0] addr, input int lane);
        case (addr)
            4'd0:    read_one = tid_base + 32'(lane);
            4'd14:   read_one = src_addr;
            4'd15:   read_one = dst_addr;
            default: read_one = regs[addr][lane];
        endcase
    endfunction

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (int r = 0; r < 16; r++)
                for (int l = 0; l < LANES; l++)
                    regs[r][l] <= 32'b0;
        end else if (write_enable && write_addr != 4'd0 &&
                     write_addr != 4'd14 && write_addr != 4'd15) begin
            for (int l = 0; l < LANES; l++)
                if (write_mask[l]) regs[write_addr][l] <= write_data[l];
        end
    end

    always_comb begin
        for (int l = 0; l < LANES; l++) begin
            read_data1[l] = read_one(read_addr1, l);
            read_data2[l] = read_one(read_addr2, l);
            read_data3[l] = read_one(read_addr3, l);
        end
    end
endmodule
