-- WM8731 audio codec on the DE10-Standard.
--   codec_cfg: XCK (master clock) + register setup over I2C, once after power-up.
--   codec_i2s: 24-bit samples in from the ADC and out to the DAC.
-- The codec is the I2S master (it drives BCLK and the LR clocks), left-justified, 24-bit, line in.
-- XCK = 50 MHz / 4 = 12.5 MHz, so "48 kHz" is really 12.5e6 / 256 = 48.83 kHz (1.7 % fast).
-- ponytail: a PLL at 12.288 MHz would give exactly 48 kHz if the effects' rates ever need to be exact.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity codec_cfg is
    generic (WAKE : integer := 2_500_000);   -- 50 ms after power-up (and after a NAK) before talking
    port (
        clk      : in    std_logic;   -- 50 MHz
        aud_xck  : out   std_logic;
        i2c_sclk : out   std_logic;
        i2c_sdat : inout std_logic;
        done     : out   std_logic    -- every register written and acknowledged
    );
end entity codec_cfg;

architecture rtl of codec_cfg is
    -- 16-bit control words: register address (7 bits) & data (9 bits).
    -- The outputs stay powered down until the end, so the setup does not pop.
    type words_t is array (natural range <>) of std_logic_vector(15 downto 0);
    constant WORDS : words_t := (
        x"1E00",   -- R15 reset
        x"0C72",   -- R6  power: mic, oscillator, CLKOUT and outputs off
        x"0117",   -- R0  line in L+R: 0 dB, unmuted
        x"0579",   -- R2  headphone out L+R: 0 dB
        x"0812",   -- R4  analog path: line in -> ADC, DAC -> out, mic muted, no bypass
        x"0A00",   -- R5  digital path: ADC high-pass on, DAC unmuted, no de-emphasis
        x"0E49",   -- R7  format: master, 24-bit, left-justified
        x"1000",   -- R8  sampling: normal mode, 256 fs, 48 kHz
        x"1201",   -- R9  active
        x"0C62");  -- R6  outputs on
    constant ADDR : std_logic_vector(7 downto 0) := x"34";   -- 0011010 + write

    constant QUARTER : integer := 125;        -- 50 MHz / 125 / 4 = 100 kHz SCL

    signal xck_div : unsigned(1 downto 0) := "00";
    signal tick_cnt : integer range 0 to QUARTER - 1 := 0;
    signal wait_cnt : integer range 0 to WAKE := WAKE;
    signal word  : integer range 0 to WORDS'length := 0;
    signal slot  : integer range 0 to 28 := 0;   -- 0 start, 1..27 = 3 x (8 bits + ack), 28 stop
    signal q     : integer range 0 to 3 := 0;    -- quarter of the slot
    signal scl   : std_logic := '1';
    signal sda   : std_logic := '1';             -- '0' pulls SDA low, '1' releases it
    signal frame : std_logic_vector(23 downto 0);
begin
    process (clk)
    begin
        if rising_edge(clk) then
            xck_div <= xck_div + 1;
        end if;
    end process;
    aud_xck <= xck_div(1);

    frame <= ADDR & WORDS(word) when word < WORDS'length else (others => '1');

    process (clk)
        variable bit_i : integer range 0 to 8;
        variable nak   : boolean;
    begin
        if rising_edge(clk) then
            if wait_cnt /= 0 then
                wait_cnt <= wait_cnt - 1;
            elsif word = WORDS'length then
                null;                                         -- all written
            elsif tick_cnt /= QUARTER - 1 then
                tick_cnt <= tick_cnt + 1;
            else
                tick_cnt <= 0;
                bit_i := (slot + 8) mod 9;                    -- slots 1..27: 0..7 data bit, 8 ack
                nak := slot >= 1 and slot <= 27 and bit_i = 8 and q = 2 and i2c_sdat /= '0';
                if slot = 0 then                              -- START: SDA falls while SCL is high
                    case q is
                        when 0 | 1 => scl <= '1'; sda <= '1';
                        when 2     => sda <= '0';
                        when 3     => scl <= '0';
                    end case;
                elsif slot = 28 then                          -- STOP: SDA rises while SCL is high
                    case q is
                        when 0 => sda <= '0';
                        when 1 => scl <= '1';
                        when 2 => sda <= '1';
                        when 3 => null;
                    end case;
                else                                          -- bit: SDA changes while SCL is low
                    case q is
                        when 0 =>
                            if bit_i = 8 then
                                sda <= '1';                   -- release for the codec's ACK
                            else
                                sda <= frame(23 - ((slot - 1) / 9) * 8 - bit_i);
                            end if;
                        when 1 => scl <= '1';
                        when 2 => null;
                        when 3 => scl <= '0';
                    end case;
                end if;

                if nak then                                   -- codec not listening yet: wait, start over
                    word <= 0; slot <= 0; q <= 0;
                    scl <= '1'; sda <= '1';
                    wait_cnt <= WAKE;
                elsif q /= 3 then
                    q <= q + 1;
                else
                    q <= 0;
                    if slot /= 28 then
                        slot <= slot + 1;
                    else
                        slot <= 0;
                        word <= word + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    i2c_sclk <= scl;
    i2c_sdat <= '0' when sda = '0' else 'Z';
    done <= '1' when word = WORDS'length else '0';
