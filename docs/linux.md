# 5. Control from Linux

The registers are at `0xFF200000`. This part writes a command-line tool that reads and writes them
from Linux, `pedalctl`, and puts a web page on top of it. The full tool is
[`sw/pedalctl.c`](https://github.com/devfernandoa/PedalFPGA/blob/main/sw/pedalctl.c); here are the
parts that matter.

## Theory: physical addresses from user space

A Linux process sees *virtual* addresses; `0xFF200000` in a C pointer means nothing to it. To reach a
physical address, the process maps it into its own address space with `mmap` on `/dev/mem`, the
device file that represents physical memory:

```c
#define LW_BRIDGE_BASE 0xFF200000u
#define MAP_SPAN       0x1000u          /* one 4 KiB page: more than the 17 registers need */

int fd = open("/dev/mem", O_RDWR | O_SYNC);
volatile uint32_t *regs = mmap(NULL, MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LW_BRIDGE_BASE);
close(fd);                               /* the mapping stays valid */

uint32_t id = regs[0];                   /* a load from 0xFF200000: the ID register */
regs[1] = 0xFFFFF742;                    /* a store to 0xFF200004: CHAIN = overdrive, delay, reverb */
```

- **`volatile`** tells the compiler that every access has an effect: without it, it may merge two
  writes, drop a read whose result it thinks it knows, or reorder them.
- **`O_SYNC`** makes the mapping uncached, so the reads and writes go to the bridge instead of the
  cache.
- **`regs[n]`** is the register at offset `4·n`, because `regs` points to 32-bit words. This is why
  the Avalon slave uses word addresses.
- `/dev/mem` needs **root**. That is fine on the board, but it is also why this approach is a
  shortcut; [part 7](further.md) shows the proper one.

The course's [Blink FPGA LED from HPS](https://insper.github.io/Embarcados-Avancados/Tutorial-HPS-FPGA-BlinkLED/)
tutorial uses the same technique for one PIO. The difference here is the check right after mapping:

```c
uint32_t id = regs[REG_ID];
if (id != PEDAL_ID) {
    fprintf(stderr, "unexpected ID 0x%08X (want 0x%08X): is soc_system.rbf on the SD card up to date?\n",
            id, PEDAL_ID);
    return 1;
}
```

## The commands

Each command is a few register accesses. Setting the chain packs names into the 4-bit slots:

```c
uint32_t chain = 0xFFFFFFFF;                          /* all empty */
for (int s = 0; s < n; s++)
    chain = (chain & ~(0xFu << (4 * s))) | ((uint32_t)fx[s] << (4 * s));
regs[REG_CHAIN] = chain;
```

and a knob write is `regs[REG_PARAM + e] = (a << 5) | b`. Presets are the 14 registers from CHAIN to
VOLUME saved to a file in `/home/root/presets`.

The tuner is more interesting: it writes `CAPTURE`, waits for the `done` bit, reads 4096 samples
through `CAPDATA` and finds the pitch in C with the YIN algorithm[^yin] (a normalized difference
function, which is more robust than plain autocorrelation against octave errors).

[^yin]: A. de Cheveigné and H. Kawahara, "YIN, a fundamental frequency estimator for speech and
    music", *J. Acoust. Soc. Am.* 111(4), 2002. The pitch detector runs on your PC
too, against synthetic notes:

```sh
make -C sw test
```

## Cross-compile and install

The board runs ARM Linux, so `pedalctl` is built with the cross compiler from
[Tutorial-HPS-BuildSystem](https://insper.github.io/Embarcados-Avancados/Tutorial-HPS-BuildSystem/).
`sw/Makefile` expects it next to the repository; point `CROSS_COMPILE` elsewhere if yours lives
somewhere else:

```sh
cd sw
make                                   # or: make CROSS_COMPILE=/path/to/arm-linux-gnueabihf-
make deploy-web                        # pedalctl + web UI + systemd services, over ssh
```

Then on the board (`ssh root@169.254.0.13`):

```console
# ./pedalctl id
0x50ED0003
# ./pedalctl input mic                 # guitar straight into the pink jack
# ./pedalctl chain overdrive delay reverb
# ./pedalctl param delay 12 20         # knob A (time), knob B (feedback)
# ./pedalctl cab on                    # speaker simulation, for headphones
# ./pedalctl tune
{"hz":82.38,"note":"E2","cents":-1}
# ./pedalctl dump
CHAIN 0xFFFFF742: overdrive delay reverb - - - - -
booster    A=16 B=16
...
```

Play while you change things: the sound changes at the next sample, with no click, because the FPGA
picks up the new registers between samples (part 3).

The HEX displays show the first effect of the chain (`Od` for overdrive) and its knobs, which is a
quick check that the write reached the FPGA without looking at the terminal.

## A web UI in 30 lines of shell

The board already has a web server: **busybox httpd**. It serves static files from a directory and
runs anything in `cgi-bin/` as a CGI program, passing the query string in `$QUERY_STRING` and sending
what the program prints back to the browser. So the whole backend is a shell script that calls
`pedalctl` ([`sw/web/cgi-bin/pedal`](https://github.com/devfernandoa/PedalFPGA/blob/main/sw/web/cgi-bin/pedal)):

```sh
#!/bin/sh
P=/home/root/pedalctl
echo "Content-Type: application/json"
echo
arg() { echo "${QUERY_STRING#*=}" | tr + ' '; }
case "$QUERY_STRING" in
    *[!a-z0-9+=]*) ;;                                    # anything odd: ignore it
    chain=*)  $P chain $(arg) >/dev/null 2>&1 ;;
    param=*)  $P param $(arg) >/dev/null 2>&1 ;;
    ...
esac
$P json                                                  # always answer with the current state
```

!!! danger "Never pass a query string to a shell unchecked"
    `$(arg)` is expanded unquoted, on purpose, to split the arguments. Without the first `case`
    line, a request like `?chain=x;reboot` would run `reboot` as root. The whitelist
    `[a-z0-9+=]` rejects every character the shell treats specially, and `pedalctl` validates
    names and numbers again.

The page, [`sw/web/index.html`](https://github.com/devfernandoa/PedalFPGA/blob/main/sw/web/index.html),
is a single file with no libraries: it calls `fetch('/cgi-bin/pedal?…')` on every change and redraws
from the JSON answer. You drag stompboxes to reorder them, turn the knobs, and use the tuner.

`deploy-web` installs two systemd services so everything starts at boot:
`pedal-web.service` (`busybox httpd -f -p 80 -h /home/root/web`) and `pedal-panel.service`
(`pedalctl panel`: the HPS KEY button steps through the presets, and the board's LCD shows the
preset name).

Open `http://169.254.0.13/` in a browser on the same network.

!!! success "Checkpoint"
    `pedalctl id` prints `0x50ED0003`, you can build a chain from the command line and from the web
    page, and the tuner reads your open strings.
