`timescale 1ns/1ps
// xlr8_axi_bridge.sv -- GPU word bus to an AXI3 master (single beat).
//
// Reads are one at a time. Stores are POSTED: the GPU's store completes as soon as the AXI write
// address and data are accepted, without waiting for the write response, and up to MAX_WR writes
// can be outstanding. Ordering rules that keep this correct:
//   - a read is not issued until every earlier write has its response (read-after-write);
//   - `idle` stays low until all write responses are back, and the register block holds DONE
//     until then, so a finished job's data is in memory;
//   - a write error response is reported (ERR_ADDR from a small address FIFO) before DONE.
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
    parameter int ID_W   = 6,
    parameter int MAX_WR = 8,
    parameter bit POSTED = 1'b1       // 0: wait for each write response (the Phase 2 behaviour)
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
    typedef enum logic [2:0] {S_IDLE, S_RD, S_RDWAIT, S_WR, S_BWAIT, S_RESP} state_t;   // S_BWAIT only when !POSTED
    state_t state;

    logic [31:0] axi_addr_q, wdata_q, rdata_q;
    logic        aw_done, w_done;
    logic        abort_q;          // abort seen while a transaction was in flight

    // ---- legality check (34-bit math so the window can reach the top of the address space)
    logic [33:0] end_byte;
    logic        legal;
    assign end_byte = {mem_addr, 2'b00} + 34'd4;
    assign legal    = (end_byte <= {2'b00, limit});

    // outstanding posted writes and their word addresses, in issue order (AXI returns same-ID responses in order)
    localparam int CW = $clog2(MAX_WR + 1);
    logic [CW-1:0]  out_cnt;
    logic [31:0]    wr_fifo [MAX_WR];
    logic [$clog2(MAX_WR)-1:0] wr_head, wr_tail;
    logic           push_wr, pop_wr;
    logic [31:0]    cur_word;
    logic [31:0]    addr_word_q;     // GPU word address of the access being issued

    assign idle = (state == S_IDLE) && (out_cnt == '0);

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
    assign m_axi_bready  = POSTED ? (out_cnt != '0) : (state == S_BWAIT);

    // a write is pushed when both its address and data have been accepted
    wire aw_hs = m_axi_awvalid && m_axi_awready;
    wire w_hs  = m_axi_wvalid  && m_axi_wready;
    assign push_wr = POSTED && (state == S_WR) && (aw_done || aw_hs) && (w_done || w_hs);
    assign pop_wr  = POSTED && m_axi_bvalid && m_axi_bready;
    assign cur_word = wr_fifo[wr_head];

    // outstanding-write bookkeeping and write-response errors
    always_ff @(posedge clk) begin
        if (rst) begin
            out_cnt <= '0; wr_head <= '0; wr_tail <= '0;
        end else begin
            out_cnt <= out_cnt + CW'(push_wr) - CW'(pop_wr);
            if (push_wr) begin wr_fifo[wr_tail] <= addr_word_q; wr_tail <= wr_tail + 1'b1; end
            if (pop_wr) wr_head <= wr_head + 1'b1;
        end
    end

    logic        wr_err_pulse;
    assign wr_err_pulse = pop_wr && (m_axi_bresp != 2'b00);

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
            addr_word_q <= 32'b0;
        end else begin
            if (abort && state != S_IDLE) abort_q <= 1'b1;
            if (wr_err_pulse) begin             // a posted write failed: report its own address
                err_valid <= 1'b1;
                err_addr  <= cur_word;
            end

            case (state)
                S_IDLE: begin
                    abort_q <= 1'b0;
                    aw_done <= 1'b0;
                    w_done  <= 1'b0;
                    if (mem_req && !abort) begin
                        if (!legal) begin
                            wdata_q   <= mem_wdata;
                            rdata_q   <= 32'b0;
                            err_valid <= 1'b1;
                            err_addr  <= mem_addr;
                            state     <= S_RESP;
                        end else if (mem_we) begin
                            if (out_cnt < MAX_WR[CW-1:0] || !POSTED) begin   // room for another posted write
                                wdata_q     <= mem_wdata;
                                axi_addr_q  <= base + {mem_addr[29:0], 2'b00};
                                addr_word_q <= mem_addr;
                                state       <= S_WR;
                            end
                        end else if (out_cnt == '0) begin                    // a read waits for earlier writes
                            axi_addr_q  <= base + {mem_addr[29:0], 2'b00};
                            addr_word_q <= mem_addr;
                            err_addr    <= mem_addr;                         // in case the read response errors
                            state       <= S_RD;
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
                    if (aw_hs) aw_done <= 1'b1;
                    if (w_hs)  w_done  <= 1'b1;
                    if ((aw_done || aw_hs) && (w_done || w_hs))
                        state <= POSTED ? ((abort_q || abort) ? S_IDLE : S_RESP) : S_BWAIT;
                end

                S_BWAIT: if (m_axi_bvalid) begin                             // only when !POSTED
                    if (m_axi_bresp != 2'b00) begin err_valid <= 1'b1; err_addr <= addr_word_q; end
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
