// =============================================================================
// Module : cnn_inference_engine
// Description : 1D-CNN Core Inference Engine (Top-Level) — v2 Deepened
// Spec Ref    : CORE_CNN_SPEC v2.0
// =============================================================================
// v2 Changes over v1 skeleton:
//   - Weight Buffer with per-PE weight distribution
//   - Bias Buffer with per-output-channel bias injection
//   - Data Distribution Network: input CBUF read → PE activation feed
//   - Compute counter logic: seq_pos / out_ch / in_ch_fold scheduling
//   - Post-processing write-back to output CBUF
//   - Full temporal folding support for IN_CH > PE_CLUSTER_NUM
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
    parameter int GP_CBUF_DEPTH     = 4096,  // Words per CBUF bank
    parameter int GP_WBUF_DEPTH     = 4096   // Weight buffer depth
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
    input  logic [3:0]                        cfg_num_layers_i,
    input  logic [2:0]                        cfg_layer_type_i  [GP_MAX_LAYER_NUM],
    input  logic [$clog2(GP_MAX_CH)-1:0]      cfg_in_ch_i       [GP_MAX_LAYER_NUM],
    input  logic [$clog2(GP_MAX_CH)-1:0]      cfg_out_ch_i      [GP_MAX_LAYER_NUM],
    input  logic [$clog2(GP_MAX_SEQ_LEN)-1:0] cfg_seq_len_i     [GP_MAX_LAYER_NUM],
    input  logic [$clog2(GP_PE_MAC_NUM+1)-1:0] cfg_kernel_size_i [GP_MAX_LAYER_NUM],
    input  logic [3:0]                        cfg_stride_i      [GP_MAX_LAYER_NUM],
    input  logic [3:0]                        cfg_padding_i     [GP_MAX_LAYER_NUM],
    input  logic [1:0]                        cfg_act_type_i    [GP_MAX_LAYER_NUM],
    input  logic [2:0]                        cfg_pool_type_i   [GP_MAX_LAYER_NUM],
    input  logic [3:0]                        cfg_pool_size_i   [GP_MAX_LAYER_NUM],
    input  logic [5:0]                        cfg_quant_shift_i [GP_MAX_LAYER_NUM],

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
    logic [3:0]  r_cur_layer;
    logic        r_all_layers_done;

    // =========================================================================
    // Input Staging Buffer (Spec §8.1)
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
    logic                            r_cbuf_sel;

    // =========================================================================
    // Weight Buffer (Spec §8.3)
    // =========================================================================
    logic signed [GP_WEIGHT_WIDTH-1:0] r_wbuf [GP_WBUF_DEPTH];
    logic [$clog2(GP_WBUF_DEPTH)-1:0]  r_wbuf_wr_ptr;
    logic                               r_wbuf_loaded;

    // =========================================================================
    // Bias Buffer (Spec §8.4)
    // =========================================================================
    logic signed [GP_ACC_WIDTH-1:0] r_bias_buf [GP_MAX_CH];
    logic [$clog2(GP_MAX_CH)-1:0]   r_bias_wr_ptr;

    // =========================================================================
    // PE Array Signals
    // =========================================================================
    logic                             w_pe_en      [GP_PE_CLUSTER_NUM];
    logic                             w_pe_clr_acc [GP_PE_CLUSTER_NUM];
    logic signed [GP_DATA_WIDTH-1:0]  w_pe_act_in  [GP_PE_CLUSTER_NUM];
    logic                             w_pe_wt_load [GP_PE_CLUSTER_NUM];
    logic signed [GP_WEIGHT_WIDTH-1:0] w_pe_wt_data [GP_PE_CLUSTER_NUM][GP_PE_MAC_NUM];
    logic                             w_pe_bias_en [GP_PE_CLUSTER_NUM];
    logic signed [GP_ACC_WIDTH-1:0]   w_pe_bias    [GP_PE_CLUSTER_NUM];
    logic [$clog2(GP_PE_MAC_NUM+1)-1:0] w_pe_kernel_size;

    logic signed [GP_ACC_WIDTH-1:0]   w_pe_acc_out [GP_PE_CLUSTER_NUM];
    logic                             w_pe_acc_valid [GP_PE_CLUSTER_NUM];

    // =========================================================================
    // PE Cluster Instantiation (Spec §9.2) — per-PE independent control
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
                .clr_acc_i    (w_pe_clr_acc[p]),
                .en_i         (w_pe_en[p]),
                .act_i        (w_pe_act_in[p]),
                .wt_load_i    (w_pe_wt_load[p]),
                .wt_data_i    (w_pe_wt_data[p]),
                .bias_en_i    (w_pe_bias_en[p]),
                .bias_i       (w_pe_bias[p]),
                .kernel_size_i(w_pe_kernel_size),
                .acc_o        (w_pe_acc_out[p]),
                .acc_valid_o  (w_pe_acc_valid[p])
            );
        end
    endgenerate

    // =========================================================================
    // Post-Processing Unit (Spec §11)
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
    logic [$clog2(GP_MAX_SEQ_LEN)-1:0] r_seq_pos;
    logic [$clog2(GP_MAX_CH)-1:0]      r_out_ch_idx;
    logic [$clog2(GP_MAX_CH)-1:0]      r_in_ch_fold;
    logic [$clog2(GP_MAX_SEQ_LEN)-1:0] r_out_seq_len;
    logic [$clog2(GP_CBUF_DEPTH)-1:0]  r_cbuf_wr_ptr;
    logic [$clog2(GP_PE_MAC_NUM+1)-1:0] r_kernel_cnt;
    logic                               r_compute_done;
    logic [$clog2(GP_MAX_CH)-1:0]      r_pe_drain_idx;

    // Current layer config shortcuts
    logic [$clog2(GP_MAX_CH)-1:0]       w_cur_in_ch;
    logic [$clog2(GP_MAX_CH)-1:0]       w_cur_out_ch;
    logic [$clog2(GP_PE_MAC_NUM+1)-1:0] w_cur_ks;
    logic [3:0]                         w_cur_stride;
    logic [3:0]                         w_cur_padding;

    assign w_cur_in_ch  = cfg_in_ch_i[r_cur_layer];
    assign w_cur_out_ch = cfg_out_ch_i[r_cur_layer];
    assign w_cur_ks     = cfg_kernel_size_i[r_cur_layer];
    assign w_cur_stride = cfg_stride_i[r_cur_layer];
    assign w_cur_padding = cfg_padding_i[r_cur_layer];
    assign w_pe_kernel_size = w_cur_ks;

    // =========================================================================
    // State Machine — Sequential
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i)
            r_state <= ST_IDLE;
        else
            r_state <= w_next_state;
    end

    // =========================================================================
    // State Machine — Combinational
    // =========================================================================
    always_comb begin
        w_next_state = r_state;
        case (r_state)
            ST_IDLE:
                if (cnn_en_i && start_i)
                    w_next_state = ST_LOAD_INPUT;

            ST_LOAD_INPUT:
                if (r_input_frame_complete)
                    w_next_state = ST_CHECK_CFG;

            ST_CHECK_CFG:
                if (w_cur_ks > GP_PE_MAC_NUM[$clog2(GP_PE_MAC_NUM+1)-1:0])
                    w_next_state = ST_ERROR;
                else
                    w_next_state = ST_LOAD_WEIGHT;

            ST_LOAD_WEIGHT:
                if (r_wbuf_loaded)
                    w_next_state = ST_COMPUTE;

            ST_COMPUTE:
                if (r_compute_done)
                    w_next_state = ST_POST_PROCESS;

            ST_POST_PROCESS:
                if (!w_pp_valid_out && !w_pp_valid_in)
                    w_next_state = ST_WRITE_BACK;

            ST_WRITE_BACK:
                w_next_state = ST_NEXT_LAYER;

            ST_NEXT_LAYER:
                if (r_cur_layer >= cfg_num_layers_i - 1)
                    w_next_state = ST_RESULT_OUT;
                else
                    w_next_state = ST_CHECK_CFG;

            ST_RESULT_OUT:
                if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
                    w_next_state = ST_DONE;

            ST_DONE:
                w_next_state = ST_IDLE;

            ST_ERROR:
                w_next_state = ST_ERROR;

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
            r_input_wr_ptr         <= '0;
            r_input_frame_complete <= 1'b0;
        end else if (r_state == ST_IDLE) begin
            r_input_wr_ptr         <= '0;
            r_input_frame_complete <= 1'b0;
        end else if (r_state == ST_LOAD_INPUT && s_axis_tvalid) begin
            r_input_buf[r_input_wr_ptr] <= s_axis_tdata;
            r_input_wr_ptr <= r_input_wr_ptr + 1;
            if (s_axis_tlast)
                r_input_frame_complete <= 1'b1;
        end
    end

    // =========================================================================
    // CBUF0 ← Input Buffer (first layer initial load)
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            // No init needed for BRAM inference
        end else if (r_state == ST_CHECK_CFG && r_cur_layer == 0) begin
            // Copy input buffer to CBUF0 for first layer
            for (int i = 0; i < C_INPUT_BUF_SIZE; i++)
                r_cbuf0[i] <= r_input_buf[i];
        end
    end

    // =========================================================================
    // Weight Buffer Loading (Spec §8.3)
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i) begin
            r_wbuf_wr_ptr <= '0;
            r_wbuf_loaded <= 1'b0;
        end else if (r_state == ST_IDLE) begin
            r_wbuf_wr_ptr <= '0;
            r_wbuf_loaded <= 1'b0;
        end else if (r_state == ST_LOAD_WEIGHT) begin
            if (wt_load_valid_i) begin
                r_wbuf[r_wbuf_wr_ptr] <= wt_load_data_i;
                r_wbuf_wr_ptr <= r_wbuf_wr_ptr + 1;
            end
            // Auto-mark loaded after 1 cycle if no external load pending
            // (For pre-loaded weights or when weights are already in buffer)
            if (!wt_load_valid_i)
                r_wbuf_loaded <= 1'b1;
        end else begin
            r_wbuf_loaded <= 1'b0;
        end
    end

    // =========================================================================
    // Bias Buffer Loading (Spec §8.4)
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i) begin
            r_bias_wr_ptr <= '0;
        end else if (bias_load_valid_i) begin
            r_bias_buf[r_bias_wr_ptr] <= bias_load_data_i;
            r_bias_wr_ptr <= r_bias_wr_ptr + 1;
        end
    end

    // =========================================================================
    // Compute Control Logic (Data Distribution + Scheduling)
    // =========================================================================
    // Conv1D compute loop:
    //   for each out_ch (folded over PE cluster):
    //     for each seq_pos (output position):
    //       for each in_ch:
    //         feed kernel window into PE, accumulate
    //       add bias, send to post-processing
    // =========================================================================

    // CBUF read address generator
    logic [$clog2(GP_CBUF_DEPTH)-1:0] w_cbuf_rd_addr;
    logic signed [GP_DATA_WIDTH-1:0]  w_cbuf_rd_data;

    // Read from current read CBUF
    assign w_cbuf_rd_addr = r_seq_pos * w_cur_stride + r_kernel_cnt;
    always_comb begin
        if (!r_cbuf_sel)
            w_cbuf_rd_data = r_cbuf0[w_cbuf_rd_addr];
        else
            w_cbuf_rd_data = r_cbuf1[w_cbuf_rd_addr];
    end

    // Weight read address: out_ch * in_ch * ks + in_ch * ks + k
    logic [$clog2(GP_WBUF_DEPTH)-1:0] w_wbuf_rd_base;
    assign w_wbuf_rd_base = r_out_ch_idx * w_cur_in_ch * w_cur_ks 
                           + r_in_ch_fold * w_cur_ks;

    // =========================================================================
    // Compute Sequencer
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i) begin
            r_seq_pos      <= '0;
            r_out_ch_idx   <= '0;
            r_in_ch_fold   <= '0;
            r_kernel_cnt   <= '0;
            r_compute_done <= 1'b0;
            r_out_seq_len  <= '0;
            r_cbuf_wr_ptr  <= '0;
            r_pe_drain_idx <= '0;
            r_cur_layer    <= '0;
            r_cbuf_sel     <= 1'b0;
        end else begin
            case (r_state)
                ST_IDLE: begin
                    r_cur_layer    <= '0;
                    r_cbuf_sel     <= 1'b0;
                    r_compute_done <= 1'b0;
                end

                ST_CHECK_CFG: begin
                    r_out_seq_len <= (cfg_seq_len_i[r_cur_layer]
                                    + 2 * cfg_padding_i[r_cur_layer]
                                    - cfg_kernel_size_i[r_cur_layer])
                                    / cfg_stride_i[r_cur_layer] + 1;
                    r_seq_pos      <= '0;
                    r_out_ch_idx   <= '0;
                    r_in_ch_fold   <= '0;
                    r_kernel_cnt   <= '0;
                    r_compute_done <= 1'b0;
                    r_cbuf_wr_ptr  <= '0;
                    r_pe_drain_idx <= '0;
                end

                ST_COMPUTE: begin
                    // Kernel sliding window counter
                    if (r_kernel_cnt < w_cur_ks - 1) begin
                        r_kernel_cnt <= r_kernel_cnt + 1;
                    end else begin
                        r_kernel_cnt <= '0;
                        // Advance sequence position
                        if (r_seq_pos < r_out_seq_len - 1) begin
                            r_seq_pos <= r_seq_pos + 1;
                        end else begin
                            r_seq_pos <= '0;
                            // Advance input channel fold
                            if (r_in_ch_fold < w_cur_in_ch - 1) begin
                                r_in_ch_fold <= r_in_ch_fold + 1;
                            end else begin
                                r_in_ch_fold <= '0;
                                // Advance output channel
                                if (r_out_ch_idx < w_cur_out_ch - 1) begin
                                    r_out_ch_idx <= r_out_ch_idx + 1;
                                end else begin
                                    r_compute_done <= 1'b1;
                                end
                            end
                        end
                    end
                end

                ST_WRITE_BACK: begin
                    // Write post-processed output to write CBUF
                    if (w_pp_valid_out) begin
                        if (!r_cbuf_sel)
                            r_cbuf1[r_cbuf_wr_ptr] <= w_pp_data_out;
                        else
                            r_cbuf0[r_cbuf_wr_ptr] <= w_pp_data_out;
                        r_cbuf_wr_ptr <= r_cbuf_wr_ptr + 1;
                    end
                end

                ST_NEXT_LAYER: begin
                    r_cur_layer <= r_cur_layer + 1'b1;
                    r_cbuf_sel  <= ~r_cbuf_sel;
                end

                default: ;
            endcase
        end
    end

    // =========================================================================
    // PE Array Data Distribution (Spec §9.1)
    // =========================================================================
    always_comb begin
        for (int p = 0; p < GP_PE_CLUSTER_NUM; p++) begin
            w_pe_en[p]      = (r_state == ST_COMPUTE) && (p == 0); // v1: single PE active
            w_pe_clr_acc[p] = (r_state == ST_CHECK_CFG);
            w_pe_act_in[p]  = (r_state == ST_COMPUTE) ? w_cbuf_rd_data : '0;
            w_pe_wt_load[p] = (r_state == ST_LOAD_WEIGHT && r_wbuf_loaded);
            w_pe_bias_en[p] = 1'b0;
            w_pe_bias[p]    = r_bias_buf[r_out_ch_idx];

            // Load weights from wbuf into PE
            for (int k = 0; k < GP_PE_MAC_NUM; k++) begin
                if (k < int'(w_cur_ks))
                    w_pe_wt_data[p][k] = r_wbuf[w_wbuf_rd_base + k];
                else
                    w_pe_wt_data[p][k] = '0;
            end
        end
    end

    // =========================================================================
    // Post-Processing Control
    // =========================================================================
    assign w_pp_en       = (r_state == ST_POST_PROCESS) || (r_state == ST_COMPUTE);
    assign w_pp_clr      = (r_state == ST_CHECK_CFG);
    assign w_pp_valid_in = w_pe_acc_valid[0] && (r_state == ST_COMPUTE);
    assign w_pp_acc_in   = w_pe_acc_out[0] + r_bias_buf[r_out_ch_idx];

    // =========================================================================
    // Result Output Logic (Spec §7.3)
    // =========================================================================
    logic [$clog2(GP_CBUF_DEPTH)-1:0] r_result_rd_ptr;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || soft_rst_i) begin
            m_axis_tvalid   <= 1'b0;
            m_axis_tdata    <= '0;
            m_axis_tlast    <= 1'b0;
            m_axis_tuser    <= 1'b0;
            r_result_rd_ptr <= '0;
        end else if (r_state == ST_RESULT_OUT) begin
            m_axis_tvalid <= 1'b1;
            m_axis_tdata  <= r_cbuf_sel ? r_cbuf0[r_result_rd_ptr] : r_cbuf1[r_result_rd_ptr];
            m_axis_tuser  <= (r_result_rd_ptr == 0) ? 1'b1 : 1'b0;
            m_axis_tlast  <= (r_result_rd_ptr == r_out_seq_len - 1) ? 1'b1 : 1'b0;
            if (m_axis_tready)
                r_result_rd_ptr <= r_result_rd_ptr + 1;
        end else begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end
    end

endmodule : cnn_inference_engine
