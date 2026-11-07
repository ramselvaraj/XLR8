`timescale 1ns/1ps
// xlr8_regs.sv -- AXI4-Lite control slave for XLR8. Register map: docs/PLAN.md section 4.
//
//   0x0000-0x00FF  registers          0x1000-0x17FF  program window (RW, 512 words)
//
// One outstanding write and one outstanding read. AW and W may arrive in any order.
// Configuration is shadowed: START snapshots every setting, so writes during a job only change the
// shadow. SLVERR (when SLVERR_EN=1) is returned for: START while BUSY, program writes while BUSY,
// writes to read-only registers, and any unmapped address. Every such access also sets
// STATUS.BAD_ACCESS. Set SLVERR_EN=0 to return OKAY instead (an AXI error on the Zynq GP port
// can raise an external abort in Linux); BAD_ACCESS still records the event.
module xlr8_regs #(
    parameter bit          SLVERR_EN = 1'b1,
    parameter int          NARGS     = 6,
    parameter logic [31:0] VERSION   = 32'h0000_0200
)(
    input  logic        clk,
    input  logic        rst,            // hard reset (aresetn)

    // AXI4-Lite slave
    input  logic [12:0] s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [12:0] s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // GPU launch (active copies)
    output logic        gpu_start,
    output logic [31:0] gpu_threads,
    output logic [31:0] gpu_src,
    output logic [31:0] gpu_dst,
    input  logic        gpu_done,

    // bridge / program RAM configuration (active copies)
    output logic [31:0] mem_base,
    output logic [31:0] mem_limit,
    output logic [31:0] prog_base,
    output logic [31:0] args [NARGS],       // active copies, preloaded into r8.. by the GPU
    input  logic        bridge_idle,
    input  logic        err_valid,
    input  logic [31:0] err_addr_in,

    // program window
    output logic        pw_we,
    output logic [8:0]  pw_waddr,
    output logic [31:0] pw_wdata,
    output logic [3:0]  pw_wstrb,
    output logic [8:0]  pw_raddr,
    input  logic [31:0] pw_rdata,

    // performance counters
    output logic        perf_clear,
    input  logic [31:0] perf_cycles,
    input  logic [31:0] perf_xacts,
    input  logic [31:0] perf_stalls,

    // resets and interrupt
    output logic        job_complete,   // one cycle: DONE has just been set (GPU finished and writes drained)
    output logic        soft_active,    // high while a soft reset is being applied
    output logic        irq
);
    localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;
    localparam logic [31:0] ID_VALUE = 32'h584C_5238;       // "XLR8"
    localparam int SOFT_CYCLES = 8;

    // register word indices (byte offset / 4)
    localparam logic [5:0] R_CTRL = 6'd0,  R_STATUS = 6'd1,  R_THREADS = 6'd2,  R_SRC = 6'd3,
                           R_DST = 6'd4,   R_PROG = 6'd5,    R_MBASE = 6'd6,    R_MLIM = 6'd7,
                           R_IRQ = 6'd8,   R_CYC = 6'd9,     R_XACT = 6'd10,    R_STALL = 6'd11,
                           R_ERRA = 6'd12, R_ID = 6'd13,     R_VER = 6'd14,     R_ARG0 = 6'd15,
                           R_ARG1 = 6'd16, R_ARG2 = 6'd17, R_ARG3 = 6'd18, R_ARG4 = 6'd19,
                           R_ARG5 = 6'd20;

    // ---------------------------------------------------------------- state
    logic        irq_en;
    logic [31:0] sh_threads, sh_src, sh_dst, sh_prog, sh_mbase, sh_mlim;
    logic [31:0] sh_args [NARGS];
    logic        job_active, done_f, error_f, bad_f;
    logic [1:0]  irq_status;                 // [0] done, [1] error
    logic [31:0] err_addr_q;
    logic [3:0]  soft_cnt;
    logic        start_pulse_q;
    logic        done_pending;       // GPU has finished; waiting for posted writes to reach memory

    assign soft_active = (soft_cnt != 4'd0);
    wire   busy        = job_active || !bridge_idle || soft_active || start_pulse_q;

    assign gpu_start  = start_pulse_q;
    assign irq        = irq_en && (|irq_status);

    // ---------------------------------------------------------------- write channel
    logic        aw_have, w_have;
    logic [12:0] aw_q;
    logic [31:0] wd_q;
    logic [3:0]  ws_q;

    assign s_axi_awready = !aw_have && !s_axi_bvalid;
    assign s_axi_wready  = !w_have  && !s_axi_bvalid;

    wire do_write = aw_have && w_have && !s_axi_bvalid;

    wire        wr_is_reg    = (aw_q[12:8] == 5'd0);
    wire        wr_is_win    = aw_q[12] && !aw_q[11];
    wire [5:0]  wr_idx       = aw_q[7:2];

    // byte-strobe merge helper
    function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] nw,
                                          input logic [3:0] st);
        merge = {st[3] ? nw[31:24] : old[31:24], st[2] ? nw[23:16] : old[23:16],
                 st[1] ? nw[15:8]  : old[15:8],  st[0] ? nw[7:0]   : old[7:0]};
    endfunction

    // combinational outcome of the write being executed this cycle
    logic        wr_err;
    logic        do_start, do_soft;
    always_comb begin
        wr_err   = 1'b0;
        do_start = 1'b0;
        do_soft  = 1'b0;
        pw_we    = 1'b0;
        if (do_write) begin
            if (wr_is_win) begin
                if (busy) wr_err = 1'b1; else pw_we = 1'b1;
            end else if (wr_is_reg) begin
                case (wr_idx)
                    R_CTRL: begin
                        if (ws_q[0]) begin
                            if (wd_q[1])      do_soft  = 1'b1;
                            else if (wd_q[0]) begin
                                if (busy) wr_err = 1'b1; else do_start = 1'b1;
                            end
                        end
                    end
                    R_THREADS, R_SRC, R_DST, R_PROG, R_MBASE, R_MLIM, R_IRQ: ;
                    R_ARG0, R_ARG1, R_ARG2, R_ARG3, R_ARG4, R_ARG5: ;
                    default: wr_err = 1'b1;     // read-only or reserved
                endcase
            end else begin
                wr_err = 1'b1;                  // unmapped
            end
        end
    end

    assign pw_waddr = aw_q[10:2];
    assign pw_wdata = wd_q;
    assign pw_wstrb = ws_q;
    assign perf_clear = do_start;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_have <= 1'b0; w_have <= 1'b0; aw_q <= '0; wd_q <= '0; ws_q <= '0;
            s_axi_bvalid <= 1'b0; s_axi_bresp <= OKAY;
            irq_en <= 1'b0;
            sh_threads <= '0; sh_src <= '0; sh_dst <= '0; sh_prog <= '0;
            sh_mbase <= '0; sh_mlim <= '0;
            for (int k = 0; k < NARGS; k++) begin sh_args[k] <= '0; args[k] <= '0; end
            gpu_threads <= '0; gpu_src <= '0; gpu_dst <= '0; mem_base <= '0; mem_limit <= '0;
            prog_base <= '0;
            job_active <= 1'b0; done_f <= 1'b0; error_f <= 1'b0; bad_f <= 1'b0;
            irq_status <= 2'b00; err_addr_q <= '0; soft_cnt <= 4'd0; start_pulse_q <= 1'b0;
            done_pending <= 1'b0; job_complete <= 1'b0;
        end else begin
            start_pulse_q <= 1'b0;
            if (soft_cnt != 4'd0) soft_cnt <= soft_cnt - 4'd1;

            // channel capture
            if (s_axi_awvalid && s_axi_awready) begin aw_have <= 1'b1; aw_q <= s_axi_awaddr; end
            if (s_axi_wvalid  && s_axi_wready)  begin w_have  <= 1'b1; wd_q <= s_axi_wdata; ws_q <= s_axi_wstrb; end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

            // job events (GPU)
            job_complete <= 1'b0;
            if (gpu_done && job_active) done_pending <= 1'b1;
            if (done_pending && bridge_idle) begin      // all write responses are back
                done_pending  <= 1'b0;
                job_active    <= 1'b0;
                done_f        <= 1'b1;
                irq_status[0] <= 1'b1;
                job_complete  <= 1'b1;
            end
            if (err_valid && job_active) begin
                if (!error_f) err_addr_q <= err_addr_in;
                error_f       <= 1'b1;
                irq_status[1] <= 1'b1;
            end

            // soft reset clears job state (a hard reset clears everything)
            if (soft_active) begin
                job_active <= 1'b0; done_f <= 1'b0; error_f <= 1'b0; done_pending <= 1'b0;
                irq_status <= 2'b00; start_pulse_q <= 1'b0;
            end

            // execute the write
            if (do_write) begin
                aw_have <= 1'b0; w_have <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= (wr_err && SLVERR_EN) ? SLVERR : OKAY;
                if (wr_err) bad_f <= 1'b1;

                if (wr_is_reg && !wr_err) begin
                    case (wr_idx)
                        R_CTRL:    if (ws_q[0]) irq_en <= wd_q[2];
                        R_THREADS: sh_threads <= merge(sh_threads, wd_q, ws_q);
                        R_SRC:     sh_src     <= merge(sh_src,     wd_q, ws_q);
                        R_DST:     sh_dst     <= merge(sh_dst,     wd_q, ws_q);
                        R_PROG:    sh_prog    <= merge(sh_prog,    wd_q, ws_q);
                        R_MBASE:   sh_mbase   <= merge(sh_mbase,   wd_q, ws_q);
                        R_MLIM:    sh_mlim    <= merge(sh_mlim,    wd_q, ws_q);
                        R_ARG0, R_ARG1, R_ARG2, R_ARG3, R_ARG4, R_ARG5:
                            sh_args[3'(wr_idx - R_ARG0)] <= merge(sh_args[3'(wr_idx - R_ARG0)], wd_q, ws_q);
                        R_IRQ:     if (ws_q[0]) irq_status <= irq_status & ~wd_q[1:0];
                        default: ;
                    endcase
                end
            end

            if (do_soft) begin
                soft_cnt <= SOFT_CYCLES[3:0];
                bad_f    <= 1'b0;
            end

            if (do_start) begin
                gpu_threads <= sh_threads; gpu_src <= sh_src; gpu_dst <= sh_dst;
                mem_base <= sh_mbase; mem_limit <= sh_mlim; prog_base <= sh_prog;
                for (int k = 0; k < NARGS; k++) args[k] <= sh_args[k];
                job_active <= 1'b1; done_pending <= 1'b0;
                done_f <= 1'b0; error_f <= 1'b0; bad_f <= 1'b0;
                err_addr_q <= '0;
                irq_status <= 2'b00;
                start_pulse_q <= 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------- read channel
    logic [31:0] rd_val;
    logic        rd_err;
    wire         rd_is_reg = (s_axi_araddr[12:8] == 5'd0);
    wire         rd_is_win = s_axi_araddr[12] && !s_axi_araddr[11];
    wire  [5:0]  rd_idx    = s_axi_araddr[7:2];

    assign pw_raddr      = s_axi_araddr[10:2];
    assign s_axi_arready = !s_axi_rvalid;

    always_comb begin
        rd_val = 32'b0;
        rd_err = 1'b0;
        if (rd_is_win) begin
            rd_val = pw_rdata;
        end else if (rd_is_reg) begin
            case (rd_idx)
                R_CTRL:    rd_val = {29'b0, irq_en, 2'b00};
                R_STATUS:  rd_val = {28'b0, bad_f, error_f, done_f, busy};
                R_THREADS: rd_val = sh_threads;
                R_SRC:     rd_val = sh_src;
                R_DST:     rd_val = sh_dst;
                R_PROG:    rd_val = sh_prog;
                R_MBASE:   rd_val = sh_mbase;
                R_MLIM:    rd_val = sh_mlim;
                R_IRQ:     rd_val = {30'b0, irq_status};
                R_CYC:     rd_val = perf_cycles;
                R_XACT:    rd_val = perf_xacts;
                R_STALL:   rd_val = perf_stalls;
                R_ERRA:    rd_val = err_addr_q;
                R_ID:      rd_val = ID_VALUE;
                R_VER:     rd_val = VERSION;
                R_ARG0, R_ARG1, R_ARG2, R_ARG3, R_ARG4, R_ARG5: rd_val = sh_args[3'(rd_idx - R_ARG0)];
                default:   rd_err = 1'b1;
            endcase
        end else begin
            rd_err = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s_axi_rvalid <= 1'b0; s_axi_rdata <= '0; s_axi_rresp <= OKAY;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rdata  <= rd_val;
                s_axi_rresp  <= (rd_err && SLVERR_EN) ? SLVERR : OKAY;
            end
        end
    end

    logic unused;
    assign unused = &{1'b0, aw_q[1:0], s_axi_araddr[1:0]};
endmodule
