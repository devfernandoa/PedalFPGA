-- Compressor (feedback, Dyna Comp style): y = x * g, out = y * level.
-- A peak follower on y (instant attack, ~43 ms release) pulls g down by 1/1024 per sample while it is
-- above COMP_T, otherwise g recovers towards the sustain knob's maximum (1x .. 16x) by 1/4096 of the
-- gap per sample. Quiet playing gets up to gmax, loud playing is held near COMP_T: even dynamics and
-- longer sustain. Same integer math as compressor() in sim/fx_model.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity compressor is
    port (
        clk        : in  std_logic;
        ce         : in  std_logic;                     -- 1 pulse per sample
        sample_in  : in  std_logic_vector(15 downto 0);
        sustain    : in  std_logic_vector(4 downto 0);  -- knob A: maximum gain 1x .. 16x
        level_k    : in  std_logic_vector(4 downto 0);  -- knob B: output level, 1.3 dB/step, 16 = unity
        sample_out : out std_logic_vector(15 downto 0)
    );
end entity compressor;

architecture rtl of compressor is
    constant COMP_GMAX : int_table := (
        4096, 4479, 4898, 5357, 5858, 6406, 7005, 7661,
        8377, 9161, 10018, 10955, 11980, 13101, 14327, 15667,
        17133, 18736, 20489, 22406, 24503, 26795, 29302, 32043,
        35041, 38320, 41905, 45826, 50113, 54802, 59929, 65535);
    constant LEVEL : int_table := (
        374, 434, 504, 585, 680, 790, 917, 1065,
        1237, 1437, 1669, 1938, 2251, 2614, 3036, 3527,
        4096, 4757, 5525, 6417, 7453, 8657, 10054, 11678,
        13563, 15753, 18296, 21250, 24681, 28666, 33294, 38669);
    constant COMP_T : integer := 10000;

    signal g   : signed(17 downto 0) := to_signed(4096, 18);   -- Q12 gain
    signal env : signed(31 downto 0) := (others => '0');       -- |y| peak, x 2^15
begin
    process (clk)
        variable y    : signed(15 downto 0);
        variable ay   : signed(31 downto 0);
        variable gmax : signed(17 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                y := sat16(shift_right(signed(sample_in) * g, 12));
                sample_out <= std_logic_vector(sat16(shift_right(y * to_signed(LEVEL(to_integer(unsigned(level_k))), 17), 12)));

                ay := shift_left(abs(resize(y, 32)), 15);
                if ay > env then
                    env <= ay;
                else
                    env <= env - shift_right(env, 11);
                end if;

                gmax := to_signed(COMP_GMAX(to_integer(unsigned(sustain))), 18);
                if shift_right(env, 15) > COMP_T then
                    g <= g - shift_right(g, 10);
                else
                    g <= g + shift_right(gmax - g, 12);
                end if;
            end if;
        end if;
    end process;
end architecture rtl;
