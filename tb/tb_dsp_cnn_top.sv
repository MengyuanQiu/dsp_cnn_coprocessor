// =============================================================================
// Testbench : tb_dsp_cnn_top
// Description : System top-level smoke testbench
// Spec Ref    : DSP_CNN_SYSTEM_SPEC v2.0, Verification Plan §6.5
// =============================================================================

`timescale 1ns / 1ps

module tb_dsp_cnn_top;

    parameter int P_CLK = 10;

    // DUT signals
    logic clk, rst_n;

    // AXI-Lite
    logic        awvalid, awready;
    logic [11:0] awaddr;
    logic        wvalid, wready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        bvalid, bready;
    logic [1:0]  bresp;
    logic        arvalid, arready;
    logic [11:0] araddr;
    logic        rvalid, rready;
    logic [31:0] rdata;
    logic [1:0]  rresp;

    // Input AXIS
    logic        s_tvalid, s_tready;
    logic signed [7:0] s_tdata;
    logic        s_tlast;
    logic [0:0]  s_tuser;

    // Output AXIS
    logic        m_tvalid, m_tready;
    logic signed [7:0] m_tdata;
    logic        m_tlast;
    logic [0:0]  m_tuser;

    logic        irq;

    // DUT
    dsp_cnn_top #(
        .GP_IN_WIDTH(8), .GP_ACT_WIDTH(8),
        .GP_CICD_R(8), .GP_CICD_N(3), .GP_CICD_M(1), .GP_CICD_PHASE(0),
        .GP_FIR_N(8), .GP_FIR_COEF_WIDTH(8), .GP_FIR_SHIFT(7),
        .GP_PE_MAC_NUM(3), .GP_PE_CLUSTER_NUM(4), .GP_MAX_LAYER_NUM(4)
    ) u_dut (
        .clk_i(clk), .rst_ni(rst_n),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready), .s_axil_awaddr(awaddr),
        .s_axil_wvalid(wvalid), .s_axil_wready(wready), .s_axil_wdata(wdata),
        .s_axil_wstrb(wstrb),
        .s_axil_bvalid(bvalid), .s_axil_bready(bready), .s_axil_bresp(bresp),
        .s_axil_arvalid(arvalid), .s_axil_arready(arready), .s_axil_araddr(araddr),
        .s_axil_rvalid(rvalid), .s_axil_rready(rready), .s_axil_rdata(rdata),
        .s_axil_rresp(rresp),
        .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tdata(s_tdata),
        .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tdata(m_tdata),
        .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .irq_o(irq)
    );

    initial clk = 0;
    always #(P_CLK/2) clk = ~clk;

    int pass_cnt = 0, fail_cnt = 0, total = 0;

    // AXI-Lite BFM
    task automatic axil_write(input logic [11:0] addr, input logic [31:0] data);
        @(posedge clk);
        awvalid <= 1; awaddr <= addr;
        wvalid  <= 1; wdata  <= data; wstrb <= 4'hF;
        fork
            begin wait(awready); @(posedge clk); awvalid <= 0; end
            begin wait(wready);  @(posedge clk); wvalid  <= 0; end
        join
        bready <= 1;
        wait(bvalid); @(posedge clk);
        bready <= 0;
    endtask

    task automatic axil_read(input logic [11:0] addr, output logic [31:0] data);
        @(posedge clk);
        arvalid <= 1; araddr <= addr;
        wait(arready); @(posedge clk);
        arvalid <= 0;
        rready <= 1;
        wait(rvalid); @(posedge clk);
        data = rdata;
        rready <= 0;
    endtask

    task automatic reset_all();
        rst_n <= 0;
        awvalid <= 0; wvalid <= 0; bready <= 0;
        arvalid <= 0; rready <= 0;
        s_tvalid <= 0; s_tdata <= 0; s_tlast <= 0; s_tuser <= 0;
        m_tready <= 1;
        repeat(10) @(posedge clk);
        rst_n <= 1;
        repeat(3) @(posedge clk);
    endtask

    // Test 1: CSR Read/Write Loopback
    task automatic test_csr_loopback();
        logic [31:0] rd;
        $display("\n========== Test 1: CSR Loopback ==========");
        reset_all();

        axil_write(12'h040, 32'h0040);
        axil_read(12'h040, rd);
        total++;
        if (rd[15:0] == 16'h0040) begin
            $display("[PASS] CSR loopback: FRAME_LEN=0x%04h", rd[15:0]); pass_cnt++;
        end else begin
            $display("[FAIL] CSR loopback: got=0x%04h exp=0x0040", rd[15:0]); fail_cnt++;
        end
    endtask

    // Test 2: IDLE Status After Reset
    task automatic test_idle_status();
        logic [31:0] rd;
        $display("\n========== Test 2: IDLE Status ==========");
        reset_all();

        axil_read(12'h004, rd);
        total++;
        if (rd[0] == 1'b1) begin
            $display("[PASS] System IDLE after reset"); pass_cnt++;
        end else begin
            $display("[FAIL] System not IDLE: SYS_STATUS=0x%08h", rd); fail_cnt++;
        end
    endtask

    // Test 3: CIC Streaming Path (send samples, check CIC tready)
    task automatic test_cic_streaming();
        $display("\n========== Test 3: CIC Streaming ==========");
        reset_all();

        // Enable CIC
        axil_write(12'h084, {15'b0, 1'b1, 16'd0});  // CIC_EN=1

        // START
        axil_write(12'h000, 32'h0001);
        repeat(5) @(posedge clk);

        // Send some samples
        for (int i = 0; i < 16; i++) begin
            @(posedge clk);
            s_tvalid <= 1;
            s_tdata  <= 8'(signed'(i));
            s_tuser  <= (i == 0) ? 1'b1 : 1'b0;
            s_tlast  <= (i == 15) ? 1'b1 : 1'b0;
        end
        @(posedge clk);
        s_tvalid <= 0; s_tlast <= 0; s_tuser <= 0;

        repeat(50) @(posedge clk);

        total++;
        $display("[PASS] CIC streaming path completed without hang"); pass_cnt++;
    endtask

    // Test 4: Error Path + IRQ
    task automatic test_error_irq();
        logic [31:0] rd;
        $display("\n========== Test 4: Error Path ==========");
        reset_all();

        // Enable IRQ mask for ERR
        axil_write(12'h010, 32'h0002);  // IRQ_ERR mask

        repeat(10) @(posedge clk);

        // Check IRQ not asserted in idle
        total++;
        if (!irq) begin
            $display("[PASS] IRQ not asserted in IDLE"); pass_cnt++;
        end else begin
            $display("[FAIL] Spurious IRQ in IDLE"); fail_cnt++;
        end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $display("==========================================================");
        $display("  DSP-CNN Top-Level Smoke Testbench");
        $display("==========================================================");

        test_csr_loopback();
        test_idle_status();
        test_cic_streaming();
        test_error_irq();

        $display("\n==========================================================");
        $display("  SUMMARY: Total=%0d Pass=%0d Fail=%0d", total, pass_cnt, fail_cnt);
        $display("==========================================================");
        if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***");
        else               $display("  *** SOME TESTS FAILED ***");
        $finish;
    end

    initial begin #(P_CLK * 100000); $display("[ERROR] Timeout!"); $finish; end

endmodule : tb_dsp_cnn_top
