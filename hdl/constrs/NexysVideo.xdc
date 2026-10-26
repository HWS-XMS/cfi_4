#
# Digilent Nexys Video (Artix-7 XC7A200T-1SBG484C).
#
# Pin names/pins are from the Digilent Nexys-Video master XDC. The glitched
# clock leaves on Pmod JA1 and the external target's trigger returns on JA4;
# a trigger mirror for the scope is on JA2. trigger_in is asynchronous and is
# synchronised per channel, so it is a false path, not a clock.
#

# --------------------------------------------------
# 100 MHz system clock (sysclk, R4)
# --------------------------------------------------
set_property -dict { PACKAGE_PIN R4 IOSTANDARD LVCMOS33 } [get_ports sysclk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports sysclk]

# --------------------------------------------------
# USB-UART bridge
#   uart_rx (FPGA input)  <- uart_tx_in  (V18), host -> FPGA
#   uart_tx (FPGA output) -> uart_rx_out (AA19), FPGA -> host
# --------------------------------------------------
set_property -dict { PACKAGE_PIN V18  IOSTANDARD LVCMOS33 } [get_ports uart_rx]
set_property -dict { PACKAGE_PIN AA19 IOSTANDARD LVCMOS33 } [get_ports uart_tx]

# --------------------------------------------------
# Pmod JA: glitched clock out, trigger mirror, trigger in
# --------------------------------------------------
# JA1 = glitched clock to the external target
set_property -dict { PACKAGE_PIN AB22 IOSTANDARD LVCMOS33 } [get_ports target_clk_out]
# JA2 = trigger mirror for the scope
set_property -dict { PACKAGE_PIN AB21 IOSTANDARD LVCMOS33 } [get_ports trig_out]
# JA4 = trigger in from the external target (async, 2-FF synchronised per channel).
# PULLDOWN gives a defined idle-low when the pin is undriven, so a soft trigger
# or a real rising edge is always a clean 0->1 transition.
set_property -dict { PACKAGE_PIN AB18 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN } [get_ports trigger_in]
set_false_path -from [get_ports trigger_in]

# --------------------------------------------------
# LEDs = glitch_count[7:0]
# --------------------------------------------------
set_property -dict { PACKAGE_PIN T14 IOSTANDARD LVCMOS25 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS25 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS25 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS25 } [get_ports { led[3] }]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS25 } [get_ports { led[4] }]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS25 } [get_ports { led[5] }]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS25 } [get_ports { led[6] }]
set_property -dict { PACKAGE_PIN Y13 IOSTANDARD LVCMOS25 } [get_ports { led[7] }]
set_false_path -to [get_ports { led[*] }]
set_false_path -to [get_ports trig_out]

# --------------------------------------------------
# Configuration
# --------------------------------------------------
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO      [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
