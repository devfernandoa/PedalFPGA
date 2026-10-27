create_clock -name CLOCK_50 -period 20 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# Effects with a clock enable (ce = fx_ce, pulsed by the chain state machine at most once
# per slot, slots are >= SLOT_WAIT+3 = 6 cycles apart): register-to-register paths inside
# them, and from their inputs (chain_x, held SLOT_WAIT+2 = 5 cycles before ce, and the
# knob register params_s, which only changes on in_ready) get 4 cycles.
foreach inst {inst_delay inst_wah inst_phaser inst_reverb} {
    set src [get_registers "*|${inst}|* *|chain_x* *|params_s*"]
    set dst [get_registers "*|${inst}|*"]
    set_multicycle_path -setup 4 -from $src -to $dst
    set_multicycle_path -hold  3 -from $src -to $dst
}

# Tremolo: ratio/ataque only change at the start of each LFO cycle (and only when the
# user changes the setting); diferencia and the rate/diferencia divider result (cociente) only load on clk_Samp.
set trm_src [get_registers {*|inst_tremolo|ratio[*] *|inst_tremolo|ataque[*] *|inst_tremolo|s0|diferencia[*]}]
set_multicycle_path -setup 4 -from $trm_src -to [get_registers {*|inst_tremolo|*}]
set_multicycle_path -hold  3 -from $trm_src -to [get_registers {*|inst_tremolo|*}]

# Board I/O that is either asynchronous or human-speed
set_false_path -to [get_ports {LEDR* HEX*}]
