## This file is a general .xdc for the Nexys A7-100T
## To use it in a project:
## - uncomment the lines corresponding to used pins
## - rename the used ports (in each line, after get_ports) according to the top level signal names in the project

## Clock signal
set_property PACKAGE_PIN E3 [get_ports CLK100MHZ]
set_property IOSTANDARD LVCMOS33 [get_ports CLK100MHZ]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports CLK100MHZ]


## LEDs
set_property PACKAGE_PIN H17 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]
set_property PACKAGE_PIN C12 [get_ports CPU_RESETN]
set_property IOSTANDARD LVCMOS33 [get_ports CPU_RESETN]