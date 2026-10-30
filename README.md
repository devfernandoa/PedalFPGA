# PedalFPGA 🎸

Real-time guitar multi-effect for the Terasic **DE10-Standard** (Cyclone V SoC). The audio path is pure
FPGA logic (no OS in the signal path); Linux on the ARM (HPS) sets up the pedalboard, from the command
line or a web page.

- 11 effects: booster, distortion (RAT-style), overdrive (Tube Screamer-style), tremolo, delay, auto-wah,
  phaser, reverb (Freeverb), compressor, chorus, flanger
- Chain any of them in any order (up to 8 slots), two knobs per effect
- Noise gate in front of the chain, cabinet simulator (512-tap FIR) and output volume after it
- Line or mic input, tuner, presets saved on the SD card
- Exactly 48 kHz through the on-board WM8731 codec (24-bit to the codec, 16-bit through the effects)
- Every effect has a bit-exact Python model, and a GHDL test checks the VHDL against it

---

## Hookup

| Jack | Use |
|------|-----|
| **Blue** (LINE IN) | Guitar in, through a preamp/buffer (input = line, the default) |
| **Pink** (MIC IN) | Guitar straight in, +20 dB in the codec (input = mic) |
| **Green** (LINE OUT) | Amp or headphones (turn the cabinet on for headphones) |

HEX5/HEX4 show the first effect in the chain, HEX3..HEX0 and LEDR its knobs.

---

## Files

| Path | What |
|------|------|
| `PedalFPGA_top.v` | Top level: HPS (Platform Designer `soc_system`) + `pedal_core`; only the pins in use |
| `pedal_core.vhd` | Audio path: codec → noise gate → effect chain → cabinet → volume → codec |
| `pedal_regs.vhd` | Register bank the HPS reads/writes (chain, knobs, config, tuner capture) |
| `cab.vhd` | Cabinet simulator: 512-tap FIR after the chain |
| `booster.vhd`, `drive.vhd`, `tremolo.vhd`, `delay.vhd`, `wah.vhd`, `phaser.vhd`, `reverb.vhd`, `compressor.vhd`, `moddelay.vhd` | The effects (`drive` is distortion and overdrive, `moddelay` chorus and flanger) |
| `sat_pkg.vhd` | Saturation helpers |
| `codec.vhd` | WM8731: register setup over I²C, 24-bit I²S in/out |
| `make_soc_system.tcl`, `pedal_regs_hw.tcl` | Generate `soc_system.qsys` from the Terasic GHRD |
| `sw/pedalctl.c` | CLI on the HPS that reads/writes the registers |
| `sw/web/` | Web UI (static page + CGI calling `pedalctl`), served by busybox httpd |
| `sim/fx_model.py` | Fixed-point models of the effects, property checks, WAV renders |
| `sim/test_vhdl.py`, `sim/tb_*.vhd` | GHDL tests: codec against a WM8731 bus model, register bank, effects + cab vs model sample by sample |

---

## Control

Registers at the start of the lightweight HPS-to-FPGA bridge (`0xFF200000`):

| Offset | Register | |
|--------|----------|-|
| `0x00` | ID (RO) | `0x50ED0003` |
| `0x04` | CHAIN | 8 slots × 4 bits, slot 0 = bits 3..0; value = effect id, `0xF` = empty |
| `0x08 + 4·e` | PARAM[e] | bits 9..5 = knob A, bits 4..0 = knob B (0..31), e = 0..10 |
| `0x34` | CONFIG | bit 0 = mic input (0 = line), bit 1 = cabinet on |
| `0x38` | VOLUME | 0..31: 31 = 0 dB, 1.5 dB per step, 0 = mute |
| `0x3C` | CAPTURE | write: capture the next 4096 input samples; read: bit 0 = done |
| `0x40` | CAPDATA | read: next captured sample (signed); write: rewind |

