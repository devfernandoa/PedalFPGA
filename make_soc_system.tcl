# Builds soc_system.qsys from the Terasic DE10-Standard GHRD system:
# keeps hps_0 (unchanged, so the SD card preloader still matches) and clk_0,
# drops the demo peripherals and puts pedal_regs on the lightweight HPS-to-FPGA bridge.
# Run: qsys-script --script=make_soc_system.tcl --search-path="$PWD,$"
package require -exact qsys 16.1
load_system soc_system.qsys

foreach i {ILC button_pio dipsw_pio f2sdram_only_master fpga_only_master hps_only_master
           jtag_uart led_pio mm_bridge_0 sysid_qsys} {
    remove_instance $i
}
foreach e {button_pio_external_connection dipsw_pio_external_connection led_pio_external_connection} {
    remove_interface $e
}

add_instance pedal_regs_0 pedal_regs
add_connection clk_0.clk pedal_regs_0.clock
add_connection clk_0.clk_reset pedal_regs_0.reset
add_connection hps_0.h2f_lw_axi_master pedal_regs_0.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/pedal_regs_0.s0 baseAddress 0x0000
add_interface pedal conduit end
set_interface_property pedal EXPORT_OF pedal_regs_0.pedal

validate_system
save_system soc_system.qsys