end architecture rtl;


library ieee;
use ieee.std_logic_1164.all;

entity codec_i2s is
    port (
        clk       : in  std_logic;                       -- 50 MHz
        bclk      : in  std_logic;
        adclrck   : in  std_logic;
        adcdat    : in  std_logic;
        daclrck   : in  std_logic;
        dacdat    : out std_logic;
        rx        : out std_logic_vector(23 downto 0);   -- left channel, latest sample
        rx_ready  : out std_logic;                       -- 1-cycle pulse when rx changes
        tx        : in  std_logic_vector(23 downto 0)    -- sent on both channels
    );
end entity codec_i2s;

-- Left-justified: LRCK high = left, MSB in the first BCLK period after an LRCK edge.
-- The codec changes its outputs on BCLK falling edges; it samples DACDAT on rising edges.
-- BCLK = XCK / 4 = 3.125 MHz, 16 clk cycles per bit, so 2-flop synchronizers are plenty.
architecture rtl of codec_i2s is
    signal bclk_s, adclrck_s, adcdat_s, daclrck_s : std_logic_vector(2 downto 0) := (others => '0');
    signal rise, fall, fall_d1, fall_d2 : std_logic := '0';
    signal rx_sr   : std_logic_vector(23 downto 0) := (others => '0');
    signal rx_n    : integer range 0 to 24 := 24;
    signal rx_lr   : std_logic := '0';
    signal tx_sr   : std_logic_vector(23 downto 0) := (others => '0');
    signal tx_lr   : std_logic := '0';
begin
    process (clk)
    begin
        if rising_edge(clk) then
            bclk_s    <= bclk_s(1 downto 0) & bclk;
            adclrck_s <= adclrck_s(1 downto 0) & adclrck;
            adcdat_s  <= adcdat_s(1 downto 0) & adcdat;
            daclrck_s <= daclrck_s(1 downto 0) & daclrck;
        end if;
    end process;
    rise <= bclk_s(1) and not bclk_s(2);
    fall <= bclk_s(2) and not bclk_s(1);

    -- ADC: shift on rising edges; a new LRCK level starts a word, the 24th bit of a left word ends it
    process (clk)
    begin
        if rising_edge(clk) then
            rx_ready <= '0';
            if rise = '1' then
                if adclrck_s(1) /= rx_lr then
                    rx_lr <= adclrck_s(1);
                    rx_sr <= rx_sr(22 downto 0) & adcdat_s(1);
                    rx_n  <= 1;
                elsif rx_n < 24 then
                    rx_sr <= rx_sr(22 downto 0) & adcdat_s(1);
                    rx_n  <= rx_n + 1;
                    if rx_n = 23 and rx_lr = '1' then
                        rx       <= rx_sr(22 downto 0) & adcdat_s(1);
                        rx_ready <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- DAC: on each falling edge, load the next word if LRCK just changed, else shift.
    -- Acting 2 cycles after the edge lets the synchronized LRCK settle (it changes right after BCLK
    -- falls) and still leaves 5 cycles (100 ns) of setup before the codec samples on the rising edge.
    process (clk)
    begin
        if rising_edge(clk) then
            fall_d1 <= fall;
            fall_d2 <= fall_d1;
            if fall_d2 = '1' then
                if daclrck_s(1) /= tx_lr then
                    tx_lr <= daclrck_s(1);
                    tx_sr <= tx;
                else
                    tx_sr <= tx_sr(22 downto 0) & '0';
                end if;
            end if;
        end if;
    end process;
    dacdat <= tx_sr(23);
end architecture rtl;
