module adder #(
    parameter int GP_DATA_WIDTH = 8
) (
    input  logic                            clk_i,
    input  logic                            rst_ni,
    input  logic signed [GP_DATA_WIDTH-1:0] a_i,
    input  logic signed [GP_DATA_WIDTH-1:0] b_i,
    output logic signed [GP_DATA_WIDTH-1:0] sum_o   // 这里传入的位宽保证了相加后不会溢出，输出位宽和输入相同
);

    always_ff @(posedge clk_i or negedge rst_ni) begin : b_add
        if (!rst_ni) begin
            sum_o <= '0;
        end else begin
            sum_o <= a_i + b_i;
        end
    end

endmodule : adder
