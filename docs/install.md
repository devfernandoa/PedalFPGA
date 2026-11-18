# Install

This page goes straight from a clean checkout to a working pedal, with no theory. If something here is
unclear, the [tutorial](codec.md) explains every step, and [When it goes wrong](troubleshooting.md)
covers the failures.

!!! abstract "Time"
    About an hour the first time, most of it Quartus compiling and the SD card image downloading.

## What you need

**Hardware**

- Terasic **DE10-Standard** and its 12 V supply
- micro-SD card, 8 GB or more
- Ethernet cable (board ↔ PC) and the mini-USB cable (UART console)
- Guitar, amp / powered speakers / headphones, 3.5 mm ↔ ¼" adapters

**Software, on a Linux PC**

- **Quartus Prime Lite** 25.1 with Cyclone V device support (Platform Designer included)
- Terasic **DE10-Standard System CD** (for the GHRD)
- ARM cross compiler `gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf`
- `git`, `make`, `ssh`/`scp`, Python 3 (+ `numpy`), and GHDL **or** Docker for the tests

## 1. Prepare the board

1. **Write the Linux image to the SD card** as in the course page
   [info-SDcard](https://insper.github.io/Embarcados-Avancados/info-SDcard/). Its u-boot must load
   `soc_system.rbf` from the FAT partition and enable the HPS-to-FPGA bridges (the course image does).
2. **Leave the MSEL switches** in the position the image's documentation asks for, insert the card,
   power the board and watch it boot on the serial console (`screen /dev/ttyUSB0 115200`).
3. **Network.** Connect the Ethernet cable directly to your PC. The board is expected at
   `169.254.0.13`; give your PC an address in the same link-local range, for example:

    ```sh
    sudo ip addr add 169.254.0.1/16 dev <your-ethernet-interface>
    ssh root@169.254.0.13         # should log in
    ```

    If your board uses another address, add `BOARD_IP=<address>` to every `make` command below.
    The course page [info-HPS-ethernet](https://insper.github.io/Embarcados-Avancados/info-HPS-ethernet/)
    has the details.

## 2. Get the code

```sh
git clone https://github.com/devfernandoa/PedalFPGA
cd PedalFPGA
```

Copy `soc_system.qsys` from the GHRD on the System CD
(`Demonstrations/SoC_FPGA/DE10_Standard_GHRD/soc_system.qsys`) into this directory. It is not in the
repository because it is Terasic's.

## 3. Build the FPGA bitstream

Run with Quartus' `bin` directories on your `PATH`:

```sh
qsys-script --script=make_soc_system.tcl --search-path="$PWD,$"   # trim the GHRD, add pedal_regs
qsys-generate soc_system.qsys --synthesis=VERILOG                 # generate the HPS system
quartus_sh --flow compile PedalFPGA                               # ~5-10 min
```

Check the result: `output_files/PedalFPGA.sof` exists, and the timing summary
(`output_files/PedalFPGA.sta.summary`) has no negative slack.

## 4. Put the bitstream on the SD card

```sh
cd sw
make rbf          # .sof -> compressed output_files/soc_system.rbf
make deploy-rbf   # copy it to the SD card's FAT partition over ssh, then reboot
```

When the board comes back, the HEX displays show `--` (empty chain) and audio passes through clean.

## 5. Build and install the software

`sw/Makefile` looks for the cross compiler next to the repository
(`../gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf`). If yours is elsewhere, pass
`CROSS_COMPILE=/path/to/bin/arm-linux-gnueabihf-`.

```sh
make              # cross-compile pedalctl
make deploy-web   # pedalctl, the web UI and the systemd services (web + front panel)
```

## 6. Play

=== "Command line"

    ```console
    $ ssh root@169.254.0.13
    # ./pedalctl id                          # expect 0x50ED0003
    # ./pedalctl input mic                   # guitar straight into the pink jack
    # ./pedalctl chain overdrive delay reverb
    # ./pedalctl param delay 12 20
    # ./pedalctl cab on                      # for headphones
    # ./pedalctl tune
    {"hz":82.38,"note":"E2","cents":-1}
    ```

=== "Web UI"

    Open **http://169.254.0.13/** in a browser. Drag a pedal by its name to reorder the chain,
    turn the knobs, bypass a pedal with its footswitch, switch input and cabinet, save presets and
    open the tuner.

=== "Front panel"

    Save a few presets first (`./pedalctl save clean`, `./pedalctl save lead`…). Then press
    **HPS KEY** on the board to step through them; the LCD shows the preset's name and chain. The
    pedal comes back on the last preset after a power cycle.

**Jacks:** guitar into **pink** (mic input, +20 dB) or a buffered/line source into **blue** (line
input); amp or headphones on **green**.

## 7. Run the tests (optional)

```sh
python3 sim/fx_model.py     # model checks + WAV renders in sim/out/
python3 sim/test_vhdl.py    # codec, registers, every effect vs its model, bit-exact
make -C sw test             # tuner's pitch detector on synthetic notes
```

## Updating

| You changed | Run |
|-------------|-----|
| VHDL / Verilog | `quartus_sh --flow compile PedalFPGA`, then `make -C sw rbf deploy-rbf` |
| `pedal_regs_hw.tcl` or `make_soc_system.tcl` | start from a fresh GHRD `soc_system.qsys`, then all of step 3 and 4 |
| `pedalctl.c` or the web UI | `make -C sw deploy-web` |

!!! success "Done"
    The pedal now starts by itself at every power-up: u-boot loads the FPGA, systemd starts the web UI
    and the front panel. To understand how each piece works, start the [tutorial](codec.md).
