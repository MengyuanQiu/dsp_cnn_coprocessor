/*
_d : delay
_i : input
_o : output
GP_ : global parameter
C_ : constant
w_ : combinational
r_ : register
*/

module filter_cicd #(
    parameter int GP_CICD_R = 64,  // CIC Filter decimation factor
    parameter int GP_CICD_N = 5,  // CIC Filter order
    parameter int GP_CICD_M = 1,  // CIC Filter differential delay
    parameter int GP_CICD_PHASE = 0,  // CIC Filter phase (0 or 1)
    parameter int GP_IN_WIDTH = 8,  // Input data bit-width
    parameter int GP_OUT_WIDTH = GP_IN_WIDTH + GP_CICD_N * $clog2(GP_CICD_M * GP_CICD_R)  // Output data bit-width
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic [ GP_IN_WIDTH-1:0] s_axis_tdata,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic [GP_OUT_WIDTH-1:0] m_axis_tdata
);
    // 扩展位宽
    localparam int C_EX_WIDTH = GP_OUT_WIDTH - GP_IN_WIDTH;

    assign s_axis_tready = 1'b1;


    /****************/
    /* RING COUNTER */
    /****************/
    logic [GP_CICD_R-1:0] r_ring_cnter;
    always_ff @(posedge clk_i or negedge rst_ni) begin : r_ring_cnter_ff
        if (!rst_ni) begin
            r_ring_cnter <= GP_CICD_R'(1);
        end else if (s_axis_tvalid) begin
            r_ring_cnter[0] <= r_ring_cnter[GP_CICD_R-1];
            r_ring_cnter[GP_CICD_R-1:1] <= r_ring_cnter[GP_CICD_R-2:0];
        end
    end

    /****************/
    /* ACCUMULATOR  */
    /****************/
    logic signed [GP_OUT_WIDTH-1:0] w_data_ex;
    logic signed [GP_OUT_WIDTH-1:0] w_in_add [GP_CICD_N];
    // 符号扩展
    assign w_data_ex = {{C_EX_WIDTH{s_axis_tdata[GP_IN_WIDTH-1]}}, s_axis_tdata};

    generate
        for (genvar i = 0; i < GP_CICD_N; i++) begin : gen_add
            if (i == 0) begin : gen_in_add_0
                // y[n] = x[n] + y[n-1]
				accumulator #(
					.GP_DATA_WIDTH(GP_OUT_WIDTH)
				) CIC_ACC (
					.clk_i(clk_i),
					.rst_ni(rst_ni),
					.ena_i(s_axis_tvalid),
					.data_i(w_data_ex),
					.data_o(w_in_add[0])
				);
            end else begin : gen_in_add_1_n
                // y_i[n] = y_{i-1}[n] + y_i[n-1]
				accumulator #(
					.GP_DATA_WIDTH(GP_OUT_WIDTH)
				) CIC_ACC (
					.clk_i(clk_i),
					.rst_ni(rst_ni),
					.ena_i(s_axis_tvalid),
					.data_i(w_in_add[i-1]),
					.data_o(w_in_add[i])
				);
            end
        end
    endgenerate

    /**********************/
    /* DOWNSAMPLE SECTION */
    /**********************/
    logic w_sclk;
    logic [GP_OUT_WIDTH-1:0] r_downsample_out;
    assign w_sclk = r_ring_cnter[GP_CICD_PHASE] & s_axis_tvalid;
    dff #(
        .GP_DATA_WIDTH(GP_OUT_WIDTH)
    ) cicd_downsample (
        .rst_ni(rst_ni),
        .ena_i (w_sclk),
        .clk_i (clk_i),
        .data_i(w_in_add[GP_CICD_N-1]),
        .data_o(r_downsample_out)
    );

	/****************/
    /* COMB SECTION */
    /****************/
    // 声明一个数组来连接各级梳状器的输入和输出
    // 维度为 [0 到 N]，多出的一级用来接收下采样器的初始输入
    logic [GP_OUT_WIDTH-1:0] w_comb_data [GP_CICD_N+1];
    logic [GP_CICD_N-1:0]    w_comb_init_done;

    // 数组的第 0 个元素，就是下采样器的输出
    assign w_comb_data[0] = r_downsample_out;

    generate
        for (genvar i = 0; i < GP_CICD_N; i++) begin : g_comb_stages
            comb_stage #(
                .GP_DATA_WIDTH(GP_OUT_WIDTH),
                .GP_DELAY_M   (GP_CICD_M)
            ) u_comb (
                .clk_i       (clk_i),
                .rst_ni      (rst_ni),
                .ena_i       (w_sclk),               // 仅在下采样时钟有效时运行
                .data_i      (w_comb_data[i]),       // 吃入上一级的数据
                .data_o      (w_comb_data[i+1]),     // 输出给下一级的数据
                .init_done_o (w_comb_init_done[i])
            );
        end
    endgenerate

    // 最后一级梳状器的输出就是 CIC 滤波器的最终数据输出
    assign m_axis_tdata = w_comb_data[GP_CICD_N];

    // Valid 信号对齐与垃圾数据屏蔽
    // 注意：因为我们在梳状器内部加了一级寄存器，N 级梳状器总共多出了 N 拍延迟。
    logic [GP_CICD_N-1:0] w_sclk_d;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            w_sclk_d <= '0;
        end else if (w_sclk) begin
            w_sclk_d <= {w_sclk_d[GP_CICD_N-2:0], 1'b1}; // 填 1，作为流水线级数计数器
        end
    end

    // 生成输出 Valid 脉冲
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            m_axis_tvalid <= 1'b0;
        end else begin
            // 核心逻辑：
            // w_sclk 是当前周期的脉冲。
            // 因为用 always_ff，赋值会在下一个时钟周期生效（刚好延后 1 拍，与 comb_stage 的输出数据完美对齐）。
            // 前面的 && 条件只是用来屏蔽刚开机时前几个无效的抽样脉冲。
            m_axis_tvalid <= w_sclk && w_comb_init_done[GP_CICD_N-1] && w_sclk_d[GP_CICD_N-1];
        end
    end

endmodule : filter_cicd
