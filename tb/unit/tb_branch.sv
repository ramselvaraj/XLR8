`timescale 1ns/1ps
// tb_branch.sv -- end-to-end test for CMP + uniform BRnzp.
// Run: make branch   (or: make unit TEST=tb_branch)
//
// Runs a counted loop per thread: out[tid] = in[tid] + 5, where the "+5" is
// accumulated one at a time in a CMP/BNE loop. Exercises branch taken/not-taken
// and a backward branch.
module tb_branch;
    localparam int WARPS      = 2;
    localparam int LANES      = 4;
    localparam int PC_W       = 16;
    localparam int ADDR_W     = 8;
    localparam int WORDS      = 1 << ADDR_W;
    localparam int PROG_WORDS = 64;
    localparam int SRC        = 16;
    localparam int DST        = 32;
    localparam int NTHREADS   = WARPS * LANES;   // 8

    logic              clk = 1'b0, reset = 1'b1, start = 1'b0;
    logic [31:0]       thread_count = NTHREADS, src_addr = SRC, dst_addr = DST;
    logic              busy, done;
    logic [PC_W-1:0]   imem_addr;
    logic [15:0]       imem_rdata;
    logic              mem_req, mem_we, mem_ready;
    logic [31:0]       mem_addr, mem_wdata, mem_rdata;

    logic [31:0] data_mem [0:WORDS-1];
    logic [15:0] prog_mem [0:PROG_WORDS-1];
    int errors = 0;
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

    assign imem_rdata = prog_mem[imem_addr[5:0]];
    assign mem_rdata  = data_mem[mem_addr[ADDR_W-1:0]];
    assign mem_ready  = 1'b1;

    always_ff @(posedge clk)
        if (mem_req && mem_we)
            data_mem[mem_addr[ADDR_W-1:0]] <= mem_wdata;

    initial begin
        for (i = 0; i < WORDS; i = i + 1)      data_mem[i] = 32'b0;
        for (i = 0; i < PROG_WORDS; i = i + 1) prog_mem[i] = 16'b0;

        // in[tid] = tid + 1
        for (i = 0; i < NTHREADS; i = i + 1) data_mem[SRC + i] = i + 1;

        // Program: acc = 0; counter = 5; loop { acc++; counter-- } while counter != 0;
        //          out[tid] = in[tid] + acc
        prog_mem[0]  = 16'h31E0; // LDR   r1, r14, r0
        prog_mem[1]  = 16'h1200; // CONST r2, 0      ; acc
        prog_mem[2]  = 16'h1305; // CONST r3, 5      ; counter
        prog_mem[3]  = 16'h1500; // CONST r5, 0      ; zero
        prog_mem[4]  = 16'h1401; // CONST r4, 1      ; one   <-- loop target
        prog_mem[5]  = 16'h0224; // ADD   r2, r2, r4 ; acc++
        prog_mem[6]  = 16'h2334; // SUB   r3, r3, r4 ; counter--
        prog_mem[7]  = 16'hD035; // CMP   r3, r5     ; flags = counter - 0
        prog_mem[8]  = 16'hEBFB; // BNE   loop       ; pc 8 -> 4 (offset -5)
        prog_mem[9]  = 16'h0112; // ADD   r1, r1, r2
        prog_mem[10] = 16'h41F0; // STR   r1, r15, r0
        prog_mem[11] = 16'h5000; // RET

        repeat (2) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done);
        #1;

        for (i = 0; i < NTHREADS; i = i + 1) begin
            if (data_mem[DST + i] !== (i + 1 + 5)) begin
                $display("FAIL thread %0d: out=%0d expected %0d", i, data_mem[DST + i], i + 6);
                errors++;
            end
        end

        if (errors == 0) $display("TB_BRANCH PASS (8 threads, +5 via CMP/BNE loop)");
        else $fatal(1, "TB_BRANCH FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "TB_BRANCH TIMEOUT");
    end
endmodule
