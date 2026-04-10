// =============================================================================
// Module : csr_controller
// Description : AXI-Lite CSR & Interrupt Controller
// Spec Ref    : CSR_INTERRUPT_SPEC v1.0
// =============================================================================
// Features:
//   - AXI-Lite Slave interface (32-bit data, 12-bit address)
//   - System Control: START (SC), STOP (SC), SOFT_RST (SC), CLR_DONE (W1C), CLR_ERR (W1C)
//   - System Status: IDLE, BUSY, DONE (sticky), ERR (sticky), module active flags
//   - Error Code: first-error capture (ERR_CODE + ERR_SUBINFO)
//   - Interrupt: mask, raw status, masked status, W1C clear
//   - CIC/FIR/CNN config registers
//   - Performance counters
//   - Busy-write protection (Spec §2.2)
// =============================================================================

module csr_controller #(
    parameter int GP_ADDR_WIDTH = 12,
    parameter int GP_DATA_WIDTH = 32
) (
    input  logic                        clk_i,
    input  logic                        rst_ni,

    // =====================================================================
    // AXI-Lite Slave Interface (Spec §3.1)
    // =====================================================================
    // Write address channel
    input  logic                        s_axil_awvalid,
    output logic                        s_axil_awready,
    input  logic [GP_ADDR_WIDTH-1:0]    s_axil_awaddr,

    // Write data channel
    input  logic                        s_axil_wvalid,
    output logic                        s_axil_wready,
    input  logic [GP_DATA_WIDTH-1:0]    s_axil_wdata,
    input  logic [GP_DATA_WIDTH/8-1:0]  s_axil_wstrb,

    // Write response channel
    output logic                        s_axil_bvalid,
    input  logic                        s_axil_bready,
    output logic [1:0]                  s_axil_bresp,

    // Read address channel
    input  logic                        s_axil_arvalid,
    output logic                        s_axil_arready,
    input  logic [GP_ADDR_WIDTH-1:0]    s_axil_araddr,

    // Read data channel
    output logic                        s_axil_rvalid,
    input  logic                        s_axil_rready,
    output logic [GP_DATA_WIDTH-1:0]    s_axil_rdata,
    output logic [1:0]                  s_axil_rresp,

    // =====================================================================
    // System Control Outputs (to datapath modules)
    // =====================================================================
    output logic                        sys_start_o,
    output logic                        sys_stop_o,
    output logic                        sys_soft_rst_o,

    // =====================================================================
    // System Status Inputs (from datapath modules)
    // =====================================================================
    input  logic                        sys_idle_i,
    input  logic                        sys_busy_i,
    input  logic                        sys_done_i,       // Pulse when task completes
    input  logic                        sys_err_i,        // Pulse when error occurs
    input  logic [15:0]                 sys_err_code_i,   // Error code
    input  logic [15:0]                 sys_err_subinfo_i,// Error sub-info
    input  logic                        cic_active_i,
    input  logic                        fir_active_i,
    input  logic                        cnn_active_i,
    input  logic                        result_valid_i,

    // =====================================================================
    // CIC Config Outputs
    // =====================================================================
    output logic [15:0]                 cic_decim_r_o,
    output logic [3:0]                  cic_order_n_o,
    output logic [1:0]                  cic_diff_m_o,
    output logic [15:0]                 cic_phase_o,
    output logic                        cic_en_o,

    // =====================================================================
    // FIR Config Outputs
    // =====================================================================
    output logic [7:0]                  fir_tap_n_o,
    output logic [5:0]                  fir_shift_o,
    output logic                        fir_en_o,

    // =====================================================================
    // CNN Config Outputs
    // =====================================================================
    output logic [3:0]                  cnn_num_layers_o,
    output logic                        cnn_en_o,

    // =====================================================================
    // Frame Config
    // =====================================================================
    output logic [15:0]                 frame_len_o,

    // =====================================================================
    // Interrupt Output
    // =====================================================================
    output logic                        irq_o
);

    // =========================================================================
    // Register Definitions (Address Map from Spec §4)
    // =========================================================================
    // System Control/Status
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_SYS_CTRL      = 12'h000;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_SYS_STATUS    = 12'h004;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_SYS_ERR_CODE  = 12'h008;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_ERR_SUMMARY   = 12'h00C;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_IRQ_MASK      = 12'h010;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_IRQ_STATUS    = 12'h014;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_IRQ_RAW       = 12'h018;

    // Frame/Input Config
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_FRAME_LEN     = 12'h040;

    // CIC Config
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_CIC_CFG0      = 12'h080;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_CIC_CFG1      = 12'h084;

    // FIR Config
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_FIR_CFG0      = 12'h0C0;

    // CNN Config
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_CNN_GLOBAL_CFG = 12'h100;

    // Perf Counters
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_CYCLE_CNT     = 12'h240;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_FRAME_CNT     = 12'h244;
    localparam logic [GP_ADDR_WIDTH-1:0] ADDR_PERF_CTRL     = 12'h250;

    // =========================================================================
    // Internal Registers
    // =========================================================================
    // Sticky status bits
    logic r_done_sticky;
    logic r_err_sticky;

    // Error capture (first-error, Spec §5.3)
    logic [15:0] r_err_code;
    logic [15:0] r_err_subinfo;
    logic [31:0] r_err_summary;
    logic        r_err_captured;  // First error already captured

    // Interrupt (Spec §6)
    logic [5:0]  r_irq_mask;
    logic [5:0]  r_irq_raw;
    logic [5:0]  w_irq_status;

    // Config registers (protected during BUSY)
    logic [15:0] r_frame_len;
    logic [15:0] r_cic_decim_r;
    logic [3:0]  r_cic_order_n;
    logic [1:0]  r_cic_diff_m;
    logic [15:0] r_cic_phase;
    logic        r_cic_en;
    logic [7:0]  r_fir_tap_n;
    logic [5:0]  r_fir_shift;
    logic        r_fir_en;
    logic [3:0]  r_cnn_num_layers;
    logic        r_cnn_en;

    // Self-clear pulses
    logic r_start_pulse;
    logic r_stop_pulse;
    logic r_soft_rst_pulse;

    // Performance counters
    logic [31:0] r_cycle_cnt;
    logic [31:0] r_frame_cnt;
    logic        r_perf_en;

    // =========================================================================
    // AXI-Lite Write Logic
    // =========================================================================
    logic                       w_wr_en;
    logic [GP_ADDR_WIDTH-1:0]   r_wr_addr;
    logic [GP_DATA_WIDTH-1:0]   r_wr_data;
    logic                       r_aw_done;
    logic                       r_w_done;

    // Simple two-phase write handshake
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_aw_done <= 1'b0;
            r_w_done  <= 1'b0;
            r_wr_addr <= '0;
            r_wr_data <= '0;
        end else begin
            if (s_axil_awvalid && s_axil_awready)
                r_aw_done <= 1'b1;
            if (s_axil_wvalid && s_axil_wready)
                r_w_done <= 1'b1;

            if (s_axil_awvalid && s_axil_awready)
                r_wr_addr <= s_axil_awaddr;
            if (s_axil_wvalid && s_axil_wready)
                r_wr_data <= s_axil_wdata;

            if (w_wr_en) begin
                r_aw_done <= 1'b0;
                r_w_done  <= 1'b0;
            end
        end
    end

    assign s_axil_awready = !r_aw_done;
    assign s_axil_wready  = !r_w_done;
    assign w_wr_en        = r_aw_done && r_w_done;

    // Write response
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            s_axil_bvalid <= 1'b0;
            s_axil_bresp  <= 2'b00;
        end else if (w_wr_en) begin
            s_axil_bvalid <= 1'b1;
            s_axil_bresp  <= 2'b00;  // OKAY
        end else if (s_axil_bvalid && s_axil_bready) begin
            s_axil_bvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Register Write Processing
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_start_pulse    <= 1'b0;
            r_stop_pulse     <= 1'b0;
            r_soft_rst_pulse <= 1'b0;
            r_frame_len      <= 16'd256;
            r_cic_decim_r    <= 16'd64;
            r_cic_order_n    <= 4'd5;
            r_cic_diff_m     <= 2'd1;
            r_cic_phase      <= 16'd0;
            r_cic_en         <= 1'b0;
            r_fir_tap_n      <= 8'd64;
            r_fir_shift      <= 6'd18;
            r_fir_en         <= 1'b0;
            r_cnn_num_layers <= 4'd1;
            r_cnn_en         <= 1'b0;
            r_irq_mask       <= 6'h0;
            r_perf_en        <= 1'b0;
        end else begin
            // Self-clear pulses default to 0
            r_start_pulse    <= 1'b0;
            r_stop_pulse     <= 1'b0;
            r_soft_rst_pulse <= 1'b0;

            if (w_wr_en) begin
                case (r_wr_addr)
                    ADDR_SYS_CTRL: begin
                        // Bit 0: START (SC)
                        if (r_wr_data[0]) r_start_pulse <= 1'b1;
                        // Bit 1: STOP (SC)
                        if (r_wr_data[1]) r_stop_pulse <= 1'b1;
                        // Bit 2: SOFT_RST (SC)
                        if (r_wr_data[2]) r_soft_rst_pulse <= 1'b1;
                        // Bit 3: CLR_DONE (W1C) - handled below
                        // Bit 4: CLR_ERR (W1C) - handled below
                    end

                    ADDR_IRQ_MASK: begin
                        r_irq_mask <= r_wr_data[5:0];
                    end

                    // Config registers: busy-write protection (Spec §2.2)
                    ADDR_FRAME_LEN: begin
                        if (!sys_busy_i) r_frame_len <= r_wr_data[15:0];
                    end

                    ADDR_CIC_CFG0: begin
                        if (!sys_busy_i) begin
                            r_cic_decim_r <= r_wr_data[15:0];
                            r_cic_order_n <= r_wr_data[19:16];
                            r_cic_diff_m  <= r_wr_data[21:20];
                        end
                    end

                    ADDR_CIC_CFG1: begin
                        if (!sys_busy_i) begin
                            r_cic_phase <= r_wr_data[15:0];
                            r_cic_en    <= r_wr_data[16];
                        end
                    end

                    ADDR_FIR_CFG0: begin
                        if (!sys_busy_i) begin
                            r_fir_tap_n <= r_wr_data[7:0];
                            r_fir_shift <= r_wr_data[13:8];
                            r_fir_en    <= r_wr_data[16];
                        end
                    end

                    ADDR_CNN_GLOBAL_CFG: begin
                        if (!sys_busy_i) begin
                            r_cnn_num_layers <= r_wr_data[3:0];
                            r_cnn_en         <= r_wr_data[4];
                        end
                    end

                    ADDR_PERF_CTRL: begin
                        r_perf_en <= r_wr_data[0];
                    end

                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // Sticky Status Logic (Spec §2.4)
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_done_sticky <= 1'b0;
            r_err_sticky  <= 1'b0;
        end else begin
            // Set on pulse
            if (sys_done_i)  r_done_sticky <= 1'b1;
            if (sys_err_i)   r_err_sticky  <= 1'b1;

            // Clear on W1C
            if (w_wr_en && r_wr_addr == ADDR_SYS_CTRL) begin
                if (r_wr_data[3]) r_done_sticky <= 1'b0;
                if (r_wr_data[4]) r_err_sticky  <= 1'b0;
            end

            // Soft reset clears error
            if (r_soft_rst_pulse) begin
                r_err_sticky  <= 1'b0;
                r_done_sticky <= 1'b0;
            end
        end
    end

    // =========================================================================
    // First-Error Capture (Spec §5.3)
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || r_soft_rst_pulse) begin
            r_err_code     <= '0;
            r_err_subinfo  <= '0;
            r_err_summary  <= '0;
            r_err_captured <= 1'b0;
        end else begin
            if (sys_err_i) begin
                r_err_summary <= r_err_summary | (32'(1) << sys_err_code_i[4:0]);
                if (!r_err_captured) begin
                    r_err_code     <= sys_err_code_i;
                    r_err_subinfo  <= sys_err_subinfo_i;
                    r_err_captured <= 1'b1;
                end
            end
            // Clear on CLR_ERR
            if (w_wr_en && r_wr_addr == ADDR_SYS_CTRL && r_wr_data[4]) begin
                r_err_code     <= '0;
                r_err_subinfo  <= '0;
                r_err_summary  <= '0;
                r_err_captured <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Interrupt Logic (Spec §6)
    // =========================================================================
    // Raw interrupt sources
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || r_soft_rst_pulse) begin
            r_irq_raw <= '0;
        end else begin
            // Set raw interrupt bits (sticky until W1C)
            if (sys_done_i)    r_irq_raw[0] <= 1'b1;  // IRQ_DONE
            if (sys_err_i)     r_irq_raw[1] <= 1'b1;  // IRQ_ERR
            if (result_valid_i) r_irq_raw[2] <= 1'b1;  // IRQ_RESULT_RDY

            // W1C clear via IRQ_STATUS register write
            if (w_wr_en && r_wr_addr == ADDR_IRQ_STATUS) begin
                r_irq_raw <= r_irq_raw & ~r_wr_data[5:0];
            end
        end
    end

    // Masked interrupt status
    assign w_irq_status = r_irq_raw & r_irq_mask;

    // Combined interrupt output
    assign irq_o = |w_irq_status;

    // =========================================================================
    // Performance Counters (Spec §10)
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || r_soft_rst_pulse) begin
            r_cycle_cnt <= '0;
            r_frame_cnt <= '0;
        end else if (r_perf_en && sys_busy_i) begin
            r_cycle_cnt <= r_cycle_cnt + 1;
        end
        if (sys_done_i) begin
            r_frame_cnt <= r_frame_cnt + 1;
        end
    end

    // =========================================================================
    // AXI-Lite Read Logic
    // =========================================================================
    logic r_rd_pending;
    logic [GP_ADDR_WIDTH-1:0] r_rd_addr;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_rd_pending  <= 1'b0;
            r_rd_addr     <= '0;
            s_axil_rvalid <= 1'b0;
            s_axil_rdata  <= '0;
            s_axil_rresp  <= 2'b00;
        end else begin
            // Accept read address
            if (s_axil_arvalid && s_axil_arready) begin
                r_rd_pending <= 1'b1;
                r_rd_addr    <= s_axil_araddr;
            end

            // Generate read response
            if (r_rd_pending && !s_axil_rvalid) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= 2'b00;

                case (r_rd_addr)
                    ADDR_SYS_CTRL:      s_axil_rdata <= '0;  // SC/W1C bits read as 0
                    ADDR_SYS_STATUS:    s_axil_rdata <= {21'b0, 
                                                          |w_irq_status,     // [10]
                                                          result_valid_i,    // [9]
                                                          cnn_active_i,      // [8]
                                                          fir_active_i,      // [7]
                                                          cic_active_i,      // [6]
                                                          sys_busy_i,        // [5] INPUT_ACTIVE
                                                          1'b0,              // [4] CFG_DONE
                                                          r_err_sticky,      // [3]
                                                          r_done_sticky,     // [2]
                                                          sys_busy_i,        // [1]
                                                          sys_idle_i};       // [0]
                    ADDR_SYS_ERR_CODE:  s_axil_rdata <= {r_err_subinfo, r_err_code};
                    ADDR_ERR_SUMMARY:   s_axil_rdata <= r_err_summary;
                    ADDR_IRQ_MASK:      s_axil_rdata <= {26'b0, r_irq_mask};
                    ADDR_IRQ_STATUS:    s_axil_rdata <= {26'b0, w_irq_status};
                    ADDR_IRQ_RAW:       s_axil_rdata <= {26'b0, r_irq_raw};

                    ADDR_FRAME_LEN:     s_axil_rdata <= {16'b0, r_frame_len};

                    ADDR_CIC_CFG0:      s_axil_rdata <= {10'b0, r_cic_diff_m, r_cic_order_n, r_cic_decim_r};
                    ADDR_CIC_CFG1:      s_axil_rdata <= {15'b0, r_cic_en, r_cic_phase};

                    ADDR_FIR_CFG0:      s_axil_rdata <= {15'b0, r_fir_en, 2'b0, r_fir_shift, r_fir_tap_n};

                    ADDR_CNN_GLOBAL_CFG: s_axil_rdata <= {27'b0, r_cnn_en, r_cnn_num_layers};

                    ADDR_CYCLE_CNT:     s_axil_rdata <= r_cycle_cnt;
                    ADDR_FRAME_CNT:     s_axil_rdata <= r_frame_cnt;
                    ADDR_PERF_CTRL:     s_axil_rdata <= {31'b0, r_perf_en};

                    default:            s_axil_rdata <= '0;
                endcase

                r_rd_pending <= 1'b0;
            end

            // Clear read valid
            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

    assign s_axil_arready = !r_rd_pending && !s_axil_rvalid;

    // =========================================================================
    // Output Assignments
    // =========================================================================
    assign sys_start_o    = r_start_pulse;
    assign sys_stop_o     = r_stop_pulse;
    assign sys_soft_rst_o = r_soft_rst_pulse;

    assign cic_decim_r_o  = r_cic_decim_r;
    assign cic_order_n_o  = r_cic_order_n;
    assign cic_diff_m_o   = r_cic_diff_m;
    assign cic_phase_o    = r_cic_phase;
    assign cic_en_o       = r_cic_en;

    assign fir_tap_n_o    = r_fir_tap_n;
    assign fir_shift_o    = r_fir_shift;
    assign fir_en_o       = r_fir_en;

    assign cnn_num_layers_o = r_cnn_num_layers;
    assign cnn_en_o         = r_cnn_en;

    assign frame_len_o    = r_frame_len;

endmodule : csr_controller
