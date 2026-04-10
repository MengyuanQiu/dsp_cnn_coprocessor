module comb_stage #(
    parameter int GP_DATA_WIDTH = 8,
    parameter int GP_DELAY_M    = 1  // 差分延迟量 (通常为 1 或 2)
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     ena_i,
    input  logic [GP_DATA_WIDTH-1:0] data_i,
    output logic [GP_DATA_WIDTH-1:0] data_o,
    output logic                     init_done_o
);

    logic [GP_DATA_WIDTH-1:0] w_delay_out;
    logic [GP_DATA_WIDTH-1:0] r_diff;

    // 1. 延迟线 (延时 M 拍)
    shiftreg #(
        .GP_DATA_WIDTH(GP_DATA_WIDTH),
        .GP_SR_STAGES (GP_DELAY_M)
    ) u_delay_line (
        .rst_ni      (rst_ni),
        .ena_i       (ena_i),
        .clk_i       (clk_i),
        .data_i      (data_i),
        .data_o      (w_delay_out),
        .sr_init_done(init_done_o)
    );

    // 2. 减法器与输出寄存器 (流水线化 Pipelining)
    // y[n] = x[n] - x[n-M]，并将结果打一拍输出
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_diff <= '0;
        end else if (ena_i) begin
            r_diff <= data_i - w_delay_out;
        end
    end

    assign data_o = r_diff;

endmodule : comb_stage
