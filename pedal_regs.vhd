-- Avalon-MM register bank written by the HPS over the lightweight bridge (0xFF200000).
--   0x00 ID        (RO) 0x50ED0001
--   0x04 CHAIN     8 slots x 4 bits, slot 0 = bits 3..0; value = effect id, 0xF = empty.
--                  Audio runs through slots 0..7 in order; an id used twice is stepped twice per sample.
--   0x08+4*e PARAM[e]  bits 9..5 = knob A, bits 4..0 = knob B  (e = 0..7)
-- Effect ids: 0 booster, 1 distortion, 2 overdrive, 3 tremolo, 4 delay, 5 wah, 6 phaser, 7 reverb
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pedal_regs is
    port (
        clk           : in  std_logic;
        reset         : in  std_logic;
        avs_address   : in  std_logic_vector(3 downto 0);   -- word address
        avs_read      : in  std_logic;
        avs_write     : in  std_logic;
        avs_writedata : in  std_logic_vector(31 downto 0);
        avs_readdata  : out std_logic_vector(31 downto 0);
        chain         : out std_logic_vector(31 downto 0);
        params        : out std_logic_vector(79 downto 0)   -- PARAM[e] = params(10e+9 downto 10e)
    );
end entity pedal_regs;

architecture rtl of pedal_regs is
    constant ID : std_logic_vector(31 downto 0) := x"50ED0001";
    -- every knob at mid scale (A=16, B=16)
    function params_mid return std_logic_vector is
        variable v : std_logic_vector(79 downto 0);
    begin
        for e in 0 to 7 loop
            v(10*e+9 downto 10*e) := "1000010000";
        end loop;
        return v;
    end function;
    constant PARAMS_RESET : std_logic_vector(79 downto 0) := params_mid;

    signal chain_r  : std_logic_vector(31 downto 0) := (others => '1');  -- all slots empty
    signal params_r : std_logic_vector(79 downto 0) := PARAMS_RESET;
begin
    process(clk)
        variable a : integer range 0 to 15;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                chain_r <= (others => '1');
                params_r <= PARAMS_RESET;
            elsif avs_write = '1' then
                a := to_integer(unsigned(avs_address));
                if a = 1 then
                    chain_r <= avs_writedata;
                end if;
                for e in 0 to 7 loop
                    if a = e + 2 then
                        params_r(10*e+9 downto 10*e) <= avs_writedata(9 downto 0);
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- readLatency 0: readdata is combinational from the address
    process(avs_address, chain_r, params_r)
        variable a : integer range 0 to 15;
    begin
        a := to_integer(unsigned(avs_address));
        avs_readdata <= (others => '0');
        if a = 0 then
            avs_readdata <= ID;
        elsif a = 1 then
            avs_readdata <= chain_r;
        end if;
        for e in 0 to 7 loop
            if a = e + 2 then
                avs_readdata(9 downto 0) <= params_r(10*e+9 downto 10*e);
            end if;
        end loop;
    end process;

    chain  <= chain_r;
    params <= params_r;
end architecture rtl;
