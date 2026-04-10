module conv #(
    parameter int GP_IN_WIDTH = 8,
    parameter int GP_FIR_N = 8
) (
    input  logic                            clk_i,
    input  logic                            rst_ni,
    // axis data stream
    input  logic                            s_axis_tvalid,
    input  logic signed [  GP_IN_WIDTH-1:0] s_axis_tdata,                // 数据输入
    output logic                            m_axis_tvalid,
    output logic signed [2*GP_IN_WIDTH-2:0] m_axis_tdata    [GP_FIR_N],
    // coef hx 初始化信号
    input  logic                            coef_init_en_i,
    output logic                            coef_init_done_o,
    input  logic signed [  GP_IN_WIDTH-1:0] coef_data_i                  // 系数输入
);

    localparam int C_COE_CNT_WIDTH = $clog2(GP_FIR_N + 1);

    // 补充了 signed 声明，确保后续 multiplier 进行有符号运算
    logic signed [GP_IN_WIDTH-1:0] r_x[GP_FIR_N];
    logic signed [GP_IN_WIDTH-1:0] r_h[GP_FIR_N];
    logic signed [2*GP_IN_WIDTH-2:0] product[GP_FIR_N];

    logic r_valid_d;
    logic [C_COE_CNT_WIDTH-1:0] r_coe_cnt;

    // -------------------------------------------------------------------
    // 1. 数据流水线与系数流水线 (同步复用与冲刷)
    // -------------------------------------------------------------------
    always_ff @(posedge clk_i) begin : b_latch_pipelines
        // 🌟 优化点：当使能配置系数时，系数正常移位加载，同时强制数据寄存器移位填 0
        if (coef_init_en_i) begin
            // 加载系数
            r_h[0] <= coef_data_i;
            r_h[GP_FIR_N-1:1] <= r_h[GP_FIR_N-2:0];

            // 同步冲刷脏数据 (Zero Padding Flush)
            r_x[0] <= '0;
            r_x[GP_FIR_N-1:1] <= r_x[GP_FIR_N-2:0];

            // 日常工作模式：只有在数据有效时才移位
        end else if (s_axis_tvalid) begin
            r_x[0] <= s_axis_tdata;
            r_x[GP_FIR_N-1:1] <= r_x[GP_FIR_N-2:0];
            // 注意：正常工作时 r_h 保持不变
        end
    end

    // -------------------------------------------------------------------
    // 2. 系数加载状态机 (支持上电初始化与运行中动态重配)
    // -------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin : b_coe_cnt
        if (!rst_ni) begin
            r_coe_cnt        <= '0;
            coef_init_done_o <= 1'b0;
        end else if (coef_init_en_i) begin
            // 当加载满 GP_FIR_N 个数据时，拉高 done 标志位
            if (r_coe_cnt == C_COE_CNT_WIDTH'(GP_FIR_N - 1)) begin
                coef_init_done_o <= 1'b1;
            end else begin
                coef_init_done_o <= 1'b0; // 只有当系数完全加载完成，才允许数据流入乘法器阵列，防止半成品系数导致的错误计算
                r_coe_cnt <= r_coe_cnt + 1'b1;
            end
        end else begin
            // 只要外部拉低配置使能，计数器清零，为下一次动态修改系数做准备
            r_coe_cnt <= '0;
        end
    end

    // -------------------------------------------------------------------
    // 3. Valid 信号延迟 (假设 multiplier 有 1 拍延迟)
    // -------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin : b_cc_valid
        if (!rst_ni) begin
            r_valid_d     <= 1'b0;
            m_axis_tvalid <= 1'b0;
        end else begin
            // 只有当系数加载完成，且有新数据时，才传递 valid
            // 这一步防御了上游在 coef_init_done_o 为 0 时乱发 valid 信号
            r_valid_d     <= s_axis_tvalid && coef_init_done_o;
            m_axis_tvalid <= r_valid_d;
        end
    end

    // -------------------------------------------------------------------
    // 4. 乘法器阵列与输出分配
    // -------------------------------------------------------------------
    generate
        for (genvar i = 0; i < GP_FIR_N; i++) begin : gen_conv_array
            multiplier #(
                .GP_IN_WIDTH(GP_IN_WIDTH)
            ) u_multiplier (
                .clk_i    (clk_i),
                .rst_ni   (rst_ni),
                .a_i      (r_x[i]),
                .b_i      (r_h[i]),
                .product_o(product[i])
            );
        end
    endgenerate

    generate
        for (genvar i = 0; i < GP_FIR_N; i++) begin : gen_output_assign
            assign m_axis_tdata[i] = product[i];
        end
    endgenerate

endmodule : conv
