`timescale 1ns/1ps
// xlr8_perf.sv -- per-job performance counters.
//
//   cycles : clocks from the cycle after `start` through the cycle `done` is high
//            (equals done_cycle - start_cycle)
//   xacts  : bus transactions completed (mem_req && mem_ready)
//   stalls : clocks with mem_req && !mem_ready
// `clear` zeroes everything and stops counting. Values hold after `done` until the next clear.
module xlr8_perf(
    input  logic        clk,
    input  logic        rst,
    input  logic        clear,
    input  logic        start,
    input  logic        done,
    input  logic        mem_req,
    input  logic        mem_ready,
    output logic [31:0] cycles,
    output logic [31:0] xacts,
    output logic [31:0] stalls
);
    logic running;

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            running <= 1'b0;
            cycles  <= 32'b0;
            xacts   <= 32'b0;
            stalls  <= 32'b0;
        end else begin
            if (start) running <= 1'b1;
            if (running) begin
                cycles <= cycles + 32'd1;
                if (mem_req && mem_ready)  xacts  <= xacts  + 32'd1;
                if (mem_req && !mem_ready) stalls <= stalls + 32'd1;
                if (done) running <= 1'b0;
            end
        end
    end
endmodule
