// =============================================================================
// Module : filter_cicd
// Description : CIC (Cascaded Integrator-Comb) Decimation Filter
// Spec Ref    : FILTER_CIC_SPEC v2.0
// =============================================================================
// Design Notes:
//   - Hogenauer structure: N integrators → R:1 downsampler → N combs
//   - Zero-DSP: uses only adders, subtractors, registers, and counters
//   - Continuous Streaming: s_axis_tready is always 1 (no backpressure)
//   - Full-Precision: internal path uses GP_OUT_WIDTH throughout
//   - Two's complement natural wrap-around (no saturation in integrators)
//   - Clock-Enable based decimation (no derived clocks)
// =============================================================================
// Naming conventions:
//   _d : delay    _i : input    _o : output
//   GP_ : global parameter    C_ : constant
//   w_ : combinational    r_ : register
// =============================================================================

module filter_cicd #(
    parameter int GP_CICD_R     = 64,  // Decimation factor R (2~4096)
    parameter int GP_CICD_N     = 5,   // Filter order N (2~8)
    parameter int GP_CICD_M     = 1,   // Differential delay M (1~2)
    parameter int GP_CICD_PHASE = 0,   // Output phase (0~R-1)
    parameter int GP_IN_WIDTH   = 8,   // Input data bit-width
    parameter int GP_OUT_WIDTH  = GP_IN_WIDTH + GP_CICD_N * $clog2(GP_CICD_M * GP_CICD_R)
) (
    input  logic                            clk_i,
    input  logic                            rst_ni,

    // Control interface (Spec §10)
    input  logic                            cic_en_i,       // Module enable (§10.1)

    // AXI-Stream input interface (Spec §6.2)
    input  logic                            s_axis_tvalid,
    output logic                            s_axis_tready,
    input  logic signed [GP_IN_WIDTH-1:0]   s_axis_tdata,
    input  logic                            s_axis_tlast,   // Frame end marker (§9.3)
    input  logic [0:0]                      s_axis_tuser,   // Frame start marker (§9.2)

    // AXI-Stream output interface (Spec §6.3)
    output logic                            m_axis_tvalid,
    input  logic                            m_axis_tready,  // Not used internally (§6.3.1)
    output logic signed [GP_OUT_WIDTH-1:0]  m_axis_tdata,
    output logic                            m_axis_tlast,   // Output frame end (§9.4)
    output logic [0:0]                      m_axis_tuser,   // Output frame start (§9.4)

    // Status interface (Spec §10.2, §10.3)
    output logic                            cic_busy_o,     // Processing active (§10.2)
    output logic                            cic_cfg_err_o   // Parameter illegal (§10.3)
);

    // =========================================================================
    // Internal Constants
    // =========================================================================
    localparam int C_EX_WIDTH = GP_OUT_WIDTH - GP_IN_WIDTH;

    // =========================================================================
    // Parameter Validation (Spec §5.2)
    // =========================================================================
    // Runtime parameter checks - cic_cfg_err_o stays high if params are illegal
    always_comb begin
        cic_cfg_err_o = 1'b0;
        if (GP_CICD_R < 2)              cic_cfg_err_o = 1'b1;  // R must be >= 2
        if (GP_CICD_N < 2)              cic_cfg_err_o = 1'b1;  // N must be >= 2
        if (GP_CICD_M < 1)              cic_cfg_err_o = 1'b1;  // M must be >= 1
        if (GP_CICD_PHASE >= GP_CICD_R) cic_cfg_err_o = 1'b1;  // PHASE must be < R
    end

    // =========================================================================
    // Input Ready - Always accept (Spec §6.2.1: tready fixed to 1)
    // =========================================================================
    assign s_axis_tready = 1'b1;

    // =========================================================================
    // Effective input valid: respects cic_en_i (Spec §10.1)
    // When cic_en_i=0, module does not accept new inputs
    // =========================================================================
    logic w_input_valid;
    assign w_input_valid = s_axis_tvalid & cic_en_i;

    // =========================================================================
    // Frame Boundary Tracking (Spec §9)
    // =========================================================================
    logic r_frame_active;       // Internal frame active flag
    logic r_frame_first_out;    // First output of current frame (for tuser)
    logic r_input_last_seen;    // Records that input tlast was seen
    logic r_last_decim_pending; // Tracks whether last decimated output is pending

    // Frame start detection (Spec §9.2)
    // Frame end detection (Spec §9.3)
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_frame_active    <= 1'b0;
            r_frame_first_out <= 1'b0;
            r_input_last_seen <= 1'b0;
        end else begin
            // Frame start: set active, prepare first output marker
            if (w_input_valid && s_axis_tuser[0]) begin
                r_frame_active    <= 1'b1;
                r_frame_first_out <= 1'b1;  // Next valid output gets tuser
                r_input_last_seen <= 1'b0;
            end

            // Frame end: record that input has ended
            if (w_input_valid && s_axis_tlast) begin
                r_input_last_seen <= 1'b1;
            end

            // Clear first-output flag after first valid output is emitted
            if (m_axis_tvalid && r_frame_first_out) begin
                r_frame_first_out <= 1'b0;
            end

            // Frame fully complete: last decimated output has been emitted
            if (m_axis_tvalid && r_last_decim_pending) begin
                r_frame_active    <= 1'b0;
                r_input_last_seen <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Busy Status (Spec §10.2)
    // =========================================================================
    assign cic_busy_o = r_frame_active;

    // =========================================================================
    // Ring Counter (Decimation Phase Counter)
    // =========================================================================
    logic [GP_CICD_R-1:0] r_ring_cnter;
    always_ff @(posedge clk_i or negedge rst_ni) begin : r_ring_cnter_ff
        if (!rst_ni) begin
            r_ring_cnter <= GP_CICD_R'(1);
        end else if (w_input_valid) begin
            r_ring_cnter[0]              <= r_ring_cnter[GP_CICD_R-1];
            r_ring_cnter[GP_CICD_R-1:1]  <= r_ring_cnter[GP_CICD_R-2:0];
        end
    end

    // =========================================================================
    // Integrator Chain (Spec §7.1)
    // N stages, each GP_OUT_WIDTH wide, natural wrap-around (Spec §8.4)
    // =========================================================================
    logic signed [GP_OUT_WIDTH-1:0] w_data_ex;
    logic signed [GP_OUT_WIDTH-1:0] w_in_add [GP_CICD_N];

    // Sign extension (Spec §8.1)
    assign w_data_ex = {{C_EX_WIDTH{s_axis_tdata[GP_IN_WIDTH-1]}}, s_axis_tdata};

    generate
        for (genvar i = 0; i < GP_CICD_N; i++) begin : gen_integrators
            if (i == 0) begin : gen_int_first
                accumulator #(
                    .GP_DATA_WIDTH(GP_OUT_WIDTH)
                ) u_integrator (
                    .clk_i  (clk_i),
                    .rst_ni (rst_ni),
                    .ena_i  (w_input_valid),
                    .data_i (w_data_ex),
                    .data_o (w_in_add[0])
                );
            end else begin : gen_int_chain
                accumulator #(
                    .GP_DATA_WIDTH(GP_OUT_WIDTH)
                ) u_integrator (
                    .clk_i  (clk_i),
                    .rst_ni (rst_ni),
                    .ena_i  (w_input_valid),
                    .data_i (w_in_add[i-1]),
                    .data_o (w_in_add[i])
                );
            end
        end
    endgenerate

    // =========================================================================
    // Downsampler (Spec §7.2)
    // Phase counter generates w_sclk pulse every R valid inputs
    // =========================================================================
    logic w_sclk;
    logic [GP_OUT_WIDTH-1:0] r_downsample_out;

    assign w_sclk = r_ring_cnter[GP_CICD_PHASE] & w_input_valid;

    dff #(
        .GP_DATA_WIDTH(GP_OUT_WIDTH)
    ) u_downsample (
        .rst_ni (rst_ni),
        .ena_i  (w_sclk),
        .clk_i  (clk_i),
        .data_i (w_in_add[GP_CICD_N-1]),
        .data_o (r_downsample_out)
    );

    // =========================================================================
    // Track whether current decimation pulse is the last one in the frame
    // This requires knowing if tlast was seen AND the ring counter wraps
    // =========================================================================
    // Record input sample count at which tlast was seen, to determine
    // which decimation pulse is the last one
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_last_decim_pending <= 1'b0;
        end else begin
            // If input last was seen and we get a decimation pulse,
            // the current decimation is the last one for this frame
            if (w_sclk && r_input_last_seen) begin
                r_last_decim_pending <= 1'b1;
            end
            // Clear after output is emitted with tlast
            if (m_axis_tvalid && r_last_decim_pending) begin
                r_last_decim_pending <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Comb Chain (Spec §7.3)
    // N stages, differential delay M, CE-based (no derived clock)
    // =========================================================================
    logic [GP_OUT_WIDTH-1:0] w_comb_data [GP_CICD_N+1];
    logic [GP_CICD_N-1:0]   w_comb_init_done;

    assign w_comb_data[0] = r_downsample_out;

    generate
        for (genvar i = 0; i < GP_CICD_N; i++) begin : g_comb_stages
            comb_stage #(
                .GP_DATA_WIDTH(GP_OUT_WIDTH),
                .GP_DELAY_M   (GP_CICD_M)
            ) u_comb (
                .clk_i       (clk_i),
                .rst_ni      (rst_ni),
                .ena_i       (w_sclk),
                .data_i      (w_comb_data[i]),
                .data_o      (w_comb_data[i+1]),
                .init_done_o (w_comb_init_done[i])
            );
        end
    endgenerate

    // =========================================================================
    // Output Data (Spec §8.5: CIC does not do final scaling)
    // =========================================================================
    assign m_axis_tdata = w_comb_data[GP_CICD_N];

    // =========================================================================
    // Valid Signal Pipeline Alignment
    // N comb stages add N cycles of latency; w_sclk_d tracks pipeline fill
    // =========================================================================
    logic [GP_CICD_N-1:0] w_sclk_d;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            w_sclk_d <= '0;
        end else if (w_sclk) begin
            w_sclk_d <= {w_sclk_d[GP_CICD_N-2:0], 1'b1};
        end
    end

    // =========================================================================
    // Output Valid Generation
    // =========================================================================
    logic w_output_valid_raw;
    assign w_output_valid_raw = w_sclk && w_comb_init_done[GP_CICD_N-1] && w_sclk_d[GP_CICD_N-1];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            m_axis_tvalid <= 1'b0;
        end else begin
            m_axis_tvalid <= w_output_valid_raw;
        end
    end

    // =========================================================================
    // Output Frame Boundary Sideband (Spec §9.4)
    //   - m_axis_tuser[0]=1 on first valid output of frame
    //   - m_axis_tlast=1 on last valid output of frame
    //   - Both must be 0 when m_axis_tvalid=0 (Spec §6.3.2)
    // =========================================================================
    // Pipeline the frame markers through the same latency as data
    // The comb chain adds N pipeline stages; valid is delayed 1 more cycle
    // Total sideband delay = N + 1 (same as data-to-valid alignment)
    localparam int C_SIDEBAND_DELAY = GP_CICD_N + 1;

    // SOF (Start of Frame) pipeline
    logic [C_SIDEBAND_DELAY-1:0] r_sof_pipe;
    // EOF (End of Frame) pipeline
    logic [C_SIDEBAND_DELAY-1:0] r_eof_pipe;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_sof_pipe <= '0;
            r_eof_pipe <= '0;
        end else if (w_sclk) begin
            // Push SOF marker: first decimation pulse after frame start
            r_sof_pipe <= {r_sof_pipe[C_SIDEBAND_DELAY-2:0], r_frame_first_out};
            // Push EOF marker: decimation pulse that is the last in the frame
            r_eof_pipe <= {r_eof_pipe[C_SIDEBAND_DELAY-2:0], r_input_last_seen};
        end
    end

    // Output sideband - gated by m_axis_tvalid (Spec §6.3.2)
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            m_axis_tuser <= 1'b0;
            m_axis_tlast <= 1'b0;
        end else begin
            if (w_output_valid_raw) begin
                m_axis_tuser[0] <= r_sof_pipe[C_SIDEBAND_DELAY-1];
                m_axis_tlast    <= r_eof_pipe[C_SIDEBAND_DELAY-1];
            end else begin
                // Non-valid cycles: sideband must be 0 (Spec §6.3.2)
                m_axis_tuser <= 1'b0;
                m_axis_tlast <= 1'b0;
            end
        end
    end

endmodule : filter_cicd
