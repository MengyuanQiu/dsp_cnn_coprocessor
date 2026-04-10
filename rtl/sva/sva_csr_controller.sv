// =============================================================================
// SVA Assertions for CSR Controller
// Spec Ref: CSR_INTERRUPT_SPEC v1.0
// =============================================================================

module sva_csr_controller (
    input logic       clk_i,
    input logic       rst_ni,
    input logic       sys_busy_i,
    input logic       irq_o,
    input logic [5:0] r_irq_raw,
    input logic [5:0] r_irq_mask,
    input logic       r_start_pulse,
    input logic       r_done_sticky,
    input logic       r_err_sticky,
    input logic       r_err_captured
);

    // A1: START pulse is single-cycle (SC behavior, Spec §5.1.1)
    property p_start_single_cycle;
        @(posedge clk_i) disable iff (!rst_ni)
        r_start_pulse |=> !r_start_pulse;
    endproperty
    assert_sc_start: assert property (p_start_single_cycle)
        else $error("SVA: START pulse not self-clearing");

    // A2: IRQ output matches masked raw (Spec §6)
    property p_irq_masked;
        @(posedge clk_i) disable iff (!rst_ni)
        !(|(r_irq_raw & r_irq_mask)) |-> !irq_o;
    endproperty
    assert_irq_masked: assert property (p_irq_masked)
        else $error("SVA: IRQ asserted when all masked");

    // A3: First-error hold (Spec §5.3)
    property p_first_error_hold;
        @(posedge clk_i) disable iff (!rst_ni)
        r_err_captured |=> r_err_captured;
    endproperty
    // Note: stays captured until CLR_ERR or soft_rst
    cover_first_error: cover property (p_first_error_hold);

    // A4: DONE and ERR are sticky (Spec §2.4)
    property p_done_sticky;
        @(posedge clk_i) disable iff (!rst_ni)
        $rose(r_done_sticky) |=> r_done_sticky;
    endproperty
    assert_done_sticky: assert property (p_done_sticky)
        else $error("SVA: DONE not sticky");

    // A5: Reset clears all status
    property p_reset_clears;
        @(posedge clk_i)
        !rst_ni |-> (!r_done_sticky && !r_err_sticky && !r_err_captured);
    endproperty
    assert_reset_clears: assert property (p_reset_clears)
        else $error("SVA: Status not cleared on reset");

endmodule : sva_csr_controller
