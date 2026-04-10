module shiftreg #(
    parameter int GP_DATA_WIDTH = 8,  // Input & output bit-width
    parameter int GP_SR_STAGES  = 4   // Number of shift registers in the shift register chain
) (
    input  logic                     rst_ni,       // Asynchronous active low reset
    input  logic                     ena_i,        // Synchronous active high enable
    input  logic                     clk_i,        // Rising-edge clock
    input  logic [GP_DATA_WIDTH-1:0] data_i,       // Input data with GP_DATA_WIDTH bits MSB:LSB, signed
    output logic [GP_DATA_WIDTH-1:0] data_o,       // Output data with GP_DATA_WIDTH bits MSB:LSB, signed
    output logic                     sr_init_done  // Flag indicates inital shift operation is done 
);
    // -------------------------------------------------------------------
    // CONSTANT DECLARATION
    localparam int C_CNT_WIDTH = $clog2(GP_SR_STAGES + 1);  // Counter width to count up to GP_SR_STAGES
    // REGISTER DECLARATION
    logic [               C_CNT_WIDTH-1:0] r_cnt;
    logic [GP_SR_STAGES*GP_DATA_WIDTH-1:0] w_data;

    // -------------------------------------------------------------------  
    generate
        genvar i;
        for (i = 0; i < GP_SR_STAGES; i = i + 1) begin : g_shift_register
            if (i == 0) begin : g_shift_register_0
                dff #(
                    .GP_DATA_WIDTH(GP_DATA_WIDTH)
                ) REG_COMMUTATOR_INP_DATA (
                    .rst_ni(rst_ni),
                    .ena_i (ena_i),
                    .clk_i (clk_i),
                    .data_i(data_i),
                    .data_o(w_data[(i+1)*GP_DATA_WIDTH-1-:GP_DATA_WIDTH])
                );
            end else begin : g_shift_register_1_n
                dff #(
                    .GP_DATA_WIDTH(GP_DATA_WIDTH)
                ) REG_COMMUTATOR_INP_DATA (
                    .rst_ni(rst_ni),
                    .ena_i (ena_i),
                    .clk_i (clk_i),
                    .data_i(w_data[(i)*GP_DATA_WIDTH-1-:GP_DATA_WIDTH]),
                    .data_o(w_data[(i+1)*GP_DATA_WIDTH-1-:GP_DATA_WIDTH])
                );
            end
        end
    endgenerate

    always_ff @(posedge clk_i or negedge rst_ni) begin : p_count_done
        if (!rst_ni) begin
            r_cnt        <= '0;
            sr_init_done <= 1'b0;
        end else if (ena_i) begin
            if (r_cnt < GP_SR_STAGES) begin
                r_cnt <= r_cnt + 1'b1;
            end else begin
                sr_init_done <= 1'b1;
            end
        end
    end

    assign data_o = w_data[GP_SR_STAGES*GP_DATA_WIDTH-1-:GP_DATA_WIDTH];

endmodule : shiftreg
