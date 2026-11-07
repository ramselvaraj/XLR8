`timescale 1ns/1ps
// dcr.sv -- Device Control Registers + wave (thread-block) launch sequencer.
//
// The hardware has WARPS*LANES physical threads (``TB``). A launch with
// thread_count > TB is processed as a sequence of waves: each wave runs the
// kernel for TB threads, then the base advances by TB and the warps restart,
// until every thread has been covered. This is the GPU "grid of blocks" idea.
//
//   D_IDLE --start--> D_LAUNCH --(1 cycle, launch=1)--> D_RUN
//   D_RUN --all_halted--> { more threads? D_LAUNCH (base += TB) : D_DONE }
//   D_DONE --(1 cycle, done=1)--> D_IDLE
//
// All registers are latched on `start`; `busy` is high for the whole launch.
module dcr #(parameter int TB = 8)(
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] thread_count,
    input  logic [31:0] src_addr,
    input  logic [31:0] dst_addr,
    input  logic        all_halted,
    output logic        busy,
    output logic        done,
    output logic        launch,       // one-cycle pulse to (re)start the warps
    output logic [31:0] block_base,   // global tid of this wave's first thread
    output logic [31:0] thread_count_q,
    output logic [31:0] src_addr_q,
    output logic [31:0] dst_addr_q
);
    typedef enum logic [1:0] {D_IDLE, D_LAUNCH, D_RUN, D_DONE} state_t;
    state_t state;

    assign busy   = (state == D_LAUNCH) || (state == D_RUN);
    assign done   = (state == D_DONE);
    assign launch = (state == D_LAUNCH);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= D_IDLE;
            block_base     <= 32'b0;
            thread_count_q <= 32'b0;
            src_addr_q     <= 32'b0;
            dst_addr_q     <= 32'b0;
        end else begin
            case (state)
                D_IDLE: if (start) begin
                    thread_count_q <= thread_count;
                    src_addr_q     <= src_addr;
                    dst_addr_q     <= dst_addr;
                    block_base     <= 32'b0;
                    state          <= D_LAUNCH;
                end
                D_LAUNCH: state <= D_RUN;
                D_RUN: if (all_halted) begin
                    if ((block_base + TB) < thread_count_q) begin
                        block_base <= block_base + TB;
                        state      <= D_LAUNCH;
                    end else begin
                        state <= D_DONE;
                    end
                end
                D_DONE: state <= D_IDLE;
                default: state <= D_IDLE;
            endcase
        end
    end
endmodule
