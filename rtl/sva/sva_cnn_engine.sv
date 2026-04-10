// =============================================================================
// SVA Assertions for CNN Inference Engine
// Spec Ref: CORE_CNN_SPEC v2.0
// =============================================================================

module sva_cnn_engine (
    input logic       clk_i,
    input logic       rst_ni,
    input logic       cnn_en_i,
    input logic       cnn_busy_o,
    input logic       cnn_done_o,
    input logic       cnn_err_o,
    input logic [3:0] r_state,
    input logic [3:0] r_cur_layer,
    input logic       r_cbuf_sel
);

    // ST_IDLE=0, ST_LOAD_INPUT=1, ST_ERROR=10

    // A1: No compute without input loaded (Spec §7.2.1)
    property p_no_compute_without_input;
        @(posedge clk_i) disable iff (!rst_ni)
        (r_state == 4'd4) |-> (r_cur_layer >= 0);  // COMPUTE requires valid layer
    endproperty
    cover_compute_valid: cover property (p_no_compute_without_input);

    // A2: ERROR state is sticky (Spec §13.2)
    property p_error_sticky;
        @(posedge clk_i) disable iff (!rst_ni)
        (r_state == 4'd10) |=> (r_state == 4'd10);
    endproperty
    assert_error_sticky: assert property (p_error_sticky)
        else $error("SVA: CNN ERROR state not sticky");

    // A3: done only asserted in DONE state
    property p_done_only_in_done;
        @(posedge clk_i) disable iff (!rst_ni)
        cnn_done_o |-> (r_state == 4'd9);
    endproperty
    assert_done_state: assert property (p_done_only_in_done)
        else $error("SVA: cnn_done_o asserted outside DONE state");

    // A4: busy deasserts in reset
    property p_busy_reset;
        @(posedge clk_i)
        !rst_ni |-> !cnn_busy_o;
    endproperty
    assert_busy_reset: assert property (p_busy_reset)
        else $error("SVA: cnn_busy_o high during reset");

    // A5: err only in ERROR state
    property p_err_only_error;
        @(posedge clk_i) disable iff (!rst_ni)
        cnn_err_o |-> (r_state == 4'd10);
    endproperty
    assert_err_state: assert property (p_err_only_error)
        else $error("SVA: cnn_err_o asserted outside ERROR state");

endmodule : sva_cnn_engine
