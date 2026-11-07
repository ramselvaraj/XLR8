`timescale 1ns/1ps
// xlr8_top.sv -- XLR8: the RAPTOR SIMT GPU behind an AXI4-Lite control port and an AXI3 master.
//
//   s_axi_ctrl_*  AXI4-Lite slave  (registers + program window, 13-bit address)
//   m_axi_*       AXI3 master      (GPU data traffic to DDR, single beat)
//   irq           level interrupt
//
// One clock. `aresetn` is active low; soft reset (CTRL.SOFT_RESET) resets the GPU, program fetch
// and counters but not the AXI interfaces.
module xlr8_top #(
    parameter int  WARPS     = 2,
    parameter int  LANES     = 4,
    parameter bit  SLVERR_EN = 1'b1,
    parameter int  ID_W      = 6
)(
    input  logic        aclk,
    input  logic        aresetn,

    // AXI4-Lite slave (control)
    input  logic [12:0] s_axi_ctrl_awaddr,
    input  logic        s_axi_ctrl_awvalid,
    output logic        s_axi_ctrl_awready,
    input  logic [31:0] s_axi_ctrl_wdata,
    input  logic [3:0]  s_axi_ctrl_wstrb,
    input  logic        s_axi_ctrl_wvalid,
    output logic        s_axi_ctrl_wready,
    output logic [1:0]  s_axi_ctrl_bresp,
    output logic        s_axi_ctrl_bvalid,
    input  logic        s_axi_ctrl_bready,
    input  logic [12:0] s_axi_ctrl_araddr,
    input  logic        s_axi_ctrl_arvalid,
    output logic        s_axi_ctrl_arready,
    output logic [31:0] s_axi_ctrl_rdata,
    output logic [1:0]  s_axi_ctrl_rresp,
    output logic        s_axi_ctrl_rvalid,
    input  logic        s_axi_ctrl_rready,

    // AXI3 master (data)
    output logic [ID_W-1:0] m_axi_awid,
    output logic [31:0] m_axi_awaddr,
    output logic [3:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic [1:0]  m_axi_awlock,
    output logic [3:0]  m_axi_awcache,
    output logic [2:0]  m_axi_awprot,
    output logic [3:0]  m_axi_awqos,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [ID_W-1:0] m_axi_wid,
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [ID_W-1:0] m_axi_bid,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic [ID_W-1:0] m_axi_arid,
    output logic [31:0] m_axi_araddr,
    output logic [3:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic [1:0]  m_axi_arlock,
    output logic [3:0]  m_axi_arcache,
    output logic [2:0]  m_axi_arprot,
    output logic [3:0]  m_axi_arqos,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [ID_W-1:0] m_axi_rid,
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    output logic        irq
);
    localparam int PC_W = 16;

    // reset: GPU side is held in reset by hard reset or an active soft reset (registered, glitch free)
    logic soft_active, hard_rst, gpu_rst;
    always_ff @(posedge aclk) begin
        hard_rst <= !aresetn;
        gpu_rst  <= !aresetn || soft_active;
    end

    // GPU
    logic        gpu_start, gpu_busy, gpu_done;
    logic [31:0] gpu_threads, gpu_src, gpu_dst;
    logic [PC_W-1:0] imem_addr;
    logic [15:0] imem_rdata;
    logic        mem_req, mem_we, mem_ready;
    logic [31:0] mem_addr, mem_wdata, mem_rdata;

    simt_gpu #(.WARPS(WARPS), .LANES(LANES), .PC_W(PC_W), .LOCK_MEMORY_OWNER(1'b1), .FAST_DIV(1'b0)) u_gpu (
        .clk(aclk), .reset(gpu_rst), .start(gpu_start),
        .thread_count(gpu_threads), .src_addr(gpu_src), .dst_addr(gpu_dst),
        .busy(gpu_busy), .done(gpu_done),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    // registers
    logic [31:0] mem_base, mem_limit, prog_base, arg0, arg1;
    logic        bridge_idle, err_valid;
    logic [31:0] err_addr;
    logic        pw_we;
    logic [8:0]  pw_waddr, pw_raddr;
    logic [31:0] pw_wdata, pw_rdata;
    logic [3:0]  pw_wstrb;
    logic        perf_clear;
    logic [31:0] perf_cycles, perf_xacts, perf_stalls;

    xlr8_regs #(.SLVERR_EN(SLVERR_EN)) u_regs (
        .clk(aclk), .rst(hard_rst),
        .s_axi_awaddr(s_axi_ctrl_awaddr), .s_axi_awvalid(s_axi_ctrl_awvalid), .s_axi_awready(s_axi_ctrl_awready),
        .s_axi_wdata(s_axi_ctrl_wdata), .s_axi_wstrb(s_axi_ctrl_wstrb), .s_axi_wvalid(s_axi_ctrl_wvalid),
        .s_axi_wready(s_axi_ctrl_wready),
        .s_axi_bresp(s_axi_ctrl_bresp), .s_axi_bvalid(s_axi_ctrl_bvalid), .s_axi_bready(s_axi_ctrl_bready),
        .s_axi_araddr(s_axi_ctrl_araddr), .s_axi_arvalid(s_axi_ctrl_arvalid), .s_axi_arready(s_axi_ctrl_arready),
        .s_axi_rdata(s_axi_ctrl_rdata), .s_axi_rresp(s_axi_ctrl_rresp), .s_axi_rvalid(s_axi_ctrl_rvalid),
        .s_axi_rready(s_axi_ctrl_rready),
        .gpu_start(gpu_start), .gpu_threads(gpu_threads), .gpu_src(gpu_src), .gpu_dst(gpu_dst),
        .gpu_done(gpu_done),
        .mem_base(mem_base), .mem_limit(mem_limit), .prog_base(prog_base), .arg0(arg0), .arg1(arg1),
        .bridge_idle(bridge_idle), .err_valid(err_valid), .err_addr_in(err_addr),
        .pw_we(pw_we), .pw_waddr(pw_waddr), .pw_wdata(pw_wdata), .pw_wstrb(pw_wstrb),
        .pw_raddr(pw_raddr), .pw_rdata(pw_rdata),
        .perf_clear(perf_clear), .perf_cycles(perf_cycles), .perf_xacts(perf_xacts),
        .perf_stalls(perf_stalls),
        .soft_active(soft_active), .irq(irq)
    );

    // program RAM; the GPU fetch address is offset by PROG_BASE (instruction index)
    logic [9:0] fetch_idx;
    assign fetch_idx = imem_addr[9:0] + prog_base[9:0];

    xlr8_prog_ram #(.DEPTH(1024)) u_prog (
        .clk(aclk), .fetch_addr(fetch_idx), .fetch_data(imem_rdata),
        .we(pw_we), .waddr(pw_waddr), .wdata(pw_wdata), .wstrb(pw_wstrb),
        .raddr(pw_raddr), .rdata(pw_rdata)
    );

    // bridge
    xlr8_axi_bridge #(.ID_W(ID_W)) u_bridge (
        .clk(aclk), .rst(hard_rst), .abort(soft_active), .idle(bridge_idle),
        .base(mem_base), .limit(mem_limit),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .err_valid(err_valid), .err_addr(err_addr),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot), .m_axi_awqos(m_axi_awqos),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wid(m_axi_wid), .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    xlr8_perf u_perf (
        .clk(aclk), .rst(hard_rst), .clear(perf_clear), .start(gpu_start), .done(gpu_done),
        .mem_req(mem_req), .mem_ready(mem_ready),
        .cycles(perf_cycles), .xacts(perf_xacts), .stalls(perf_stalls)
    );

    logic unused;
    assign unused = &{1'b0, gpu_busy, arg0, arg1, imem_addr[PC_W-1:10], prog_base[31:10]};
endmodule
