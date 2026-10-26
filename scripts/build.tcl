#
# Headless synthesis, implementation and bitstream generation.
#
#   vivado -mode batch -source scripts/build.tcl
#
# Non-project mode: no .xpr, no IP to regenerate. The nine MMCME2_ADV are
# instantiated inline in CFI.sv, so the whole design is the source tree below.
#

set repo        [file normalize [file join [file dirname [info script]] ..]]
set rtl         [file join $repo hdl rtl]
set outputDir   [file join $repo build]
# Nexys Video: XC7A200T-1SBG484C. 4 channels need 9 of its 10 MMCMs.
set part        xc7a200tsbg484-1
set top         TOP

file mkdir $outputDir

# Setup design sources. No DuT on this FPGA: the UART-driven injector is the
# whole design.
read_verilog -sv [file join $rtl SR_LATCH.sv]
read_verilog -sv [file join $rtl OFFSET.sv]
read_verilog -sv [file join $rtl SYNCHRONIZER.sv]
read_verilog -sv [file join $rtl TRIGGER.sv]
read_verilog -sv [file join $rtl CDC_PULSE.sv]
read_verilog -sv [file join $rtl UART_RX.sv]
read_verilog -sv [file join $rtl UART_TX.sv]
read_verilog -sv [file join $rtl GLITCH_CHANNEL.sv]
read_verilog -sv [file join $rtl CFI.sv]
read_verilog -sv [file join $rtl TOP.sv]

read_xdc [file join $repo hdl constrs NexysVideo.xdc]

# Run synthesis.
synth_design            -top $top -part $part -include_dirs $rtl

write_checkpoint        -force $outputDir/post_synth.dcp
report_timing_summary   -file  $outputDir/post_synth_timing_summary.rpt
report_utilization      -file  $outputDir/post_synth_util.rpt

# Implementation
opt_design
place_design
report_clock_utilization -file $outputDir/clock_util.rpt

# Optionally run optimization if there are timing violations after placement
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} {
    puts "Found setup timing violations => running physical optimization"
    phys_opt_design
}

write_checkpoint        -force $outputDir/post_place.dcp
report_utilization      -file  $outputDir/post_place_util.rpt
report_timing_summary   -file  $outputDir/post_place_timing_summary.rpt

route_design
write_checkpoint        -force $outputDir/post_route.dcp
report_route_status     -file  $outputDir/post_route_status.rpt
report_timing_summary   -file  $outputDir/post_route_timing_summary.rpt
report_power            -file  $outputDir/post_route_power.rpt
report_drc              -file  $outputDir/post_imp_drc.rpt

write_bitstream -force $outputDir/cfi_4.bit
