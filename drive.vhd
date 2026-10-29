-- Overdrive (OVERDRIVE = true, Tube Screamer style) and distortion (false, RAT style).
--   high-pass -> gain (drive knob) -> clipper -> [+ dry, OD only] -> 2-pole low-pass -> make-up -> level knob
-- The pre high-pass keeps the bass out of the clipper (less mud), the low-pass removes the fizz that
-- clipping adds, and the make-up table (calibrated in sim/fx_model.py) keeps the loudness independent
-- of the drive: level = 16 sounds as loud as the clean guitar. One pipeline stage per sample (4 samples
-- of latency, 83 us). Same integer math as drive() in sim/fx_model.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity drive is
    generic (OVERDRIVE : boolean);
    port (
        clk        : in  std_logic;
        ce         : in  std_logic;                     -- 1 pulse per sample
        sample_in  : in  std_logic_vector(15 downto 0);
        drive_k    : in  std_logic_vector(4 downto 0);  -- knob A: gain into the clipper
        level_k    : in  std_logic_vector(4 downto 0);  -- knob B: output level, 1.3 dB/step, 16 = unity
        sample_out : out std_logic_vector(15 downto 0)
    );
end entity drive;

architecture rtl of drive is
    -- Gain into the clipper, x/16: overdrive 2..60x, distortion 4..400x (exponential)
    constant OD_GAIN : int_table := (
        32, 36, 40, 44, 50, 55, 62, 69,
        77, 86, 96, 107, 119, 133, 149, 166,
        185, 207, 231, 257, 287, 320, 358, 399,
        445, 497, 555, 619, 691, 771, 860, 960);
    constant DIST_GAIN : int_table := (
        64, 74, 86, 100, 116, 135, 156, 181,
        210, 244, 283, 328, 381, 441, 512, 594,
        689, 800, 928, 1076, 1249, 1449, 1681, 1950,
        2262, 2625, 3045, 3533, 4099, 4755, 5517, 6400);
    -- Make-up gain per drive setting, x/4096
    constant OD_COMP : int_table := (
        3878, 3578, 3324, 3108, 2839, 2653, 2437, 2262,
        2098, 1948, 1815, 1696, 1593, 1496, 1408, 1334,
        1268, 1207, 1154, 1108, 1065, 1028, 993, 963,
        936, 912, 890, 872, 855, 840, 827, 816);
    constant DIST_COMP : int_table := (
        1652, 1440, 1256, 1101, 975, 869, 785, 714,
        656, 609, 569, 536, 507, 484, 465, 449,
        436, 424, 415, 407, 400, 395, 391, 387,
        384, 381, 379, 378, 376, 375, 375, 374);
    -- Level knob, x/4096
    constant LEVEL : int_table := (
        374, 434, 504, 585, 680, 790, 917, 1065,
        1237, 1437, 1669, 1938, 2251, 2614, 3036, 3527,
        4096, 4757, 5525, 6417, 7453, 8657, 10054, 11678,
        13563, 15753, 18296, 21250, 24681, 28666, 33294, 38669);

    function pick(c : boolean; a, b : int_table) return int_table is
    begin
        if c then return a; else return b; end if;
    end function;
    function pick(c : boolean; a, b : integer) return integer is
    begin
        if c then return a; else return b; end if;
    end function;

    constant GAIN : int_table := pick(OVERDRIVE, OD_GAIN, DIST_GAIN);
    constant COMP : int_table := pick(OVERDRIVE, OD_COMP, DIST_COMP);
    -- one-pole coefficients (Q15): pre high-pass 720 / 150 Hz, tone low-pass 3.2 / 2.8 kHz
    constant HP_A : integer := pick(OVERDRIVE, 2947, 637);
    constant LP_A : integer := pick(OVERDRIVE, 11214, 10055);

    -- low-pass states keep 8 extra fraction bits (x * 256) so the low cutoffs don't lose precision
    signal lp_pre, lp1, lp2 : signed(31 downto 0) := (others => '0');
    signal v, xd, s, m      : signed(15 downto 0) := (others => '0');
begin
    process(clk)
        variable x    : signed(15 downto 0);
        variable hp   : signed(17 downto 0);
        variable gv   : signed(33 downto 0);
        variable u2   : signed(31 downto 0);
        variable u3   : signed(32 downto 0);
        variable c    : signed(15 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                x := signed(sample_in);

                -- stage 5: level knob
                sample_out <= std_logic_vector(sat16(shift_right(m * to_signed(LEVEL(to_integer(unsigned(level_k))), 17), 12)));
                -- stage 4: make-up gain for this drive setting
                m <= sat16(shift_right(resize(shift_right(lp2, 8), 16) * to_signed(COMP(to_integer(unsigned(drive_k))), 17), 12));

                -- stage 3: tone low-pass, 2 poles
                lp2 <= lp2 + resize(shift_right((lp1 - lp2) * to_signed(LP_A, 16), 15), 32);
                lp1 <= lp1 + resize(shift_right((shift_left(resize(s, 32), 8) - lp1) * to_signed(LP_A, 16), 15), 32);

                -- stage 2: clipper
                if OVERDRIVE then
                    -- cubic soft clip 1.5(u - u^3/3) of u = v in [-1, 1]: smooth, flat at the ends
                    u2 := shift_right(v * v, 15);
                    u3 := shift_right(resize(u2, 17) * v, 15);
                    c  := sat16(shift_right(shift_left(resize(v, 33), 1) + resize(v, 33) - u3, 1));
                    s  <= resize(shift_right(resize(c, 17) + resize(xd, 17), 1), 16);  -- blend with the dry signal
                else
                    s  <= v;                                                           -- hard clip (done in stage 1)
                end if;

                -- stage 1: pre high-pass, then gain into [-1, 1]
                hp := resize(x, 18) - resize(shift_right(lp_pre, 8), 18);
                lp_pre <= lp_pre + resize(shift_right((shift_left(resize(x, 32), 8) - lp_pre) * to_signed(HP_A, 16), 15), 32);
                gv := shift_right(hp * to_signed(GAIN(to_integer(unsigned(drive_k))), 16), 4);
                if gv > 32767 then
                    v <= to_signed(32767, 16);
                elsif gv < -32767 then
                    v <= to_signed(-32767, 16);
                else
                    v <= resize(gv, 16);
                end if;
                xd <= x;
            end if;
        end if;
    end process;
end architecture rtl;
