# 4. Registers for the HPS

So far the effect chain and the knobs are just signals. This part turns them into **registers the ARM
can read and write**: a small Avalon-MM peripheral, `pedal_regs`, placed on the lightweight
HPS-to-FPGA bridge with Platform Designer.

## Theory: how the ARM reaches the FPGA

The Cyclone V SoC connects the HPS and the FPGA with three AXI bridges:

| Bridge | Direction | Width | HPS address |
|--------|-----------|-------|-------------|
| HPS-to-FPGA | ARM → FPGA | 32/64/128 bit | `0xC0000000` (960 MB) |
| **Lightweight HPS-to-FPGA** | ARM → FPGA | 32 bit | **`0xFF200000`** (2 MB) |
| FPGA-to-HPS | FPGA → ARM | 32/64/128 bit | |

For a handful of control registers the **lightweight** bridge is the right one: it is simple and has a
fixed address. A CPU load from `0xFF200000 + offset` becomes an AXI read on the bridge, Platform
Designer's interconnect turns it into an **Avalon-MM** read of the peripheral at that offset, and the
32-bit answer goes back the same way. From the CPU's point of view the FPGA registers are just memory.

An Avalon-MM slave is a simple interface. For a register bank with no wait states:

| Signal | Meaning |
|--------|---------|
| `address` | which register (in **words** here, so offset `0x04` is address 1) |
| `write`, `writedata` | when `write` is high, store `writedata` at `address` this cycle |
| `read`, `readdata` | when `read` is high, put the value on `readdata` **one cycle later** (`readLatency = 1`) |

