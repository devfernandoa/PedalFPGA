# PedalFPGA: a guitar multi-effect in FPGA fabric, controlled from Linux

- **Author:** Fernando Alzueta
- **Course:** Embarcados Avançados (SoC and Embedded Linux), Insper
- **Board:** Terasic DE10-Standard (Cyclone V SoC: FPGA + dual-core ARM, the *HPS*)
- **Source:** [github.com/devfernandoa/PedalFPGA](https://github.com/devfernandoa/PedalFPGA)

In this tutorial you build a real-time guitar effects pedal on the DE10-Standard. The audio never
touches the ARM: samples come from the on-board WM8731 codec, run through a chain of effects written
in VHDL and go back out, all in FPGA logic, one sample every 20.8 µs with no operating system in the
way. Linux on the HPS only *configures* the pedal: which effects are on, in which order, and where the
knobs are, through a small register bank on the lightweight HPS-to-FPGA bridge. On top of that you
add a command-line tool and a web page served by the board.

The [course tutorials](https://insper.github.io/Embarcados-Avancados/) show how to blink an FPGA LED
from the HPS, and the 2020 student tutorial
[Audio na DE10](https://insper.github.io/Embarcados-Avancados/2020/Audio/) shows how to get sound in
and out of the codec. This one goes further on both sides: a hand-written codec interface at exactly
48 kHz, DSP in fixed point verified bit by bit against a Python model, a time-multiplexed effect chain
with its timing constraints, and a custom Avalon peripheral driven from user space.

## What you will build

```text
 guitar ─► WM8731 ═I²S═► codec_i2s ─► noise gate ─► slot 0 ─► … ─► slot 7 ─► cabinet ─► volume ─► codec_i2s ═I²S═► WM8731 ─► amp
             ▲                                            ▲
             └═I²C═ codec_cfg                             │ CHAIN, PARAM[e], CONFIG, VOLUME
                                                      pedal_regs                                          FPGA, 50 MHz, no OS
 ════════════════════════════════════════════════════════ ▲ ══ lightweight HPS-to-FPGA bridge (Avalon-MM) ═══════════════
                                                      pedalctl ◄── CGI ◄── busybox httpd ◄── browser        HPS, Linux
```

The finished pedal has 11 effects (booster, distortion, overdrive, tremolo, delay, auto-wah, phaser,
reverb, compressor, chorus, flanger), up to 8 of them chained in any order with two knobs each, plus a
noise gate, a cabinet simulator and an output volume. The tutorial walks through the parts every one of
those effects depends on and builds one effect (the tremolo) from scratch; the others follow the same
pattern and are in the repository.

## How the tutorial is organised

| Part | You learn | You get |
|------|-----------|---------|
| [1. Talking to the codec](codec.md) | I²C, I²S, clocking an audio codec | Guitar in → FPGA → amp, bit for bit |
| [2. Your first effect](effect.md) | Fixed-point DSP, LFOs, checking HDL against a model | A tremolo, tested in GHDL |
| [3. A chain of effects](chain.md) | Time-multiplexing, cycle budgets, multicycle constraints | Any effects, any order |
| [4. Registers for the HPS](hps.md) | Avalon-MM slaves, Platform Designer, the LW bridge | Knobs the ARM can turn |
| [5. Control from Linux](linux.md) | `/dev/mem` + `mmap`, cross-compiling, CGI | `pedalctl` and a web UI |
| [6. When it goes wrong](troubleshooting.md) | The critical points and how to debug them | |
| [7. Going further](further.md) | Where to go next | |

Each part ends in something you can run. Do them in order: every part uses the previous one.

## What you need

**Hardware**

- Terasic DE10-Standard and its power supply, a micro-SD card (8 GB or more), USB cable (UART), Ethernet cable
- A guitar (or any line-level source: a phone works) and an amp, powered speakers or headphones
- 3.5 mm ↔ ¼" adapters for the guitar and the amp

**Software** (the versions used here; newer ones should work)

- Quartus Prime Lite 25.1 with Cyclone V support, Platform Designer included
- The DE10-Standard System CD from Terasic (for the *GHRD*, the Golden Hardware Reference Design)
- A Linux SD card for the DE10-Standard whose u-boot loads `soc_system.rbf` from the FAT partition and
  enables the HPS-to-FPGA bridges: the course image from
  [info-SDcard](https://insper.github.io/Embarcados-Avancados/info-SDcard/) is one
- The ARM cross compiler `gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf`, as in
  [Tutorial-HPS-BuildSystem](https://insper.github.io/Embarcados-Avancados/Tutorial-HPS-BuildSystem/)
- Python 3 and either [GHDL](https://github.com/ghdl/ghdl) or Docker (for the simulations)

**Background:** the course tutorials up to
[Blink FPGA LED from HPS](https://insper.github.io/Embarcados-Avancados/Tutorial-HPS-FPGA-BlinkLED/):
you should know how to compile a Quartus project, boot the board from the SD card and `ssh` into it.

Get the code:

```sh
git clone https://github.com/devfernandoa/PedalFPGA
cd PedalFPGA
```

!!! info "A few numbers to keep in mind"
    - Sample rate \(f_s = 48\,\text{kHz}\): one sample every \(1/f_s = 20.83\,\mu\text{s}\)
    - FPGA clock 50 MHz: **1041 clock cycles per sample**. Every effect in the chain has to fit in that budget.
    - Samples are 16-bit signed (−32768 … 32767) inside the effects, 24-bit at the codec.
