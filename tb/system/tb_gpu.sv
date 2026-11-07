`timescale 1ns/1ps
// tb_gpu.sv -- SIMT GPU integration testbench (Phase 1/2/3).
//
// Owns the memory system (data + program), loads files via plusargs, drives the
// DCR launch, and can run a second program without resetting data memory
// (Phase 3 two-pass: interior blur then border blur). Dumps data memory; the
// Python driver (run_sim.py) checks it against the isa_sim golden model.
//
// Plusargs:
//   +frame=<path>  input framebuffer hex (one 32-bit word per line)
//   +prog=<path>   program hex, pass 1 (one 16-bit instruction per line)
//   +count=<n>     pass 1 thread count
//   +prog2=<path>  program hex, pass 2 (optional)
//   +count2=<n>    pass 2 thread count
//   +out=<path>    where to dump the resulting data memory
//   +src=<n>       source framebuffer word address
//   +dst=<n>       destination framebuffer word address
//   +width=<n> +height=<n>   image dims (trace header)
//   +pass1=<s> +pass2=<s>    pass names for the trace
//   +trace=<path>  write a deterministic text trace (optional)
module tb_gpu;
    parameter int WARPS      = 2;
    parameter int LANES      = 4;
    parameter int PC_W       = 16;
    parameter int ADDR_W     = 15;              // 32768 data words
    parameter int WORDS      = 1 << ADDR_W;
    parameter int PROG_WORDS = 1024;
    localparam int TB        = WARPS * LANES;   // physical threads per wave

    logic              clk = 1'b0;
    logic              reset = 1'b1;
    logic              start = 1'b0;
    logic [31:0]       thread_count = 32'b0;
    logic [31:0]       src_addr = 32'b0, dst_addr = 32'b0;
    logic              busy, done;
    logic [PC_W-1:0]   imem_addr;
    logic [15:0]       imem_rdata;
    logic              mem_req, mem_we, mem_ready;
    logic [31:0]       mem_addr, mem_wdata, mem_rdata;

    logic [31:0] data_mem [0:WORDS-1];
    logic [15:0] prog_mem [0:PROG_WORDS-1];

    wire [WARPS-1:0] gnt = dut.warp_grant;      // hierarchical read for trace

    string frame_path = "frame.hex", prog_path = "prog.hex", out_path = "out.hex";
    string prog2_path = "", trace_path = "";
    string pass1 = "kernel", pass2 = "border";
    int unsigned count = WORDS, src = 0, dst = 0, count2 = 0;
    int unsigned width = 0, height = 0;
    bit have_pass2, trace_on;
    int tfd, gw;
    int reads = 0, writes = 0, grants0 = 0, grants1 = 0;
    int unsigned cycles;
    integer i;

    simt_gpu #(.WARPS(WARPS), .LANES(LANES), .PC_W(PC_W)) dut(
        .clk(clk), .reset(reset), .start(start),
        .thread_count(thread_count), .src_addr(src_addr), .dst_addr(dst_addr),
        .busy(busy), .done(done),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .mem_req(mem_req), .mem_we(mem_we),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    always #5 clk = ~clk;
    assign imem_rdata = prog_mem[imem_addr[9:0]];
    assign mem_rdata = data_mem[mem_addr[ADDR_W-1:0]];
    assign mem_ready = 1'b1;

    always_comb gw = gnt[0] ? 0 : (gnt[1] ? 1 : -1);

    always_ff @(posedge clk) begin
        if (mem_req && mem_we)
            data_mem[mem_addr[ADDR_W-1:0]] <= mem_wdata;
    end

    always_ff @(posedge clk) begin
        if (reset) cycles <= 0;
        else       cycles <= cycles + 1;
    end

    // Trace + counters.
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (mem_req) begin
                if (mem_we) begin
                    writes <= writes + 1;
                    if (trace_on)
                        $fdisplay(tfd, "BUS cycle=%0d warp=%0d op=write addr=%0d data=%08x",
                                  cycles, gw, mem_addr, mem_wdata);
                end else begin
                    reads <= reads + 1;
                    if (trace_on)
                        $fdisplay(tfd, "BUS cycle=%0d warp=%0d op=read addr=%0d",
                                  cycles, gw, mem_addr);
                end
            end
            if (|gnt) begin
                if (gnt[0]) grants0 <= grants0 + 1;
                else        grants1 <= grants1 + 1;
                if (trace_on)
                    $fdisplay(tfd, "GRANT cycle=%0d warp=%0d pc=%0d",
                              cycles, gw, imem_addr);
            end
        end
    end

    task automatic run_pass(input string pf, input int unsigned nt, input int pno);
        for (i = 0; i < PROG_WORDS; i = i + 1) prog_mem[i] = 16'b0;
        $readmemh(pf, prog_mem);
        thread_count = nt;
        if (trace_on)
            $fdisplay(tfd, "PASS_START cycle=%0d pass=%0s threads=%0d waves=%0d",
                      cycles, pno == 1 ? pass1 : pass2, nt, (nt + TB - 1) / TB);
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        wait (done);
        @(posedge clk);
        if (trace_on)
            $fdisplay(tfd, "PASS_DONE cycle=%0d pass=%0s",
                      cycles, pno == 1 ? pass1 : pass2);
        repeat (2) @(posedge clk);
    endtask

    initial begin
        for (i = 0; i < WORDS; i = i + 1)      data_mem[i] = 32'b0;
        for (i = 0; i < PROG_WORDS; i = i + 1) prog_mem[i] = 16'b0;

        void'($value$plusargs("frame=%s", frame_path));
        void'($value$plusargs("prog=%s",  prog_path));
        void'($value$plusargs("prog2=%s", prog2_path));
        void'($value$plusargs("out=%s",   out_path));
        void'($value$plusargs("trace=%s", trace_path));
        void'($value$plusargs("pass1=%s", pass1));
        void'($value$plusargs("pass2=%s", pass2));
        if (!$value$plusargs("count=%d",  count))  count  = WORDS;
        if (!$value$plusargs("count2=%d", count2)) count2 = 0;
        if (!$value$plusargs("src=%d",    src))    src    = 0;
        if (!$value$plusargs("dst=%d",    dst))    dst    = 0;
        if (!$value$plusargs("width=%d",  width))  width  = 0;
        if (!$value$plusargs("height=%d", height)) height = 0;

        have_pass2 = (prog2_path != "");
        trace_on   = (trace_path != "");
        if (trace_on) begin
            tfd = $fopen(trace_path, "w");
            $fdisplay(tfd, "CONFIG width=%0d height=%0d src=%0d dst=%0d",
                      width, height, src, dst);
        end

        $readmemh(frame_path, data_mem, src);   // whole frame, from src
        $display("tb_gpu: frame=%0s prog=%0s prog2=%0s out=%0s count=%0d count2=%0d",
                 frame_path, prog_path, prog2_path, out_path, count, count2);

        src_addr = src;
        dst_addr = dst;

        repeat (2) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        run_pass(prog_path, count, 1);
        if (have_pass2) run_pass(prog2_path, count2, 2);

        repeat (2) @(posedge clk);
        $writememh(out_path, data_mem);
        if (trace_on) begin
            $fdisplay(tfd, "SUMMARY cycles=%0d reads=%0d writes=%0d grants_warp0=%0d grants_warp1=%0d",
                      cycles, reads, writes, grants0, grants1);
            $fclose(tfd);
        end
        $display("tb_gpu: wrote %0s after %0d cycles", out_path, cycles);
        $finish;
    end

    // Watchdog: fail loudly instead of hanging if the GPU never finishes.
    initial begin
        repeat (50000000) @(posedge clk);
        $fatal(1, "tb_gpu: TIMEOUT - GPU never asserted done");
    end
endmodule
