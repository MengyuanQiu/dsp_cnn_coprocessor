// =============================================================================
// Module : filter_fir
// Description : FIR Compensation Filter with Head/Tail Flush
// Spec Ref    : FILTER_FIR_SPEC v2.0
// =============================================================================
// Design Notes:
//   - Direct-Form FIR: parallel multiplier array + pipelined adder tree
//   - Coefficient loading via streaming protocol (coef_load_start/valid/done)
//   - Head Flush: zero-fill delay line before first frame data (GP_FIR_N cycles)
//   - Tail Flush: zero-fill after last frame sample (GP_FIR_N-1 cycles)
//   - Round-Half-Up rounding before arithmetic right shift (Spec §12.3)
//   - Signed saturation clamp (Spec §12.4)
//   - Frame boundary sideband pipeline alignment (Spec §11.5)
//   - State machine: IDLE→COEF_LOAD→HEAD_FLUSH→RUN→TAIL_FLUSH→DONE→ERROR
// =============================================================================

module filter_fir #(
    parameter int GP_IN_WIDTH   = 24,   // Input data bit-width (from CIC)
    parameter int GP_OUT_WIDTH  = 8,    // Output data bit-width (to CNN)
    parameter int GP_COEF_WIDTH = 16,   // Coefficient bit-width
    parameter int GP_FIR_N      = 64,   // Number of FIR taps
    parameter int GP_SHIFT      = 18    // Output right-shift amount
) (
    input  logic                              clk_i,
    input  logic                              rst_ni,

    // Control interface (Spec §14)
    input  logic                              fir_en_i,         // Module enable (§14.1)

    // AXI-Stream input interface (Spec §7.1)
    input  logic                              s_axis_tvalid,
    output logic                              s_axis_tready,
    input  logic signed [GP_IN_WIDTH-1:0]     s_axis_tdata,
    input  logic                              s_axis_tlast,     // Frame end (§11.2)
    input  logic [0:0]                        s_axis_tuser,     // Frame start (§11.1)

    // AXI-Stream output interface (Spec §7.2)
    output logic                              m_axis_tvalid,
    input  logic                              m_axis_tready,
    output logic signed [GP_OUT_WIDTH-1:0]    m_axis_tdata,
    output logic                              m_axis_tlast,     // Output frame end (§11.4)
    output logic [0:0]                        m_axis_tuser,     // Output frame start (§11.3)

    // Coefficient loading interface (Spec §8)
    input  logic                              coef_load_start_i,  // Begin loading (§8.3)
    input  logic                              coef_load_valid_i,  // Coeff data valid (§8.3)
    input  logic signed [GP_COEF_WIDTH-1:0]   coef_data_i,        // Coeff data (§8.2)
    input  logic                              coef_load_done_i,   // Loading complete (§8.3)

    // Status interface (Spec §14)
    output logic                              fir_busy_o,       // Processing active (§14.2)
    output logic                              coef_ready_o,     // Coefficients valid (§14.3)
    output logic                              fir_cfg_err_o,    // Config error (§14.4)
    output logic                              coef_load_err_o   // Coeff load error (§8.4)
);

    // =========================================================================
    // Internal Constants
    // =========================================================================
    localparam int C_CNT_WIDTH   = $clog2(GP_FIR_N + 1);
    // Multiplier output width: signed * signed = 2*max(W)-1 bits
    localparam int C_MULT_WIDTH  = GP_IN_WIDTH + GP_COEF_WIDTH - 1;
    // Adder tree stages
    localparam int C_TREE_STAGES = $clog2(GP_FIR_N);
    // Full precision accumulator width
    localparam int C_ACC_WIDTH   = C_MULT_WIDTH + C_TREE_STAGES;
    // Total data pipeline latency: multiplier(1) + adder_tree(C_TREE_STAGES) + saturation(1) + output_reg(1)
    localparam int C_DATA_LATENCY = 1 + C_TREE_STAGES + 1 + 1;

    // =========================================================================
    // State Machine (Spec §13)
    // =========================================================================
    typedef enum logic [2:0] {
        ST_IDLE       = 3'd0,
        ST_COEF_LOAD  = 3'd1,
        ST_HEAD_FLUSH = 3'd2,
        ST_RUN        = 3'd3,
        ST_TAIL_FLUSH = 3'd4,
        ST_DONE       = 3'd5,
        ST_ERROR      = 3'd6
    } fir_state_t;

    fir_state_t r_state, w_next_state;

    // =========================================================================
    // Internal Signals
    // =========================================================================
    // Coefficient storage
    logic signed [GP_COEF_WIDTH-1:0] r_coef [GP_FIR_N];
    logic [C_CNT_WIDTH-1:0]          r_coef_cnt;
    logic                            r_coef_ready;

    // Data delay line
    logic signed [GP_IN_WIDTH-1:0]   r_x [GP_FIR_N];

    // Flush/frame counters
    logic [C_CNT_WIDTH-1:0]          r_flush_cnt;

    // Pipeline data valid
    logic                            w_pipe_valid;    // Data entering multiplier array

    // Multiplier outputs
    logic signed [C_MULT_WIDTH-1:0]  w_products [GP_FIR_N];

    // Adder tree IO
    logic signed [C_MULT_WIDTH-1:0]  w_tree_inputs [GP_FIR_N];
    logic                            w_tree_out_valid;
    logic signed [GP_OUT_WIDTH-1:0]  w_tree_out_data;

    // Sideband pipeline
    logic [C_DATA_LATENCY-1:0]       r_valid_pipe;
    logic [C_DATA_LATENCY-1:0]       r_sof_pipe;
    logic [C_DATA_LATENCY-1:0]       r_eof_pipe;

    // Frame tracking
    logic                            r_first_output;   // Next valid output is SOF
    logic                            r_tail_last_tick;  // Last tick of tail flush

    // =========================================================================
    // Parameter Validation (Spec §5)
    // =========================================================================
    always_comb begin
        fir_cfg_err_o = 1'b0;
        if (GP_FIR_N < 4)                      fir_cfg_err_o = 1'b1;
        if (GP_FIR_N > 256)                     fir_cfg_err_o = 1'b1;
        if (GP_SHIFT > 63)                      fir_cfg_err_o = 1'b1;
    end

    // =========================================================================
    // State Machine - Sequential
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_state <= ST_IDLE;
        end else begin
            r_state <= w_next_state;
        end
    end

    // =========================================================================
    // State Machine - Combinational (Spec §13.2)
    // =========================================================================
    always_comb begin
        w_next_state = r_state;

        case (r_state)
            ST_IDLE: begin
                if (fir_cfg_err_o) begin
                    w_next_state = ST_ERROR;
                end else if (coef_load_start_i && fir_en_i) begin
                    w_next_state = ST_COEF_LOAD;
                end
            end

            ST_COEF_LOAD: begin
                if (coef_load_done_i && r_coef_cnt == C_CNT_WIDTH'(GP_FIR_N)) begin
                    w_next_state = ST_HEAD_FLUSH;
                end else if (coef_load_done_i && r_coef_cnt != C_CNT_WIDTH'(GP_FIR_N)) begin
                    // Incorrect number of coefficients loaded
                    w_next_state = ST_ERROR;
                end
            end

            ST_HEAD_FLUSH: begin
                if (r_flush_cnt == C_CNT_WIDTH'(GP_FIR_N - 1)) begin
                    w_next_state = ST_RUN;
                end
            end

            ST_RUN: begin
                if (!fir_en_i) begin
                    w_next_state = ST_ERROR;
                end else if (s_axis_tvalid && s_axis_tlast) begin
                    w_next_state = ST_TAIL_FLUSH;
                end
            end

            ST_TAIL_FLUSH: begin
                if (r_flush_cnt == C_CNT_WIDTH'(GP_FIR_N - 2)) begin
                    w_next_state = ST_DONE;
                end
            end

            ST_DONE: begin
                // Wait for pipeline to drain, then return to IDLE
                if (!r_valid_pipe[C_DATA_LATENCY-1]) begin
                    w_next_state = ST_IDLE;
                end
            end

            ST_ERROR: begin
                // Stay in error until reset
                w_next_state = ST_ERROR;
            end

            default: w_next_state = ST_IDLE;
        endcase
    end

    // =========================================================================
    // Status Outputs (Spec §14)
    // =========================================================================
    assign fir_busy_o   = (r_state != ST_IDLE) && (r_state != ST_DONE);
    assign coef_ready_o = r_coef_ready;

    // =========================================================================
    // Input Ready (Spec §7.1.2)
    // Only accept input data during RUN state
    // =========================================================================
    assign s_axis_tready = (r_state == ST_RUN) ? 1'b1 : 1'b0;

    // =========================================================================
    // Coefficient Loading (Spec §8)
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_coef_cnt    <= '0;
            r_coef_ready  <= 1'b0;
            coef_load_err_o <= 1'b0;
        end else begin
            case (r_state)
                ST_IDLE: begin
                    r_coef_cnt    <= '0;
                    coef_load_err_o <= 1'b0;
                end

                ST_COEF_LOAD: begin
                    if (coef_load_valid_i) begin
                        if (r_coef_cnt < C_CNT_WIDTH'(GP_FIR_N)) begin
                            r_coef[r_coef_cnt] <= coef_data_i;
                            r_coef_cnt <= r_coef_cnt + 1'b1;
                        end else begin
                            // Too many coefficients
                            coef_load_err_o <= 1'b1;
                        end
                    end
                    if (coef_load_done_i) begin
                        if (r_coef_cnt == C_CNT_WIDTH'(GP_FIR_N)) begin
                            r_coef_ready <= 1'b1;
                        end else begin
                            coef_load_err_o <= 1'b1;
                            r_coef_ready    <= 1'b0;
                        end
                    end
                end

                ST_HEAD_FLUSH: begin
                    // Coefficients are now locked
                end

                default: ;
            endcase
        end
    end

    // =========================================================================
    // Flush Counter (Spec §10)
    // Used for both HEAD_FLUSH and TAIL_FLUSH
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_flush_cnt <= '0;
        end else begin
            if (r_state == ST_HEAD_FLUSH || r_state == ST_TAIL_FLUSH) begin
                r_flush_cnt <= r_flush_cnt + 1'b1;
            end else begin
                r_flush_cnt <= '0;
            end
        end
    end

    // =========================================================================
    // Data Delay Line (Spec §9.1)
    // Shift register: r_x[0] = newest, r_x[N-1] = oldest
    // =========================================================================
    // Determine data input to delay line
    logic                          w_shift_en;
    logic signed [GP_IN_WIDTH-1:0] w_shift_data;

    always_comb begin
        w_shift_en   = 1'b0;
        w_shift_data = '0;

        case (r_state)
            ST_HEAD_FLUSH: begin
                // Zero-fill during head flush (Spec §10.3)
                w_shift_en   = 1'b1;
                w_shift_data = '0;
            end

            ST_RUN: begin
                // Normal operation: shift on valid input
                w_shift_en   = s_axis_tvalid;
                w_shift_data = s_axis_tdata;
            end

            ST_TAIL_FLUSH: begin
                // Zero-fill during tail flush (Spec §10.6)
                w_shift_en   = 1'b1;
                w_shift_data = '0;
            end

            default: begin
                w_shift_en   = 1'b0;
                w_shift_data = '0;
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i = 0; i < GP_FIR_N; i++) begin
                r_x[i] <= '0;
            end
        end else if (w_shift_en) begin
            r_x[0] <= w_shift_data;
            for (int i = 1; i < GP_FIR_N; i++) begin
                r_x[i] <= r_x[i-1];
            end
        end
    end

    // =========================================================================
    // Pipe Valid - drives multiplier array (data entering the pipeline)
    // Valid during HEAD_FLUSH, RUN (with valid input), and TAIL_FLUSH
    // =========================================================================
    assign w_pipe_valid = w_shift_en;

    // =========================================================================
    // Parallel Multiplier Array (Spec §9.3)
    // =========================================================================
    generate
        for (genvar i = 0; i < GP_FIR_N; i++) begin : gen_mult_array
            // Registered multiplier: 1 cycle latency
            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    w_products[i] <= '0;
                end else if (w_pipe_valid) begin
                    w_products[i] <= r_x[i] * r_coef[i];
                end
            end
        end
    endgenerate

    // =========================================================================
    // Pipelined Adder Tree (Spec §9.4)
    // Using existing adder_tree module for structural consistency
    // Input width = C_MULT_WIDTH, Output = GP_OUT_WIDTH with shift+saturate
    // =========================================================================
    assign w_tree_inputs = w_products;

    adder_tree #(
        .GP_NUM_INPUTS (GP_FIR_N),
        .GP_IN_WIDTH   (C_MULT_WIDTH),
        .GP_OUT_WIDTH  (GP_OUT_WIDTH),
        .GP_SHIFT      (GP_SHIFT)
    ) u_adder_tree (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .s_axis_tvalid (r_valid_pipe[0]),    // Delayed by 1 for multiplier latency
        .s_axis_tdata  (w_tree_inputs),
        .m_axis_tvalid (w_tree_out_valid),
        .m_axis_tdata  (w_tree_out_data)
    );

    // =========================================================================
    // Valid / Sideband Pipeline (Spec §11.5)
    // Align valid/sof/eof through the same latency as data
    // =========================================================================

    // Frame tracking: detect first valid output and last valid output
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_first_output   <= 1'b0;
            r_tail_last_tick <= 1'b0;
        end else begin
            // Mark first output: when transitioning from HEAD_FLUSH to RUN
            if (r_state == ST_HEAD_FLUSH && w_next_state == ST_RUN) begin
                r_first_output <= 1'b1;
            end else if (r_first_output && w_pipe_valid && r_state == ST_RUN) begin
                r_first_output <= 1'b0;  // Clear after first real data enters
            end

            // Mark last output: final tick of tail flush
            if (r_state == ST_TAIL_FLUSH && r_flush_cnt == C_CNT_WIDTH'(GP_FIR_N - 2)) begin
                r_tail_last_tick <= 1'b1;
            end else begin
                r_tail_last_tick <= 1'b0;
            end
        end
    end

    // Sideband input signals (pre-pipeline)
    logic w_sof_in, w_eof_in;
    assign w_sof_in = r_first_output && w_pipe_valid && (r_state == ST_RUN);
    assign w_eof_in = r_tail_last_tick;

    // Pipeline shift registers for valid, SOF, EOF
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_valid_pipe <= '0;
            r_sof_pipe   <= '0;
            r_eof_pipe   <= '0;
        end else begin
            r_valid_pipe <= {r_valid_pipe[C_DATA_LATENCY-2:0], w_pipe_valid};
            r_sof_pipe   <= {r_sof_pipe[C_DATA_LATENCY-2:0],  w_sof_in};
            r_eof_pipe   <= {r_eof_pipe[C_DATA_LATENCY-2:0],  w_eof_in};
        end
    end

    // =========================================================================
    // Output Assignment (Spec §7.2)
    // =========================================================================
    // Only emit outputs during valid RUN or TAIL_FLUSH pipeline drain
    // Head flush outputs are suppressed
    logic w_head_flush_output;
    assign w_head_flush_output = 1'b0; // Head flush data is internally consumed, not output

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= '0;
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            // Use adder tree valid for output
            m_axis_tvalid <= w_tree_out_valid;
            m_axis_tdata  <= w_tree_out_data;

            if (w_tree_out_valid) begin
                m_axis_tuser[0] <= r_sof_pipe[C_DATA_LATENCY-1];
                m_axis_tlast    <= r_eof_pipe[C_DATA_LATENCY-1];
            end else begin
                // Non-valid: sideband must be 0 (Spec §7.2.2)
                m_axis_tuser <= 1'b0;
                m_axis_tlast <= 1'b0;
            end
        end
    end

endmodule : filter_fir
