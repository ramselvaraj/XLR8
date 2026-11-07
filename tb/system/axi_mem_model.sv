`timescale 1ns/1ps
// axi_mem_model.sv -- AXI3 slave memory for the XLR8 testbench (32-bit, single beat).
//
// Random stalls on every channel (stall_pct percent of cycles a handshake is withheld), optional
// error response for one word, and protocol checking of the master:
//   - len == 0, size == 2, address aligned and inside the model
//   - valid/payload stable until ready
//   - only one outstanding read and one outstanding write
module axi_mem_model #(
    parameter int          WORDS = 32768,
    parameter logic [31:0] BASE  = 32'h1000_0000,
    parameter int          ID_W  = 6
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  stall_pct,
    input  logic        err_en,
    input  logic [31:0] err_word,          // word index (relative to BASE) that returns SLVERR

    input  logic [ID_W-1:0] awid,
    input  logic [31:0] awaddr,
    input  logic [3:0]  awlen,
    input  logic [2:0]  awsize,
    input  logic        awvalid,
    output logic        awready,
    input  logic [31:0] wdata,
    input  logic [3:0]  wstrb,
    input  logic        wlast,
    input  logic        wvalid,
    output logic        wready,
    output logic [ID_W-1:0] bid,
    output logic [1:0]  bresp,
    output logic        bvalid,
    input  logic        bready,
    input  logic [ID_W-1:0] arid,
    input  logic [31:0] araddr,
    input  logic [3:0]  arlen,
    input  logic [2:0]  arsize,
    input  logic        arvalid,
    output logic        arready,
    output logic [ID_W-1:0] rid,
    output logic [31:0] rdata,
    output logic [1:0]  rresp,
    output logic        rlast,
    output logic        rvalid,
    input  logic        rready,

    output int unsigned n_ar,
    output int unsigned n_aw,
    output int unsigned n_proto_err,
    output logic [31:0] last_ar_word,
    output logic [31:0] last_aw_word
);
    logic [31:0] mem [WORDS];

    initial for (int i = 0; i < WORDS; i++) mem[i] = 32'b0;

    function automatic bit pass();
        return ($urandom_range(0, 99) >= stall_pct);
    endfunction

    task automatic perr(input string msg);
        n_proto_err++;
        $display("%0t AXI PROTOCOL ERROR: %s", $time, msg);
    endtask

    function automatic bit addr_ok(input logic [31:0] a);
        return (a >= BASE) && (a < BASE + 32'(WORDS * 4)) && (a[1:0] == 2'b00);
    endfunction

    // ---------------- read side
    logic        rd_pending;
    logic [31:0] rd_word;
    logic        ar_prev_stall;
    logic [31:0] ar_prev_addr;

    // ---------------- write side
    logic        aw_have, w_have, wr_pending;
    logic [31:0] aw_word, w_data_q;
    logic [3:0]  w_strb_q;
    logic        wr_err_q;
    logic        aw_prev_stall, w_prev_stall;
    logic [31:0] aw_prev_addr, w_prev_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready <= 1'b0; wready <= 1'b0; arready <= 1'b0;
            bvalid <= 1'b0; bresp <= 2'b00; bid <= '0;
            rvalid <= 1'b0; rresp <= 2'b00; rid <= '0; rlast <= 1'b0; rdata <= '0;
            rd_pending <= 1'b0; aw_have <= 1'b0; w_have <= 1'b0; wr_pending <= 1'b0;
            ar_prev_stall <= 1'b0; aw_prev_stall <= 1'b0; w_prev_stall <= 1'b0;
            n_ar <= 0; n_aw <= 0; n_proto_err <= 0;
            last_ar_word <= '0; last_aw_word <= '0;
        end else begin
            // ---- read address
            arready <= !rd_pending && pass();
            if (arvalid && arready) begin
                if (arlen != 0 || arsize != 3'd2) perr("AR len/size");
                if (!addr_ok(araddr)) perr($sformatf("AR address %08x", araddr));
                rd_word    <= (araddr - BASE) >> 2;
                last_ar_word <= (araddr - BASE) >> 2;
                rd_pending <= 1'b1;
                n_ar       <= n_ar + 1;
            end else if (arvalid && rd_pending) begin
                perr("second read outstanding");
            end
            if (ar_prev_stall && !(arvalid && araddr == ar_prev_addr)) perr("AR changed before ready");
            ar_prev_stall <= arvalid && !arready;
            ar_prev_addr  <= araddr;

            // ---- read data
            if (rd_pending && !rvalid && pass()) begin
                rvalid <= 1'b1;
                rlast  <= 1'b1;
                rdata  <= (rd_word < 32'(WORDS)) ? mem[rd_word[14:0]] : 32'hDEAD_BEEF;
                rresp  <= (err_en && rd_word == err_word) ? 2'b10 : 2'b00;
            end
            if (rvalid && rready) begin
                rvalid <= 1'b0; rd_pending <= 1'b0;
            end

            // ---- write address / data
            awready <= !aw_have && !wr_pending && pass();
            wready  <= !w_have  && !wr_pending && pass();
            if (awvalid && awready) begin
                if (awlen != 0 || awsize != 3'd2) perr("AW len/size");
                if (!addr_ok(awaddr)) perr($sformatf("AW address %08x", awaddr));
                aw_have <= 1'b1; aw_word <= (awaddr - BASE) >> 2;
                last_aw_word <= (awaddr - BASE) >> 2;
            end else if (awvalid && (aw_have || wr_pending)) begin
                perr("second write outstanding (AW)");
            end
            if (wvalid && wready) begin
                if (!wlast) perr("WLAST not set");
                w_have <= 1'b1; w_data_q <= wdata; w_strb_q <= wstrb;
            end
            if (aw_prev_stall && !(awvalid && awaddr == aw_prev_addr)) perr("AW changed before ready");
            if (w_prev_stall  && !(wvalid  && wdata == w_prev_data))   perr("W changed before ready");
            aw_prev_stall <= awvalid && !awready; aw_prev_addr <= awaddr;
            w_prev_stall  <= wvalid  && !wready;  w_prev_data  <= wdata;

            if (aw_have && w_have && !wr_pending && pass()) begin
                if (aw_word < 32'(WORDS)) begin
                    if (!(err_en && aw_word == err_word)) begin
                        for (int b = 0; b < 4; b++)
                            if (w_strb_q[b]) mem[aw_word[14:0]][b*8 +: 8] <= w_data_q[b*8 +: 8];
                    end
                end
                wr_err_q   <= (err_en && aw_word == err_word);
                wr_pending <= 1'b1;
                aw_have    <= 1'b0;
                w_have     <= 1'b0;
                n_aw       <= n_aw + 1;
            end
            if (wr_pending && !bvalid && pass()) begin
                bvalid <= 1'b1;
                bresp  <= wr_err_q ? 2'b10 : 2'b00;
            end
            if (bvalid && bready) begin
                bvalid <= 1'b0; wr_pending <= 1'b0;
            end
        end
    end
endmodule
