create_clock -name CLOCK_50 -period 20 [get_ports CLOCK_50]
derive_pll_clocks
derive_clock_uncertainty

# Effects with a clock enable (ce = fx_ce, pulsed by the chain state machine at most once
# per slot, slots are >= SLOT_WAIT+3 = 6 cycles apart): register-to-register paths inside
# them, and from their inputs (chain_x, held SLOT_WAIT+2 = 5 cycles before ce, and the
# knob register params_s, which only changes on in_ready) get 4 cycles.
foreach inst {inst_distortion inst_overdrive inst_tremolo inst_delay inst_wah inst_phaser inst_reverb
              inst_compressor inst_chorus inst_flanger} {
    set src [get_registers "*|${inst}|* *|chain_x* *|params_s*"]
    set dst [get_registers "*|${inst}|*"]
    set_multicycle_path -setup 4 -from $src -to $dst
    set_multicycle_path -hold  3 -from $src -to $dst
}

# Board I/O that is either asynchronous or human-speed
set_false_path -to [get_ports {LEDR* HEX*}]
