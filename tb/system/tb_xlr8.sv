`timescale 1ns/1ps
// tb_xlr8.sv -- system testbench for xlr8_top: AXI4-Lite master BFM, AXI3 memory model with
// random stalls, and the Phase 2 test list.
//
// Plusargs:
//   +test=<name|all>   regs prog job busy raw oor axierr b2b reset irq   (default all)
//   +stall=<pct>       handshake stall percentage on every AXI channel (default 0)
//   +prog=<hex>        brighten program hex (default build/prog/brighten.hex)
//   Ball mode (replaces the tests):
//   +ballprog=<hex> +ballparams=<hex, 5 words per frame> +frames=<n> +ballout=<hex>
//   +verilator+seed+<n>   random seed
module tb_xlr8;
    localparam logic [31:0] MEM_BASE = 32'h1000_0000;
    localparam int          WORDS    = 32768;
    localparam logic [31:0] MEM_LIM  = WORDS * 4;
    localparam int          SRC      = 32'h2000;
    localparam int          DST      = 32'h6000;
    localparam int          SRC2     = 32'h3000;
    localparam int          DST2     = 32'h7000;

    // register byte offsets
    localparam logic [12:0] A_CTRL = 'h00, A_STATUS = 'h04, A_THREADS = 'h08, A_SRC = 'h0C,
                            A_DST = 'h10, A_PROG = 'h14, A_MBASE = 'h18, A_MLIM = 'h1C,
                            A_IRQ = 'h20, A_CYC = 'h24, A_XACT = 'h28, A_STALL = 'h2C,
                            A_ERRA = 'h30, A_ID = 'h34, A_VER = 'h38, A_ARG0 = 'h3C, A_ARG1 = 'h40, A_ARG2 = 'h44, A_ARG3 = 'h48, A_ARG4 = 'h4C, A_ARG5 = 'h50,
                            A_WIN = 'h1000;

    logic clk = 1'b0;
    logic aresetn = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------ DUT and memory
    logic [12:0] awaddr = '0, araddr = '0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = '0;
    logic [3:0]  wstrb = '0;
    wire         awready, wready, bvalid, arready, rvalid;
    wire  [1:0]  bresp, rresp;
    wire  [31:0] rdata;

    wire [5:0]  m_awid, m_wid, m_bid, m_arid, m_rid;
    wire [31:0] m_awaddr, m_wdata, m_araddr, m_rdata;
    wire [3:0]  m_awlen, m_awcache, m_awqos, m_wstrb, m_arlen, m_arcache, m_arqos;
    wire [2:0]  m_awsize, m_awprot, m_arsize, m_arprot;
    wire [1:0]  m_awburst, m_awlock, m_bresp, m_arburst, m_arlock, m_rresp;
    wire        m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
    wire        m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
    wire        irq;

    logic [7:0]  stall_pct = 8'd0;
    logic        err_en = 1'b0;
    logic [31:0] err_word = '0;
    int unsigned n_ar, n_aw, n_perr;
    logic [31:0] last_ar_word, last_aw_word;
    logic        mem_rst_n = 1'b0;

    xlr8_top dut (
        .aclk(clk), .aresetn(aresetn),
        .s_axi_ctrl_awaddr(awaddr), .s_axi_ctrl_awvalid(awvalid), .s_axi_ctrl_awready(awready),
        .s_axi_ctrl_wdata(wdata), .s_axi_ctrl_wstrb(wstrb), .s_axi_ctrl_wvalid(wvalid),
        .s_axi_ctrl_wready(wready), .s_axi_ctrl_bresp(bresp), .s_axi_ctrl_bvalid(bvalid),
        .s_axi_ctrl_bready(bready), .s_axi_ctrl_araddr(araddr), .s_axi_ctrl_arvalid(arvalid),
        .s_axi_ctrl_arready(arready), .s_axi_ctrl_rdata(rdata), .s_axi_ctrl_rresp(rresp),
        .s_axi_ctrl_rvalid(rvalid), .s_axi_ctrl_rready(rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock), .m_axi_awcache(m_awcache),
        .m_axi_awprot(m_awprot), .m_axi_awqos(m_awqos), .m_axi_awvalid(m_awvalid),
        .m_axi_awready(m_awready), .m_axi_wid(m_wid), .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb),
        .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock), .m_axi_arcache(m_arcache),
        .m_axi_arprot(m_arprot), .m_axi_arqos(m_arqos), .m_axi_arvalid(m_arvalid),
        .m_axi_arready(m_arready), .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
        .irq(irq)
    );

    axi_mem_model #(.WORDS(WORDS), .BASE(MEM_BASE)) u_mem (
        .clk(clk), .rst_n(mem_rst_n), .stall_pct(stall_pct), .err_en(err_en), .err_word(err_word),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awvalid(m_awvalid),
        .awready(m_awready), .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid),
        .wready(m_wready), .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arvalid(m_arvalid),
        .arready(m_arready), .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
        .rvalid(m_rvalid), .rready(m_rready),
        .n_ar(n_ar), .n_aw(n_aw), .n_proto_err(n_perr),
        .last_ar_word(last_ar_word), .last_aw_word(last_aw_word)
    );

    // ------------------------------------------------------------ bookkeeping
    int errors = 0;
    int unsigned cyc = 0;
    always_ff @(posedge clk) cyc <= cyc + 1;

    // independent job-cycle measurement (start pulse cycle to done pulse cycle)
    int unsigned start_cyc = 0, done_cyc = 0;
    bit          start_seen = 0;
    always_ff @(posedge clk) begin
        if (dut.gpu_start) begin start_cyc <= cyc; start_seen <= 1; end
        if (dut.job_complete) done_cyc <= cyc;     // DONE set: GPU finished and posted writes drained
    end

    // irq must never be high before STATUS.DONE is observable: track the first irq rise vs done flag
    int irq_early = 0;
    always_ff @(posedge clk) if (irq && !dut.u_regs.done_f && !dut.u_regs.error_f) irq_early <= irq_early + 1;

    // DONE (and so the interrupt) must not rise while a write is still outstanding in memory:
    // an interrupt-driven driver reads the results the moment it fires.
    int done_early = 0;
    logic done_f_q = 1'b0;
    always_ff @(posedge clk) begin
        done_f_q <= dut.u_regs.done_f;
        if (dut.u_regs.done_f && !done_f_q && (u_mem.wr_out != 0 || u_mem.bvalid || u_mem.awq.size() != 0))
            done_early <= done_early + 1;
    end

    // GPU bus protocol: request held stable until ready
    logic        p_req, p_we; logic [31:0] p_addr, p_wdata;
    int          bus_viol = 0;
    always_ff @(posedge clk) begin
        if (p_req && !dut.mem_ready && aresetn && !dut.u_regs.soft_active) begin
            if (!(dut.mem_req && dut.mem_we == p_we && dut.mem_addr == p_addr &&
                  (!p_we || dut.mem_wdata == p_wdata))) bus_viol <= bus_viol + 1;
        end
        p_req <= dut.mem_req && !dut.mem_ready; p_we <= dut.mem_we;
        p_addr <= dut.mem_addr; p_wdata <= dut.mem_wdata;
    end

    // independent monitor: first completed GPU access outside the window, in time order
    logic [31:0] mon_limit = '0, mon_first = '0;
    bit          mon_have = 0;
    always_ff @(posedge clk) begin
        if (dut.mem_req && dut.mem_ready && !mon_have &&
            ({2'b00, dut.mem_addr, 2'b00} + 34'd4 > {2'b00, mon_limit})) begin
            mon_have <= 1'b1; mon_first <= dut.mem_addr;
        end
    end

    task automatic fail(input string msg);
        errors++;
        $display("%0t FAIL: %s", $time, msg);
    endtask

    task automatic expect32(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) fail($sformatf("%s: got %08x expected %08x", what, got, exp));
    endtask

    // ------------------------------------------------------------ AXI4-Lite master BFM
    task automatic rnd_delay();
        repeat ($urandom_range(0, 99) < stall_pct ? $urandom_range(1, 4) : 0) @(posedge clk);
    endtask

    task automatic axil_write(input logic [12:0] a, input logic [31:0] d, input logic [3:0] s,
                              output logic [1:0] resp);
        int mode;
        mode = $urandom_range(0, 2);     // 0: AW first, 1: W first, 2: together
        fork
            begin
                if (mode == 1) repeat ($urandom_range(1, 3)) @(posedge clk);
                rnd_delay();
                awaddr <= a; awvalid <= 1'b1;
                @(posedge clk);
                while (!awready) @(posedge clk);
                awvalid <= 1'b0;
            end
            begin
                if (mode == 0) repeat ($urandom_range(1, 3)) @(posedge clk);
                rnd_delay();
                wdata <= d; wstrb <= s; wvalid <= 1'b1;
                @(posedge clk);
                while (!wready) @(posedge clk);
                wvalid <= 1'b0;
            end
        join
        rnd_delay();
        bready <= 1'b1;
        @(posedge clk);
        while (!bvalid) @(posedge clk);
        resp = bresp;
        bready <= 1'b0;
    endtask

    task automatic axil_read(input logic [12:0] a, output logic [31:0] d, output logic [1:0] resp);
        rnd_delay();
        araddr <= a; arvalid <= 1'b1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        arvalid <= 1'b0;
        rnd_delay();
        rready <= 1'b1;
        @(posedge clk);
        while (!rvalid) @(posedge clk);
        d = rdata; resp = rresp;
        rready <= 1'b0;
    endtask

    logic [1:0] resp_q;
    task automatic wr(input logic [12:0] a, input logic [31:0] d);
        axil_write(a, d, 4'hF, resp_q);
        if (resp_q != 2'b00) fail($sformatf("write %04x unexpected resp %0d", a, resp_q));
    endtask

    task automatic wr_expect_err(input logic [12:0] a, input logic [31:0] d, input string what);
        axil_write(a, d, 4'hF, resp_q);
        if (resp_q != 2'b10) fail($sformatf("%s: expected SLVERR, got %0d", what, resp_q));
    endtask

    logic [31:0] rd_q;
    task automatic rd(input logic [12:0] a, output logic [31:0] d);
        axil_read(a, d, resp_q);
        if (resp_q != 2'b00) fail($sformatf("read %04x unexpected resp %0d", a, resp_q));
    endtask

    task automatic rd_expect_err(input logic [12:0] a, input string what);
        axil_read(a, rd_q, resp_q);
        if (resp_q != 2'b10) fail($sformatf("%s: expected SLVERR on read, got %0d", what, resp_q));
    endtask

    task automatic reg_expect(input string what, input logic [12:0] a, input logic [31:0] exp);
        rd(a, rd_q);
        expect32(what, rd_q, exp);
    endtask

    // ------------------------------------------------------------ helpers
    task automatic do_reset(input int cycles = 6);
        aresetn <= 1'b0; mem_rst_n <= 1'b0;
        awvalid <= 0; wvalid <= 0; bready <= 0; arvalid <= 0; rready <= 0;
        repeat (cycles) @(posedge clk);
        aresetn <= 1'b1; mem_rst_n <= 1'b1;
        repeat (3) @(posedge clk);
    endtask

    task automatic configure(input int unsigned threads, input int unsigned src, input int unsigned dst,
                             input logic [31:0] base = MEM_BASE, input logic [31:0] lim = MEM_LIM);
        wr(A_THREADS, threads); wr(A_SRC, src); wr(A_DST, dst);
        wr(A_MBASE, base); wr(A_MLIM, lim); wr(A_PROG, 0);
        mon_limit = lim; mon_have = 1'b0;
    endtask

    task automatic wait_done(input int unsigned max_polls = 200000);
        logic [31:0] st;
        int unsigned n = 0;
        do begin
            rd(A_STATUS, st);
            n++;
            if (n > max_polls) begin fail("timeout waiting for DONE"); return; end
        end while (st[0]);
    endtask

    logic [15:0] prog_img [1024];
    int          prog_len;

    task automatic read_prog(input string path);
        for (int i = 0; i < 1024; i++) prog_img[i] = 16'h0;
        $readmemh(path, prog_img);
        prog_len = 0;
        for (int i = 0; i < 1024; i++) if (prog_img[i] != 16'h0) prog_len = i + 1;
        if (prog_len == 0) fail($sformatf("program %s empty or missing", path));
    endtask

    task automatic load_prog();
        for (int w = 0; w < (prog_len + 1) / 2; w++)
            wr(A_WIN + 13'(w * 4), {prog_img[2*w+1], prog_img[2*w]});
    endtask

    logic [31:0] refmem [WORDS];
    task automatic fill_pattern(input int unsigned src, input int n, input int unsigned seed);
        for (int i = 0; i < n; i++) u_mem.mem[src + i] = (i * 32'h9E3779B1) ^ seed ^ (i << 7);
    endtask

    task automatic snapshot();
        for (int i = 0; i < WORDS; i++) refmem[i] = u_mem.mem[i];
    endtask

    // brighten: dst[tid] = src[tid] + 0x20 for tid < n; everything else unchanged
    task automatic check_brighten(input int unsigned src, input int unsigned dst, input int n,
                                  input string tag);
        int bad = 0;
        for (int i = 0; i < WORDS; i++) begin
            logic [31:0] exp;
            exp = refmem[i];
            if (i >= dst && i < dst + n) exp = refmem[src + (i - dst)] + 32'h20;
            if (u_mem.mem[i] !== exp) begin
                if (bad < 3) fail($sformatf("%s: mem[%0d]=%08x expected %08x", tag, i, u_mem.mem[i], exp));
                bad++;
            end
        end
    endtask

    // check only dst[0..n) == src[i] + 0x20 (src must be unchanged by whatever ran before)
    task automatic check_region(input int unsigned src, input int unsigned dst, input int n, input string tag);
        int bad = 0;
        for (int i = 0; i < n; i++) begin
            logic [31:0] exp;
            exp = u_mem.mem[src + i] + 32'h20;
            if (u_mem.mem[dst + i] !== exp) begin
                if (bad < 3) fail($sformatf("%s: mem[%0d]=%08x expected %08x", tag, dst + i, u_mem.mem[dst + i], exp));
                bad++;
            end
        end
    endtask

    task automatic launch();
        wr(A_CTRL, 32'h1);
    endtask

    task automatic launch_and_wait();
        launch();
        wait_done();
    endtask

    // ------------------------------------------------------------ tests
    task automatic t_regs();
        logic [31:0] v;
        $display("test regs");
        reg_expect("ID", A_ID, 32'h584C5238);
        reg_expect("VERSION", A_VER, 32'h0000_0200);
        reg_expect("STATUS idle", A_STATUS, 32'h0);
        foreach_reg: begin
            logic [12:0] regs [6] = '{A_THREADS, A_SRC, A_DST, A_PROG, A_MBASE, A_MLIM};
            for (int r = 0; r < 6; r++) begin
                wr(regs[r], 32'hA5A5_5A5A);
                reg_expect("readback", regs[r], 32'hA5A5_5A5A);
                axil_write(regs[r], 32'h0000_00FF, 4'b0001, resp_q);
                reg_expect("strobe 0001", regs[r], 32'hA5A5_5AFF);
                axil_write(regs[r], 32'h1234_0000, 4'b1100, resp_q);
                reg_expect("strobe 1100", regs[r], 32'h1234_5AFF);
                axil_write(regs[r], 32'hFFFF_FFFF, 4'b0000, resp_q);
                reg_expect("strobe 0000", regs[r], 32'h1234_5AFF);
                wr(regs[r], 32'h0);
            end
        end
        for (int k = 0; k < 6; k++) wr(A_ARG0 + 13'(k * 4), 32'h1111_0000 + 32'(k) * 32'h0101);
        for (int k = 0; k < 6; k++) reg_expect("ARGk", A_ARG0 + 13'(k * 4), 32'h1111_0000 + 32'(k) * 32'h0101);
        axil_write(A_ARG5, 32'h0000_00EE, 4'b0001, resp_q);
        reg_expect("ARG5 strobe", A_ARG5, 32'h1111_05EE);
        for (int k = 0; k < 6; k++) wr(A_ARG0 + 13'(k * 4), 0);
        rd_expect_err(13'h0054, "read past ARG5");
        wr(A_CTRL, 32'h4);
        reg_expect("CTRL irq_en", A_CTRL, 32'h4);
        wr(A_CTRL, 32'h0);
        // read-only and reserved registers
        wr_expect_err(A_STATUS, 32'h1, "write STATUS");
        reg_expect("STATUS bad_access", A_STATUS, 32'h8);
        wr_expect_err(A_ID, 32'h0, "write ID");
        wr_expect_err(A_CYC, 32'h0, "write CYCLES");
        wr_expect_err(13'h0054, 32'h0, "write reserved reg");
        rd_expect_err(13'h0054, "read reserved reg");
        rd_expect_err(13'h0100, "read unmapped 0x100");
        wr_expect_err(13'h0F00, 32'h0, "write unmapped 0xF00");
        rd_expect_err(13'h1800, "read unmapped 0x1800");
        wr_expect_err(13'h1800, 32'h0, "write unmapped 0x1800");
        rd_expect_err(13'h1FFC, "read unmapped top");
        // bad_access is cleared by a legal START; verify with a zero-thread job.
        // (A program is needed: with an all-zero program memory the warps run NOPs forever.)
        load_prog();
        configure(0, SRC, DST);
        launch_and_wait();
        reg_expect("STATUS after zero-thread job", A_STATUS, 32'h2);
        // the DONE bit is sticky
        reg_expect("STATUS sticky 1", A_STATUS, 32'h2);
        reg_expect("STATUS sticky 2", A_STATUS, 32'h2);
    endtask

    task automatic t_prog();
        logic [31:0] v;
        $display("test prog");
        // pattern write and readback across the window, with byte strobes
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'hC0DE_0000 | w);
        for (int w = 0; w < 512; w++) reg_expect("win rb", A_WIN + 13'(w * 4), 32'hC0DE_0000 | w);
        axil_write(A_WIN + 13'h10, 32'h0000_AB00, 4'b0010, resp_q);
        reg_expect("win strobe", A_WIN + 13'h10, 32'hC0DE_AB04);
        axil_write(A_WIN + 13'h10, 32'hEF00_0000, 4'b1000, resp_q);
        reg_expect("win strobe hi", A_WIN + 13'h10, 32'hEFDE_AB04);
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        // real program through the window, executed by the GPU fetch path
        load_prog();
        for (int w = 0; w < (prog_len + 1) / 2; w++)
            reg_expect("prog rb", A_WIN + 13'(w * 4), {prog_img[2*w+1], prog_img[2*w]});
        fill_pattern(SRC, 256, 32'h1111);
        snapshot();
        configure(256, SRC, DST);
        launch_and_wait();
        check_brighten(SRC, DST, 256, "prog window run");
        // PROG_BASE: relocate the program by 16 instructions and run it from there
        for (int w = 0; w < 8; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        for (int w = 0; w < (prog_len + 1) / 2; w++)
            wr(A_WIN + 13'((w + 8) * 4), {prog_img[2*w+1], prog_img[2*w]});
        fill_pattern(SRC, 64, 32'h2222);
        snapshot();
        configure(64, SRC, DST);
        wr(A_PROG, 16);
        launch_and_wait();
        check_brighten(SRC, DST, 64, "PROG_BASE run");
        wr(A_PROG, 0);
    endtask

    task automatic t_job();
        int unsigned ar0, aw0, nx;
        logic [31:0] v;
        $display("test job");
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        fill_pattern(SRC, 256, 32'h3333);
        snapshot();
        configure(256, SRC, DST);
        ar0 = n_ar; aw0 = n_aw;
        launch_and_wait();
        check_brighten(SRC, DST, 256, "job");
        reg_expect("STATUS done", A_STATUS, 32'h2);
        nx = (n_ar - ar0) + (n_aw - aw0);
        if (nx != 512) fail($sformatf("AXI transactions %0d expected 512", nx));
        rd(A_XACT, v);  expect32("BUS_XACTS", v, nx);
        rd(A_CYC, v);   expect32("CYCLES", v, done_cyc - start_cyc);
        rd(A_STALL, v);
        if (v == 0) fail("BUS_STALLS is zero");
        $display("  job: cycles=%0d xacts=%0d stalls=%0d", done_cyc - start_cyc, nx, v);
    endtask

    task automatic t_busy();
        logic [31:0] v, st;
        $display("test busy");
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        fill_pattern(SRC, 1024, 32'h4444);
        snapshot();
        configure(1024, SRC, DST);
        launch();
        rd(A_STATUS, st);
        if (!st[0]) fail("not BUSY right after START");
        // START while BUSY: SLVERR, no effect on the running job
        wr_expect_err(A_CTRL, 32'h1, "START while BUSY");
        // shadow-only configuration writes
        wr(A_THREADS, 5); wr(A_SRC, 32'h100); wr(A_DST, 32'h200); wr(A_MLIM, 32'h40);
        reg_expect("shadow THREADS", A_THREADS, 5);
        // program window write while BUSY: SLVERR and no change
        wr_expect_err(A_WIN, 32'hFFFF_FFFF, "program write while BUSY");
        wait_done();
        check_brighten(SRC, DST, 1024, "job unaffected by BUSY writes");
        rd(A_STATUS, st);
        if (st[2:0] != 3'b010) fail($sformatf("STATUS after busy test %03b", st[2:0]));
        rd(A_WIN, v);
        if (v == 32'hFFFF_FFFF) fail("program window was modified while BUSY");
        // the shadow writes now take effect on the next START
        configure(256, SRC, DST);
        fill_pattern(SRC, 256, 32'h5555);
        snapshot();
        launch_and_wait();
        check_brighten(SRC, DST, 256, "second job");
    endtask

    task automatic t_raw();
        string rawp;
        int bad = 0;
        $display("test raw (read-after-write through posted stores)");
        if (!$value$plusargs("rawprog=%s", rawp)) rawp = "build/prog/raw.hex";
        read_prog(rawp);
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        for (int round = 0; round < 3; round++) begin
            for (int i = 0; i < 1024; i++) u_mem.mem[DST + i] = 32'hFFFF_FFFF;
            configure(256, SRC, DST);
            launch_and_wait();
            for (int t = 0; t < 256; t++) begin
                if (u_mem.mem[DST + t]       !== 32'(t + 1)) bad++;
                if (u_mem.mem[DST + 256 + t] !== 32'(t + 2)) bad++;
                if (u_mem.mem[DST + 512 + t] !== 32'(t + 3)) bad++;
            end
        end
        if (bad != 0) fail($sformatf("raw: %0d wrong words (a load passed an earlier posted store)", bad));
        read_prog(prog_path);
    endtask

    task automatic t_oor();
        logic [31:0] v, st;
        int unsigned ar0, aw0;
        $display("test oor");
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        fill_pattern(SRC, 256, 32'h6666);
        snapshot();
        // window ends before the destination buffer: loads are legal, stores are not
        configure(64, SRC, DST, MEM_BASE, (SRC + 64) * 4);
        ar0 = n_ar; aw0 = n_aw;
        launch_and_wait();
        rd(A_STATUS, st);
        if (!st[2]) fail("ERROR not set for out-of-range stores");
        if (!mon_have) fail("monitor saw no illegal access");
        reg_expect("ERR_ADDR", A_ERRA, mon_first);
        rd(A_IRQ, v);
        if (!v[1]) fail("IRQ_STATUS.error not set");
        if (n_aw != aw0) fail("out-of-range stores reached AXI");
        if (n_ar - ar0 != 64) fail($sformatf("expected 64 legal reads, saw %0d", n_ar - ar0));
        check_brighten(SRC, DST, 0, "oor memory untouched");
        // a clean job right after clears ERROR and ERR_ADDR
        configure(64, SRC, DST);
        launch_and_wait();
        rd(A_STATUS, st);
        if (st[2]) fail("ERROR not cleared by next START");
        reg_expect("ERR_ADDR cleared", A_ERRA, 0);
        // exact boundary: limit just covers the last destination word
        snapshot();
        configure(8, SRC, DST, MEM_BASE, (DST + 8) * 4);
        launch_and_wait();
        rd(A_STATUS, st);
        if (st[2]) fail("boundary-exact window flagged ERROR");
        // one word short
        configure(8, SRC, DST, MEM_BASE, (DST + 7) * 4);
        launch_and_wait();
        rd(A_STATUS, st);
        if (!st[2]) fail("one-word-short window not flagged");
        reg_expect("ERR_ADDR short", A_ERRA, DST + 7);
        // limit of zero: everything illegal, job still ends
        configure(8, SRC, DST, MEM_BASE, 0);
        launch_and_wait();
        reg_expect("ERR_ADDR first", A_ERRA, mon_first);
    endtask

    task automatic t_axierr();
        logic [31:0] v, st;
        $display("test axierr");
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        fill_pattern(SRC, 64, 32'h7777);
        err_en = 1'b1; err_word = SRC + 3;           // a read error
        configure(64, SRC, DST);
        launch_and_wait();
        rd(A_STATUS, st);
        if (!st[2]) fail("read SLVERR did not set ERROR");
        reg_expect("ERR_ADDR read err", A_ERRA, SRC + 3);
        err_word = DST + 5;                          // a write error
        configure(64, SRC, DST);
        launch_and_wait();
        rd(A_STATUS, st);
        if (!st[2]) fail("write SLVERR did not set ERROR");
        reg_expect("ERR_ADDR write err", A_ERRA, DST + 5);
        err_en = 1'b0;
        configure(64, SRC, DST);
        launch_and_wait();
        rd(A_STATUS, st);
        if (st[2]) fail("ERROR stuck after clean job");
    endtask

    task automatic t_b2b();
        int unsigned n, s, d;
        $display("test b2b");
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        for (int j = 0; j < 20; j++) begin
            n = $urandom_range(1, 200);
            s = 32'h2000 + $urandom_range(0, 'h7FF);
            d = 32'h6000 + $urandom_range(0, 'h7FF);
            fill_pattern(s, n, $urandom());
            snapshot();
            configure(n, s, d);
            launch_and_wait();
            check_brighten(s, d, n, $sformatf("b2b job %0d (n=%0d src=%0d dst=%0d)", j, n, s, d));
        end
    endtask

    task automatic t_reset();
        logic [31:0] v, st;
        $display("test reset");
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        // soft reset during a job at several offsets. Memory responses are slowed so a transaction
        // is usually still in flight when the reset hits, and the next START is retried at once:
        // the bridge must drain the old transaction before a new job may begin.
        begin
            logic [7:0] saved_stall;
            saved_stall = stall_pct;
            for (int k = 0; k < 16; k++) begin
                stall_pct = 8'd92;
                fill_pattern(SRC, 512, 32'h8888 + k);
                configure(512, SRC, DST);
                launch();
                // while the job runs, queue the next job in the shadow registers (SRC2/DST2)
                fill_pattern(SRC2, 128, 32'h9999 + k);
                for (int i = 0; i < 256; i++) u_mem.mem[DST2 + i] = 32'h0;
                wr(A_THREADS, 128); wr(A_SRC, SRC2); wr(A_DST, DST2);
                repeat ($urandom_range(0, 60) + k * 7) @(posedge clk);
                wr(A_CTRL, 32'h2);                       // SOFT_RESET
                // START immediately and retry until accepted: lands inside the drain window
                begin
                    int tries = 0;
                    do begin
                        axil_write(A_CTRL, 32'h1, 4'hF, resp_q);
                        tries++;
                    end while (resp_q == 2'b10 && tries < 2000);
                    if (resp_q == 2'b10) fail("START never accepted after soft reset");
                end
                wait_done();
                rd(A_STATUS, st);
                if (st[2:0] != 3'b010) fail($sformatf("STATUS after post-reset job %03b", st[2:0]));
                check_region(SRC2, DST2, 128, $sformatf("job after soft reset %0d", k));
            end
            stall_pct = saved_stall;
        end
        // soft reset, then confirm BUSY drops and DONE/IRQ are clear without starting a job
        fill_pattern(SRC, 512, 32'h7A7A);
        configure(512, SRC, DST);
        launch();
        repeat (50) @(posedge clk);
        wr(A_CTRL, 32'h2);
        begin
            int n = 0;
            do begin rd(A_STATUS, st); n++; end while (st[0] && n < 2000);
            if (st[0]) fail("BUSY stuck after soft reset");
        end
        if (st[1]) fail("DONE set after soft reset");
        rd(A_IRQ, v); expect32("IRQ_STATUS after soft reset", v, 0);
        // soft reset recovers a hung GPU (empty program memory runs NOPs forever)
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        configure(8, SRC, DST);
        launch();
        repeat (3000) @(posedge clk);
        rd(A_STATUS, st);
        if (!st[0]) fail("expected the empty-program job to still be running");
        wr(A_CTRL, 32'h2);
        begin
            int n = 0;
            do begin rd(A_STATUS, st); n++; end while (st[0] && n < 2000);
            if (st[0]) fail("soft reset did not recover a hung GPU");
        end
        load_prog();
        fill_pattern(SRC, 64, 32'h5B5B);
        snapshot();
        configure(64, SRC, DST);
        launch_and_wait();
        check_brighten(SRC, DST, 64, "job after hung-GPU recovery");
        // hard reset during a job
        fill_pattern(SRC, 512, 32'hAAAA);
        configure(512, SRC, DST);
        launch();
        repeat (200) @(posedge clk);
        do_reset();
        reg_expect("ID after hard reset", A_ID, 32'h584C5238);
        reg_expect("STATUS after hard reset", A_STATUS, 32'h0);
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        fill_pattern(SRC, 128, 32'hBBBB);
        snapshot();
        configure(128, SRC, DST);
        launch_and_wait();
        check_brighten(SRC, DST, 128, "job after hard reset");
    endtask

    task automatic t_irq();
        logic [31:0] v, st;
        int n;
        $display("test irq");
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        fill_pattern(SRC, 128, 32'hCCCC);
        configure(128, SRC, DST);
        wr(A_CTRL, 32'h4);                            // IRQ_EN
        if (irq) fail("irq high before job");
        wr(A_CTRL, 32'h5);                            // START | IRQ_EN (CTRL is written whole)
        if (irq) fail("irq high right after START");
        n = 0;
        while (!irq && n < 200000) begin @(posedge clk); n++; end
        if (!irq) fail("irq never rose");
        rd(A_STATUS, st);
        if (!st[1] || st[0]) fail($sformatf("irq high but STATUS=%03b", st[2:0]));
        rd(A_IRQ, v); expect32("IRQ_STATUS done", v, 32'h1);
        wr(A_IRQ, 32'h1);                             // W1C
        rd(A_IRQ, v); expect32("IRQ_STATUS cleared", v, 0);
        if (irq) fail("irq still high after W1C");
        rd(A_STATUS, st);
        if (!st[1]) fail("STATUS.DONE should stay set after IRQ_STATUS clear");
        // masked: IRQ_EN off keeps the line low but IRQ_STATUS still records
        wr(A_CTRL, 32'h0);
        launch_and_wait();
        if (irq) fail("irq high with IRQ_EN=0");
        rd(A_IRQ, v); expect32("IRQ_STATUS recorded while masked", v, 32'h1);
        wr(A_IRQ, 32'h3);
        if (irq_early != 0) fail($sformatf("irq asserted before DONE/ERROR %0d times", irq_early));
    endtask

    // ------------------------------------------------------------ ball frames
    logic [31:0] params [5 * 2048];
    task automatic t_ball();
        string pp, ppar, pout;
        int nf, fd;
        bit ball_args;
        logic [31:0] v;
        void'($value$plusargs("ballprog=%s", pp));
        void'($value$plusargs("ballparams=%s", ppar));
        void'($value$plusargs("ballout=%s", pout));
        if (!$value$plusargs("frames=%d", nf)) nf = 1;
        ball_args = $test$plusargs("ballargs");
        $readmemh(ppar, params);
        read_prog(pp);
        for (int w = 0; w < 512; w++) wr(A_WIN + 13'(w * 4), 32'h0);
        load_prog();
        fd = $fopen(pout, "w");
        for (int f = 0; f < nf; f++) begin
            if (ball_args) begin
                for (int i = 0; i < 5; i++) wr(A_ARG0 + 13'(i * 4), params[f * 5 + i]);
            end else begin
                for (int i = 0; i < 5; i++) u_mem.mem[SRC + i] = params[f * 5 + i];
            end
            configure(4096, SRC, DST);
            launch_and_wait();
            rd(A_STATUS, v);
            if (v[2:0] != 3'b010) fail($sformatf("frame %0d STATUS %03b", f, v[2:0]));
            for (int i = 0; i < 4096; i++) $fwrite(fd, "%08x\n", u_mem.mem[DST + i]);
            if (f == 0) begin
                rd(A_CYC, v);   $display("ball frame cycles=%0d", v);
                rd(A_XACT, v);  $display("ball frame xacts=%0d", v);
                rd(A_STALL, v); $display("ball frame stalls=%0d", v);
            end
        end
        $fclose(fd);
    endtask

    // ------------------------------------------------------------ main
    string tname, prog_path;
    initial begin
        if (!$value$plusargs("test=%s", tname)) tname = "all";
        if (!$value$plusargs("prog=%s", prog_path)) prog_path = "build/prog/brighten.hex";
        if ($value$plusargs("stall=%d", stall_pct)) ;
        $display("tb_xlr8: test=%0s stall=%0d%%", tname, stall_pct);

        do_reset();
        if (tname == "ball") begin
            t_ball();
        end else begin
            read_prog(prog_path);
            if (tname == "all" || tname == "regs")   begin do_reset(); t_regs();   end
            if (tname == "all" || tname == "prog")   begin do_reset(); t_prog();   end
            if (tname == "all" || tname == "job")    begin do_reset(); t_job();    end
            if (tname == "all" || tname == "busy")   begin do_reset(); t_busy();   end
            if (tname == "all" || tname == "raw")    begin do_reset(); t_raw();    end
            if (tname == "all" || tname == "oor")    begin do_reset(); t_oor();    end
            if (tname == "all" || tname == "axierr") begin do_reset(); t_axierr(); end
            if (tname == "all" || tname == "b2b")    begin do_reset(); t_b2b();    end
            if (tname == "all" || tname == "reset")  begin do_reset(); t_reset();  end
            if (tname == "all" || tname == "irq")    begin do_reset(); t_irq();    end
        end

        if (done_early != 0) fail($sformatf("DONE rose %0d times with writes still outstanding", done_early));
        if (n_perr != 0)  fail($sformatf("%0d AXI protocol errors", n_perr));
        if (bus_viol != 0) fail($sformatf("%0d GPU bus protocol violations (request not held)", bus_viol));
        if (errors == 0) $display("tb_xlr8: PASS");
        else             $fatal(1, "tb_xlr8: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $fatal(1, "tb_xlr8: TIMEOUT");
    end
endmodule
