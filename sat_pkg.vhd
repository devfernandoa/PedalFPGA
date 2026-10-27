library ieee;
use ieee.numeric_std.all;

package sat_pkg is
    -- Clamp any-width signed value to 16 bits (instead of wrapping around).
    function sat16(x : signed) return signed;
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
end package body sat_pkg;
