# 2. Your first effect: a tremolo

A tremolo makes the volume go up and down a few times a second. It is the simplest effect that still
has every ingredient of the others: a per-sample multiply, an oscillator (the *LFO*, low-frequency
oscillator) and knobs mapped to useful ranges. Building it teaches the method used for all 11
effects in this pedal:

1. Write the effect in Python with **integers only**, exactly as the hardware will compute it.
2. Listen to it and check its properties (rate, level) in Python, where that is easy.
3. Write the VHDL with the same arithmetic.
4. Simulate the VHDL and compare it with the Python model **sample by sample**: they must be identical.

## Theory: fixed point

The FPGA has no floating point to spare, so samples and gains are integers that stand for fractions.
A 16-bit signed sample \(x \in [-32768, 32767]\) stands for \(x / 2^{15} \in [-1, 1)\). That is the
**Q15** format, and gains use it too: 32767 ≈ 1.0, 16384 = 0.5.

Multiplying two Q15 numbers gives a Q30 result (32 bits), so you shift right by 15 to get back to Q15:

$$ y = \frac{x \cdot g}{2^{15}} \quad\Longrightarrow\quad \texttt{y = (x * g) >> 15} $$

The Cyclone V has hardware multipliers (DSP blocks, 18×18 and 27×27), so `x * g` costs one DSP block
and no logic. Two rules keep fixed point from biting you:

- **Overflow wraps around.** 32767 + 1 in 16 bits is −32768: a full-scale click. Whenever a result can
  exceed 16 bits, compute it wider and **saturate** (clamp) it. `sat_pkg.vhd` has `sat16` for that.
- **`>>` on a negative number rounds toward −∞**, in Python and in VHDL's `shift_right` on `signed`
  alike. Use the same operation on both sides and the results match exactly.

## Theory: the LFO as a phase accumulator

To make a slow oscillator at frequency \(f\) without dividers or a sine table, keep a 32-bit counter,
the *phase*, and add a constant to it every sample. It wraps around at \(2^{32}\), so it wraps
\(f\) times a second when the increment is

$$ \Delta = \frac{2^{32} \, f}{f_s} $$

For \(f = 0.5\) Hz at 48 kHz, \(\Delta = 44\,739\). The top bits of the phase are a sawtooth; folding
it gives a triangle (`tri15` in `sat_pkg.vhd`):

```vhdl
-- 32-bit LFO phase -> triangle 0..32767 (peak at half period)
if phase(31) = '1' then
    return signed('0' & not phase(30 downto 16));   -- falling half
else
    return signed('0' & phase(30 downto 16));       -- rising half
end if;
```

A triangle LFO sounds a little mechanical. Passing it through *smoothstep*, \(3t^2 - 2t^3\), rounds
the corners into something close to a sine, with just two multiplications.

This technique (a *numerically controlled oscillator*, the core of direct digital synthesis) gives
frequency steps of \(f_s / 2^{32} \approx 11\,\mu\text{Hz}\) and costs one adder.

## The model

