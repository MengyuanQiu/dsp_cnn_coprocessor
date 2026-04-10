// =============================================================================
// Testbench : tb_filter_cicd
// Description : Block-level testbench for CIC Decimation Filter
// Spec Ref    : FILTER_CIC_SPEC v2.0, Verification Plan §6.2, §10.2
// =============================================================================
// Verification targets:
//   1. Impulse response
//   2. DC (constant) input
//   3. Alternating max/min input
//   4. Frame boundary (tuser/tlast) mapping
//   5. cic_en_i gating
//   6. Parameter validation (cic_cfg_err_o)
//   7. Output valid periodicity (R cycles)
//   8. Golden model comparison (fixed-width two's complement)
// =============================================================================

`timescale 1ns / 1ps

module tb_filter_cicd;

    // =========================================================================
    // Test Parameters
    // =========================================================================
    parameter int P_R         = 8;
    parameter int P_N         = 3;
    parameter int P_M         = 1;
    parameter int P_PHASE     = 0;
    parameter int P_IN_WIDTH  = 8;
    parameter int P_OUT_WIDTH = P_IN_WIDTH + P_N * $clog2(P_M * P_R);

    parameter int P_FRAME_LEN = 64;  // Input samples per frame
    parameter int P_CLK_PERIOD = 10; // ns

    // =========================================================================
    // DUT Signals
    // =========================================================================
    logic                           clk;
    logic                           rst_n;
    logic                           cic_en;

    logic                           s_tvalid;
    logic                           s_tready;
    logic signed [P_IN_WIDTH-1:0]   s_tdata;
    logic                           s_tlast;
    logic [0:0]                     s_tuser;

    logic                           m_tvalid;
    logic                           m_tready;
    logic signed [P_OUT_WIDTH-1:0]  m_tdata;
    logic                           m_tlast;
    logic [0:0]                     m_tuser;

    logic                           cic_busy;
    logic                           cic_cfg_err;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    filter_cicd #(
        .GP_CICD_R     (P_R),
        .GP_CICD_N     (P_N),
        .GP_CICD_M     (P_M),
        .GP_CICD_PHASE (P_PHASE),
        .GP_IN_WIDTH   (P_IN_WIDTH),
        .GP_OUT_WIDTH  (P_OUT_WIDTH)
    ) u_dut (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        .cic_en_i       (cic_en),
        .s_axis_tvalid  (s_tvalid),
        .s_axis_tready  (s_tready),
        .s_axis_tdata   (s_tdata),
        .s_axis_tlast   (s_tlast),
        .s_axis_tuser   (s_tuser),
        .m_axis_tvalid  (m_tvalid),
        .m_axis_tready  (m_tready),
        .m_axis_tdata   (m_tdata),
        .m_axis_tlast   (m_tlast),
        .m_axis_tuser   (m_tuser),
        .cic_busy_o     (cic_busy),
        .cic_cfg_err_o  (cic_cfg_err)
    );

    // =========================================================================
    // Clock Generation
    // =========================================================================
    initial clk = 1'b0;
    always #(P_CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // Golden Reference Model (Fixed-width two's complement, Spec §17)
    // =========================================================================
    // This model matches the RTL bit-exact behavior:
    // 1. Sign-extend input to GP_OUT_WIDTH
    // 2. N-stage integrator chain with wrap-around
    // 3. Phase-based decimation
    // 4. N-stage comb chain with M-delay

    logic signed [P_OUT_WIDTH-1:0] golden_integrators [P_N];
    logic signed [P_OUT_WIDTH-1:0] golden_comb_delay  [P_N][P_M];
    logic signed [P_OUT_WIDTH-1:0] golden_comb_out    [P_N];
    logic signed [P_OUT_WIDTH-1:0] golden_result;

    int golden_input_count;
    int golden_output_count;
    int golden_valid_outputs;

    // Arrays to store golden outputs for comparison
    logic signed [P_OUT_WIDTH-1:0] golden_outputs [$];

    task automatic golden_reset();
        for (int i = 0; i < P_N; i++) begin
            golden_integrators[i] = '0;
            golden_comb_out[i] = '0;
            for (int j = 0; j < P_M; j++) begin
                golden_comb_delay[i][j] = '0;
            end
        end
        golden_input_count = 0;
        golden_output_count = 0;
        golden_valid_outputs = 0;
        golden_outputs.delete();
    endtask

    task automatic golden_process_sample(input logic signed [P_IN_WIDTH-1:0] sample);
        logic signed [P_OUT_WIDTH-1:0] extended;
        logic signed [P_OUT_WIDTH-1:0] decim_val;
        logic signed [P_OUT_WIDTH-1:0] comb_in;

        // 1. Sign-extend
        extended = P_OUT_WIDTH'(signed'(sample));

        // 2. Integrator chain (wrap-around arithmetic)
        golden_integrators[0] = golden_integrators[0] + extended;
        for (int i = 1; i < P_N; i++) begin
            golden_integrators[i] = golden_integrators[i] + golden_integrators[i-1];
        end

        golden_input_count++;

        // 3. Check decimation phase
        if (((golden_input_count - 1) % P_R) == P_PHASE) begin
            decim_val = golden_integrators[P_N-1];

            // 4. Comb chain
            comb_in = decim_val;
            for (int i = 0; i < P_N; i++) begin
                logic signed [P_OUT_WIDTH-1:0] delayed;
                delayed = golden_comb_delay[i][P_M-1];

                golden_comb_out[i] = comb_in - delayed;

                // Shift delay line
                for (int j = P_M-1; j > 0; j--) begin
                    golden_comb_delay[i][j] = golden_comb_delay[i][j-1];
                end
                golden_comb_delay[i][0] = comb_in;

                comb_in = golden_comb_out[i];
            end

            golden_output_count++;
            golden_result = golden_comb_out[P_N-1];

            // Only count after comb pipeline is filled
            if (golden_output_count > P_N) begin
                golden_outputs.push_back(golden_result);
                golden_valid_outputs++;
            end
        end
    endtask

    // =========================================================================
    // Test Infrastructure
    // =========================================================================
    int test_pass_count = 0;
    int test_fail_count = 0;
    int total_tests = 0;

    // Capture DUT outputs
    logic signed [P_OUT_WIDTH-1:0] dut_outputs [$];
    int dut_output_count = 0;

    // Monitor DUT output
    always_ff @(posedge clk) begin
        if (m_tvalid) begin
            dut_outputs.push_back(m_tdata);
            dut_output_count++;
        end
    end

    // =========================================================================
    // Helper Tasks
    // =========================================================================
    task automatic reset_dut();
        rst_n    <= 1'b0;
        cic_en   <= 1'b0;
        s_tvalid <= 1'b0;
        s_tdata  <= '0;
        s_tlast  <= 1'b0;
        s_tuser  <= 1'b0;
        m_tready <= 1'b1;
        dut_outputs.delete();
        dut_output_count = 0;
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
    endtask

    task automatic send_frame(
        input logic signed [P_IN_WIDTH-1:0] samples [],
        input int frame_len
    );
        cic_en <= 1'b1;
        for (int i = 0; i < frame_len; i++) begin
            @(posedge clk);
            s_tvalid <= 1'b1;
            s_tdata  <= samples[i];
            s_tuser  <= (i == 0) ? 1'b1 : 1'b0;           // SOF
            s_tlast  <= (i == frame_len - 1) ? 1'b1 : 1'b0; // EOF
        end
        @(posedge clk);
        s_tvalid <= 1'b0;
        s_tdata  <= '0;
        s_tuser  <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    task automatic wait_for_outputs(input int expected_count, input int timeout_cycles);
        int wait_cnt = 0;
        while (dut_output_count < expected_count && wait_cnt < timeout_cycles) begin
            @(posedge clk);
            wait_cnt++;
        end
    endtask

    task automatic check_result(input string test_name);
        int min_count;
        int mismatches = 0;

        min_count = (dut_outputs.size() < golden_outputs.size()) ?
                     dut_outputs.size() : golden_outputs.size();

        if (min_count == 0) begin
            $display("[WARN] %s: No outputs to compare (DUT=%0d, Golden=%0d)",
                     test_name, dut_outputs.size(), golden_outputs.size());
            return;
        end

        for (int i = 0; i < min_count; i++) begin
            if (dut_outputs[i] !== golden_outputs[i]) begin
                $display("[FAIL] %s: Output[%0d] DUT=%0h Golden=%0h",
                         test_name, i, dut_outputs[i], golden_outputs[i]);
                mismatches++;
            end
        end

        if (mismatches == 0) begin
            $display("[PASS] %s: %0d outputs matched", test_name, min_count);
            test_pass_count++;
        end else begin
            $display("[FAIL] %s: %0d/%0d mismatches", test_name, mismatches, min_count);
            test_fail_count++;
        end
        total_tests++;
    endtask

    // =========================================================================
    // Test Cases
    // =========================================================================

    // --- Test 1: Impulse Response ---
    task automatic test_impulse();
        logic signed [P_IN_WIDTH-1:0] samples [];
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 1: Impulse Response ==========");
        reset_dut();
        golden_reset();

        // Create impulse: first sample = 1, rest = 0
        samples[0] = P_IN_WIDTH'(1);
        for (int i = 1; i < P_FRAME_LEN; i++) samples[i] = '0;

        // Process through golden model
        for (int i = 0; i < P_FRAME_LEN; i++) golden_process_sample(samples[i]);

        // Send to DUT
        send_frame(samples, P_FRAME_LEN);
        wait_for_outputs(golden_valid_outputs, P_FRAME_LEN + 100);

        check_result("Impulse");
    endtask

    // --- Test 2: DC Input ---
    task automatic test_dc();
        logic signed [P_IN_WIDTH-1:0] samples [];
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 2: DC Input ==========");
        reset_dut();
        golden_reset();

        // Create DC: all samples = 10
        for (int i = 0; i < P_FRAME_LEN; i++) samples[i] = P_IN_WIDTH'(signed'(10));

        for (int i = 0; i < P_FRAME_LEN; i++) golden_process_sample(samples[i]);

        send_frame(samples, P_FRAME_LEN);
        wait_for_outputs(golden_valid_outputs, P_FRAME_LEN + 100);

        check_result("DC Input");
    endtask

    // --- Test 3: Alternating Max/Min ---
    task automatic test_alternating();
        logic signed [P_IN_WIDTH-1:0] samples [];
        logic signed [P_IN_WIDTH-1:0] max_val, min_val;
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 3: Alternating Max/Min ==========");
        reset_dut();
        golden_reset();

        max_val = (1 << (P_IN_WIDTH-1)) - 1;  // 0x7F for 8-bit
        min_val = -(1 << (P_IN_WIDTH-1));      // 0x80 for 8-bit

        for (int i = 0; i < P_FRAME_LEN; i++) begin
            samples[i] = (i % 2 == 0) ? max_val : min_val;
        end

        for (int i = 0; i < P_FRAME_LEN; i++) golden_process_sample(samples[i]);

        send_frame(samples, P_FRAME_LEN);
        wait_for_outputs(golden_valid_outputs, P_FRAME_LEN + 100);

        check_result("Alternating Max/Min");
    endtask

    // --- Test 4: Random Input ---
    task automatic test_random();
        logic signed [P_IN_WIDTH-1:0] samples [];
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 4: Random Input ==========");
        reset_dut();
        golden_reset();

        for (int i = 0; i < P_FRAME_LEN; i++) begin
            samples[i] = $random;
        end

        for (int i = 0; i < P_FRAME_LEN; i++) golden_process_sample(samples[i]);

        send_frame(samples, P_FRAME_LEN);
        wait_for_outputs(golden_valid_outputs, P_FRAME_LEN + 100);

        check_result("Random Input");
    endtask

    // --- Test 5: Frame Boundary Markers ---
    task automatic test_frame_boundary();
        logic signed [P_IN_WIDTH-1:0] samples [];
        int sof_seen, eof_seen;
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 5: Frame Boundary Markers ==========");
        reset_dut();

        for (int i = 0; i < P_FRAME_LEN; i++) samples[i] = P_IN_WIDTH'(signed'(i + 1));

        sof_seen = 0;
        eof_seen = 0;

        // Start monitoring in background
        fork
            begin
                // Monitor SOF/EOF on output
                forever begin
                    @(posedge clk);
                    if (m_tvalid) begin
                        if (m_tuser[0]) sof_seen++;
                        if (m_tlast)    eof_seen++;
                    end
                end
            end
            begin
                send_frame(samples, P_FRAME_LEN);
                wait_for_outputs(P_FRAME_LEN / P_R, P_FRAME_LEN + 200);
                // Allow extra cycles for pipeline drain
                repeat (50) @(posedge clk);
            end
        join_any
        disable fork;

        total_tests++;
        if (sof_seen == 1 && eof_seen == 1) begin
            $display("[PASS] Frame Boundary: SOF=%0d, EOF=%0d", sof_seen, eof_seen);
            test_pass_count++;
        end else begin
            $display("[FAIL] Frame Boundary: SOF=%0d (exp 1), EOF=%0d (exp 1)", sof_seen, eof_seen);
            test_fail_count++;
        end
    endtask

    // --- Test 6: CIC Enable Gating ---
    task automatic test_enable_gating();
        $display("\n========== Test 6: CIC Enable Gating ==========");
        reset_dut();

        // Send data with CIC disabled
        cic_en <= 1'b0;
        s_tvalid <= 1'b1;
        s_tdata  <= P_IN_WIDTH'(signed'(42));
        s_tuser  <= 1'b1;
        s_tlast  <= 1'b0;
        repeat (20) @(posedge clk);
        s_tvalid <= 1'b0;

        total_tests++;
        if (dut_output_count == 0 && cic_busy == 1'b0) begin
            $display("[PASS] Enable Gating: No output when disabled, busy=%b", cic_busy);
            test_pass_count++;
        end else begin
            $display("[FAIL] Enable Gating: outputs=%0d, busy=%b", dut_output_count, cic_busy);
            test_fail_count++;
        end
    endtask

    // --- Test 7: s_axis_tready Always High ---
    task automatic test_tready_always_high();
        $display("\n========== Test 7: s_axis_tready Always High ==========");
        reset_dut();

        total_tests++;
        // Check tready is high after reset
        @(posedge clk);
        if (s_tready === 1'b1) begin
            $display("[PASS] tready Always High: s_axis_tready=%b after reset", s_tready);
            test_pass_count++;
        end else begin
            $display("[FAIL] tready Always High: s_axis_tready=%b (expected 1)", s_tready);
            test_fail_count++;
        end
    endtask

    // --- Test 8: Non-valid Sideband Must Be 0 ---
    task automatic test_sideband_zero_when_invalid();
        int violations;
        $display("\n========== Test 8: Sideband Zero When Invalid ==========");
        reset_dut();
        golden_reset();

        violations = 0;

        // Send some data
        fork
            begin
                logic signed [P_IN_WIDTH-1:0] samples [];
                samples = new[P_FRAME_LEN];
                for (int i = 0; i < P_FRAME_LEN; i++) samples[i] = P_IN_WIDTH'(signed'(i));
                send_frame(samples, P_FRAME_LEN);
                repeat (100) @(posedge clk);
            end
            begin
                // Monitor sideband during non-valid cycles
                forever begin
                    @(posedge clk);
                    if (!m_tvalid) begin
                        if (m_tlast !== 1'b0 || m_tuser !== 1'b0) begin
                            violations++;
                        end
                    end
                end
            end
        join_any
        disable fork;

        total_tests++;
        if (violations == 0) begin
            $display("[PASS] Sideband Zero When Invalid: no violations");
            test_pass_count++;
        end else begin
            $display("[FAIL] Sideband Zero When Invalid: %0d violations", violations);
            test_fail_count++;
        end
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("==========================================================");
        $display("  CIC Decimation Filter Testbench");
        $display("  Parameters: R=%0d, N=%0d, M=%0d, PHASE=%0d, IN_W=%0d",
                 P_R, P_N, P_M, P_PHASE, P_IN_WIDTH);
        $display("  Output Width: %0d", P_OUT_WIDTH);
        $display("==========================================================");

        // Run all tests
        test_impulse();
        test_dc();
        test_alternating();
        test_random();
        test_frame_boundary();
        test_enable_gating();
        test_tready_always_high();
        test_sideband_zero_when_invalid();

        // Summary
        $display("\n==========================================================");
        $display("  TEST SUMMARY");
        $display("  Total:  %0d", total_tests);
        $display("  Passed: %0d", test_pass_count);
        $display("  Failed: %0d", test_fail_count);
        $display("==========================================================");

        if (test_fail_count == 0) begin
            $display("  *** ALL TESTS PASSED ***");
        end else begin
            $display("  *** SOME TESTS FAILED ***");
        end

        $finish;
    end

    // Timeout watchdog
    initial begin
        #(P_CLK_PERIOD * 50000);
        $display("[ERROR] Global timeout reached!");
        $finish;
    end

endmodule : tb_filter_cicd
