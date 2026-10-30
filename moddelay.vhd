-- Chorus (FLANGER = false) and flanger (true): a 2048-sample delay line swept by a triangle LFO,
-- read at a fractional position (linear interpolation between two taps) and mixed with the dry signal.
--   chorus:  7 ms + up to 15 ms sweep, 0.2 .. 3 Hz, wet at -3 dB, no feedback
--   flanger: 0.5 ms + up to 4.5 ms sweep, 0.05 .. 2 Hz, 50/50 mix, feedback 0.7 (deep notches)
-- The two taps come from two copies of the line (one read port each). Reads use the addresses computed
-- at the previous sample, so they see the line before this sample's write, as in delay.vhd.
-- Same integer math as moddelay() in sim/fx_model.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity moddelay is
    generic (FLANGER : boolean);
    port (
        clk        : in  std_logic;
        ce         : in  std_logic;                     -- 1 pulse per sample
        sample_in  : in  std_logic_vector(15 downto 0);
        rate       : in  std_logic_vector(4 downto 0);  -- knob A: LFO rate (exponential)
        depth      : in  std_logic_vector(4 downto 0);  -- knob B: sweep width
        sample_out : out std_logic_vector(15 downto 0)
    );
end entity moddelay;

architecture rtl of moddelay is
    constant CHO_INC : int_table := (
        17896, 19529, 21312, 23258, 25381, 27698, 30226, 32985,
        35996, 39282, 42868, 46781, 51052, 55712, 60798, 66348,
        72404, 79014, 86226, 94098, 102687, 112061, 122291, 133454,
        145637, 158931, 173439, 189272, 206550, 225405, 245981, 268435);
    constant FLA_INC : int_table := (
        4474, 5039, 5676, 6393, 7201, 8111, 9136, 10291,
        11591, 13056, 14706, 16564, 18657, 21015, 23670, 26661,
        30030, 33825, 38099, 42914, 48337, 54445, 61325, 69074,
        77802, 87634, 98708, 111181, 125231, 141055, 158880, 178957);
    function pick(c : boolean; a, b : integer) return integer is
    begin
        if c then return a; else return b; end if;
    end function;
    function pick_t(c : boolean; a, b : int_table) return int_table is
    begin
        if c then return a; else return b; end if;
    end function;
    constant INC  : int_table := pick_t(FLANGER, FLA_INC, CHO_INC);
    constant BASE : integer := pick(FLANGER, 24, 336);      -- samples
    constant SPAN : integer := pick(FLANGER, 7, 23);        -- samples of sweep per depth step
    constant FB   : integer := pick(FLANGER, 22938, 0);     -- Q15

    constant N : integer := 2048;
    type ram_t is array (0 to N - 1) of signed(15 downto 0);
    signal ram0, ram1 : ram_t := (others => (others => '0'));
    signal wp, rp0, rp1 : unsigned(10 downto 0) := (others => '0');
    signal t0, t1 : signed(15 downto 0) := (others => '0');
    signal frac   : unsigned(14 downto 0) := (others => '0');
    signal phase  : unsigned(31 downto 0) := (others => '0');
begin
    process (clk)
        variable x, wet : signed(15 downto 0);
        variable dq     : unsigned(31 downto 0);
        variable rp     : unsigned(10 downto 0);
        variable tr     : signed(15 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                x := signed(sample_in);
                -- interpolated tap: t0 + (t1 - t0) * frac  (|t0 + ...| <= max(|t0|, |t1|), fits 16 bits)
                wet := resize(t0 + shift_right((resize(t1, 17) - t0) * signed('0' & frac), 15), 16);
                if FLANGER then
                    sample_out <= std_logic_vector(sat16(shift_right(resize(x, 17) + wet, 1)));
                else
                    sample_out <= std_logic_vector(sat16(resize(x, 17) + shift_right(wet * to_signed(23170, 16), 15)));
                end if;

                t0 <= ram0(to_integer(rp0));
                t1 <= ram1(to_integer(rp1));
                ram0(to_integer(wp)) <= sat16(resize(x, 17) + shift_right(wet * to_signed(FB, 16), 15));
                ram1(to_integer(wp)) <= sat16(resize(x, 17) + shift_right(wet * to_signed(FB, 16), 15));

                -- next read position: BASE + depth * SPAN * tri (Q15 samples)
                tr := tri15(phase);                         -- 0 .. 32767
                dq := to_unsigned(BASE * 32768, 32) +
                      resize(to_unsigned(to_integer(unsigned(depth)) * SPAN, 10) * unsigned(tr(14 downto 0)), 32);
                frac <= dq(14 downto 0);
                rp := wp - dq(25 downto 15);                -- mod 2048 by wrap-around
                rp0 <= rp;
                rp1 <= rp - 1;
                wp <= wp + 1;
                phase <= phase + to_unsigned(INC(to_integer(unsigned(rate))), 32);
            end if;
        end if;
    end process;
end architecture rtl;