| Id | Effect | Knob A | Knob B |
|----|--------|--------|--------|
| 0 | booster | Gain | Fine |
| 1 | distortion | Drive | Level |
| 2 | overdrive | Drive | Level |
| 3 | tremolo | Speed (0.5–12 Hz) | Depth |
| 4 | delay | Time (20 ms–1 s) | Feedback |
| 5 | auto-wah | Sensitivity | Resonance |
| 6 | phaser | Rate | Depth |
| 7 | reverb | Room | Damping |
| 8 | compressor | Sustain (max gain 1–16×) | Level |
| 9 | chorus | Rate (0.2–3 Hz) | Depth (7–22 ms) |
| 10 | flanger | Rate (0.05–2 Hz) | Depth (0.5–5 ms) |

On the board:

```sh
pedalctl chain overdrive delay reverb   # signal goes through them in this order
pedalctl param delay 12 20              # knob A, knob B
pedalctl input mic                      # or line
pedalctl cab on                         # or off
pedalctl volume 25                      # 0..31, 31 = 0 dB
pedalctl tune                           # {"hz":82.38,"note":"E2","cents":-1}
pedalctl save lead                      # presets live in /home/root/presets
pedalctl load lead
pedalctl dump
```

**Front panel** (how the finished pedal would work): press **HPS KEY** on the board to step to the
next preset (in name order, wrapping around); the LCD shows its name, its number and the chain. The
pedal comes back on the last preset after a power cycle. It runs as the `pedal-panel` service
(`pedalctl panel`). The contrast is set for the DE10-Standard's blue LCD; for another module run
`pedalctl lcdcal` (stop `pedal-panel` first), step through it with HPS KEY and put the values in
`sw/pedal-panel.service` (`PANEL_FLIP=1` if it is upside down). `pedalctl paneltest` prints a sample screen on any machine.

Or open `http://<board-ip>/` for the web UI: stompboxes you drag to reorder and bypass, input and
cabinet switches, presets and a tuner.

---

## Build

Requires Quartus Prime (Lite is enough), the Terasic DE10-Standard GHRD, and an ARM cross compiler (see `sw/Makefile`).

```sh
# copy the GHRD's soc_system.qsys here first; this trims it and adds pedal_regs
qsys-script --script=make_soc_system.tcl --search-path="$PWD,$"
qsys-generate soc_system.qsys --synthesis=VERILOG
quartus_sh --flow compile PedalFPGA

cd sw
make rbf deploy-rbf     # .sof -> .rbf onto the SD card, reboots (u-boot loads it)
make deploy-web         # pedalctl + web UI + systemd service
```

`BOARD_IP` defaults to `169.254.0.13`; override with `make BOARD_IP=... deploy-web`.

---

## Testing

```sh
python3 sim/fx_model.py     # property checks on the models (level, LFO rate, stability...) + WAVs in sim/out/
python3 sim/test_vhdl.py    # codec I2C/I2S, register bank, then every effect + the cab vs its model, bit-exact
make -C sw test             # pitch detector on synthetic notes (runs on this machine)
```

`test_vhdl.py` uses a local `ghdl` if there is one, otherwise the `ghdl/ghdl` Docker image (a few minutes).
When changing an effect, change the model and the VHDL together and keep both tests passing.
The cabinet's coefficients come from `cab_coefs()` in the model (`python3 sim/fx_model.py --vhdl` prints them).

---

## License

Copyright © 2025 Fernando Alzueta.

The PedalFPGA design is licensed under the **CERN Open Hardware Licence v2 – Strongly Reciprocal**
(CERN-OHL-S-2.0, see `LICENSE`). You may study, modify, build and sell it, but anything you distribute
that is based on it, including a product, must come with its complete source under the same licence.

**Commercial licensing:** to use this design in a product without releasing your source under
CERN-OHL-S, contact fefealzueta@gmail.com for a separate commercial licence.

The HPS system is generated by `make_soc_system.tcl` from the `soc_system.qsys` of Terasic's
DE10-Standard GHRD, which is not part of this repository and keeps Terasic's terms.
