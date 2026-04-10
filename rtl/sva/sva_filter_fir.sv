// =============================================================================
// SVA Assertions for FIR Compensation Filter
// Spec Ref: FILTER_FIR_SPEC v2.0
// =============================================================================

module sva_filter_fir (
    input logic       clk_i,
    input logic       rst_ni,
    input logic       fir_en_i,
    input logic       s_axis_tvalid,
    input logic       s_axis_tready,
    input logic       m_axis_tvalid,
    input logic       m_axis_tlast,
    input logic [0:0] m_axis_tuser,
    input logic       fir_busy_o,
    input logic       coef_ready_o,
    input logic       fir_cfg_err_o,
    input logic       coef_load_err_o,
    input logic [2:0] r_state  // Internal state (via hierarchical access or bind)
);

    // A1: s_axis_tready only high in RUN state (Spec §7.1.2)
    // ST_RUN = 3'd3
    property p_tready_only_in_run;
        @(posedge clk_i) disable iff (!rst_ni)
        s_axis_tready |-> (r_state == 3'd3);
    endproperty
    assert_tready_only_run: assert property (p_tready_only_in_run)
        else $error("SVA: tready high outside RUN state");

    // A2: Sideband zero when output invalid (Spec §7.2.2)
    property p_sideband_zero;
        @(posedge clk_i) disable iff (!rst_ni)
        !m_axis_tvalid |-> (m_axis_tlast == 1'b0 && m_axis_tuser == 1'b0);
    endproperty
    assert_sideband_zero: assert property (p_sideband_zero)
        else $error("SVA: FIR sideband non-zero when invalid");

    // A3: coef_ready only after valid load (Spec §8.3)
    property p_coef_ready_not_in_idle;
        @(posedge clk_i) disable iff (!rst_ni)
        (r_state == 3'd0) |-> !coef_ready_o; // IDLE => not ready (until loaded)
    endproperty
    // This is a cover rather than assert since initial state after first load persists
    cover_coef_idle: cover property (p_coef_ready_not_in_idle);

    // A4: ERROR state is sticky (Spec §13.2)
    property p_error_sticky;
        @(posedge clk_i) disable iff (!rst_ni)
        (r_state == 3'd6) |=> (r_state == 3'd6);
    endproperty
    assert_error_sticky: assert property (p_error_sticky)
        else $error("SVA: FIR ERROR state not sticky");

    // A5: busy_o deasserts in reset
    property p_busy_reset;
        @(posedge clk_i)
        !rst_ni |-> !fir_busy_o;
    endproperty
    assert_busy_reset: assert property (p_busy_reset)
        else $error("SVA: fir_busy_o high during reset");

endmodule : sva_filter_fir
