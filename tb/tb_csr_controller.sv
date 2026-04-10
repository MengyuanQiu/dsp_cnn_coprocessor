// =============================================================================
// Testbench : tb_csr_controller
// Description : Block-level testbench for CSR/Interrupt Controller
// Spec Ref    : CSR_INTERRUPT_SPEC v1.0, Verification Plan §6.1
// =============================================================================

`timescale 1ns / 1ps

module tb_csr_controller;

    parameter int P_ADDR_W = 12;
    parameter int P_DATA_W = 32;
    parameter int P_CLK    = 10;

    // =========================================================================
    // DUT Signals
    // =========================================================================
    logic clk, rst_n;

    // AXI-Lite
    logic                    awvalid, awready;
    logic [P_ADDR_W-1:0]    awaddr;
    logic                    wvalid, wready;
    logic [P_DATA_W-1:0]    wdata;
    logic [P_DATA_W/8-1:0]  wstrb;
    logic                    bvalid, bready;
    logic [1:0]              bresp;
    logic                    arvalid, arready;
    logic [P_ADDR_W-1:0]    araddr;
    logic                    rvalid, rready;
    logic [P_DATA_W-1:0]    rdata;
    logic [1:0]              rresp;

    // Control/Status
    logic        sys_start, sys_stop, sys_soft_rst;
    logic        sys_idle, sys_busy, sys_done_pulse, sys_err_pulse;
    logic [15:0] sys_err_code, sys_err_subinfo;
    logic        cic_active, fir_active, cnn_active, result_valid;
    logic [15:0] cic_decim_r;
    logic [3:0]  cic_order_n;
    logic [1:0]  cic_diff_m;
    logic [15:0] cic_phase;
    logic        cic_en, fir_en, cnn_en;
    logic [7:0]  fir_tap_n;
    logic [5:0]  fir_shift;
    logic [3:0]  cnn_num_layers;
    logic [15:0] frame_len;
    logic        irq;

    // =========================================================================
    // DUT
    // =========================================================================
    csr_controller #(
        .GP_ADDR_WIDTH(P_ADDR_W),
        .GP_DATA_WIDTH(P_DATA_W)
    ) u_dut (
        .clk_i(clk), .rst_ni(rst_n),
        .s_axil_awvalid(awvalid), .s_axil_awready(awready), .s_axil_awaddr(awaddr),
        .s_axil_wvalid(wvalid),   .s_axil_wready(wready),   .s_axil_wdata(wdata),
        .s_axil_wstrb(wstrb),
        .s_axil_bvalid(bvalid),   .s_axil_bready(bready),   .s_axil_bresp(bresp),
        .s_axil_arvalid(arvalid), .s_axil_arready(arready), .s_axil_araddr(araddr),
        .s_axil_rvalid(rvalid),   .s_axil_rready(rready),   .s_axil_rdata(rdata),
        .s_axil_rresp(rresp),
        .sys_start_o(sys_start), .sys_stop_o(sys_stop), .sys_soft_rst_o(sys_soft_rst),
        .sys_idle_i(sys_idle), .sys_busy_i(sys_busy),
        .sys_done_i(sys_done_pulse), .sys_err_i(sys_err_pulse),
        .sys_err_code_i(sys_err_code), .sys_err_subinfo_i(sys_err_subinfo),
        .cic_active_i(cic_active), .fir_active_i(fir_active),
        .cnn_active_i(cnn_active), .result_valid_i(result_valid),
        .cic_decim_r_o(cic_decim_r), .cic_order_n_o(cic_order_n),
        .cic_diff_m_o(cic_diff_m), .cic_phase_o(cic_phase), .cic_en_o(cic_en),
        .fir_tap_n_o(fir_tap_n), .fir_shift_o(fir_shift), .fir_en_o(fir_en),
        .cnn_num_layers_o(cnn_num_layers), .cnn_en_o(cnn_en),
        .frame_len_o(frame_len), .irq_o(irq)
    );

    // Clock
    initial clk = 0;
    always #(P_CLK/2) clk = ~clk;

    // =========================================================================
    // Test Infrastructure
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0, total = 0;

    // AXI-Lite BFM Tasks
    task automatic axil_write(input logic [P_ADDR_W-1:0] addr, input logic [P_DATA_W-1:0] data);
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

    task automatic axil_read(input logic [P_ADDR_W-1:0] addr, output logic [P_DATA_W-1:0] data);
        @(posedge clk);
        arvalid <= 1; araddr <= addr;
        wait(arready); @(posedge clk);
        arvalid <= 0;
        rready <= 1;
        wait(rvalid); @(posedge clk);
        data = rdata;
        rready <= 0;
    endtask

    task automatic check(input string name, input logic [P_DATA_W-1:0] actual, expected);
        total++;
        if (actual === expected) begin
            $display("[PASS] %s: 0x%08h", name, actual);
            pass_cnt++;
        end else begin
            $display("[FAIL] %s: got=0x%08h exp=0x%08h", name, actual, expected);
            fail_cnt++;
        end
    endtask

    task automatic reset_dut();
        rst_n <= 0;
        awvalid <= 0; wvalid <= 0; bready <= 0;
        arvalid <= 0; rready <= 0;
        sys_idle <= 1; sys_busy <= 0;
        sys_done_pulse <= 0; sys_err_pulse <= 0;
        sys_err_code <= 0; sys_err_subinfo <= 0;
        cic_active <= 0; fir_active <= 0; cnn_active <= 0; result_valid <= 0;
        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);
    endtask

    // =========================================================================
    // Test Cases
    // =========================================================================

    // Test 1: Reset Default Values (Spec §5.1, §5.2)
    task automatic test_reset_defaults();
        logic [P_DATA_W-1:0] rd;
        $display("\n========== Test 1: Reset Default Values ==========");
        reset_dut();

        axil_read(12'h000, rd); check("SYS_CTRL reset", rd, 32'h0);
        axil_read(12'h004, rd); check("SYS_STATUS.IDLE", rd[0], 1'b1);
        axil_read(12'h008, rd); check("ERR_CODE reset", rd, 32'h0);
        axil_read(12'h040, rd); check("FRAME_LEN default", rd[15:0], 16'd256);
        axil_read(12'h080, rd); check("CIC_CFG0 default R", rd[15:0], 16'd64);
    endtask

    // Test 2: RW Register Access
    task automatic test_rw_access();
        logic [P_DATA_W-1:0] rd;
        $display("\n========== Test 2: RW Register Access ==========");
        reset_dut();

        axil_write(12'h040, 32'h0100);  // FRAME_LEN = 256
        axil_read(12'h040, rd);
        check("FRAME_LEN write/read", rd[15:0], 16'h0100);

        axil_write(12'h080, {10'b0, 2'd1, 4'd3, 16'd32});  // CIC_CFG0
        axil_read(12'h080, rd);
        check("CIC_CFG0.DECIM_R", rd[15:0], 16'd32);
        check("CIC_CFG0.ORDER_N", rd[19:16], 4'd3);
    endtask

    // Test 3: SC (Self-Clear) Bits (Spec §5.1.1)
    task automatic test_self_clear();
        logic [P_DATA_W-1:0] rd;
        $display("\n========== Test 3: SC Self-Clear ==========");
        reset_dut();

        axil_write(12'h000, 32'h0001);  // START
        @(posedge clk);
        total++;
        if (sys_start) begin
            $display("[PASS] START pulse detected"); pass_cnt++;
        end else begin
            $display("[FAIL] START pulse not detected"); fail_cnt++;
        end
        @(posedge clk);
        total++;
        if (!sys_start) begin
            $display("[PASS] START self-cleared"); pass_cnt++;
        end else begin
            $display("[FAIL] START not self-cleared"); fail_cnt++;
        end
    endtask

    // Test 4: W1C (Write-1-to-Clear) (Spec §5.1)
    task automatic test_w1c();
        logic [P_DATA_W-1:0] rd;
        $display("\n========== Test 4: W1C Done/Err Clear ==========");
        reset_dut();

        // Trigger DONE sticky
        @(posedge clk); sys_done_pulse <= 1;
        @(posedge clk); sys_done_pulse <= 0;
        repeat(2) @(posedge clk);

        axil_read(12'h004, rd);
        check("DONE sticky set", rd[2], 1'b1);

        // Clear DONE via W1C
        axil_write(12'h000, 32'h0008);  // CLR_DONE
        repeat(2) @(posedge clk);
        axil_read(12'h004, rd);
        check("DONE after W1C", rd[2], 1'b0);
    endtask

    // Test 5: Busy Write Protection (Spec §2.2)
    task automatic test_busy_protect();
        logic [P_DATA_W-1:0] rd;
        $display("\n========== Test 5: Busy Write Protection ==========");
        reset_dut();

        // Write initial value
        axil_write(12'h040, 32'h0080);  // FRAME_LEN = 128
        axil_read(12'h040, rd);
        check("FRAME_LEN before busy", rd[15:0], 16'h0080);

        // Set busy
        sys_busy <= 1; sys_idle <= 0;
        repeat(2) @(posedge clk);

        // Try to write while busy
        axil_write(12'h040, 32'h0200);  // Try FRAME_LEN = 512
        axil_read(12'h040, rd);
        check("FRAME_LEN protected during busy", rd[15:0], 16'h0080);

        sys_busy <= 0; sys_idle <= 1;
    endtask

    // Test 6: First-Error Capture (Spec §5.3)
    task automatic test_first_error();
        logic [P_DATA_W-1:0] rd;
        $display("\n========== Test 6: First-Error Capture ==========");
        reset_dut();

        // First error
        sys_err_code <= 16'h0005; sys_err_subinfo <= 16'h0002;
        @(posedge clk); sys_err_pulse <= 1;
        @(posedge clk); sys_err_pulse <= 0;
        repeat(2) @(posedge clk);

        // Second error (should NOT overwrite)
        sys_err_code <= 16'h0009; sys_err_subinfo <= 16'h0004;
        @(posedge clk); sys_err_pulse <= 1;
        @(posedge clk); sys_err_pulse <= 0;
        repeat(2) @(posedge clk);

        axil_read(12'h008, rd);
        check("First error code held", rd[15:0], 16'h0005);
        check("First error subinfo held", rd[31:16], 16'h0002);
    endtask

    // Test 7: IRQ Mask/Status/Clear (Spec §6)
    task automatic test_irq();
        logic [P_DATA_W-1:0] rd;
        $display("\n========== Test 7: IRQ Mask/Status/Clear ==========");
        reset_dut();

        // Enable IRQ_DONE mask
        axil_write(12'h010, 32'h0001);  // mask bit 0

        // Trigger done
        @(posedge clk); sys_done_pulse <= 1;
        @(posedge clk); sys_done_pulse <= 0;
        repeat(3) @(posedge clk);

        total++;
        if (irq) begin
            $display("[PASS] IRQ asserted on DONE"); pass_cnt++;
        end else begin
            $display("[FAIL] IRQ not asserted"); fail_cnt++;
        end

        // Read IRQ status
        axil_read(12'h014, rd);
        check("IRQ_STATUS.DONE", rd[0], 1'b1);

        // Clear via W1C
        axil_write(12'h014, 32'h0001);
        repeat(2) @(posedge clk);

        total++;
        if (!irq) begin
            $display("[PASS] IRQ cleared after W1C"); pass_cnt++;
        end else begin
            $display("[FAIL] IRQ still asserted after W1C"); fail_cnt++;
        end
    endtask

    // Test 8: Performance Counters (Spec §10)
    task automatic test_perf_counters();
        logic [P_DATA_W-1:0] rd;
        $display("\n========== Test 8: Performance Counters ==========");
        reset_dut();

        // Enable perf counters
        axil_write(12'h250, 32'h0001);
        sys_busy <= 1; sys_idle <= 0;
        repeat(10) @(posedge clk);
        sys_busy <= 0; sys_idle <= 1;
        repeat(2) @(posedge clk);

        axil_read(12'h240, rd);
        total++;
        if (rd > 0) begin
            $display("[PASS] CYCLE_CNT > 0: %0d", rd); pass_cnt++;
        end else begin
            $display("[FAIL] CYCLE_CNT = 0"); fail_cnt++;
        end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $display("==========================================================");
        $display("  CSR/Interrupt Controller Testbench");
        $display("==========================================================");

        test_reset_defaults();
        test_rw_access();
        test_self_clear();
        test_w1c();
        test_busy_protect();
        test_first_error();
        test_irq();
        test_perf_counters();

        $display("\n==========================================================");
        $display("  SUMMARY: Total=%0d Pass=%0d Fail=%0d", total, pass_cnt, fail_cnt);
        $display("==========================================================");
        if (fail_cnt == 0) $display("  *** ALL TESTS PASSED ***");
        else               $display("  *** SOME TESTS FAILED ***");
        $finish;
    end

    initial begin #(P_CLK * 50000); $display("[ERROR] Timeout!"); $finish; end

endmodule : tb_csr_controller