From [`sim/fx_model.py`](https://github.com/devfernandoa/PedalFPGA/blob/main/sim/fx_model.py):

```python
TREM_INC = [lfo_inc(f) for f in exp_table(0.5, 12)]   # knob A: 0.5 .. 12 Hz, exponential

def tremolo(xs, a, b):
    """LFO (triangle, smoothstep-shaped) -> gain = 1 - depth*lfo, never above 1."""
    phase = s = 0
    gain = 32767
    depth, inc, out = b * 1057, TREM_INC[a], []        # knob B: 31 * 1057 = 32767 = 100 %
    for x in xs:
        out.append((x * gain) >> 15)
        gain_n = 32767 - ((depth * s) >> 15)
        t = tri(phase)
        t2 = (t * t) >> 15
        s_n = min(32767, (t2 * (98304 - 2 * t)) >> 15)  # smoothstep t^2 (3 - 2t); 98304 = 3.0 in Q15
        phase, s, gain = (phase + inc) & 0xFFFFFFFF, s_n, gain_n
    return out
```

Things to notice:

- **The knob ranges are tables.** A knob is 5 bits (0..31). Rate is perceived logarithmically, so
  `exp_table(0.5, 12)` spaces the 32 rates exponentially between 0.5 and 12 Hz, and `lfo_inc` turns
  each into a phase increment. The VHDL gets the same table as constants (`python3 sim/fx_model.py
  --vhdl` prints them), so there is no division or exponential in hardware.
- **`gain = 1 − depth·lfo`** never goes above 1, so the tremolo never makes the signal louder: no
  clipping, whatever the knobs.
- **The `_n` variables** are the values the registers take at the *next* sample. In VHDL every signal
  assigned in a clocked process updates at the clock edge, so `gain` used in this sample is the one
  computed in the previous one. The model must reproduce that one-sample lag exactly, or the outputs
  differ by one sample and the comparison fails.

Run the model's checks; it also writes WAV files to `sim/out/` (needs `numpy`):

```sh
python3 sim/fx_model.py
```

Among other lines it prints `tremolo speed  0:  0.50 Hz, 2 dips in 4 s` … `speed 31: 12.00 Hz, 48 dips
in 4 s`. Listen to `sim/out/tremolo.wav`: that is what the board will play.

## The VHDL

From [`tremolo.vhd`](https://github.com/devfernandoa/PedalFPGA/blob/main/tremolo.vhd):

```vhdl
entity tremolo is
    port (
        clk        : in  std_logic;
        ce         : in  std_logic;                     -- 1 pulse per sample
        sample_in  : in  std_logic_vector(15 downto 0);
        rate       : in  std_logic_vector(4 downto 0);  -- knob A
        depth      : in  std_logic_vector(4 downto 0);  -- knob B
        sample_out : out std_logic_vector(15 downto 0)
    );
end entity tremolo;

architecture rtl of tremolo is
    constant TREM_INC : int_table := (44739, 49569, ..., 1073742);   -- from fx_model.py --vhdl
    signal phase : unsigned(31 downto 0) := (others => '0');
    signal lfo   : signed(15 downto 0) := (others => '0');
    signal gain  : signed(15 downto 0) := to_signed(32767, 16);
begin
    process(clk)
        variable t  : signed(15 downto 0);
        variable t2 : signed(31 downto 0);
        variable sm : signed(35 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                sample_out <= std_logic_vector(resize(shift_right(signed(sample_in) * gain, 15), 16));
                gain <= to_signed(32767, 16)
                      - resize(shift_right(to_signed(to_integer(unsigned(depth)) * 1057, 16) * lfo, 15), 16);
                t  := tri15(phase);
                t2 := shift_right(t * t, 15);
                sm := shift_right(resize(t2, 18) * (to_signed(98304, 18) - shift_left(resize(t, 18), 1)), 15);
                if sm > 32767 then lfo <= to_signed(32767, 16); else lfo <= resize(sm, 16); end if;
                phase <= phase + to_unsigned(TREM_INC(to_integer(unsigned(rate))), 32);
            end if;
        end if;
    end process;
end architecture rtl;
```

Line for line, it is the model. Two hardware ideas are new:

- **`ce` (clock enable).** The effect runs on the 50 MHz clock but only advances when `ce` pulses, once
  per sample. Everything stays in one clock domain; no 48 kHz clock exists anywhere.
- **Widths are explicit.** `t * t` of two 16-bit numbers is 32 bits; `98304` needs 18 bits signed, so
  `sm` is 36 bits. In Python integers never overflow; in VHDL you choose every width, and a too-narrow
  one silently drops the top bits. The bit-exact test is what catches that.

## Prove it: VHDL against the model

[`sim/tb_fx.vhd`](https://github.com/devfernandoa/PedalFPGA/blob/main/sim/tb_fx.vhd) reads samples
from a text file, drives the effect with the same timing as the real chain (input held for a few
cycles, one `ce` pulse, output read after it) and writes the output to another file.
`sim/test_vhdl.py` feeds it half a second of a synthetic guitar riff at three knob settings and
compares the result with the model:

```sh
python3 sim/test_vhdl.py tremolo
```

```text
tremolo    A= 0 B=31  ok
tremolo    A=16 B=16  ok
tremolo    A=31 B= 0  ok
```

A mismatch prints the first sample that differs and both values. When you change an effect, change
the model and the VHDL together and keep both tests passing.

!!! tip "Why not just listen?"
    A wrong width or a missing saturation often sounds *almost* right: a faint crackle on loud notes,
    a tremolo that clicks once per cycle. The ear finds that late, on the board, after a 5-minute
    compile. The bit-exact test finds it in seconds and tells you the sample number.

## Try it on the board

The tremolo is effect id 3. Once you have part 5 working, `pedalctl chain tremolo` and
`pedalctl param tremolo 20 31` (fast, full depth) make the effect obvious.

!!! success "Checkpoint"
    `python3 sim/test_vhdl.py tremolo` prints `ok` three times, and you understand every line of
    `tremolo.vhd`. The other effects in the repository (`delay.vhd`, `phaser.vhd`, `reverb.vhd`, …)
    are built the same way; `delay.vhd` adds a block RAM, covered in part 3.
