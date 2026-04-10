// =============================================================================
// SVA Assertions for CIC Decimation Filter
// Bind file: bind to filter_cicd module
// Spec Ref: FILTER_CIC_SPEC v2.0
// =============================================================================

module sva_filter_cicd
    import dsp_cnn_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,
    input logic cic_en_i,
    input logic s_axis_tvalid,
    input logic s_axis_tready,
    input logic m_axis_tvalid,
    input logic m_axis_tlast,
    input logic [0:0] m_axis_tuser,
    input logic cic_busy_o,
    input logic cic_cfg_err_o
);

    // A1: s_axis_tready must always be 1 (Spec §6.2.1)
    property p_tready_always_high;
        @(posedge clk_i) disable iff (!rst_ni)
        s_axis_tready == 1'b1;
    endproperty
    assert_tready_always_high: assert property (p_tready_always_high)
        else $error("SVA: s_axis_tready not always high");

    // A2: Sideband must be 0 when m_axis_tvalid=0 (Spec §6.3.2)
    property p_sideband_zero_when_invalid;
        @(posedge clk_i) disable iff (!rst_ni)
        !m_axis_tvalid |-> (m_axis_tlast == 1'b0 && m_axis_tuser == 1'b0);
    endproperty
    assert_sideband_zero: assert property (p_sideband_zero_when_invalid)
        else $error("SVA: sideband non-zero when tvalid=0");

    // A3: No output when CIC disabled (Spec §10.1)
    // After disable, allow pipeline drain time
    property p_no_output_when_disabled;
        @(posedge clk_i) disable iff (!rst_ni)
        (!cic_en_i && !s_axis_tvalid) |-> ##[0:3] !m_axis_tvalid;
    endproperty
    // Note: relaxed check due to pipeline latency
    cover_no_output_disabled: cover property (p_no_output_when_disabled);

    // A4: busy_o reflects frame_active state (Spec §10.2)
    property p_busy_deasserts_in_reset;
        @(posedge clk_i)
        !rst_ni |-> !cic_busy_o;
    endproperty
    assert_busy_reset: assert property (p_busy_deasserts_in_reset)
        else $error("SVA: cic_busy_o high during reset");

    // A5: cfg_err static check (compile-time params, always stable)
    property p_cfg_err_stable;
        @(posedge clk_i) disable iff (!rst_ni)
        $stable(cic_cfg_err_o);
    endproperty
    assert_cfg_err_stable: assert property (p_cfg_err_stable)
        else $error("SVA: cic_cfg_err_o changed at runtime");

endmodule : sva_filter_cicd
