-- Auto-wah / envelope filter (Boss AW-3, Mu-Tron style): a resonant band-pass whose frequency follows
-- how hard you play, since there is no expression pedal to sweep it by foot.
--   envelope follower (2 ms attack, 120 ms release) -> frequency 350 Hz .. 2.5 kHz
--   Chamberlin state-variable filter, band-pass output scaled by 1/Q so the peak gain stays the same.
-- Same integer math as wah() in sim/fx_model.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity wah is
    port (
        clk         : in  std_logic;
        ce          : in  std_logic;                     -- 1 pulse per sample
        sample_in   : in  std_logic_vector(15 downto 0);
        sensitivity : in  std_logic_vector(4 downto 0);  -- knob A: how far the envelope opens the filter
        resonance   : in  std_logic_vector(4 downto 0);  -- knob B: Q = 1 .. 8
        sample_out  : out std_logic_vector(15 downto 0)
    );
end entity wah;

architecture rtl of wah is
    constant F_MIN   : integer := 1501;   -- 2 sin(pi fc / fs) in Q15 for fc = 350 Hz
    constant F_SPAN  : integer := 9200;   -- up to ~2.5 kHz
    constant ATTACK  : integer := 340;    -- envelope one-pole coefficients, Q15
    constant RELEASE : integer := 6;

    signal env    : signed(31 downto 0) := (others => '0');  -- |x| envelope, x 2^15
    signal f_coef : signed(15 downto 0) := to_signed(F_MIN, 16);
    signal lp, bp : signed(31 downto 0) := (others => '0');  -- SVF states, x 256
begin
    process(clk)
        variable x     : signed(15 downto 0);
        variable q     : signed(15 downto 0);   -- 1/Q in Q14
        variable lp_n  : signed(31 downto 0);
        variable hp    : signed(31 downto 0);
        variable bp_n  : signed(31 downto 0);
        variable ax    : signed(31 downto 0);
        variable sweep : integer;
    begin
        if rising_edge(clk) then
            if ce = '1' then
                x := signed(sample_in);
                q := to_signed(16384 - to_integer(unsigned(resonance)) * 462, 16);

                -- state-variable filter (Chamberlin)
                lp_n := lp + resize(shift_right(bp * f_coef, 15), 32);
                hp   := shift_left(resize(x, 32), 8) - lp_n - resize(shift_right(bp * q, 14), 32);
                bp_n := bp + resize(shift_right(hp * f_coef, 15), 32);
                lp <= lp_n;
                bp <= bp_n;
                -- band-pass * (1/Q) = unity gain at the peak, x 2 to match the clean level
                sample_out <= std_logic_vector(sat16(shift_left(shift_right(resize(shift_right(bp_n, 8), 32) * q, 14), 1)));

                -- envelope follower: fast attack, slow release; the frequency uses it from the next sample
                ax := shift_left(resize(abs(resize(x, 17)), 32), 15);
                if ax > env then
                    env <= env + resize(shift_right((ax - env) * to_signed(ATTACK, 16), 15), 32);
                else
                    env <= env + resize(shift_right((ax - env) * to_signed(RELEASE, 16), 15), 32);
                end if;
                sweep := to_integer(shift_right(resize(shift_right(env, 15), 18) * to_signed(to_integer(unsigned(sensitivity)), 7), 4));
                if sweep > F_SPAN then
                    sweep := F_SPAN;
                end if;
                f_coef <= to_signed(F_MIN + sweep, 16);
            end if;
        end if;
    end process;
end architecture rtl;
