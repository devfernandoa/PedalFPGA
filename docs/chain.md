# 3. A chain of effects

A pedalboard runs the guitar through several pedals in an order the player chooses. In the FPGA that
means a sample must go through a *configurable* sequence of effects, once per sample period. This
part shows how [`pedal_core.vhd`](https://github.com/devfernandoa/PedalFPGA/blob/main/pedal_core.vhd)
does it, and what that does to timing.

## Theory: spatial or temporal?

There are two ways to connect N effects in a programmable order:

- **Spatially:** wire every effect's input to a multiplexer that can pick any other effect's output.
  All effects compute at the same time, but N effects need N multiplexers with N inputs each, and the
  combinational path through a chain of 8 effects is far too long for 50 MHz.
- **Temporally:** have a single "bus", the sample travelling down the chain (`chain_x`), and give it
  to one effect at a time. Each effect still exists once in hardware, but only one of them works in a
  given clock cycle.

The second one is possible because of the cycle budget computed in the overview: **1041 clock cycles
per sample**. Running an effect takes 6 of them. Eight slots cost about 50 cycles, and the cabinet
simulator (a 512-tap FIR filter that does one multiply-accumulate per cycle) about 515. Even with all
of it on, the sample is done well before the next one arrives.

## The chain register

The HPS writes the order as one 32-bit register, `CHAIN`: 8 slots of 4 bits, slot 0 in bits 3..0.
Each slot holds an effect id (0 = booster … 10 = flanger), or `0xF` for "empty".
`overdrive → delay → reverb` is:

```text
 slot:   7    6    5    4    3    2    1    0
 CHAIN = F    F    F    F    F    7    4    2    = 0xFFFFF742
```

## The state machine

```vhdl
type chain_state_t is (CH_IDLE, CH_WAIT, CH_FIRE, CH_LATCH);
```

```text
             rx_ready (new sample)
  CH_IDLE ─────────────────────────► CH_WAIT ──(slot = 8)──► output the sample ──► CH_IDLE
                                      │  ▲  │
                     empty slot: skip │  │  │ SLOT_WAIT+1 cycles: chain_x stable
                     (shift chain_sh) └──┘  ▼
                                      CH_LATCH ◄── CH_FIRE ◄── pulse fx_ce(id) for one cycle
                     chain_x <= fx_out(id),
                     next slot
```

1. **`CH_IDLE`**: when a new input sample is ready, copy it (after the noise gate) into `chain_x`, take a
   snapshot of `CHAIN` into the shift register `chain_sh`, and start at slot 0.
2. **`CH_WAIT`**: the id of the current slot is `chain_sh(3 downto 0)`. If it is empty, shift
   `chain_sh` by 4 bits and go to the next slot. Otherwise wait `SLOT_WAIT + 1` = 4 cycles with
   `chain_x` stable, then raise that effect's `ce` for one cycle.
3. **`CH_FIRE`**: `ce` is high during this cycle; the effect's registers update at the end of it.
4. **`CH_LATCH`**: copy the effect's output back into `chain_x` and move to the next slot.

After slot 7 the sample goes to the cabinet (if on) and to the output. Every effect's input is the
same signal, `chain_x`, and every effect's output lands in an array indexed by id, so adding an effect
is one more instance and one more entry in the array:

```vhdl
inst_tremolo : entity work.tremolo
port map (clk => CLOCK_50, ce => fx_ce(FX_TREM), sample_in => chain_x,
          rate => p(FX_TREM)(9 downto 5), depth => p(FX_TREM)(4 downto 0),
          sample_out => fx_out(FX_TREM));
```

Taking a snapshot of `CHAIN` once per sample matters: if the HPS rewrites it while a sample is in the
middle of the chain, that sample still goes through a consistent sequence. The knobs get the same
treatment: `params_s <= params` only when a new sample arrives.

!!! note "Each effect exists once"
    Because the hardware is shared in time but not duplicated, an id that appears in two slots steps
    the same effect twice per sample: its LFO would run at double speed, its delay buffer would get two
    writes per sample. `pedalctl` refuses to put an effect in the chain twice.

## Effects with memory: block RAM

The tremolo keeps a few registers of state. A delay needs one second of audio: 48 000 samples × 16
bits = 768 kbit. That goes into the Cyclone V's **M10K** block RAMs (the 5CSXFC6D6 has 553 of them,
about 5.5 Mbit; the delay uses about 14 %). Quartus infers block RAM from an array that is read and
written in a clocked process, at most once each per cycle:

```vhdl
type sample_buffer_t is array (0 to 48000 - 1) of signed(15 downto 0);
signal buffer_mem : sample_buffer_t;
...
if ce = '1' then
    delayed_sample <= buffer_mem(read_ptr);                 -- registered read
    buffer_mem(write_ptr) <= sat16(input + feedback_term);  -- write
```

This is a circular buffer: `write_ptr` advances once per sample and wraps at 48 000; `read_ptr`
trails it by the delay time set by knob A (960 to 47 987 samples, 20 ms to 1 s). When both pointers
hit the same address in the same cycle, the read returns the **old** contents (*read-during-write*
behaviour). The Python model has to do the same, `d_n = buf[rp]` before `buf[wp] = …`, or the test
from part 2 fails.

## Theory: multicycle paths

Timing analysis (TimeQuest) assumes, by default, that every path from one register to another must
settle in **one** clock period: 20 ns at 50 MHz. Some effects have long chains of arithmetic between
registers (a multiply, a shift, another multiply, a saturation), and some of those do not fit in 20 ns.
Quartus then reports negative slack, and on the board the effect would produce garbage.

But look at the state machine: the effect's input `chain_x` is stable for 5 cycles before `ce` rises,
and `ce` rises at most once every 6 cycles. Nothing reads the result one cycle later. So these paths
actually have several cycles to settle, and you can tell the timing analyzer so. From
[`PedalFPGA.sdc`](https://github.com/devfernandoa/PedalFPGA/blob/main/PedalFPGA.sdc):

```tcl
foreach inst {inst_distortion inst_overdrive inst_tremolo inst_delay inst_wah inst_phaser inst_reverb
              inst_compressor inst_chorus inst_flanger} {
    set src [get_registers "*|${inst}|* *|chain_x* *|params_s*"]
    set dst [get_registers "*|${inst}|*"]
    set_multicycle_path -setup 4 -from $src -to $dst
    set_multicycle_path -hold  3 -from $src -to $dst
}
```

`-setup 4` gives these paths 4 clock periods (80 ns). `-hold 3` moves the hold check back to where it
was: without it, the analyzer would demand that data *stays* stable for 3 cycles after launch, which
is not what is meant. Always pair a setup multicycle of N with a hold multicycle of N − 1.

!!! danger "A multicycle constraint is a promise"
    The timing analyzer will not check whether your design actually keeps the inputs stable for those
    cycles. If you change `SLOT_WAIT` in `pedal_core.vhd`, the constraint must change with it, or the
    design will pass timing and fail on the board. That is why the comments in both files point at
    each other.

After compiling, open the **Timing Analyzer** report and check that the *Setup* and *Hold* summaries
have no negative slack, for the 50 MHz clock and for the PLL's.

## Try it

With part 5 done:

```sh
pedalctl chain overdrive delay reverb
pedalctl chain reverb delay overdrive     # same effects, very different sound
```

Distorting a reverb tail sounds harsh; reverberating a distorted guitar sounds like a big amp in a
room. Same hardware, only the order changed.

!!! success "Checkpoint"
    You can explain why the chain needs 6 cycles per slot, and the timing report is clean.
