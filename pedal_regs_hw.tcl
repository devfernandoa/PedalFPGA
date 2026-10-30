# Platform Designer component for pedal_regs.vhd (register map in the .vhd header)
package require -exact qsys 16.1

set_module_property NAME pedal_regs
set_module_property VERSION 1.0
set_module_property DISPLAY_NAME "PedalFPGA registers"
set_module_property GROUP "PedalFPGA"
set_module_property EDITABLE false

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL pedal_regs
add_fileset_file pedal_regs.vhd VHDL PATH pedal_regs.vhd TOP_LEVEL_FILE

add_interface clock clock end
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset reset Input 1

add_interface s0 avalon end
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
set_interface_property s0 addressUnits WORDS
set_interface_property s0 readLatency 1
set_interface_property s0 readWaitTime 0
set_interface_property s0 writeWaitTime 0
add_interface_port s0 avs_address address Input 5
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32
add_interface_port s0 avs_readdata readdata Output 32

add_interface pedal conduit end
add_interface_port pedal chain chain Output 32
add_interface_port pedal params params Output 110
add_interface_port pedal cfg config Output 2
add_interface_port pedal volume volume Output 5
add_interface_port pedal cap_sample cap_sample Input 16
add_interface_port pedal cap_valid cap_valid Input 1
