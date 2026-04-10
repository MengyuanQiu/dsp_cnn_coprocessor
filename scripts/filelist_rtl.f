// =============================================================================
// RTL File List for DSP-CNN Coprocessor
// Usage: vlog -f filelist_rtl.f
// =============================================================================

// Global Package
../rtl/dsp_cnn_pkg.sv

// Primitive building blocks
../rtl/dff.sv
../rtl/shiftreg.sv
../rtl/accumulator.sv
../rtl/adder.sv
../rtl/multiplier.sv
../rtl/comb_stage.sv
../rtl/adder_tree.sv
../rtl/axi_stream_if.sv
../rtl/conv.sv

// DSP Front-End
../rtl/filter_cicd.sv
../rtl/filter_fir.sv

// CNN Core
../rtl/cnn_pe.sv
../rtl/cnn_post_processor.sv
../rtl/cnn_inference_engine.sv

// System
../rtl/csr_controller.sv
../rtl/dsp_cnn_top.sv

// SVA Assertions (optional, comment out if not needed)
../rtl/sva/sva_filter_cicd.sv
../rtl/sva/sva_filter_fir.sv
../rtl/sva/sva_csr_controller.sv
../rtl/sva/sva_cnn_engine.sv
