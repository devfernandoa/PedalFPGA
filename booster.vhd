-- Clean boost: sample_out = sample_in * multiplier / 256, saturated to 16 bits.
-- multiplier comes from knob A (coarse) & knob B (fine), so the gain goes 0 .. 4x (256 = 1x).
-- Combinational. Same math as the booster in sim/test_vhdl.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity booster is
    port (
        sample_in  : in  std_logic_vector(15 downto 0);
        multiplier : in  std_logic_vector(15 downto 0);   -- gain * 256, unsigned (0 .. 1023 used)
        sample_out : out std_logic_vector(15 downto 0)
    );
end entity booster;

architecture rtl of booster is
    signal prod : signed(32 downto 0);
begin
    prod <= signed(sample_in) * signed('0' & multiplier);
    sample_out <= std_logic_vector(sat16(shift_right(prod, 8)));
end architecture rtl;
