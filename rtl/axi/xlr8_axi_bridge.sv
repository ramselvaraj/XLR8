`timescale 1ns/1ps
// xlr8_axi_bridge.sv -- GPU word bus to an AXI3 master (single beat, one outstanding).
//
// GPU side follows docs/BUS_PROTOCOL.md: the request is held until `mem_ready`, which pulses for
// one cycle when the transaction has completed, with `mem_rdata` valid in that cycle.
//
// Address translation: AXI byte address = base + (word address << 2).
// An access is legal only if (word_addr * 4 + 4) <= limit. An illegal access produces no AXI
// traffic; reads return 0, writes are dropped, and `err_valid` pulses with the word address.
// An AXI error response (SLVERR/DECERR) also pulses `err_valid`; the access still completes.
//
// `abort` (soft reset): the transaction in flight finishes on the AXI side (a master may not
// withdraw a request) but its result is discarded and no `mem_ready` is produced. `idle` is low
// until that drain completes.
module xlr8_axi_bridge #(
    parameter int ID_W = 6
)(
    input  logic        clk,
    input  logic        rst,
    input  logic        abort,
    output logic        idle,
    // window
    input  logic [31:0] base,
    input  logic [31:0] limit,
    // GPU word bus
    input  logic        mem_req,
    input  logic        mem_we,
    input  logic [31:0] mem_addr,
    input  logic [31:0] mem_wdata,
    output logic [31:0] mem_rdata,
    output logic        mem_ready,
    // error report
    output logic        err_valid,
    output logic [31:0] err_addr,
    // AXI3 master
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
    output logic        m_axi_rready
);
    typedef enum logic [2:0] {S_IDLE, S_RD, S_RDWAIT, S_WR, S_BWAIT, S_RESP} state_t;
    state_t state;

    logic [31:0] axi_addr_q, wdata_q, rdata_q;
    logic        aw_done, w_done;
    logic        abort_q;          // abort seen while a transaction was in flight

    // ---- legality check (34-bit math so the window can reach the top of the address space)
    logic [33:0] end_byte;
    logic        legal;
    assign end_byte = {mem_addr, 2'b00} + 34'd4;
    assign legal    = (end_byte <= {2'b00, limit});

    assign idle = (state == S_IDLE);

    // GPU side
    assign mem_ready = (state == S_RESP) && !abort_q;
    assign mem_rdata = rdata_q;

    // AXI constants
    assign m_axi_awid    = '0;
    assign m_axi_wid     = '0;
    assign m_axi_arid    = '0;
    assign m_axi_awlen   = 4'd0;
    assign m_axi_arlen   = 4'd0;
    assign m_axi_awsize  = 3'd2;
    assign m_axi_arsize  = 3'd2;
    assign m_axi_awburst = 2'b01;
    assign m_axi_arburst = 2'b01;
    assign m_axi_awlock  = 2'b00;
    assign m_axi_arlock  = 2'b00;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_awqos   = 4'd0;
    assign m_axi_arqos   = 4'd0;
    assign m_axi_wlast   = 1'b1;
    assign m_axi_wstrb   = 4'hF;

    assign m_axi_awaddr  = axi_addr_q;
    assign m_axi_araddr  = axi_addr_q;
    assign m_axi_wdata   = wdata_q;

    assign m_axi_arvalid = (state == S_RD);
    assign m_axi_awvalid = (state == S_WR) && !aw_done;
    assign m_axi_wvalid  = (state == S_WR) && !w_done;
    assign m_axi_rready  = (state == S_RDWAIT);
    assign m_axi_bready  = (state == S_BWAIT);

    always_ff @(posedge clk) begin
        err_valid <= 1'b0;
        if (rst) begin
            state      <= S_IDLE;
            abort_q    <= 1'b0;
            aw_done    <= 1'b0;
            w_done     <= 1'b0;
            axi_addr_q <= 32'b0;
            wdata_q    <= 32'b0;
            rdata_q    <= 32'b0;
            err_addr   <= 32'b0;
        end else begin
            if (abort && state != S_IDLE) abort_q <= 1'b1;

            case (state)
                S_IDLE: begin
                    abort_q <= 1'b0;
                    aw_done <= 1'b0;
                    w_done  <= 1'b0;
                    if (mem_req && !abort) begin
                        wdata_q <= mem_wdata;
                        if (!legal) begin
                            rdata_q   <= 32'b0;
                            err_valid <= 1'b1;
                            err_addr  <= mem_addr;
                            state     <= S_RESP;
                        end else begin
                            axi_addr_q <= base + {mem_addr[29:0], 2'b00};
                            err_addr   <= mem_addr;     // remembered in case the response errors
                            state      <= mem_we ? S_WR : S_RD;
                        end
                    end
                end

                S_RD: if (m_axi_arready) state <= S_RDWAIT;

                S_RDWAIT: if (m_axi_rvalid) begin
                    rdata_q <= m_axi_rdata;
                    if (m_axi_rresp != 2'b00) err_valid <= 1'b1;
                    state <= (abort_q || abort) ? S_IDLE : S_RESP;
                end

                S_WR: begin
                    if (m_axi_awvalid && m_axi_awready) aw_done <= 1'b1;
                    if (m_axi_wvalid  && m_axi_wready)  w_done  <= 1'b1;
                    if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
                        (w_done  || (m_axi_wvalid  && m_axi_wready)))
                        state <= S_BWAIT;
                end

                S_BWAIT: if (m_axi_bvalid) begin
                    if (m_axi_bresp != 2'b00) err_valid <= 1'b1;
                    state <= (abort_q || abort) ? S_IDLE : S_RESP;
                end

                S_RESP: state <= S_IDLE;

                default: state <= S_IDLE;
            endcase
        end
    end

    // Unused-but-required AXI inputs
    logic unused;
    assign unused = &{1'b0, m_axi_bid, m_axi_rid, m_axi_rlast};
endmodule
