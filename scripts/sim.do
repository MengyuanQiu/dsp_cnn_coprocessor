# =============================================================================
# QuestaSim Simulation Script (Windows .do file)
# Usage: vsim -do sim.do -c (batch mode)  or  vsim -do sim.do (GUI mode)
# =============================================================================
# Before running, set the TB_TOP variable to select the testbench:
#   set TB_TOP tb_filter_cicd
#   set TB_TOP tb_filter_fir
#   set TB_TOP tb_csr_controller
#   set TB_TOP tb_cnn_pe
#   set TB_TOP tb_dsp_cnn_top
# =============================================================================

# Default testbench if not set externally
if {![info exists TB_TOP]} {
    set TB_TOP tb_filter_cicd
}

puts "============================================"
puts "  DSP-CNN Coprocessor Simulation"
puts "  Testbench: $TB_TOP"
puts "============================================"

# Create work library
if {[file exists work]} {
    vdel -all -lib work
}
vlib work
vmap work work

# Compile RTL
puts ">>> Compiling RTL..."
vlog -sv -work work +incdir+../rtl -f ../scripts/filelist_rtl.f

# Compile Testbench
puts ">>> Compiling Testbench: $TB_TOP..."
vlog -sv -work work ../tb/${TB_TOP}.sv

# Elaborate and Run
puts ">>> Running simulation..."
vsim -t 1ps -voptargs="+acc" work.${TB_TOP}

# Add waves (if in GUI mode)
if {[batch_mode] == 0} {
    add wave -divider "DUT"
    add wave -r sim:/${TB_TOP}/u_dut/*
    add wave -divider "TB"
    add wave sim:/${TB_TOP}/*
}

# Run simulation
run -all

# Report results
puts "============================================"
puts "  Simulation Complete: $TB_TOP"
puts "============================================"

# Quit in batch mode
if {[batch_mode]} {
    quit -f
}
