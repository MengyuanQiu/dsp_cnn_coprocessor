module multiplier #(
    parameter int GP_DATA_WIDTH = 8
) (
    input  logic                       clk_i,
    input  logic                       rst_ni,
    input  logic signed [  GP_DATA_WIDTH-1:0] a_i,
    input  logic signed [  GP_DATA_WIDTH-1:0] b_i,
    output logic [2*GP_DATA_WIDTH-2:0] product_o
);

    always_ff @(posedge clk_i or negedge rst_ni) begin : blockName
        if (!rst_ni) begin
            product_o <= '0;
        end else begin
            product_o <= $signed(a_i) * $signed(b_i);
        end
    end

endmodule : multiplier
