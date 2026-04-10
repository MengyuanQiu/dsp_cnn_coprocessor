// =============================================================================
// Module : cnn_post_processor
// Description : Post-Processing Unit for CNN output
// Spec Ref    : CORE_CNN_SPEC v2.0, §11
// =============================================================================
// Pipeline: acc_in -> [bias_add] -> [ReLU] -> [Pooling] -> [ReQuant] -> data_out
// =============================================================================

module cnn_post_processor #(
    parameter int GP_DATA_WIDTH   = 8,
    parameter int GP_ACC_WIDTH    = 32
) (
    input  logic                            clk_i,
    input  logic                            rst_ni,

    // Control
    input  logic                            en_i,        // Process enable
    input  logic                            clr_i,       // Clear internal state (new frame/layer)

    // Configuration
    input  logic [1:0]                      act_type_i,  // 0=None, 1=ReLU (Spec §11.1)
    input  logic [2:0]                      pool_type_i, // 0=None, 1=Max, 2=Avg (Spec §11.2)
    input  logic [3:0]                      pool_size_i, // Pooling window size
    input  logic [5:0]                      quant_shift_i, // Re-quantization shift (Spec §11.3)

    // Input (from PE accumulator, with bias already added)
    input  logic                            valid_i,
    input  logic signed [GP_ACC_WIDTH-1:0]  acc_i,

    // Output (quantized activation)
    output logic                            valid_o,
    output logic signed [GP_DATA_WIDTH-1:0] data_o
);

    // =========================================================================
    // Constants
    // =========================================================================
    localparam logic signed [GP_DATA_WIDTH-1:0] C_MAX_VAL = (1 <<< (GP_DATA_WIDTH - 1)) - 1;
    localparam logic signed [GP_DATA_WIDTH-1:0] C_MIN_VAL = -(1 <<< (GP_DATA_WIDTH - 1));

    // =========================================================================
    // Pipeline Stage 1: ReLU (Spec §11.1)
    // =========================================================================
    logic signed [GP_ACC_WIDTH-1:0] r_relu_out;
    logic                           r_relu_valid;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_relu_out   <= '0;
            r_relu_valid <= 1'b0;
        end else if (valid_i && en_i) begin
            case (act_type_i)
                2'd0:    r_relu_out <= acc_i;                                      // None
                2'd1:    r_relu_out <= (acc_i[GP_ACC_WIDTH-1]) ? '0 : acc_i;       // ReLU
                default: r_relu_out <= acc_i;
            endcase
            r_relu_valid <= 1'b1;
        end else begin
            r_relu_valid <= 1'b0;
        end
    end

    // =========================================================================
    // Pipeline Stage 2: Pooling (Spec §11.2)
    // =========================================================================
    logic signed [GP_ACC_WIDTH-1:0] r_pool_out;
    logic                           r_pool_valid;
    logic signed [GP_ACC_WIDTH-1:0] r_pool_acc;    // For avg pooling accumulator
    logic signed [GP_ACC_WIDTH-1:0] r_pool_max;    // For max pooling
    logic [3:0]                     r_pool_cnt;     // Window counter

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || clr_i) begin
            r_pool_out   <= '0;
            r_pool_valid <= 1'b0;
            r_pool_acc   <= '0;
            r_pool_max   <= {1'b1, {(GP_ACC_WIDTH-1){1'b0}}};  // Most negative
            r_pool_cnt   <= '0;
        end else if (r_relu_valid) begin
            case (pool_type_i)
                3'd0: begin  // No pooling - passthrough
                    r_pool_out   <= r_relu_out;
                    r_pool_valid <= 1'b1;
                end

                3'd1: begin  // Max pooling
                    if (r_relu_out > r_pool_max)
                        r_pool_max <= r_relu_out;
                    else
                        r_pool_max <= r_pool_max;

                    r_pool_cnt <= r_pool_cnt + 1'b1;
                    if (r_pool_cnt == pool_size_i - 1) begin
                        r_pool_out   <= (r_relu_out > r_pool_max) ? r_relu_out : r_pool_max;
                        r_pool_valid <= 1'b1;
                        r_pool_max   <= {1'b1, {(GP_ACC_WIDTH-1){1'b0}}};
                        r_pool_cnt   <= '0;
                    end else begin
                        r_pool_valid <= 1'b0;
                    end
                end

                3'd2: begin  // Average pooling
                    r_pool_acc <= r_pool_acc + r_relu_out;
                    r_pool_cnt <= r_pool_cnt + 1'b1;
                    if (r_pool_cnt == pool_size_i - 1) begin
                        // Approximate division by pool_size (arithmetic right shift)
                        r_pool_out   <= r_pool_acc + r_relu_out;  // Will be shifted in requant
                        r_pool_valid <= 1'b1;
                        r_pool_acc   <= '0;
                        r_pool_cnt   <= '0;
                    end else begin
                        r_pool_valid <= 1'b0;
                    end
                end

                default: begin
                    r_pool_out   <= r_relu_out;
                    r_pool_valid <= 1'b1;
                end
            endcase
        end else begin
            r_pool_valid <= 1'b0;
        end
    end

    // =========================================================================
    // Pipeline Stage 3: Re-Quantization (Spec §11.3)
    // Round-Half-Up + Arithmetic Right Shift + Saturation
    // =========================================================================
    logic signed [GP_ACC_WIDTH-1:0] w_rounded;
    logic signed [GP_ACC_WIDTH-1:0] w_shifted;

    // Round-Half-Up: add 2^(shift-1) before shifting
    always_comb begin
        if (quant_shift_i > 0)
            w_rounded = r_pool_out + (GP_ACC_WIDTH'(1) <<< (quant_shift_i - 1));
        else
            w_rounded = r_pool_out;
    end

    // Arithmetic right shift
    assign w_shifted = w_rounded >>> quant_shift_i;

    // Saturation + output register
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            data_o  <= '0;
            valid_o <= 1'b0;
        end else if (r_pool_valid && en_i) begin
            if (w_shifted > GP_ACC_WIDTH'(signed'(C_MAX_VAL)))
                data_o <= C_MAX_VAL;
            else if (w_shifted < GP_ACC_WIDTH'(signed'(C_MIN_VAL)))
                data_o <= C_MIN_VAL;
            else
                data_o <= GP_DATA_WIDTH'(w_shifted);
            valid_o <= 1'b1;
        end else begin
            valid_o <= 1'b0;
        end
    end

endmodule : cnn_post_processor
