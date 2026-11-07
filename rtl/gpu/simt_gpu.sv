`timescale 1ns/1ps
// simt_gpu.sv -- Phase 1 SIMT GPU top level.
//
// Wires the DCR, dispatcher, warp scheduler and WARPS x LANES SIMT warps to a
// combinational instruction-memory port and the shared data bus
// (docs/BUS_PROTOCOL.md).
//
// The wiring here is provided scaffolding. Behaviour lives in the submodules
// (see the TODO blocks in dcr/dispatcher/scheduler/warp/mem_unit/regfile/alu/
// decoder).
module simt_gpu #(
    parameter int WARPS = 2,
    parameter int LANES = 4,
    parameter int PC_W  = 16,
    parameter bit LOCK_MEMORY_OWNER = 0
)(
    input  logic            clk,
    input  logic            reset,
    input  logic            start,
    input  logic [31:0]     thread_count,
    input  logic [31:0]     src_addr,
    input  logic [31:0]     dst_addr,
    output logic            busy,
    output logic            done,
    // Instruction memory (combinational read)
    output logic [PC_W-1:0] imem_addr,
    input  logic [15:0]     imem_rdata,
    // Data bus
    output logic            mem_req,
    output logic            mem_we,
    output logic [31:0]     mem_addr,
    output logic [31:0]     mem_wdata,
    input  logic [31:0]     mem_rdata,
    input  logic            mem_ready
);
    logic [WARPS-1:0]            warp_start;
    logic [WARPS-1:0][31:0]      warp_tid_base;
    logic [WARPS-1:0][LANES-1:0] warp_lane_mask;
    logic [WARPS-1:0]            warp_ready;
    logic [WARPS-1:0]            warp_grant;
    logic [WARPS-1:0]            scheduled_grant, locked_grant;
    logic memory_locked;
    logic [WARPS-1:0]            warp_halted;
    logic [WARPS-1:0]            w_mem_req;
    logic [WARPS-1:0]            w_mem_we;
    logic [WARPS-1:0][31:0]      w_mem_addr;
    logic [WARPS-1:0][31:0]      w_mem_wdata;
    logic [WARPS-1:0][PC_W-1:0]  w_imem_addr;
    logic [31:0]                 src_q, dst_q, threads_q, block_base;
    logic                        all_halted, launch;

    dcr #(.TB(WARPS*LANES)) u_dcr(
        .clk(clk), .reset(reset), .start(start),
        .thread_count(thread_count), .src_addr(src_addr), .dst_addr(dst_addr),
        .all_halted(all_halted),
        .busy(busy), .done(done), .launch(launch), .block_base(block_base),
        .thread_count_q(threads_q), .src_addr_q(src_q), .dst_addr_q(dst_q)
    );

    dispatcher #(.WARPS(WARPS), .LANES(LANES)) u_disp(
        .start(launch), .thread_count(threads_q), .block_base(block_base),
        .warp_start(warp_start),
        .warp_tid_base(warp_tid_base),
        .warp_lane_mask(warp_lane_mask)
    );

    scheduler #(.WARPS(WARPS)) u_sched(
        .clk(clk), .reset(reset),
        .ready(warp_ready), .grant(scheduled_grant)
    );

    assign warp_grant = LOCK_MEMORY_OWNER && memory_locked ? locked_grant : scheduled_grant;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin memory_locked <= 0; locked_grant <= 0; end
        else if (LOCK_MEMORY_OWNER) begin
            if (!memory_locked && mem_req && !mem_ready) begin
                memory_locked <= 1;
                locked_grant <= scheduled_grant;
            end else if (memory_locked && mem_req && mem_ready) memory_locked <= 0;
        end
    end

    generate
        for (genvar w = 0; w < WARPS; w++) begin : g_warp
            warp #(.LANES(LANES), .PC_W(PC_W)) u_warp(
                .clk(clk), .reset(reset),
                .start_warp(warp_start[w]),
                .tid_base(warp_tid_base[w]),
                .src_addr(src_q), .dst_addr(dst_q),
                .lane_mask(warp_lane_mask[w]),
                .grant(warp_grant[w]),
                .ready(warp_ready[w]),
                .imem_addr(w_imem_addr[w]),
                .mem_req(w_mem_req[w]), .mem_we(w_mem_we[w]),
                .mem_addr(w_mem_addr[w]), .mem_wdata(w_mem_wdata[w]),
                .mem_rdata(mem_rdata), .mem_ready(mem_ready),
                .imem_rdata(imem_rdata),
                .halted(warp_halted[w])
            );
        end
    endgenerate

    assign all_halted = &warp_halted;

    always_comb begin
        imem_addr = '0;
        mem_req   = 1'b0;
        mem_we    = 1'b0;
        mem_addr  = 32'b0;
        mem_wdata = 32'b0;
        for (int w = 0; w < WARPS; w++) begin
            if (warp_grant[w]) begin
                imem_addr = w_imem_addr[w];
                mem_req   = w_mem_req[w];
                mem_we    = w_mem_we[w];
                mem_addr  = w_mem_addr[w];
                mem_wdata = w_mem_wdata[w];
            end
        end
    end
endmodule
