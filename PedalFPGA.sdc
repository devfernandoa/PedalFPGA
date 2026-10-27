create_clock -name CLOCK_50 -period 20 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# Effects with a per-sample clock enable (ce = in_ready, ~1 pulse every 1041 clocks):
# register-to-register paths inside them, and from their inputs (sample_gated and the
# knob register params_s, which also only change on in_ready), get 4 cycles.
# ponytail: 4 is way below 1041, raise if needed.
foreach inst {inst_delay inst_wah inst_phaser inst_reverb} {
    set src [get_registers "*|${inst}|* *|sample_gated* *|params_s*"]
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
