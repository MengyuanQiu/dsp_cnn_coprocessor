module accumulator #(
    parameter int GP_DATA_WIDTH = 8
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     ena_i,
    input  logic [GP_DATA_WIDTH-1:0] data_i,
    output logic [GP_DATA_WIDTH-1:0] data_o
);

    logic signed [GP_DATA_WIDTH-1:0] r_data;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_data <= '0;
        end else if(ena_i) begin
            r_data <= r_data + $signed(data_i);
        end
    end

    assign data_o = r_data;

endmodule : accumulator
