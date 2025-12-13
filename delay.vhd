-- filepath: delay.vhd
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity delay is
    port (
        clk         : in  std_logic;
        sample_in   : in  std_logic_vector(15 downto 0);
        delay_time  : in  std_logic_vector(4 downto 0);  -- SW[9:5] - tempo do delay
        feedback    : in  std_logic_vector(4 downto 0);  -- SW[4:0] - quantidade de repetições
        sample_out  : out std_logic_vector(15 downto 0)
    );
end entity delay;

architecture a of delay is
    -- Buffer circular para armazenar amostras (max ~0.5s @ 48kHz)
    constant BUFFER_SIZE : integer := 24000;
    type sample_buffer_t is array (0 to BUFFER_SIZE-1) of signed(15 downto 0);
    signal buffer_mem : sample_buffer_t := (others => (others => '0'));
    
    signal write_ptr : integer range 0 to BUFFER_SIZE-1 := 0;
    signal read_ptr  : integer range 0 to BUFFER_SIZE-1 := 0;
    
    signal delayed_sample : signed(15 downto 0) := (others => '0');
    signal mixed_sample   : signed(31 downto 0) := (others => '0');
    signal feedback_amt   : signed(15 downto 0) := (others => '0');
    signal sample_in_s    : signed(15 downto 0);
    
begin
    sample_in_s <= signed(sample_in);
    
    process(clk)
        variable delay_samples : integer;
        variable fb_mult : signed(31 downto 0);
        variable dry_wet : signed(31 downto 0);
    begin
        if rising_edge(clk) then
            -- Calcular delay em amostras (0 a ~23000 amostras)
            delay_samples := to_integer(unsigned(delay_time)) * 750;
            if delay_samples >= BUFFER_SIZE then
                delay_samples := BUFFER_SIZE - 1;
            end if;
            
            -- Calcular ponteiro de leitura
            if write_ptr >= delay_samples then
                read_ptr <= write_ptr - delay_samples;
            else
                read_ptr <= BUFFER_SIZE - (delay_samples - write_ptr);
            end if;
            
            -- Ler amostra atrasada
            delayed_sample <= buffer_mem(read_ptr);
            
            -- Calcular feedback (0 a ~97%)
            fb_mult := delayed_sample * to_signed(to_integer(unsigned(feedback)) * 1000, 16);
            feedback_amt <= fb_mult(30 downto 15);
            
            -- Mixar sinal seco + atrasado com feedback
            dry_wet := sample_in_s * to_signed(16384, 16) + 
                       delayed_sample * to_signed(to_integer(unsigned(feedback)) * 512, 16);
            
            -- Escrever no buffer (entrada + feedback)
            buffer_mem(write_ptr) <= sample_in_s + feedback_amt(15 downto 0);
            
            -- Incrementar ponteiro de escrita
            if write_ptr = BUFFER_SIZE - 1 then
                write_ptr <= 0;
            else
                write_ptr <= write_ptr + 1;
            end if;
            
            -- Saída com saturação
            if dry_wet(31) = '0' and dry_wet(30 downto 15) > 32767 then
                sample_out <= std_logic_vector(to_signed(32767, 16));
            elsif dry_wet(31) = '1' and dry_wet(30 downto 15) < -32768 then
                sample_out <= std_logic_vector(to_signed(-32768, 16));
            else
                sample_out <= std_logic_vector(dry_wet(30 downto 15));
            end if;
        end if;
    end process;
    
end architecture a;