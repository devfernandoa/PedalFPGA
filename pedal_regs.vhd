-- Avalon-MM register bank written by the HPS over the lightweight bridge (0xFF200000).
--   0x00 ID        (RO) 0x50ED0003
--   0x04 CHAIN     8 slots x 4 bits, slot 0 = bits 3..0; value = effect id, 0xF = empty.
--                  Audio runs through slots 0..7 in order; an id used twice is stepped twice per sample.
--   0x08+4*e PARAM[e]  bits 9..5 = knob A, bits 4..0 = knob B  (e = 0..10)
--   0x34 CONFIG    bit 0 = mic input (0 = line in), bit 1 = cabinet simulator on
--   0x38 VOLUME    bits 4..0: output volume, 31 = 0 dB, 1.5 dB per step, 0 = mute
--   0x3C CAPTURE   write: capture the next 4096 input samples (for the tuner); read: bit 0 = done
--   0x40 CAPDATA   read: next captured sample (signed, sign-extended), from the first one on;
--                  write: rewind to the first sample
-- Effect ids: 0 booster, 1 distortion, 2 overdrive, 3 tremolo, 4 delay, 5 wah, 6 phaser, 7 reverb,
--             8 compressor, 9 chorus, 10 flanger
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pedal_regs is
    port (
        clk           : in  std_logic;
        reset         : in  std_logic;
        avs_address   : in  std_logic_vector(4 downto 0);   -- word address
        avs_read      : in  std_logic;
        avs_write     : in  std_logic;
        avs_writedata : in  std_logic_vector(31 downto 0);
        avs_readdata  : out std_logic_vector(31 downto 0);  -- readLatency 1
        chain         : out std_logic_vector(31 downto 0);
        params        : out std_logic_vector(109 downto 0); -- PARAM[e] = params(10e+9 downto 10e)
        cfg           : out std_logic_vector(1 downto 0);
        volume        : out std_logic_vector(4 downto 0);
        cap_sample    : in  std_logic_vector(15 downto 0);  -- input samples for the capture buffer
        cap_valid     : in  std_logic
    );
end entity pedal_regs;

architecture rtl of pedal_regs is
    constant ID : std_logic_vector(31 downto 0) := x"50ED0003";
    constant N_FX : integer := 11;
    constant CAP_N : integer := 4096;
    -- every knob at mid scale (A=16, B=16)
    function params_mid return std_logic_vector is
        variable v : std_logic_vector(109 downto 0);
    begin
        for e in 0 to N_FX - 1 loop
            v(10*e+9 downto 10*e) := "1000010000";
        end loop;
        return v;
    end function;
    constant PARAMS_RESET : std_logic_vector(109 downto 0) := params_mid;

    signal chain_r  : std_logic_vector(31 downto 0) := (others => '1');  -- all slots empty
    signal params_r : std_logic_vector(109 downto 0) := PARAMS_RESET;
    signal config_r : std_logic_vector(1 downto 0) := "00";
    signal volume_r : std_logic_vector(4 downto 0) := "11111";

    type cap_ram_t is array (0 to CAP_N - 1) of std_logic_vector(15 downto 0);
    signal cap_ram : cap_ram_t;
    signal cap_wp, cap_rp : integer range 0 to CAP_N - 1 := 0;
    signal capturing : std_logic := '0';
    signal cap_done  : std_logic := '0';
    signal cap_q     : std_logic_vector(15 downto 0);   -- cap_ram(cap_rp), one cycle late
begin
    process(clk)
        variable a : integer range 0 to 31;
    begin
        if rising_edge(clk) then
            a := to_integer(unsigned(avs_address));

            -- capture buffer: written by the audio side, read by the HPS
            if capturing = '1' and cap_valid = '1' then
                cap_ram(cap_wp) <= cap_sample;
                if cap_wp = CAP_N - 1 then
                    capturing <= '0';
                    cap_done <= '1';
                else
                    cap_wp <= cap_wp + 1;
                end if;
            end if;
            cap_q <= cap_ram(cap_rp);

            -- reads (readLatency 1). CAPDATA advances on each read; the bridge never reads on
            -- back-to-back cycles, so cap_q has caught up with cap_rp by the next read.
            avs_readdata <= (others => '0');
            if avs_read = '1' then
                case a is
                    when 0 => avs_readdata <= ID;
                    when 1 => avs_readdata <= chain_r;
                    when 2 to 12 => avs_readdata(9 downto 0) <= params_r(10*(a-2)+9 downto 10*(a-2));
                    when 13 => avs_readdata(1 downto 0) <= config_r;
                    when 14 => avs_readdata(4 downto 0) <= volume_r;
                    when 15 => avs_readdata(0) <= cap_done;
                    when 16 =>
                        avs_readdata <= std_logic_vector(resize(signed(cap_q), 32));
                        if cap_rp /= CAP_N - 1 then
                            cap_rp <= cap_rp + 1;
                        end if;
                    when others => null;
                end case;
            end if;

            if reset = '1' then
                chain_r <= (others => '1');
                params_r <= PARAMS_RESET;
                config_r <= "00";
                volume_r <= "11111";
                capturing <= '0';
                cap_done <= '0';
            elsif avs_write = '1' then
                case a is
                    when 1 => chain_r <= avs_writedata;
                    when 2 to 12 => params_r(10*(a-2)+9 downto 10*(a-2)) <= avs_writedata(9 downto 0);
                    when 13 => config_r <= avs_writedata(1 downto 0);
                    when 14 => volume_r <= avs_writedata(4 downto 0);
                    when 15 =>
                        capturing <= '1';
                        cap_done <= '0';
                        cap_wp <= 0;
                        cap_rp <= 0;
                    when 16 => cap_rp <= 0;
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    chain  <= chain_r;
    params <= params_r;
    cfg    <= config_r;
    volume <= volume_r;
end architecture rtl;
