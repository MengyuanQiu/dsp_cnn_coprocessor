// =============================================================================
// Module : cnn_pe
// Description : Processing Element for 1D-CNN Inference Engine
// Spec Ref    : CORE_CNN_SPEC v2.0, §9.2
// =============================================================================
// Architecture:
//   - Input Tapped Delay Line (TDL) of length GP_PE_MAC_NUM
//   - GP_PE_MAC_NUM parallel multiplier paths (signed 8x8 -> 16-bit)
//   - Local adder tree to reduce products to single partial sum
//   - Double-buffered weight registers (w0/w1) for pipeline hiding
//   - Bias injection port
// =============================================================================

module cnn_pe #(
    parameter int GP_DATA_WIDTH   = 8,    // Activation bit-width
    parameter int GP_WEIGHT_WIDTH = 8,    // Weight bit-width
    parameter int GP_ACC_WIDTH    = 32,   // Accumulator bit-width
    parameter int GP_PE_MAC_NUM   = 3     // Max kernel size / MAC count per PE
) (
    input  logic                              clk_i,
    input  logic                              rst_ni,

    // Control
    input  logic                              clr_acc_i,        // Clear accumulator (new output position)
    input  logic                              en_i,             // PE enable (shift + MAC)

    // Data input (single activation sample, shifted through TDL)
    input  logic signed [GP_DATA_WIDTH-1:0]   act_i,

    // Weight loading
    input  logic                              wt_load_i,        // Load weights into shadow register
    input  logic signed [GP_WEIGHT_WIDTH-1:0] wt_data_i [GP_PE_MAC_NUM],  // Weight vector

    // Bias injection
    input  logic                              bias_en_i,        // Add bias to accumulator
    input  logic signed [GP_ACC_WIDTH-1:0]    bias_i,

    // Kernel size (runtime configurable, <= GP_PE_MAC_NUM)
    input  logic [$clog2(GP_PE_MAC_NUM+1)-1:0] kernel_size_i,

    // Accumulated output
    output logic signed [GP_ACC_WIDTH-1:0]    acc_o,
    output logic                              acc_valid_o
);

    // =========================================================================
    // Internal Constants
    // =========================================================================
    localparam int C_PROD_WIDTH = GP_DATA_WIDTH + GP_WEIGHT_WIDTH;

    // =========================================================================
    // Tapped Delay Line (TDL) - Spec §9.2.3
    // =========================================================================
    logic signed [GP_DATA_WIDTH-1:0] r_tdl [GP_PE_MAC_NUM];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i = 0; i < GP_PE_MAC_NUM; i++) begin
                r_tdl[i] <= '0;
            end
        end else if (en_i) begin
            r_tdl[0] <= act_i;
            for (int i = 1; i < GP_PE_MAC_NUM; i++) begin
                r_tdl[i] <= r_tdl[i-1];
            end
        end
    end

    // =========================================================================
    // Double-Buffered Weight Registers (Spec §8.3, §9.2.1)
    // Shadow (w_shadow) loaded while active (w_active) is in use
    // =========================================================================
    logic signed [GP_WEIGHT_WIDTH-1:0] r_wt_active [GP_PE_MAC_NUM];
    logic signed [GP_WEIGHT_WIDTH-1:0] r_wt_shadow [GP_PE_MAC_NUM];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i = 0; i < GP_PE_MAC_NUM; i++) begin
                r_wt_active[i] <= '0;
                r_wt_shadow[i] <= '0;
            end
        end else if (wt_load_i) begin
            // Load into shadow, swap shadow -> active
            for (int i = 0; i < GP_PE_MAC_NUM; i++) begin
                r_wt_shadow[i] <= wt_data_i[i];
                r_wt_active[i] <= r_wt_shadow[i];
            end
        end
    end

    // =========================================================================
    // Parallel Multiplier Array (Spec §9.2.1)
    // =========================================================================
    logic signed [C_PROD_WIDTH-1:0] w_products [GP_PE_MAC_NUM];

    always_comb begin
        for (int i = 0; i < GP_PE_MAC_NUM; i++) begin
            if (i < int'(kernel_size_i)) begin
                w_products[i] = r_tdl[i] * r_wt_active[i];
            end else begin
                w_products[i] = '0;  // Zero-mask unused taps
            end
        end
    end

    // =========================================================================
    // Local Adder Tree (reduce GP_PE_MAC_NUM products to single sum)
    // =========================================================================
    logic signed [GP_ACC_WIDTH-1:0] w_mac_sum;

    always_comb begin
        w_mac_sum = '0;
        for (int i = 0; i < GP_PE_MAC_NUM; i++) begin
            w_mac_sum = w_mac_sum + GP_ACC_WIDTH'(signed'(w_products[i]));
        end
    end

    // =========================================================================
    // Accumulator (Spec §9.3)
    // Supports clear (new output position) and accumulate (folding rounds)
    // =========================================================================
    logic signed [GP_ACC_WIDTH-1:0] r_acc;
    logic                           r_acc_valid;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_acc       <= '0;
            r_acc_valid <= 1'b0;
        end else if (clr_acc_i) begin
            r_acc       <= '0;
            r_acc_valid <= 1'b0;
        end else if (en_i) begin
            r_acc       <= r_acc + w_mac_sum;
            r_acc_valid <= 1'b1;
        end else if (bias_en_i) begin
            r_acc       <= r_acc + bias_i;
            r_acc_valid <= 1'b1;
        end
    end

    assign acc_o       = r_acc;
    assign acc_valid_o = r_acc_valid;

endmodule : cnn_pe
