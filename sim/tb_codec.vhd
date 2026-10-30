-- codec.vhd against a model of the WM8731 side of the bus. Run by sim/test_vhdl.py.
--   I2C: decodes every write, NAKs the very first byte (codec still waking up) to exercise the retry,
--        then checks the register words against the expected list.
--   I2S: the model is the master (BCLK = 3.125 MHz, left-justified, 32 bits per channel).
--        It sends a different 24-bit word per frame on ADCDAT (left) and junk on the right channel,
--        and reads DACDAT back on both channels.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_codec is
end entity tb_codec;

architecture sim of tb_codec is
    signal clk : std_logic := '0';
    signal done_sim : boolean := false;

    -- I2C
    signal scl, sda : std_logic;
    signal sda_ack  : std_logic := 'Z';
    signal cfg_done : std_logic;
    type words_t is array (natural range <>) of std_logic_vector(15 downto 0);
    constant EXPECT : words_t := (x"1E00", x"0C72", x"0117", x"0579", x"0812", x"0A00", x"0E49", x"1000", x"1201", x"0C62");

    -- I2S
    signal bclk, lrck : std_logic := '0';
    signal adcdat, dacdat : std_logic := '0';
    signal rx : std_logic_vector(23 downto 0);
    signal rx_ready : std_logic;
    signal tx : std_logic_vector(23 downto 0) := x"A5C3F1";
    signal rx_count : integer := 0;

    function word_for(k : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(k * 123457 - 4000000, 24));
    end function;
begin
    clk <= not clk after 10 ns when not done_sim;

    cfg: entity work.codec_cfg generic map (WAKE => 1000)
        port map (clk => clk, aud_xck => open, i2c_sclk => scl, i2c_sdat => sda, done => cfg_done);
    sda <= 'H';            -- board pull-up
    sda <= sda_ack;

    i2s: entity work.codec_i2s
        port map (clk => clk, bclk => bclk, adclrck => lrck, adcdat => adcdat, daclrck => lrck, dacdat => dacdat,
                  rx => rx, rx_ready => rx_ready, tx => tx);

    -- I2C slave: START = SDA falls while SCL high; bits read on SCL rising; ACK after each byte
    i2c_model: process
        variable bits : std_logic_vector(23 downto 0);
        variable n, words : integer := 0;
        variable first : boolean := true;
    begin
        loop
            wait until falling_edge(sda) and scl = '1';
            n := 0;
            while n < 24 loop
                wait until rising_edge(scl);
                bits(23 - n) := to_x01(sda);
                n := n + 1;
                if n mod 8 = 0 then                      -- ACK clock: pull SDA low while SCL is low
                    wait until falling_edge(scl);
                    if not first then sda_ack <= '0'; end if;
                    wait until falling_edge(scl);
                    sda_ack <= 'Z';
                    if first then first := false; exit; end if;
                end if;
            end loop;
            if n = 24 then
                assert bits(23 downto 16) = x"34" report "I2C: wrong device address" severity failure;
                assert words < EXPECT'length report "I2C: too many writes" severity failure;
                assert bits(15 downto 0) = EXPECT(words)
                    report "I2C: word " & integer'image(words) & " is wrong" severity failure;
                words := words + 1;
                if words = EXPECT'length then
                    wait for 50 us;
                    assert cfg_done = '1' report "I2C: done not set" severity failure;
                    report "I2C ok: " & integer'image(words) & " words, retried after a NAK";
                    wait;
                end if;
            end if;
        end loop;
    end process;

    -- I2S master: 64 BCLK per frame; LRCK and data change on falling edges
    i2s_master: process
        variable w : std_logic_vector(23 downto 0);
        variable got_l, got_r : std_logic_vector(23 downto 0);
    begin
        wait for 1 us;
        for k in 0 to 40 loop
            for ch in 0 to 1 loop                        -- 0 = left (LRCK high), 1 = right
                if ch = 0 then w := word_for(k); else w := x"5A5A5A"; end if;
                for b in 0 to 31 loop
                    bclk <= '0';
                    if b = 0 then
                        if ch = 0 then lrck <= '1'; else lrck <= '0'; end if;
                    end if;
                    if b < 24 then adcdat <= w(23 - b); else adcdat <= '0'; end if;
                    wait for 160 ns;
                    bclk <= '1';
                    if b < 24 then                       -- the codec samples DACDAT on rising edges
                        if ch = 0 then got_l(23 - b) := dacdat; else got_r(23 - b) := dacdat; end if;
                    end if;
                    wait for 160 ns;
                end loop;
            end loop;
            if k >= 2 then                               -- the first frames carry the reset value
                assert got_l = tx and got_r = tx report "I2S: DAC word wrong" severity failure;
            end if;
        end loop;
        assert rx_count >= 38 report "I2S: too few ADC words" severity failure;
        report "I2S ok: " & integer'image(rx_count) & " ADC words, DAC words match";
        wait for 4 ms;                                   -- let the I2C side finish (~3.3 ms)
        assert cfg_done = '1' report "I2C never finished" severity failure;
        done_sim <= true;
        wait;
    end process;

    rx_check: process
    begin
        wait until rising_edge(clk) and rx_ready = '1';
        assert rx = word_for(rx_count) report "I2S: ADC word " & integer'image(rx_count) & " wrong" severity failure;
        rx_count <= rx_count + 1;
    end process;
end architecture sim;
