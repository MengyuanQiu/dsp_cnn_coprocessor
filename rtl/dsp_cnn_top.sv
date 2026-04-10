// =============================================================================
// Module : dsp_cnn_top
// Description : DSP-CNN Coprocessor System Top-Level Integration
// Spec Ref    : DSP_CNN_SYSTEM_SPEC v2.0
// =============================================================================
// Architecture:
//   Input Stream → CIC Decimator → FIR Compensator → CNN Inference Engine → Result
//                                                                    ↑
//                                           AXI-Lite CSR Controller
// =============================================================================
// This module integrates:
//   1. CSR Controller (AXI-Lite register interface)
//   2. CIC Decimation Filter
//   3. FIR Compensation Filter
//   4. CNN Inference Engine
//   5. Global FSM (system lifecycle management)
//   6. Error collection and interrupt routing
// =============================================================================

module dsp_cnn_top #(
    // System parameters
    parameter int GP_IN_WIDTH       = 8,
    parameter int GP_ACT_WIDTH      = 8,
    parameter int GP_WEIGHT_WIDTH   = 8,
    parameter int GP_ACC_WIDTH      = 32,
    // CIC parameters
    parameter int GP_CICD_R         = 64,
    parameter int GP_CICD_N         = 5,
    parameter int GP_CICD_M         = 1,
    parameter int GP_CICD_PHASE     = 0,
    parameter int GP_CIC_OUT_WIDTH  = GP_IN_WIDTH + GP_CICD_N * $clog2(GP_CICD_M * GP_CICD_R),
    // FIR parameters
    parameter int GP_FIR_N          = 64,
    parameter int GP_FIR_COEF_WIDTH = 16,
    parameter int GP_FIR_SHIFT      = 18,
    // CNN parameters
    parameter int GP_PE_MAC_NUM     = 3,
    parameter int GP_PE_CLUSTER_NUM = 64,
    parameter int GP_MAX_LAYER_NUM  = 16,
    // AXI-Lite
    parameter int GP_AXIL_ADDR_W    = 12,
    parameter int GP_AXIL_DATA_W    = 32
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,

    // =====================================================================
    // AXI-Lite Slave Interface (CPU/MCU configuration)
    // =====================================================================
    input  logic                          s_axil_awvalid,
    output logic                          s_axil_awready,
    input  logic [GP_AXIL_ADDR_W-1:0]    s_axil_awaddr,
    input  logic                          s_axil_wvalid,
    output logic                          s_axil_wready,
    input  logic [GP_AXIL_DATA_W-1:0]    s_axil_wdata,
    input  logic [GP_AXIL_DATA_W/8-1:0]  s_axil_wstrb,
    output logic                          s_axil_bvalid,
    input  logic                          s_axil_bready,
    output logic [1:0]                    s_axil_bresp,
    input  logic                          s_axil_arvalid,
    output logic                          s_axil_arready,
    input  logic [GP_AXIL_ADDR_W-1:0]    s_axil_araddr,
    output logic                          s_axil_rvalid,
    input  logic                          s_axil_rready,
    output logic [GP_AXIL_DATA_W-1:0]    s_axil_rdata,
    output logic [1:0]                    s_axil_rresp,

    // =====================================================================
    // AXI-Stream Input (raw sample stream)
    // =====================================================================
    input  logic                          s_axis_tvalid,
    output logic                          s_axis_tready,
    input  logic signed [GP_IN_WIDTH-1:0] s_axis_tdata,
    input  logic                          s_axis_tlast,
    input  logic [0:0]                    s_axis_tuser,

    // =====================================================================
    // AXI-Stream Output (inference result)
    // =====================================================================
    output logic                          m_axis_tvalid,
    input  logic                          m_axis_tready,
    output logic signed [GP_ACT_WIDTH-1:0] m_axis_tdata,
    output logic                          m_axis_tlast,
    output logic [0:0]                    m_axis_tuser,

    // =====================================================================
    // Interrupt Output
    // =====================================================================
    output logic                          irq_o
);

    // =========================================================================
    // Internal Interconnect Signals
    // =========================================================================

    // --- CSR Controller outputs ---
    logic        w_sys_start;
    logic        w_sys_stop;
    logic        w_sys_soft_rst;
    logic        w_cic_en;
    logic        w_fir_en;
    logic        w_cnn_en;
    logic [15:0] w_frame_len;

    // --- CIC <-> FIR interconnect ---
    logic                           w_cic_m_tvalid;
    logic                           w_cic_m_tready;
    logic signed [GP_CIC_OUT_WIDTH-1:0] w_cic_m_tdata;
    logic                           w_cic_m_tlast;
    logic [0:0]                     w_cic_m_tuser;
    logic                           w_cic_busy;
    logic                           w_cic_cfg_err;

    // --- FIR <-> CNN interconnect ---
    logic                           w_fir_m_tvalid;
    logic                           w_fir_m_tready;
    logic signed [GP_ACT_WIDTH-1:0] w_fir_m_tdata;
    logic                           w_fir_m_tlast;
    logic [0:0]                     w_fir_m_tuser;
    logic                           w_fir_busy;
    logic                           w_fir_coef_ready;
    logic                           w_fir_cfg_err;
    logic                           w_fir_coef_err;

    // --- CNN status ---
    logic                           w_cnn_busy;
    logic                           w_cnn_done;
    logic                           w_cnn_err;

    // --- System-level status ---
    logic        w_sys_idle;
    logic        w_sys_busy;
    logic        w_sys_done;
    logic        w_sys_err;
    logic [15:0] w_sys_err_code;
    logic [15:0] w_sys_err_subinfo;

    // =========================================================================
    // Global FSM (Spec §00 System Spec - System Lifecycle)
    // =========================================================================
    typedef enum logic [3:0] {
        GFSM_RESET         = 4'd0,
        GFSM_IDLE          = 4'd1,
        GFSM_CONFIG        = 4'd2,
        GFSM_STREAMING_DSP = 4'd3,
        GFSM_CNN_COMPUTE   = 4'd4,
        GFSM_RESULT_DRAIN  = 4'd5,
        GFSM_DONE          = 4'd6,
        GFSM_ERROR         = 4'd7
    } gfsm_state_t;

    gfsm_state_t r_gfsm, w_gfsm_next;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || w_sys_soft_rst) begin
            r_gfsm <= GFSM_IDLE;
        end else begin
            r_gfsm <= w_gfsm_next;
        end
    end

    always_comb begin
        w_gfsm_next = r_gfsm;
        case (r_gfsm)
            GFSM_IDLE: begin
                if (w_sys_start)
                    w_gfsm_next = GFSM_STREAMING_DSP;
            end
            GFSM_STREAMING_DSP: begin
                // CIC+FIR processing until frame complete
                if (w_fir_m_tlast && w_fir_m_tvalid)
                    w_gfsm_next = GFSM_CNN_COMPUTE;
                if (w_cic_cfg_err || w_fir_cfg_err)
                    w_gfsm_next = GFSM_ERROR;
            end
            GFSM_CNN_COMPUTE: begin
                if (w_cnn_done)
                    w_gfsm_next = GFSM_RESULT_DRAIN;
                if (w_cnn_err)
                    w_gfsm_next = GFSM_ERROR;
            end
            GFSM_RESULT_DRAIN: begin
                if (m_axis_tvalid && m_axis_tready && m_axis_tlast)
                    w_gfsm_next = GFSM_DONE;
            end
            GFSM_DONE: begin
                w_gfsm_next = GFSM_IDLE;
            end
            GFSM_ERROR: begin
                if (w_sys_soft_rst)
                    w_gfsm_next = GFSM_IDLE;
            end
            default: w_gfsm_next = GFSM_IDLE;
        endcase
    end

    // System status derivation
    assign w_sys_idle = (r_gfsm == GFSM_IDLE);
    assign w_sys_busy = (r_gfsm != GFSM_IDLE) && (r_gfsm != GFSM_DONE);
    assign w_sys_done = (r_gfsm == GFSM_DONE);
    assign w_sys_err  = (r_gfsm == GFSM_ERROR);

    // Error code aggregation
    always_comb begin
        w_sys_err_code    = 16'h0000;
        w_sys_err_subinfo = 16'h0000;
        if (w_cic_cfg_err) begin
            w_sys_err_code    = 16'h0005;  // ERR_CIC_PARAM_ILLEGAL
            w_sys_err_subinfo = {12'b0, 4'd2};  // MOD_ID_CIC
        end else if (w_fir_cfg_err) begin
            w_sys_err_code    = 16'h0006;  // ERR_FIR_PARAM_ILLEGAL
            w_sys_err_subinfo = {12'b0, 4'd3};  // MOD_ID_FIR
        end else if (w_cnn_err) begin
            w_sys_err_code    = 16'h0009;  // ERR_CNN_PARAM_ILLEGAL
            w_sys_err_subinfo = {12'b0, 4'd4};  // MOD_ID_CNN
        end
    end

    // =========================================================================
    // CSR Controller Instantiation
    // =========================================================================
    csr_controller #(
        .GP_ADDR_WIDTH (GP_AXIL_ADDR_W),
        .GP_DATA_WIDTH (GP_AXIL_DATA_W)
    ) u_csr (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        // AXI-Lite
        .s_axil_awvalid     (s_axil_awvalid),
        .s_axil_awready     (s_axil_awready),
        .s_axil_awaddr      (s_axil_awaddr),
        .s_axil_wvalid      (s_axil_wvalid),
        .s_axil_wready      (s_axil_wready),
        .s_axil_wdata       (s_axil_wdata),
        .s_axil_wstrb       (s_axil_wstrb),
        .s_axil_bvalid      (s_axil_bvalid),
        .s_axil_bready      (s_axil_bready),
        .s_axil_bresp       (s_axil_bresp),
        .s_axil_arvalid     (s_axil_arvalid),
        .s_axil_arready     (s_axil_arready),
        .s_axil_araddr      (s_axil_araddr),
        .s_axil_rvalid      (s_axil_rvalid),
        .s_axil_rready      (s_axil_rready),
        .s_axil_rdata       (s_axil_rdata),
        .s_axil_rresp       (s_axil_rresp),
        // Control outputs
        .sys_start_o        (w_sys_start),
        .sys_stop_o         (w_sys_stop),
        .sys_soft_rst_o     (w_sys_soft_rst),
        // Status inputs
        .sys_idle_i         (w_sys_idle),
        .sys_busy_i         (w_sys_busy),
        .sys_done_i         (w_sys_done),
        .sys_err_i          (w_sys_err),
        .sys_err_code_i     (w_sys_err_code),
        .sys_err_subinfo_i  (w_sys_err_subinfo),
        .cic_active_i       (w_cic_busy),
        .fir_active_i       (w_fir_busy),
        .cnn_active_i       (w_cnn_busy),
        .result_valid_i     (m_axis_tvalid),
        // Config outputs
        .cic_decim_r_o      (),  // Connected via parameters for now
        .cic_order_n_o      (),
        .cic_diff_m_o       (),
        .cic_phase_o        (),
        .cic_en_o           (w_cic_en),
        .fir_tap_n_o        (),
        .fir_shift_o        (),
        .fir_en_o           (w_fir_en),
        .cnn_num_layers_o   (),
        .cnn_en_o           (w_cnn_en),
        .frame_len_o        (w_frame_len),
        // Interrupt
        .irq_o              (irq_o)
    );

    // =========================================================================
    // CIC Decimation Filter
    // =========================================================================
    filter_cicd #(
        .GP_CICD_R     (GP_CICD_R),
        .GP_CICD_N     (GP_CICD_N),
        .GP_CICD_M     (GP_CICD_M),
        .GP_CICD_PHASE (GP_CICD_PHASE),
        .GP_IN_WIDTH   (GP_IN_WIDTH),
        .GP_OUT_WIDTH  (GP_CIC_OUT_WIDTH)
    ) u_cic (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .cic_en_i       (w_cic_en && (r_gfsm == GFSM_STREAMING_DSP)),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tuser   (s_axis_tuser),
        .m_axis_tvalid  (w_cic_m_tvalid),
        .m_axis_tready  (w_cic_m_tready),
        .m_axis_tdata   (w_cic_m_tdata),
        .m_axis_tlast   (w_cic_m_tlast),
        .m_axis_tuser   (w_cic_m_tuser),
        .cic_busy_o     (w_cic_busy),
        .cic_cfg_err_o  (w_cic_cfg_err)
    );

    // =========================================================================
    // FIR Compensation Filter
    // =========================================================================
    // Note: CIC output width -> FIR input width; FIR output -> CNN activation width
    filter_fir #(
        .GP_IN_WIDTH   (GP_CIC_OUT_WIDTH),
        .GP_OUT_WIDTH  (GP_ACT_WIDTH),
        .GP_COEF_WIDTH (GP_FIR_COEF_WIDTH),
        .GP_FIR_N      (GP_FIR_N),
        .GP_SHIFT      (GP_FIR_SHIFT)
    ) u_fir (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .fir_en_i           (w_fir_en && (r_gfsm == GFSM_STREAMING_DSP)),
        .s_axis_tvalid      (w_cic_m_tvalid),
        .s_axis_tready      (w_cic_m_tready),
        .s_axis_tdata       (w_cic_m_tdata),
        .s_axis_tlast       (w_cic_m_tlast),
        .s_axis_tuser       (w_cic_m_tuser),
        .m_axis_tvalid      (w_fir_m_tvalid),
        .m_axis_tready      (w_fir_m_tready),
        .m_axis_tdata       (w_fir_m_tdata),
        .m_axis_tlast       (w_fir_m_tlast),
        .m_axis_tuser       (w_fir_m_tuser),
        // Coefficient loading (connected via CSR coef window in full impl)
        .coef_load_start_i  (1'b0),
        .coef_load_valid_i  (1'b0),
        .coef_data_i        ('0),
        .coef_load_done_i   (1'b0),
        // Status
        .fir_busy_o         (w_fir_busy),
        .coef_ready_o       (w_fir_coef_ready),
        .fir_cfg_err_o      (w_fir_cfg_err),
        .coef_load_err_o    (w_fir_coef_err)
    );

    // =========================================================================
    // CNN Inference Engine
    // =========================================================================
    // FIR ready: CNN always ready to accept during STREAMING_DSP
    assign w_fir_m_tready = (r_gfsm == GFSM_STREAMING_DSP) ? 1'b1 : 1'b0;

    cnn_inference_engine #(
        .GP_DATA_WIDTH     (GP_ACT_WIDTH),
        .GP_WEIGHT_WIDTH   (GP_WEIGHT_WIDTH),
        .GP_ACC_WIDTH      (GP_ACC_WIDTH),
        .GP_PE_MAC_NUM     (GP_PE_MAC_NUM),
        .GP_PE_CLUSTER_NUM (GP_PE_CLUSTER_NUM),
        .GP_MAX_LAYER_NUM  (GP_MAX_LAYER_NUM)
    ) u_cnn (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .cnn_en_i       (w_cnn_en),
        .start_i        (r_gfsm == GFSM_CNN_COMPUTE && w_gfsm_next == GFSM_CNN_COMPUTE),
        .soft_rst_i     (w_sys_soft_rst),
        // Input from FIR
        .s_axis_tvalid  (w_fir_m_tvalid),
        .s_axis_tready  (),
        .s_axis_tdata   (w_fir_m_tdata),
        .s_axis_tlast   (w_fir_m_tlast),
        .s_axis_tuser   (w_fir_m_tuser),
        // Output (result)
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tuser   (m_axis_tuser),
        // Status
        .cnn_busy_o     (w_cnn_busy),
        .cnn_done_o     (w_cnn_done),
        .cnn_err_o      (w_cnn_err),
        // Layer config (from CSR - simplified passthrough)
        .cfg_num_layers_i        (4'd1),
        .cfg_layer_type_i        ('{default: '0}),
        .cfg_in_ch_i             ('{default: '0}),
        .cfg_out_ch_i            ('{default: '0}),
        .cfg_seq_len_i           ('{default: '0}),
        .cfg_kernel_size_i       ('{default: '0}),
        .cfg_stride_i            ('{default: 4'd1}),
        .cfg_padding_i           ('{default: '0}),
        .cfg_act_type_i          ('{default: '0}),
        .cfg_pool_type_i         ('{default: '0}),
        .cfg_pool_size_i         ('{default: '0}),
        .cfg_quant_shift_i       ('{default: '0}),
        // Weight/bias loading
        .wt_load_valid_i (1'b0),
        .wt_load_data_i  ('0),
        .bias_load_valid_i(1'b0),
        .bias_load_data_i ('0)
    );

endmodule : dsp_cnn_top
