// =============================================================================
// Module : cnn_inference_engine
// Description : 1D-CNN Core Inference Engine (Top-Level)
// Spec Ref    : CORE_CNN_SPEC v2.0
// =============================================================================
// Architecture:
//   - Input Staging Buffer: receives one frame from FIR
//   - Ping-Pong CBUF: CBUF0/CBUF1 with per-layer role flipping
//   - PE Cluster Array: GP_PE_CLUSTER_NUM parallel PEs
//   - Post-Processing: ReLU + Pooling + ReQuant
//   - Layer/Global FSM: sequential layer execution
//   - Weight/Bias Buffers: loaded via config interface
// =============================================================================

module cnn_inference_engine #(
    parameter int GP_DATA_WIDTH     = 8,
    parameter int GP_WEIGHT_WIDTH   = 8,
    parameter int GP_ACC_WIDTH      = 32,
    parameter int GP_PE_MAC_NUM     = 3,
    parameter int GP_PE_CLUSTER_NUM = 64,
    parameter int GP_MAX_LAYER_NUM  = 16,
    parameter int GP_MAX_SEQ_LEN    = 256,
    parameter int GP_MAX_CH         = 256,
    parameter int GP_CBUF_DEPTH     = 4096  // Words per CBUF bank
) (
    input  logic                              clk_i,
    input  logic                              rst_ni,

    // System control (Spec §7.1)
    input  logic                              cnn_en_i,
    input  logic                              start_i,
    input  logic                              soft_rst_i,

    // AXI-Stream input (from FIR, Spec §7.2)
    input  logic                              s_axis_tvalid,
    output logic                              s_axis_tready,
    input  logic signed [GP_DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic                              s_axis_tlast,
    input  logic [0:0]                        s_axis_tuser,

    // AXI-Stream output (result, Spec §7.3)
    output logic                              m_axis_tvalid,
    input  logic                              m_axis_tready,
    output logic signed [GP_DATA_WIDTH-1:0]   m_axis_tdata,
    output logic                              m_axis_tlast,
    output logic [0:0]                        m_axis_tuser,

    // Status (Spec §7.1)
    output logic                              cnn_busy_o,
    output logic                              cnn_done_o,
    output logic                              cnn_err_o,

    // Layer config interface (from CSR, simplified for v1)
    input  logic [3:0]                        cfg_num_layers_i,         // Total layers
    input  logic [2:0]                        cfg_layer_type_i  [GP_MAX_LAYER_NUM],  // Layer type enum
    input  logic [$clog2(GP_MAX_CH)-1:0]      cfg_in_ch_i       [GP_MAX_LAYER_NUM],  // Input channels
    input  logic [$clog2(GP_MAX_CH)-1:0]      cfg_out_ch_i      [GP_MAX_LAYER_NUM],  // Output channels
    input  logic [$clog2(GP_MAX_SEQ_LEN)-1:0] cfg_seq_len_i     [GP_MAX_LAYER_NUM],  // Sequence length
    input  logic [$clog2(GP_PE_MAC_NUM+1)-1:0] cfg_kernel_size_i [GP_MAX_LAYER_NUM],  // Kernel size
    input  logic [3:0]                        cfg_stride_i      [GP_MAX_LAYER_NUM],  // Stride
    input  logic [3:0]                        cfg_padding_i     [GP_MAX_LAYER_NUM],  // Padding
    input  logic [1:0]                        cfg_act_type_i    [GP_MAX_LAYER_NUM],  // Activation type
    input  logic [2:0]                        cfg_pool_type_i   [GP_MAX_LAYER_NUM],  // Pool type
    input  logic [3:0]                        cfg_pool_size_i   [GP_MAX_LAYER_NUM],  // Pool window size
    input  logic [5:0]                        cfg_quant_shift_i [GP_MAX_LAYER_NUM],  // ReQuant shift

    // Weight/Bias loading interface
    input  logic                              wt_load_valid_i,
    input  logic signed [GP_WEIGHT_WIDTH-1:0] wt_load_data_i,
    input  logic                              bias_load_valid_i,
    input  logic signed [GP_ACC_WIDTH-1:0]    bias_load_data_i
);

    // =========================================================================
    // Global FSM (Spec §4.4, §13)
    // =========================================================================
    typedef enum logic [3:0] {
        ST_IDLE         = 4'd0,
        ST_LOAD_INPUT   = 4'd1,
        ST_CHECK_CFG    = 4'd2,
        ST_LOAD_WEIGHT  = 4'd3,
        ST_COMPUTE      = 4'd4,
        ST_POST_PROCESS = 4'd5,
        ST_WRITE_BACK   = 4'd6,
        ST_NEXT_LAYER   = 4'd7,
        ST_RESULT_OUT   = 4'd8,
        ST_DONE         = 4'd9,
        ST_ERROR        = 4'd10
    } cnn_state_t;

    cnn_state_t r_state, w_next_state;

    // =========================================================================
    // Layer Tracking
    // =========================================================================
    logic [3:0]  r_cur_layer;        // Current layer index
    logic        r_all_layers_done;  // All layers completed

    // =========================================================================
    // Input Buffer (simplified: stores one frame)
    // =========================================================================
    localparam int C_INPUT_BUF_SIZE = GP_MAX_SEQ_LEN;
    logic signed [GP_DATA_WIDTH-1:0] r_input_buf [C_INPUT_BUF_SIZE];
    logic [$clog2(C_INPUT_BUF_SIZE)-1:0] r_input_wr_ptr;
    logic r_input_frame_complete;

    // =========================================================================
    // Ping-Pong CBUF (Spec §8.2)
    // =========================================================================
    logic signed [GP_DATA_WIDTH-1:0] r_cbuf0 [GP_CBUF_DEPTH];
    logic signed [GP_DATA_WIDTH-1:0] r_cbuf1 [GP_CBUF_DEPTH];
    logic                            r_cbuf_sel;  // 0=read CBUF0/write CBUF1, 1=read CBUF1/write CBUF0

    // =========================================================================
    // PE Array Signals
    // =========================================================================
    // Simplified: instantiate GP_PE_CLUSTER_NUM PEs
    logic                             w_pe_en;
    logic                             w_pe_clr_acc;
    logic signed [GP_DATA_WIDTH-1:0]  w_pe_act_in;
    logic                             w_pe_wt_load;
    logic signed [GP_WEIGHT_WIDTH-1:0] w_pe_wt_data [GP_PE_MAC_NUM];
    logic                             w_pe_bias_en;
    logic signed [GP_ACC_WIDTH-1:0]   w_pe_bias;
    logic [$clog2(GP_PE_MAC_NUM+1)-1:0] w_pe_kernel_size;

    logic signed [GP_ACC_WIDTH-1:0]   w_pe_acc_out [GP_PE_CLUSTER_NUM];
    logic                             w_pe_acc_valid [GP_PE_CLUSTER_NUM];

    // =========================================================================
    // PE Cluster Instantiation (Spec §9.2)
    // =========================================================================
    generate
        for (genvar p = 0; p < GP_PE_CLUSTER_NUM; p++) begin : gen_pe_cluster
            cnn_pe #(
                .GP_DATA_WIDTH   (GP_DATA_WIDTH),
                .GP_WEIGHT_WIDTH (GP_WEIGHT_WIDTH),
                .GP_ACC_WIDTH    (GP_ACC_WIDTH),
                .GP_PE_MAC_NUM   (GP_PE_MAC_NUM)
            ) u_pe (
                .clk_i        (clk_i),
                .rst_ni       (rst_ni),
                .clr_acc_i    (w_pe_clr_acc),
                .en_i         (w_pe_en),
                .act_i        (w_pe_act_in),
                .wt_load_i    (w_pe_wt_load),
                .wt_data_i    (w_pe_wt_data),
                .bias_en_i    (w_pe_bias_en),
                .bias_i       (w_pe_bias),
                .kernel_size_i(w_pe_kernel_size),
                .acc_o        (w_pe_acc_out[p]),
                .acc_valid_o  (w_pe_acc_valid[p])
            );
        end
    endgenerate

    // =========================================================================
    // Post-Processing Unit (Spec §11)
    // One shared post-processor (outputs are serialized)
    // =========================================================================
    logic                            w_pp_en;
    logic                            w_pp_clr;
    logic                            w_pp_valid_in;
    logic signed [GP_ACC_WIDTH-1:0]  w_pp_acc_in;
    logic                            w_pp_valid_out;
    logic signed [GP_DATA_WIDTH-1:0] w_pp_data_out;

    cnn_post_processor #(
        .GP_DATA_WIDTH (GP_DATA_WIDTH),
        .GP_ACC_WIDTH  (GP_ACC_WIDTH)
    ) u_post_proc (
        .clk_i        (clk_i),
        .rst_ni       (rst_ni),
        .en_i         (w_pp_en),
        .clr_i        (w_pp_clr),
        .act_type_i   (cfg_act_type_i[r_cur_layer]),
        .pool_type_i  (cfg_pool_type_i[r_cur_layer]),
        .pool_size_i  (cfg_pool_size_i[r_cur_layer]),
        .quant_shift_i(cfg_quant_shift_i[r_cur_layer]),
        .valid_i      (w_pp_valid_in),
        .acc_i        (w_pp_acc_in),
        .valid_o      (w_pp_valid_out),
        .data_o       (w_pp_data_out)
    );

    // =========================================================================
    // Compute Counters
    // =========================================================================
    logic [$clog2(GP_MAX_SEQ_LEN)-1:0] r_seq_pos;     // Current output sequence position
    logic [$clog2(GP_MAX_CH)-1:0]      r_out_ch_idx;   // Current output channel being computed
    logic [$clog2(GP_MAX_CH)-1:0]      r_in_ch_fold;   // Current input channel fold
    logic [$clog2(GP_MAX_SEQ_LEN)-1:0] r_out_seq_len;  // Computed output sequence length
    logic [$clog2(GP_CBUF_DEPTH)-1:0]  r_cbuf_wr_ptr;  // Write pointer into output CBUF

    // =========================================================================
    // State Machine - Sequential
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i) begin
            r_state <= ST_IDLE;
        end else begin
            r_state <= w_next_state;
        end
    end

    // =========================================================================
    // State Machine - Combinational
    // =========================================================================
    always_comb begin
        w_next_state = r_state;

        case (r_state)
            ST_IDLE: begin
                if (cnn_en_i && start_i)
                    w_next_state = ST_LOAD_INPUT;
            end

            ST_LOAD_INPUT: begin
                if (r_input_frame_complete)
                    w_next_state = ST_CHECK_CFG;
            end

            ST_CHECK_CFG: begin
                // Validate current layer config
                if (cfg_kernel_size_i[r_cur_layer] > GP_PE_MAC_NUM[$clog2(GP_PE_MAC_NUM+1)-1:0])
                    w_next_state = ST_ERROR;
                else
                    w_next_state = ST_LOAD_WEIGHT;
            end

            ST_LOAD_WEIGHT: begin
                // Weights loaded for current layer
                w_next_state = ST_COMPUTE;
            end

            ST_COMPUTE: begin
                // After computing all output positions and channels
                if (r_seq_pos >= r_out_seq_len && r_out_ch_idx >= cfg_out_ch_i[r_cur_layer])
                    w_next_state = ST_POST_PROCESS;
            end

            ST_POST_PROCESS: begin
                w_next_state = ST_WRITE_BACK;
            end

            ST_WRITE_BACK: begin
                w_next_state = ST_NEXT_LAYER;
            end

            ST_NEXT_LAYER: begin
                if (r_cur_layer >= cfg_num_layers_i - 1)
                    w_next_state = ST_RESULT_OUT;
                else
                    w_next_state = ST_CHECK_CFG;
            end

            ST_RESULT_OUT: begin
                if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
                    w_next_state = ST_DONE;
            end

            ST_DONE: begin
                w_next_state = ST_IDLE;
            end

            ST_ERROR: begin
                w_next_state = ST_ERROR;
            end

            default: w_next_state = ST_IDLE;
        endcase
    end

    // =========================================================================
    // Status Outputs
    // =========================================================================
    assign cnn_busy_o = (r_state != ST_IDLE) && (r_state != ST_DONE);
    assign cnn_done_o = (r_state == ST_DONE);
    assign cnn_err_o  = (r_state == ST_ERROR);

    // =========================================================================
    // Input Loading Logic (Spec §8.1)
    // =========================================================================
    assign s_axis_tready = (r_state == ST_LOAD_INPUT);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i) begin
            r_input_wr_ptr        <= '0;
            r_input_frame_complete <= 1'b0;
        end else if (r_state == ST_IDLE) begin
            r_input_wr_ptr        <= '0;
            r_input_frame_complete <= 1'b0;
        end else if (r_state == ST_LOAD_INPUT && s_axis_tvalid) begin
            r_input_buf[r_input_wr_ptr] <= s_axis_tdata;
            r_input_wr_ptr <= r_input_wr_ptr + 1;
            if (s_axis_tlast) begin
                r_input_frame_complete <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Layer Control Logic
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i) begin
            r_cur_layer      <= '0;
            r_all_layers_done <= 1'b0;
            r_cbuf_sel       <= 1'b0;
            r_seq_pos        <= '0;
            r_out_ch_idx     <= '0;
            r_in_ch_fold     <= '0;
            r_out_seq_len    <= '0;
            r_cbuf_wr_ptr    <= '0;
        end else begin
            case (r_state)
                ST_IDLE: begin
                    r_cur_layer      <= '0;
                    r_all_layers_done <= 1'b0;
                    r_cbuf_sel       <= 1'b0;
                end

                ST_CHECK_CFG: begin
                    // Compute output sequence length
                    r_out_seq_len <= (cfg_seq_len_i[r_cur_layer] 
                                    + 2 * cfg_padding_i[r_cur_layer]
                                    - cfg_kernel_size_i[r_cur_layer]) 
                                    / cfg_stride_i[r_cur_layer] + 1;
                    r_seq_pos    <= '0;
                    r_out_ch_idx <= '0;
                    r_in_ch_fold <= '0;
                    r_cbuf_wr_ptr <= '0;
                end

                ST_NEXT_LAYER: begin
                    r_cur_layer <= r_cur_layer + 1'b1;
                    r_cbuf_sel  <= ~r_cbuf_sel;  // Flip Ping-Pong (Spec §8.2.2)
                end

                default: ;
            endcase
        end
    end

    // =========================================================================
    // PE Array Control (simplified v1 scheduling)
    // =========================================================================
    assign w_pe_en          = (r_state == ST_COMPUTE);
    assign w_pe_clr_acc     = (r_state == ST_CHECK_CFG);
    assign w_pe_wt_load     = (r_state == ST_LOAD_WEIGHT);
    assign w_pe_bias_en     = 1'b0;  // Bias injection handled during post-process
    assign w_pe_bias        = '0;
    assign w_pe_kernel_size = cfg_kernel_size_i[r_cur_layer];
    assign w_pe_act_in      = '0;  // Connected through data distribution in full implementation

    // Placeholder weight data (connected through weight buffer in full implementation)
    always_comb begin
        for (int i = 0; i < GP_PE_MAC_NUM; i++) begin
            w_pe_wt_data[i] = '0;
        end
    end

    // =========================================================================
    // Post-Processing Control
    // =========================================================================
    assign w_pp_en       = (r_state == ST_POST_PROCESS) || (r_state == ST_COMPUTE);
    assign w_pp_clr      = (r_state == ST_CHECK_CFG);
    assign w_pp_valid_in = w_pe_acc_valid[0];  // Use first PE for now
    assign w_pp_acc_in   = w_pe_acc_out[0];

    // =========================================================================
    // Result Output Logic (Spec §7.3)
    // =========================================================================
    logic [$clog2(GP_CBUF_DEPTH)-1:0] r_result_rd_ptr;
    logic                              r_result_last;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i) begin
            m_axis_tvalid  <= 1'b0;
            m_axis_tdata   <= '0;
            m_axis_tlast   <= 1'b0;
            m_axis_tuser   <= 1'b0;
            r_result_rd_ptr <= '0;
        end else if (r_state == ST_RESULT_OUT) begin
            m_axis_tvalid  <= 1'b1;
            m_axis_tdata   <= r_cbuf_sel ? r_cbuf0[r_result_rd_ptr] : r_cbuf1[r_result_rd_ptr];
            m_axis_tuser   <= (r_result_rd_ptr == 0) ? 1'b1 : 1'b0;
            // Check if this is the last result
            m_axis_tlast   <= (r_result_rd_ptr == r_out_seq_len - 1) ? 1'b1 : 1'b0;

            if (m_axis_tready) begin
                r_result_rd_ptr <= r_result_rd_ptr + 1;
            end
        end else begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end
    end

endmodule : cnn_inference_engine
