-- Reverb, Freeverb structure (Jezar, public domain): 8 parallel damped comb filters -> 4 all-passes.
-- The comb input is scaled by 1/4 so the combs (gain up to 1/(1-0.97) ~ 33 at low frequencies)
-- don't saturate on loud notes. Same integer math as reverb() in sim/fx_model.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

-- Comb: buf[n] = x + g * lowpass(buf[n - N]). The low-pass in the loop ("damping") makes the
-- high frequencies die faster, like soft walls.
entity reverb_comb is
    generic (N : integer);
    port (
        clk, ce : in  std_logic;
        x       : in  signed(15 downto 0);
        g       : in  signed(15 downto 0);   -- feedback, Q15
        damp    : in  signed(16 downto 0);   -- 1 - damping, Q15
        y       : out signed(15 downto 0)    -- buf[n - N]
    );
end entity reverb_comb;

architecture rtl of reverb_comb is
    type buf_t is array (0 to N - 1) of signed(15 downto 0);
    signal buf  : buf_t := (others => (others => '0'));
    signal ptr  : integer range 0 to N - 1 := 0;
    signal yr   : signed(15 downto 0) := (others => '0');
    signal filt : signed(15 downto 0) := (others => '0');
begin
    y <= yr;
    process(clk)
        variable nxt : integer range 0 to N - 1;
    begin
        if rising_edge(clk) then
            if ce = '1' then
                if ptr = N - 1 then nxt := 0; else nxt := ptr + 1; end if;
                buf(ptr) <= sat16(resize(x, 17) + shift_right(filt * g, 15));
                yr <= buf(nxt);                  -- the next slot holds the sample written N samples ago
                filt <= filt + resize(shift_right((resize(yr, 17) - resize(filt, 17)) * damp, 15), 16);
                ptr <= nxt;
            end if;
        end if;
    end process;
end architecture rtl;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

-- Schroeder all-pass, g = 0.5: y = buf[n - N] - x, buf[n] = x + buf[n - N] / 2. Combinational x -> y,
-- so the four all-passes run in the same sample.
entity reverb_allpass is
    generic (N : integer);
    port (
        clk, ce : in  std_logic;
        x       : in  signed(15 downto 0);
        y       : out signed(15 downto 0)
    );
end entity reverb_allpass;

architecture rtl of reverb_allpass is
    type buf_t is array (0 to N - 1) of signed(15 downto 0);
    signal buf : buf_t := (others => (others => '0'));
    signal ptr : integer range 0 to N - 1 := 0;
    signal bo  : signed(15 downto 0) := (others => '0');
begin
    y <= sat16(resize(bo, 17) - resize(x, 17));
    process(clk)
        variable nxt : integer range 0 to N - 1;
    begin
        if rising_edge(clk) then
            if ce = '1' then
                if ptr = N - 1 then nxt := 0; else nxt := ptr + 1; end if;
                buf(ptr) <= sat16(resize(x, 17) + shift_right(bo, 1));
                bo <= buf(nxt);
                ptr <= nxt;
            end if;
        end if;
    end process;
end architecture rtl;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity reverb is
    port (
        clk         : in  std_logic;
        ce          : in  std_logic;                     -- 1 pulse per sample
        sample_in   : in  std_logic_vector(15 downto 0);
        room_size   : in  std_logic_vector(4 downto 0);  -- knob A: comb feedback 0.70 .. 0.97 (decay time)
        damping     : in  std_logic_vector(4 downto 0);  -- knob B: 0.05 .. 0.75, higher = darker tail
        sample_out  : out std_logic_vector(15 downto 0)
    );
end entity reverb;

architecture rtl of reverb is
    type len_t is array (0 to 7) of integer;
    constant COMB_LEN : len_t := (1214, 1293, 1390, 1476, 1548, 1623, 1695, 1760);  -- Freeverb, 44.1k -> 48k
    constant AP_LEN   : len_t := (605, 480, 371, 245, 0, 0, 0, 0);

    type s16_array is array (natural range <>) of signed(15 downto 0);
    signal x, cin   : signed(15 downto 0);
    signal g        : signed(15 downto 0);
    signal damp     : signed(16 downto 0);
    signal comb_y   : s16_array(0 to 7);
    signal ap       : s16_array(0 to 4);    -- ap(0) = comb mix, ap(4) = wet
begin
    x    <= signed(sample_in);
    cin  <= shift_right(x, 2);
    g    <= to_signed(22938 + to_integer(unsigned(room_size)) * 285, 16);
    damp <= to_signed(32768 - (1638 + to_integer(unsigned(damping)) * 740), 17);

    combs : for i in 0 to 7 generate
        c : entity work.reverb_comb generic map (N => COMB_LEN(i))
            port map (clk => clk, ce => ce, x => cin, g => g, damp => damp, y => comb_y(i));
    end generate;

    process(comb_y)
        variable tot : signed(18 downto 0);
    begin
        tot := (others => '0');
        for i in 0 to 7 loop
            tot := tot + resize(comb_y(i), 19);
        end loop;
        ap(0) <= resize(shift_right(tot, 3), 16);
    end process;

    allpasses : for i in 0 to 3 generate
        a : entity work.reverb_allpass generic map (N => AP_LEN(i))
            port map (clk => clk, ce => ce, x => ap(i), y => ap(i + 1));
    end generate;

    process(clk)
    begin
        if rising_edge(clk) then
            if ce = '1' then
                -- dry 1.0 + wet 1.5 (the comb input was scaled by 1/4)
                sample_out <= std_logic_vector(sat16(resize(x, 18) + shift_right(resize(ap(4), 18) * 3, 1)));
            end if;
        end if;
    end process;
end architecture rtl;
