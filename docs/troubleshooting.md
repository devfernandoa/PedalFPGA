# 6. When it goes wrong

These are the critical points of the project: each one cost real debugging time while building it.
They are ordered from the board up.

## No sound at all

| Check | How |
|-------|-----|
| Right jacks? | Pink = mic (guitar straight in), blue = line, **green** = output. The output is not the pink one. |
| Input matches the jack? | `pedalctl dump` → `CONFIG`. A guitar in the pink jack with input = line gives silence. |
| Volume? | `pedalctl volume 31`. 0 is mute. |
| Codec configured? | If even a clean signal (chain empty) is silent, the I²C setup never finished. See below. |
| FPGA loaded at all? | The HEX displays show `--` with an empty chain. If they are blank or show random segments, the FPGA has no design (or another one). |

**The codec never gets configured.** The DE10-Standard's codec shares its I²C bus with the video
decoder (ADV7180). If `TD_RESET_N` is not held low the decoder can disturb the bus. Check
`assign TD_RESET_N = 1'b0;` in the top level and that the pin is assigned in the `.qsf`. To see the
bus itself, put `FPGA_I2C_SCLK`/`FPGA_I2C_SDAT` in Signal Tap, trigger on the first falling SDA and
check that the codec pulls SDA low on every ninth bit (ACK).

## Noise, clicks or distortion that should not be there

- **Clicks on loud notes, every effect:** an overflow that wraps around instead of saturating. Run
  `python3 sim/test_vhdl.py <effect>`: if the model has `sat16` and the VHDL does not, the test points
  at the first sample.
- **Loud noise or garbage on the output while the input is fine (check with `pedalctl tune`):** the
  transmit side of the I²S changes DACDAT too close to the BCLK rising edge. `codec_i2s` waits 2 cycles after the
  synchronized falling edge for this reason; if you change the synchronizer depth, re-check that there
  is still setup time left.
- **Hum and hiss with the mic input:** the +20 dB boost amplifies everything. The noise gate in front
  of the chain mutes the input after 0.5 s below a small threshold (`GATE_THRESH` in
  `pedal_core.vhd`); raise it if your guitar is noisy.
- **Everything sounds slightly detuned, the tuner reads ~30 cents sharp:** XCK is 12.5 MHz (50 / 4)
  instead of 12.288 MHz. Use the PLL from part 1.

## Works in simulation, not on the board

Almost always timing. Open the **Timing Analyzer** report:

- **Negative setup slack inside an effect:** the multicycle constraints in `PedalFPGA.sdc` did not match
  the registers. The `get_registers` patterns use instance names (`inst_tremolo`…); if you rename an
  instance or add an effect, add it to the list. The report's *Ignored Constraints* section lists
  patterns that matched nothing.
- **Negative slack after you changed `SLOT_WAIT`:** the multicycle values must change with it (part 3).
- **Unconstrained paths:** every input from the codec is asynchronous to `CLOCK_50`. They are all
  synchronized with two flip-flops before use, which is the only safe way to bring them in.

## The HPS cannot see the registers

| Symptom | Cause |
|---------|-------|
| `unexpected ID 0x00000000` or another value | The FPGA has a different design: an old `soc_system.rbf` on the SD card, or the `.sof` you programmed by JTAG was replaced at reboot. Run `make deploy-rbf` again. |
| `open /dev/mem: Permission denied` | Run as root. |
| The board **freezes** on `pedalctl` | The bridge is not enabled, or the FPGA is not configured: an access to the lightweight bridge that nobody answers never completes, and the CPU waits forever. Check that u-boot loaded the `.rbf` (watch the serial console during boot) and enabled the bridges. Never program the FPGA over JTAG while something on Linux is polling the registers. |
| Writes work but reads return the previous value | `readLatency` in `pedal_regs_hw.tcl` does not match the VHDL. |
| Linux does not boot after a new `.rbf` | `hps_0` was changed, so the SD card's preloader no longer matches it. Start again from the GHRD's `soc_system.qsys` and only add things (that is what `make_soc_system.tcl` does). |

## Platform Designer and the build

- **`qsys-script` cannot find `pedal_regs`:** run it from the repository root with
  `--search-path="$PWD,$"`; it looks for `pedal_regs_hw.tcl` in the current directory.
- **Errors about `soc_system` ports in the top level:** you edited the system but did not run
  `qsys-generate` again, so the generated Verilog has the old ports.
- **`test_vhdl.py` fails before testing anything:** no `ghdl` and no Docker. Install either; with
  Docker the first run downloads the image.

## The web UI does nothing

- `http://<board>/cgi-bin/pedal` should return JSON. If it returns the script's source, the file is not
  executable: `chmod +x /home/root/web/cgi-bin/pedal` (`make deploy-web` does it).
- If it returns `{"hz":0}` or nothing, run the same `pedalctl` command over ssh to see its error.
- `systemctl status pedal-web` shows whether the server is running.

## A general method

1. **Separate the problem.** Clean signal with an empty chain? Then the codec and the clocking are
   fine. One effect fails? Test only that one in simulation.
2. **Trust the bit-exact test, then the timing report, then Signal Tap,** in that order: each one is
   slower than the one before.
3. **Change one thing per compile.** A full compile takes minutes; two changes at once means two
   compiles when one is wrong.
