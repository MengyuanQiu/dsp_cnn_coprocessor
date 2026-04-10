module dff #(
    parameter int GP_DATA_WIDTH = 8  // Set input & output bit-width
) (
    input  logic                     rst_ni,  // Asynchronous active low reset
    input  logic                     ena_i,   // Synchronous active high enable
    input  logic                     clk_i,   // Rising-edge clock
    input  logic [GP_DATA_WIDTH-1:0] data_i,  // Input data with GP_DATA_WIDTH bits MSB:LSB, signed or unsigned
    output logic [GP_DATA_WIDTH-1:0] data_o   // Output data with GP_DATA_WIDTH bits MSB:LSB, signed or unsigned
);
    // -------------------------------------------------------------------
    logic [GP_DATA_WIDTH-1:0] r_data;
    // -------------------------------------------------------------------  
    always_ff @(posedge clk_i or negedge rst_ni) begin : p_dff
        if (!rst_ni) begin
            r_data <= 'd0;
        end
        else if (ena_i) begin
            r_data <= data_i;
        end
    end

    assign data_o = r_data;
endmodule : dff
