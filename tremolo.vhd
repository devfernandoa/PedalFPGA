-- Tremolo: volume follows an LFO. gain = 1 - depth * lfo, so it never gets louder than the input.
-- LFO = triangle from a 32-bit phase accumulator, shaped by smoothstep t^2(3-2t) so it sounds like a sine.
-- Same integer math as tremolo() in sim/fx_model.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity tremolo is
    port (
        clk        : in  std_logic;
        ce         : in  std_logic;                     -- 1 pulse per sample
        sample_in  : in  std_logic_vector(15 downto 0);
        rate       : in  std_logic_vector(4 downto 0);  -- knob A: 0.5 .. 12 Hz (exponential)
        depth      : in  std_logic_vector(4 downto 0);  -- knob B: 0 .. 100 %
        sample_out : out std_logic_vector(15 downto 0)
    );
end entity tremolo;

architecture rtl of tremolo is
    -- phase increment per sample = 2^32 * f / 48000
    constant TREM_INC : int_table := (
        44739, 49569, 54921, 60850, 67419, 74697, 82761, 91696,
        101595, 112563, 124715, 138179, 153096, 169624, 187936, 208225,
        230704, 255610, 283205, 313779, 347654, 385186, 426770, 472842,
        523889, 580447, 643110, 712538, 789462, 874690, 969119, 1073742);

    signal phase : unsigned(31 downto 0) := (others => '0');
    signal lfo   : signed(15 downto 0) := (others => '0');          -- 0 .. 32767
    signal gain  : signed(15 downto 0) := to_signed(32767, 16);     -- Q15, <= 1
begin
    process(clk)
        variable t  : signed(15 downto 0);
        variable t2 : signed(31 downto 0);
        variable sm : signed(35 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                sample_out <= std_logic_vector(resize(shift_right(signed(sample_in) * gain, 15), 16));
                gain <= to_signed(32767, 16) - resize(shift_right(to_signed(to_integer(unsigned(depth)) * 1057, 16) * lfo, 15), 16);

                t  := tri15(phase);
                t2 := shift_right(t * t, 15);
                sm := shift_right(resize(t2, 18) * (to_signed(98304, 18) - shift_left(resize(t, 18), 1)), 15);
                if sm > 32767 then
                    lfo <= to_signed(32767, 16);
                else
                    lfo <= resize(sm, 16);
                end if;
                phase <= phase + to_unsigned(TREM_INC(to_integer(unsigned(rate))), 32);
            end if;
        end if;
    end process;
end architecture rtl;
