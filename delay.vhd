-- filepath: delay.vhd
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity delay is
    port (
        clk         : in  std_logic;
        ce          : in  std_logic;  -- 1 pulse por amostra (48 kHz)
        sample_in   : in  std_logic_vector(15 downto 0);
        delay_time  : in  std_logic_vector(4 downto 0);  -- knob A: 20 ms .. 1 s
        feedback    : in  std_logic_vector(4 downto 0);  -- knob B: repeats, 0 = a single echo, 31 = 0.9 feedback
        sample_out  : out std_logic_vector(15 downto 0)
    );
end entity delay;

architecture a of delay is
    -- Circular buffer, 1 s @ 48 kHz (768 kbit of M10K). Same integer math as delay() in sim/fx_model.py.
    constant BUFFER_SIZE : integer := 48000;
    type sample_buffer_t is array (0 to BUFFER_SIZE-1) of signed(15 downto 0);
    signal buffer_mem : sample_buffer_t := (others => (others => '0'));
    
    signal write_ptr : integer range 0 to BUFFER_SIZE-1 := 0;
    signal read_ptr  : integer range 0 to BUFFER_SIZE-1 := 0;
    
    signal delayed_sample : signed(15 downto 0) := (others => '0');
    signal echo_lp        : signed(31 downto 0) := (others => '0');  -- delayed sample low-passed (x 256)
    signal sample_in_s    : signed(15 downto 0);
    
begin
    sample_in_s <= signed(sample_in);
    
    process(clk)
        variable delay_samples : integer;
        variable echo    : signed(15 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                -- 960 .. 47987 samples (20 ms .. 1 s)
                delay_samples := 960 + to_integer(unsigned(delay_time)) * 1517;
            
                -- Calcular ponteiro de leitura
                if write_ptr >= delay_samples then
                    read_ptr <= write_ptr - delay_samples;
                else
                    read_ptr <= BUFFER_SIZE - (delay_samples - write_ptr);
                end if;
            
                -- Read the delayed sample (the RAM read sees the contents before this cycle's write)
                delayed_sample <= buffer_mem(read_ptr);
                -- Repeats go through a 3.5 kHz low-pass, so each one is darker, like tape/analog delays
                echo := resize(shift_right(echo_lp, 8), 16);
                echo_lp <= echo_lp + resize(shift_right((shift_left(resize(delayed_sample, 32), 8) - echo_lp) * to_signed(12044, 16), 15), 32);
                -- Buffer gets input + feedback (up to 0.9)
                buffer_mem(write_ptr) <= sat16(resize(sample_in_s, 17) + shift_right(echo * to_signed(to_integer(unsigned(feedback)) * 950, 16), 15));
                -- Output: dry at 1.0 + echo at 0.6
                sample_out <= std_logic_vector(sat16(resize(sample_in_s, 17) + shift_right(echo * to_signed(19661, 16), 15)));
                -- Incrementar ponteiro de escrita
                if write_ptr = BUFFER_SIZE - 1 then
                    write_ptr <= 0;
                else
                    write_ptr <= write_ptr + 1;
                end if;
            
            end if;
        end if;
    end process;
    
end architecture a;