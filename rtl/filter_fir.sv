module filter_fir #(
    parameter int GP_IN_WIDTH = 8,
    parameter int GP_SHIFT = 0,
    parameter int GP_FIR_N = 8,
    parameter int GP_OUT_WIDTH = 8
) (
    input logic clk_i,
    input logic rst_ni,
    axi_stream_if.slave s_axis,
    axi_stream_if.master m_axis
);
    // 内部常量声明
    localparam int C_CNT_WIDTH = $clog2(GP_FIR_N);

    // conv 模块相关信号
    logic                            conv_init;
    logic                            conv_init_done;
    logic signed [  GP_IN_WIDTH-1:0] conv_coef_data;
    logic                            conv_s_valid;
    logic                            conv_m_valid;
    logic signed [  GP_IN_WIDTH-1:0] conv_s_tdata;  // 数据输入
    logic signed [2*GP_IN_WIDTH-2:0] conv_m_tdata[     GP_FIR_N];

    // adder_tree 模块相关信号
    logic                            adder_tree_s_valid;
    logic                            adder_tree_m_valid;
    logic signed [2*GP_IN_WIDTH-2:0] adder_tree_s_tdata[GP_FIR_N];
    logic signed [ GP_OUT_WIDTH-1:0] adder_tree_m_tdata;

    // coe rom 相关信号
    logic        [  C_CNT_WIDTH-1:0] coe_rom_addr;
    logic signed [  GP_IN_WIDTH-1:0] coe_rom_data;
    // logic                            coe_rom_en; 其用init_coe信号替代，见后文

    // 其他的相关控制信号
    logic                            flush_frame;  // 检测到帧尾以及复位后，启动冲刷信号
    logic                            init_coe;  // 系数加载使能信号
    logic        [    C_CNT_WIDTH:0] frame_cnt;  // 帧内数据计数器，控制冲刷过程
    logic        [    C_CNT_WIDTH:0] coe_cnt;  // 系数计数器，控制系数加载和冲刷过程


    // when conv_init_done is hign , assert s_axis.tready to start accepting data
    assign s_axis.tready = conv_init_done ? 1'b1 : 1'b0;

    always_ff @(posedge clk_i or negedge rst_ni) begin : blk_flush_cnt_cc
        if (!rst_ni) begin
            frame_cnt <= 0;
        end else if (flush_frame) begin
            frame_cnt <= frame_cnt + 1'b1;
        end else begin
            frame_cnt <= 0;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : blk_flush_frame_cc
        if (!rst_ni) begin
            flush_frame <= 1'b1;  // 上电复位时默认进入冲刷状态，等待第一帧数据到来
        end else if (s_axis.tlast) begin
            flush_frame <= 1'b1;
        end else if (frame_cnt == (GP_FIR_N - 1)) begin
            flush_frame <= 1'b0;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : blk_conv_s_valid_cc
        if (!rst_ni) begin
            conv_s_valid <= 1'b0;
        end else begin
            // 只要处于冲刷状态，或者总线上有真实的握手数据，就向后级流水线传递 Valid
            conv_s_valid <= flush_frame || (s_axis.tvalid && s_axis.tready);
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : blk_conv_s_tdata_cc
        if (!rst_ni) begin
            conv_s_tdata <= '0;
        end else if (flush_frame) begin
            conv_s_tdata <= '0;
        end else begin
            conv_s_tdata <= s_axis.tdata;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : blk_init_coe_cc
        if (!rst_ni) begin
            init_coe <= 1'b1;
        end else if (s_axis.tuser[0]) begin
            init_coe <= 1'b1;
        end else if (coe_cnt == (GP_FIR_N - 1)) begin
            init_coe <= 1'b0;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : blk_cnt_coe_cc
        if (!rst_ni) begin
            coe_cnt <= 0;
        end else if (init_coe) begin
            coe_cnt <= coe_cnt + 1'b1;
        end else begin
            coe_cnt <= 0;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : blk_conv_init_cc
        if (!rst_ni) begin
            conv_init <= 1'b0;
        end else if (init_coe) begin
            conv_init <= 1'b1;
        end else begin
            conv_init <= 1'b0;
        end
    end

    assign coe_rom_addr = coe_cnt;
    assign conv_coef_data = coe_rom_data;

    always_comb begin
        adder_tree_s_valid = conv_m_valid;
        for(int i = 0; i < GP_FIR_N; i++) begin
            adder_tree_s_tdata[i] = conv_m_tdata[i];
        end
        m_axis.tvalid = adder_tree_m_valid;
        m_axis.tdata = adder_tree_m_tdata;
    end


    conv #(
        .GP_IN_WIDTH(GP_IN_WIDTH),
        .GP_FIR_N(GP_FIR_N)
    ) u_conv (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .s_axis_tvalid(conv_s_valid),
        .s_axis_tdata(conv_s_tdata),
        .m_axis_tvalid(conv_m_valid),
        .m_axis_tdata(conv_m_tdata),
        .coef_init_en_i(conv_init),
        .coef_init_done_o(conv_init_done),
        .coef_data_i(conv_coef_data)
    );


    adder_tree #(
        .GP_NUM_INPUTS(GP_FIR_N),
        .GP_IN_WIDTH(2 * GP_IN_WIDTH - 2),
        .GP_OUT_WIDTH(GP_OUT_WIDTH),
        .GP_SHIFT(GP_SHIFT)
    ) u_adder_tree (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .s_axis_tvalid(adder_tree_s_valid),
        .s_axis_tdata(adder_tree_s_tdata),
        .m_axis_tvalid(adder_tree_m_valid),
        .m_axis_tdata(adder_tree_m_tdata)
    );

    // coe rom 模块实例化

endmodule : filter_fir
