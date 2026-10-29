library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Helpers shared by the effects. The constant tables in the effects come from sim/fx_model.py --vhdl.
package sat_pkg is
    -- Clamp any-width signed value to 16 bits (instead of wrapping around).
    function sat16(x : signed) return signed;
    -- One value per knob position (0..31)
    type int_table is array (0 to 31) of integer;
    -- 32-bit LFO phase -> triangle 0..32767 (peak at half period)
    function tri15(phase : unsigned(31 downto 0)) return signed;
end package sat_pkg;

package body sat_pkg is
    function sat16(x : signed) return signed is
    begin
        if x > 32767 then
            return to_signed(32767, 16);
        elsif x < -32768 then
            return to_signed(-32768, 16);
        else
            return resize(x, 16);
        end if;
    end function;

    function tri15(phase : unsigned(31 downto 0)) return signed is
    begin
        if phase(31) = '1' then
            return signed('0' & not phase(30 downto 16));  -- 65535 - t
        else
            return signed('0' & phase(30 downto 16));
        end if;
    end function;
end package body sat_pkg;
