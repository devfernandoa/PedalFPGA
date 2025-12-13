# PedalFPGA 🎸

Real-time, FPGA-based guitar effects implemented in VHDL for Terasic DE10 / DE1-SoC boards.

This project implements a multi-effect pedal (Booster, Distortion, Overdrive, Tremolo) running on the Cyclone V FPGA. Audio I/O uses the on-board WM8731 codec via I2C/I2S. Effects run in parallel on the FPGA and are switched by push buttons; parameters are controlled by DIP switches and shown on 7-segment displays.

---

## Contents

- `testaudio_DE10SoC.vhd` - Top-level (DE10-Standard target)
- `au_setup.vhd`, `au_in.vhd`, `au_out.vhd` - Codec setup and I2S input/output
- `booster.vhd` - Clean boost (multiplier)
- `distortion.vhd` - Hard clipping distortion
- `overdrive.vhd` - Soft clipping (overdrive)
- `tremolo.vhd`, `wave_setup.vhd` - Tremolo effect and LFO
- `output_files/`, `db/` - Build outputs and project database

---

## Quick Features

- Real-time audio processing on the FPGA (no OS latency)
- Four effects processed in parallel: Booster, Distortion, Overdrive, Tremolo
- Noise gate + DC blocker to reduce hiss and remove DC offset
- Parameters controlled with switches (`SW[9:0]`) and displayed on HEX / LED
- Synth-friendly VHDL code with small, isolated modules for each effect

---

## Controls & Mapping

- **Effect selection (KEY buttons):**
  - KEY0 → Booster (clean boost)
  - KEY1 → Distortion (hard clip)
  - KEY2 → Overdrive (soft clip)
  - KEY3 → Tremolo

- **Switches (`SW`):**
  - `SW[9..5]` — primary parameter (coarse): Gain / Drive / Rate
  - `SW[4..0]` — secondary parameter (fine): Level / Depth

- **Visual feedback:**
  - `LEDR[9:0]` mirrors `SW[9:0]`
  - `HEX4..HEX5` show active effect label
  - `HEX0..HEX3` show numeric switch values

---

## Build & Program (Quartus)

Requirements

- Intel Quartus Prime (matching project settings; e.g., 24.1)
- Terasic DE10-Standard or DE1-SoC board
- Line In/Out cables and a guitar preamp/buffer (recommended)

From shell (example):

```bash
# compile with Quartus (project is PedalFPGA)
quartus_sh --flow compile PedalFPGA

# program the device (example using the programmer in Quartus GUI or command):
quartus_pgm -c USB-Blaster -m jtag -o "p;output_files/PedalFPGA.sof"
```

Notes

- Project top-level is `testaudio_DE10SoC.vhd`. There may be a `testaudio_DE1SoC.vhd` version (backup) for DE1 boards.
- Check `PedalFPGA.qsf` for pin assignments and constraints.

---

## Architecture & Signal Flow

1. `au_in` deserializes I2S from WM8731 into 16-bit samples.
2. Samples pass through a **DC blocker** to remove offset.
3. A **Noise Gate** mutes small signals (reduces hiss) and includes a hold timer to avoid chopping zero crossings.
4. The clean signal is fed in parallel to Booster, Distortion, Overdrive and Tremolo.
5. A multiplexer selects the active effect output (based on `KEY`), which goes to `au_out` for DAC/I2S output.

## Contributing & Testing

- Fork and submit PRs for small fixes (narrow scope — fix warnings, improve clarity, add unit/simulation tests in `simulation/`).
- Add an `sdc` timing constraints file for better static timing analysis.
- Provide a driver or mapping if you use a different ADC (e.g., LTC2308 instead of AD7928).

---

## License

This project uses the MIT license. See `LICENSE` for details.

---

If you'd like, I can also:

- Add a short user guide for bench testing with an audio interface and scope,
- Add a screenshot or picture of the board wiring and a small `HOWTO` for safe power and audio levels.

Enjoy building and playing with your FPGA pedal! 🎵