The [Avalon Interface Specifications](https://www.intel.com/content/www/us/en/docs/programmable/683091/current/introduction-to-the-interface-specifications.html)
have the full protocol; the course's
[NIOS IP tutorial](https://insper.github.io/Embarcados-Avancados/Tutorial-FPGA-NIOS-IP/) builds one by
hand in Platform Designer's GUI. Here it is described in a Tcl script instead, so it can be versioned
and rebuilt from the command line.

## The register map

| Offset | Register | |
|--------|----------|-|
| `0x00` | ID (RO) | `0x50ED0003`: "is the right design loaded?" |
| `0x04` | CHAIN | 8 slots × 4 bits (part 3) |
| `0x08 + 4·e` | PARAM[e] | bits 9..5 = knob A, bits 4..0 = knob B, for effect e = 0..10 |
| `0x34` | CONFIG | bit 0 = mic input, bit 1 = cabinet on |
| `0x38` | VOLUME | 31 = 0 dB, 1.5 dB per step, 0 = mute |
| `0x3C` | CAPTURE | write: record the next 4096 input samples; read: bit 0 = done |
| `0x40` | CAPDATA | read: next recorded sample; write: back to the first one |

Always give a register bank a constant **ID register** at offset 0. Reading it is the first thing the
software does: if it does not match, the FPGA has a different design (or none), and the software stops
instead of writing to registers that are not there.

## The peripheral

The core of [`pedal_regs.vhd`](https://github.com/devfernandoa/PedalFPGA/blob/main/pedal_regs.vhd) is
a single clocked process:

```vhdl
if avs_read = '1' then                       -- readLatency 1: readdata is registered
    case a is
        when 0 => avs_readdata <= ID;
        when 1 => avs_readdata <= chain_r;
        when 2 to 12 => avs_readdata(9 downto 0) <= params_r(10*(a-2)+9 downto 10*(a-2));
        ...
    end case;
end if;
if reset = '1' then
    chain_r <= (others => '1');              -- all slots empty: clean signal at power-up
    ...
elsif avs_write = '1' then
    case a is
        when 1 => chain_r <= avs_writedata;
        when 2 to 12 => params_r(10*(a-2)+9 downto 10*(a-2)) <= avs_writedata(9 downto 0);
        ...
    end case;
end if;
```

The registers come out of the peripheral as plain signals (`chain`, `params`, `cfg`, `volume`) in a
**conduit**: an interface Platform Designer just exports to the top level, where they are wired to
`pedal_core`.

The `CAPTURE`/`CAPDATA` pair is a small trick worth knowing: the HPS cannot read samples at 48 kHz
reliably from user space, so the FPGA records 4096 of them into a block RAM (85 ms of audio) and the HPS
reads them back at its own pace. The tuner in part 5 uses it.

`sim/tb_regs.vhd` checks the bank the way the bridge drives it (reads with latency 1, idle cycles
between accesses); it runs as part of `python3 sim/test_vhdl.py`.

## Describing it to Platform Designer

[`pedal_regs_hw.tcl`](https://github.com/devfernandoa/PedalFPGA/blob/main/pedal_regs_hw.tcl) is the
component description, what the *New Component* wizard would otherwise write. The interesting part
declares the Avalon slave and the conduit:

```tcl
add_interface s0 avalon end
set_interface_property s0 addressUnits WORDS
set_interface_property s0 readLatency 1
add_interface_port s0 avs_address address Input 5
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32
add_interface_port s0 avs_readdata readdata Output 32

add_interface pedal conduit end
add_interface_port pedal chain chain Output 32
add_interface_port pedal params params Output 110
...
```

`readLatency 1` must match the VHDL: if the component said 0, the interconnect would take `readdata`
in the same cycle as `read`, one cycle too early, and every read would return the previous value.

## Building the system: start from the GHRD

The HPS block (`hps_0`) holds hundreds of settings: DDR3 timing, which pins go to Ethernet, SD, UART,
USB… They must match the board **and the preloader on the SD card**, which was generated from the same
settings. Getting them right from scratch is the hardest part of any HPS project, so don't: start from
Terasic's **GHRD** (Golden Hardware Reference Design) for the DE10-Standard, whose `hps_0` is known to
work with the stock SD card image.

[`make_soc_system.tcl`](https://github.com/devfernandoa/PedalFPGA/blob/main/make_soc_system.tcl) edits
the GHRD's `soc_system.qsys` with `qsys-script`, the command-line side of Platform Designer:

```tcl
load_system soc_system.qsys

# drop the GHRD's demo peripherals (LED/button/switch PIOs, JTAG UART, ...)
foreach i {ILC button_pio dipsw_pio f2sdram_only_master fpga_only_master hps_only_master
           jtag_uart led_pio mm_bridge_0 sysid_qsys} {
    remove_instance $i
}
...
# put pedal_regs at offset 0 of the lightweight bridge, and export its conduit
add_instance pedal_regs_0 pedal_regs
add_connection clk_0.clk pedal_regs_0.clock
add_connection clk_0.clk_reset pedal_regs_0.reset
add_connection hps_0.h2f_lw_axi_master pedal_regs_0.s0
set_connection_parameter_value hps_0.h2f_lw_axi_master/pedal_regs_0.s0 baseAddress 0x0000
add_interface pedal conduit end
set_interface_property pedal EXPORT_OF pedal_regs_0.pedal

validate_system
save_system soc_system.qsys
```

`hps_0` is never touched, so the SD card's preloader still matches. `--search-path="$PWD,$"` tells
`qsys-script` to look for `*_hw.tcl` components in the current directory (`$` stands for the default
library). This is the command you ran in part 1:

```sh
qsys-script --script=make_soc_system.tcl --search-path="$PWD,$"
qsys-generate soc_system.qsys --synthesis=VERILOG
```

Open the result in Platform Designer (`qsys-edit soc_system.qsys`) to see it: `hps_0`, `clk_0` and
`pedal_regs_0` at base address `0x0000` of `h2f_lw_axi_master`.

## The top level

[`PedalFPGA_top.v`](https://github.com/devfernandoa/PedalFPGA/blob/main/PedalFPGA_top.v) instantiates
the generated `soc_system` and `pedal_core`, and connects the conduit between them:

```verilog
soc_system u0 (
    .clk_clk        (CLOCK_50),
    .reset_reset_n  (1'b1),
    .pedal_chain    (pedal_chain),
    .pedal_params   (pedal_params),
    .pedal_config   (pedal_config),
    .pedal_volume   (pedal_volume),
    ...
    .memory_mem_a   (HPS_DDR3_ADDR),     // and every other HPS pin
    ...
);

pedal_core core (.CLOCK_50 (CLOCK_50), .chain (pedal_chain), .params (pedal_params), ...);
```

Every HPS pin (DDR3, Ethernet, SD, USB, UART…) must stay connected even though the FPGA design does
not use them: the preloader configures all of them, and a missing one breaks the boot. The pin
assignments are in `PedalFPGA.qsf`, taken from the GHRD.

## Loading the FPGA from the SD card

JTAG programming is lost at power-off, and it can also race with Linux: if the HPS touches the bridge
while the FPGA is being reprogrammed, the system hangs. For normal use the board configures the FPGA
**before Linux boots**: u-boot reads `soc_system.rbf` from the SD card's FAT partition, loads it, and
enables the bridges.

The `.rbf` (raw binary file) is the `.sof` converted to the format u-boot expects, compressed:

```sh
cd sw
make rbf          # quartus_cpf -c -o bitstream_compression=on ../output_files/PedalFPGA.sof ../output_files/soc_system.rbf
make deploy-rbf   # copies it to the board's FAT partition over ssh and reboots
```

`deploy-rbf` mounts `/dev/mmcblk0p1` on the board, copies the file, unmounts and reboots. The board is
reached at `BOARD_IP`, `169.254.0.13` by default (a link-local address on a direct cable); override it
with `make BOARD_IP=192.168.0.42 deploy-rbf`.

!!! warning "Compressed bitstream and MSEL"
    The FPGA accepts a compressed bitstream only if the MSEL switches on the board select a mode that
    allows it. Keep them as the documentation of your SD card image says; if u-boot prints an error at
    `fpga load`, try `make rbf` without `bitstream_compression=on` or check the switches.

!!! success "Checkpoint"
    `soc_system.qsys` shows `pedal_regs_0` on the lightweight bridge, the project compiles, and the
    board boots with your `.rbf` (sound passes through as in part 1, without JTAG).
