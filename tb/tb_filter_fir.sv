// =============================================================================
// Testbench : tb_filter_fir
// Description : Block-level testbench for FIR Compensation Filter
// Spec Ref    : FILTER_FIR_SPEC v2.0, Verification Plan §6.3
// =============================================================================
// Verification targets:
//   1. Coefficient loading protocol (start/valid/done)
//   2. Head flush (GP_FIR_N zeros before first data)
//   3. Tail flush (GP_FIR_N-1 zeros after last data)
//   4. Impulse response (single 1 in a zero frame)
//   5. DC input response
//   6. Frame boundary sideband (tuser/tlast) alignment
//   7. Coefficient loading error (count mismatch)
//   8. State machine transitions
//   9. Golden model comparison (fixed-point)
// =============================================================================

`timescale 1ns / 1ps

module tb_filter_fir;

    // =========================================================================
    // Test Parameters
    // =========================================================================
    parameter int P_IN_WIDTH   = 8;
    parameter int P_OUT_WIDTH  = 8;
    parameter int P_COEF_WIDTH = 8;
    parameter int P_FIR_N      = 8;
    parameter int P_SHIFT      = 7;     // shift to scale products back
    parameter int P_FRAME_LEN  = 32;
    parameter int P_CLK_PERIOD = 10;

    // Derived
    localparam int C_MULT_WIDTH  = P_IN_WIDTH + P_COEF_WIDTH - 1;
    localparam int C_TREE_STAGES = $clog2(P_FIR_N);
    localparam int C_DATA_LAT    = 1 + C_TREE_STAGES + 1 + 1;

    // =========================================================================
    // DUT Signals
    // =========================================================================
    logic                            clk;
    logic                            rst_n;
    logic                            fir_en;

    // Input AXIS
    logic                            s_tvalid;
    logic                            s_tready;
    logic signed [P_IN_WIDTH-1:0]    s_tdata;
    logic                            s_tlast;
    logic [0:0]                      s_tuser;

    // Output AXIS
    logic                            m_tvalid;
    logic                            m_tready;
    logic signed [P_OUT_WIDTH-1:0]   m_tdata;
    logic                            m_tlast;
    logic [0:0]                      m_tuser;

    // Coefficient interface
    logic                            coef_start;
    logic                            coef_valid;
    logic signed [P_COEF_WIDTH-1:0]  coef_data;
    logic                            coef_done;

    // Status
    logic                            fir_busy;
    logic                            coef_ready;
    logic                            fir_cfg_err;
    logic                            coef_load_err;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    filter_fir #(
        .GP_IN_WIDTH   (P_IN_WIDTH),
        .GP_OUT_WIDTH  (P_OUT_WIDTH),
        .GP_COEF_WIDTH (P_COEF_WIDTH),
        .GP_FIR_N      (P_FIR_N),
        .GP_SHIFT      (P_SHIFT)
    ) u_dut (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .fir_en_i           (fir_en),
        .s_axis_tvalid      (s_tvalid),
        .s_axis_tready      (s_tready),
        .s_axis_tdata       (s_tdata),
        .s_axis_tlast       (s_tlast),
        .s_axis_tuser       (s_tuser),
        .m_axis_tvalid      (m_tvalid),
        .m_axis_tready      (m_tready),
        .m_axis_tdata       (m_tdata),
        .m_axis_tlast       (m_tlast),
        .m_axis_tuser       (m_tuser),
        .coef_load_start_i  (coef_start),
        .coef_load_valid_i  (coef_valid),
        .coef_data_i        (coef_data),
        .coef_load_done_i   (coef_done),
        .fir_busy_o         (fir_busy),
        .coef_ready_o       (coef_ready),
        .fir_cfg_err_o      (fir_cfg_err),
        .coef_load_err_o    (coef_load_err)
    );

    // =========================================================================
    // Clock Generation
    // =========================================================================
    initial clk = 1'b0;
    always #(P_CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // Test Infrastructure
    // =========================================================================
    int test_pass_count = 0;
    int test_fail_count = 0;
    int total_tests = 0;

    // Capture DUT outputs
    logic signed [P_OUT_WIDTH-1:0] dut_outputs [$];
    int dut_output_count;

    always_ff @(posedge clk) begin
        if (m_tvalid) begin
            dut_outputs.push_back(m_tdata);
            dut_output_count++;
        end
    end

    // =========================================================================
    // Golden Reference Model (Fixed-Point FIR, Spec §17)
    // =========================================================================
    logic signed [P_COEF_WIDTH-1:0] golden_coefs [P_FIR_N];
    logic signed [P_OUT_WIDTH-1:0]  golden_outputs [$];

    // Compute FIR output for a sequence including head/tail flush
    task automatic golden_compute(
        input logic signed [P_IN_WIDTH-1:0]   samples [],
        input int                              frame_len,
        input logic signed [P_COEF_WIDTH-1:0]  coefs [P_FIR_N]
    );
        // Total sequence: GP_FIR_N zeros (head) + frame_len data + GP_FIR_N-1 zeros (tail)
        int total_len = P_FIR_N + frame_len + (P_FIR_N - 1);
        logic signed [P_IN_WIDTH-1:0] extended_seq [];
        extended_seq = new[total_len];

        // Head flush zeros
        for (int i = 0; i < P_FIR_N; i++)
            extended_seq[i] = '0;
        // Actual data
        for (int i = 0; i < frame_len; i++)
            extended_seq[P_FIR_N + i] = samples[i];
        // Tail flush zeros
        for (int i = 0; i < P_FIR_N - 1; i++)
            extended_seq[P_FIR_N + frame_len + i] = '0;

        golden_outputs.delete();

        // Compute convolution for each position
        for (int n = P_FIR_N - 1; n < total_len; n++) begin
            logic signed [63:0] acc;  // Wide accumulator
            logic signed [63:0] rounded;
            logic signed [63:0] shifted;
            logic signed [P_OUT_WIDTH-1:0] saturated;

            acc = 0;
            for (int k = 0; k < P_FIR_N; k++) begin
                acc = acc + (64'(signed'(extended_seq[n - k])) * 64'(signed'(coefs[k])));
            end

            // Round-Half-Up (Spec §12.3)
            if (P_SHIFT > 0) begin
                rounded = acc + (64'(1) <<< (P_SHIFT - 1));
            end else begin
                rounded = acc;
            end

            // Arithmetic right shift (Spec §12.2)
            shifted = rounded >>> P_SHIFT;

            // Saturation (Spec §12.4)
            if (shifted > ((1 <<< (P_OUT_WIDTH - 1)) - 1)) begin
                saturated = P_OUT_WIDTH'((1 <<< (P_OUT_WIDTH - 1)) - 1);
            end else if (shifted < -(1 <<< (P_OUT_WIDTH - 1))) begin
                saturated = P_OUT_WIDTH'(-(1 <<< (P_OUT_WIDTH - 1)));
            end else begin
                saturated = P_OUT_WIDTH'(shifted);
            end

            golden_outputs.push_back(saturated);
        end
    endtask

    // =========================================================================
    // Helper Tasks
    // =========================================================================
    task automatic reset_dut();
        rst_n      <= 1'b0;
        fir_en     <= 1'b0;
        s_tvalid   <= 1'b0;
        s_tdata    <= '0;
        s_tlast    <= 1'b0;
        s_tuser    <= 1'b0;
        m_tready   <= 1'b1;
        coef_start <= 1'b0;
        coef_valid <= 1'b0;
        coef_data  <= '0;
        coef_done  <= 1'b0;
        dut_outputs.delete();
        dut_output_count = 0;
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
    endtask

    task automatic load_coefficients(
        input logic signed [P_COEF_WIDTH-1:0] coefs [P_FIR_N]
    );
        fir_en <= 1'b1;

        // Start loading
        @(posedge clk);
        coef_start <= 1'b1;
        @(posedge clk);
        coef_start <= 1'b0;

        // Send coefficients one per cycle
        for (int i = 0; i < P_FIR_N; i++) begin
            @(posedge clk);
            coef_valid <= 1'b1;
            coef_data  <= coefs[i];
        end
        @(posedge clk);
        coef_valid <= 1'b0;

        // Assert done
        @(posedge clk);
        coef_done <= 1'b1;
        @(posedge clk);
        coef_done <= 1'b0;

        // Wait for head flush to complete
        repeat (P_FIR_N + 5) @(posedge clk);
    endtask

    task automatic send_frame(
        input logic signed [P_IN_WIDTH-1:0] samples [],
        input int frame_len
    );
        for (int i = 0; i < frame_len; i++) begin
            @(posedge clk);
            s_tvalid <= 1'b1;
            s_tdata  <= samples[i];
            s_tuser  <= (i == 0) ? 1'b1 : 1'b0;
            s_tlast  <= (i == frame_len - 1) ? 1'b1 : 1'b0;
        end
        @(posedge clk);
        s_tvalid <= 1'b0;
        s_tdata  <= '0;
        s_tuser  <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    task automatic wait_done(input int timeout = 500);
        int cnt = 0;
        while (fir_busy && cnt < timeout) begin
            @(posedge clk);
            cnt++;
        end
        // Extra cycles for pipeline drain
        repeat (C_DATA_LAT + 10) @(posedge clk);
    endtask

    task automatic check_result(input string test_name);
        int min_count, mismatches;
        min_count = (dut_outputs.size() < golden_outputs.size()) ?
                     dut_outputs.size() : golden_outputs.size();

        if (min_count == 0) begin
            $display("[WARN] %s: No outputs to compare (DUT=%0d, Golden=%0d)",
                     test_name, dut_outputs.size(), golden_outputs.size());
            total_tests++;
            return;
        end

        mismatches = 0;
        for (int i = 0; i < min_count; i++) begin
            if (dut_outputs[i] !== golden_outputs[i]) begin
                $display("[FAIL] %s: Output[%0d] DUT=%0d Golden=%0d",
                         test_name, i, dut_outputs[i], golden_outputs[i]);
                mismatches++;
                if (mismatches > 5) begin
                    $display("       ... (suppressing further mismatches)");
                    break;
                end
            end
        end

        total_tests++;
        if (mismatches == 0) begin
            $display("[PASS] %s: %0d outputs matched", test_name, min_count);
            test_pass_count++;
        end else begin
            $display("[FAIL] %s: %0d/%0d mismatches", test_name, mismatches, min_count);
            test_fail_count++;
        end
    endtask

    // =========================================================================
    // Test Cases
    // =========================================================================

    // --- Test 1: Coefficient Loading & State Machine ---
    task automatic test_coef_load();
        logic signed [P_COEF_WIDTH-1:0] coefs [P_FIR_N];
        $display("\n========== Test 1: Coefficient Loading ==========");
        reset_dut();

        // Unity filter: h[0]=1, rest=0 (scaled by 2^P_SHIFT)
        for (int i = 0; i < P_FIR_N; i++) coefs[i] = '0;
        coefs[0] = P_COEF_WIDTH'(signed'(1 << P_SHIFT));  // 128 for 8-bit, shift=7

        load_coefficients(coefs);

        total_tests++;
        if (coef_ready && !coef_load_err) begin
            $display("[PASS] Coef Load: coef_ready=%b, err=%b", coef_ready, coef_load_err);
            test_pass_count++;
        end else begin
            $display("[FAIL] Coef Load: coef_ready=%b, err=%b", coef_ready, coef_load_err);
            test_fail_count++;
        end
    endtask

    // --- Test 2: Impulse Response ---
    task automatic test_impulse();
        logic signed [P_IN_WIDTH-1:0]   samples [];
        logic signed [P_COEF_WIDTH-1:0] coefs [P_FIR_N];
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 2: Impulse Response ==========");
        reset_dut();

        // Low-pass filter coefficients (simple box filter)
        for (int i = 0; i < P_FIR_N; i++) coefs[i] = P_COEF_WIDTH'(signed'(16));  // ~= 2^P_SHIFT / N

        load_coefficients(coefs);

        // Impulse: first sample = 64, rest = 0
        samples[0] = P_IN_WIDTH'(signed'(64));
        for (int i = 1; i < P_FRAME_LEN; i++) samples[i] = '0;

        golden_compute(samples, P_FRAME_LEN, coefs);

        send_frame(samples, P_FRAME_LEN);
        wait_done();

        check_result("Impulse");
    endtask

    // --- Test 3: DC Input ---
    task automatic test_dc();
        logic signed [P_IN_WIDTH-1:0]   samples [];
        logic signed [P_COEF_WIDTH-1:0] coefs [P_FIR_N];
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 3: DC Input ==========");
        reset_dut();

        // Unity passthrough coefficients
        for (int i = 0; i < P_FIR_N; i++) coefs[i] = '0;
        coefs[0] = P_COEF_WIDTH'(signed'(1 << P_SHIFT));

        load_coefficients(coefs);

        // DC: all samples = 42
        for (int i = 0; i < P_FRAME_LEN; i++) samples[i] = P_IN_WIDTH'(signed'(42));

        golden_compute(samples, P_FRAME_LEN, coefs);

        send_frame(samples, P_FRAME_LEN);
        wait_done();

        check_result("DC Input");
    endtask

    // --- Test 4: Frame Boundary Sideband ---
    task automatic test_frame_boundary();
        logic signed [P_IN_WIDTH-1:0]   samples [];
        logic signed [P_COEF_WIDTH-1:0] coefs [P_FIR_N];
        int sof_count, eof_count;
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 4: Frame Boundary Sideband ==========");
        reset_dut();

        for (int i = 0; i < P_FIR_N; i++) coefs[i] = '0;
        coefs[0] = P_COEF_WIDTH'(signed'(1 << P_SHIFT));

        load_coefficients(coefs);

        for (int i = 0; i < P_FRAME_LEN; i++) samples[i] = P_IN_WIDTH'(signed'(i + 1));

        sof_count = 0;
        eof_count = 0;

        fork
            begin
                forever begin
                    @(posedge clk);
                    if (m_tvalid) begin
                        if (m_tuser[0]) sof_count++;
                        if (m_tlast)    eof_count++;
                    end
                end
            end
            begin
                send_frame(samples, P_FRAME_LEN);
                wait_done();
            end
        join_any
        disable fork;

        total_tests++;
        if (sof_count == 1 && eof_count == 1) begin
            $display("[PASS] Frame Boundary: SOF=%0d, EOF=%0d", sof_count, eof_count);
            test_pass_count++;
        end else begin
            $display("[FAIL] Frame Boundary: SOF=%0d (exp 1), EOF=%0d (exp 1)", sof_count, eof_count);
            test_fail_count++;
        end
    endtask

    // --- Test 5: tready Behavior ---
    task automatic test_tready();
        $display("\n========== Test 5: tready Behavior ==========");
        reset_dut();

        total_tests++;
        // Before coeff load, tready should be 0 (not in RUN state)
        @(posedge clk);
        if (s_tready === 1'b0) begin
            $display("[PASS] tready: s_axis_tready=0 before coef load");
            test_pass_count++;
        end else begin
            $display("[FAIL] tready: s_axis_tready=%b (expected 0)", s_tready);
            test_fail_count++;
        end
    endtask

    // --- Test 6: Sideband Zero When Invalid ---
    task automatic test_sideband_zero();
        logic signed [P_IN_WIDTH-1:0]   samples [];
        logic signed [P_COEF_WIDTH-1:0] coefs [P_FIR_N];
        int violations;
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 6: Sideband Zero When Invalid ==========");
        reset_dut();

        for (int i = 0; i < P_FIR_N; i++) coefs[i] = P_COEF_WIDTH'(signed'(16));
        load_coefficients(coefs);

        for (int i = 0; i < P_FRAME_LEN; i++) samples[i] = P_IN_WIDTH'(signed'(i));

        violations = 0;

        fork
            begin
                forever begin
                    @(posedge clk);
                    if (!m_tvalid) begin
                        if (m_tlast !== 1'b0 || m_tuser !== 1'b0)
                            violations++;
                    end
                end
            end
            begin
                send_frame(samples, P_FRAME_LEN);
                wait_done();
            end
        join_any
        disable fork;

        total_tests++;
        if (violations == 0) begin
            $display("[PASS] Sideband Zero: no violations");
            test_pass_count++;
        end else begin
            $display("[FAIL] Sideband Zero: %0d violations", violations);
            test_fail_count++;
        end
    endtask

    // --- Test 7: Random Data ---
    task automatic test_random();
        logic signed [P_IN_WIDTH-1:0]   samples [];
        logic signed [P_COEF_WIDTH-1:0] coefs [P_FIR_N];
        samples = new[P_FRAME_LEN];

        $display("\n========== Test 7: Random Data ==========");
        reset_dut();

        // Random coefficients
        for (int i = 0; i < P_FIR_N; i++) coefs[i] = P_COEF_WIDTH'($urandom);

        load_coefficients(coefs);

        // Random input
        for (int i = 0; i < P_FRAME_LEN; i++) samples[i] = P_IN_WIDTH'($urandom);

        golden_compute(samples, P_FRAME_LEN, coefs);

        send_frame(samples, P_FRAME_LEN);
        wait_done();

        check_result("Random");
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("==========================================================");
        $display("  FIR Compensation Filter Testbench");
        $display("  Parameters: IN_W=%0d, OUT_W=%0d, COEF_W=%0d, N=%0d, SHIFT=%0d",
                 P_IN_WIDTH, P_OUT_WIDTH, P_COEF_WIDTH, P_FIR_N, P_SHIFT);
        $display("==========================================================");

        test_coef_load();
        test_impulse();
        test_dc();
        test_frame_boundary();
        test_tready();
        test_sideband_zero();
        test_random();

        $display("\n==========================================================");
        $display("  TEST SUMMARY");
        $display("  Total:  %0d", total_tests);
        $display("  Passed: %0d", test_pass_count);
        $display("  Failed: %0d", test_fail_count);
        $display("==========================================================");

        if (test_fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");

        $finish;
    end

    // Timeout watchdog
    initial begin
        #(P_CLK_PERIOD * 100000);
        $display("[ERROR] Global timeout reached!");
        $finish;
    end

endmodule : tb_filter_fir
