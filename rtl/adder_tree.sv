module adder_tree #(
    parameter int GP_NUM_INPUTS = 9,   // 输入数据的个数 N (>=2)
    parameter int GP_IN_WIDTH   = 16,  // 输入数据的位宽
    parameter int GP_OUT_WIDTH  = 8,   // 输出数据的位宽 (通常小于输入位宽，需进行截断和饱和处理)
    parameter int GP_SHIFT      = 0    // 输出右移位数 (相当于小数点位置)，默认为0表示不右移
) (
    input  logic                           clk_i,
    input  logic                           rst_ni,
    input  logic                           s_axis_tvalid,
    input  logic signed [ GP_IN_WIDTH-1:0] s_axis_tdata   [GP_NUM_INPUTS],  // SystemVerilog 解包数组输入
    output logic                           m_axis_tvalid,
    output logic signed [GP_OUT_WIDTH-1:0] m_axis_tdata
);

    // -------------------------------------------------------------------
    // 常量计算与参数定义
    // -------------------------------------------------------------------
    // 1. 计算总级数 S = ceil(log2(N))
    localparam int C_STAGES = $clog2(GP_NUM_INPUTS);

    // 2. 计算最终输出位宽 (每级加法增加 1-bit 符号位防溢出)
    localparam int C_INTERNAL_WIDTH = GP_IN_WIDTH + C_STAGES;

    // -------------------------------------------------------------------
    // 辅助函数：计算第 stage 级的输入节点数 (完美复现数学推导)
    // -------------------------------------------------------------------
    function automatic integer get_nodes(input integer stage, input integer n);
        integer nodes = n;
        for (int i = 0; i < stage; i++) begin
            nodes = (nodes + 1) >> 1;  // 向上取整：ceil(nodes / 2)
        end
        return nodes;
    endfunction

    // -------------------------------------------------------------------
    // 内部信号声明
    // -------------------------------------------------------------------
    // 二维矩阵：存放每一级流水线的数据。
    // 维度 1: [0 到 C_STAGES]，共 C_STAGES + 1 层 (包含第0层初始数据)
    // 维度 2: [GP_NUM_INPUTS]，为了通过编译，第二维统一定义为最大宽度，但我们只用有效部分
    logic signed [C_INTERNAL_WIDTH-1:0] r_stage_data[C_STAGES+1][GP_NUM_INPUTS];

    // -------------------------------------------------------------------
    // 第 0 级：输入数据符号扩展，接入加法树根部
    // -------------------------------------------------------------------
    generate
        for (genvar i = 0; i < GP_NUM_INPUTS; i++) begin : gen_input_ext
            // 纯组合逻辑，将输入符号扩展到最大位宽
            assign r_stage_data[0][i] = C_INTERNAL_WIDTH'(signed'(s_axis_tdata[i]));
        end
    endgenerate

    // -------------------------------------------------------------------
    // 第 1 到 S 级：动态生成流水线加法器和透传逻辑
    // -------------------------------------------------------------------
    generate
        for (genvar s = 0; s < C_STAGES; s++) begin : gen_tree_stages
            // 利用函数在编译期算出当前级的输入节点数、加法器个数和透传标志
            localparam int NODES_IN = get_nodes(s, GP_NUM_INPUTS);
            localparam int ADDERS = NODES_IN >> 1;  // 等同于 floor(NODES_IN / 2)
            localparam int PASSTHRU = NODES_IN[0];

            // 1. 生成加法器
            for (genvar i = 0; i < ADDERS; i++) begin : gen_adders
                adder #(
                    .GP_DATA_WIDTH(C_INTERNAL_WIDTH)
                ) u_adder (
                    .clk_i(clk_i),
                    .rst_ni(rst_ni),
                    .a_i(r_stage_data[s][2*i]),
                    .b_i(r_stage_data[s][2*i+1]),
                    .sum_o(r_stage_data[s+1][i])
                );
            end

            // 2. 生成透传线 (如果当前节点数为奇数)
            if (PASSTHRU == 1) begin : gen_passthru
                always_ff @(posedge clk_i or negedge rst_ni) begin
                    if (!rst_ni) begin
                        r_stage_data[s+1][ADDERS] <= '0;
                    end else begin
                        // 将本级最后一个落单的节点，直接打一拍送到下一级
                        r_stage_data[s+1][ADDERS] <= r_stage_data[s][NODES_IN-1];
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------
    // 顶层输出映射：截断 (Truncation) 与饱和 (Saturation) (打1拍)
    // -------------------------------------------------------------------

    // 预先计算目标位宽所能表示的最大正数和最大负数
    // 用 C_INTERNAL_WIDTH 位宽保存，防止比较时位宽不匹配导致判断错误
    localparam logic signed [C_INTERNAL_WIDTH-1:0] C_MAX_VAL = (1 << (GP_OUT_WIDTH - 1)) - 1;
    localparam logic signed [C_INTERNAL_WIDTH-1:0] C_MIN_VAL = -(1 << (GP_OUT_WIDTH - 1));

    logic signed [C_INTERNAL_WIDTH-1:0] w_full_data;
    logic signed [C_INTERNAL_WIDTH-1:0] w_shifted_data;

    // 获取加法树最后一级的全精度输出
    assign w_full_data = r_stage_data[C_STAGES][0];

    // 1. 截断 (Truncation)：进行算术右移，丢弃指定的低位 fractional bits
    assign w_shifted_data = w_full_data >>> GP_SHIFT;

    // 2. 饱和检查与寄存输出 (增加一拍潜伏期)
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            m_axis_tdata <= '0;
        end else begin
            if (w_shifted_data > C_MAX_VAL) begin
                // 正溢出：强制输出最大正数 (例如 16位就是 16'h7FFF)
                m_axis_tdata <= GP_OUT_WIDTH'(C_MAX_VAL);
            end else if (w_shifted_data < C_MIN_VAL) begin
                // 负溢出：强制输出最大负数 (例如 16位就是 16'h8000)
                m_axis_tdata <= GP_OUT_WIDTH'(C_MIN_VAL);
            end else begin
                // 无溢出：安全地直接取低位给输出
                m_axis_tdata <= w_shifted_data[GP_OUT_WIDTH-1:0];
            end
        end
    end

    // -------------------------------------------------------------------
    // Valid 信号同步延迟管道 
    // -------------------------------------------------------------------
    // 总延迟 = 加法树级数 (C_STAGES) + 最终输出饱和打拍 (1)
    localparam int C_TOTAL_LATENCY = C_STAGES + 1;

    logic [C_TOTAL_LATENCY-1:0] r_valid_pipe;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_valid_pipe <= '0;
        end else begin
            // 每次把 s_axis_tvalid 挤入管道最低位，最高位就是最终的 m_axis_tvalid
            r_valid_pipe <= {r_valid_pipe[C_TOTAL_LATENCY-2:0], s_axis_tvalid};
        end
    end

    // 输出最终的 Valid
    assign m_axis_tvalid = r_valid_pipe[C_TOTAL_LATENCY-1];

endmodule : adder_tree
