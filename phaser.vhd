-- filepath: phaser.vhd
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity phaser is
    port (
        clk         : in  std_logic;
        sample_in   : in  std_logic_vector(15 downto 0);
        rate        : in  std_logic_vector(4 downto 0);  -- SW[9:5] - velocidade do LFO
        depth       : in  std_logic_vector(4 downto 0);  -- SW[4:0] - profundidade
        sample_out  : out std_logic_vector(15 downto 0)
    );
end entity phaser;

architecture a of phaser is
    -- LFO para modular os all-pass filters
    signal lfo_counter : unsigned(23 downto 0) := (others => '0');
    signal lfo_value   : signed(15 downto 0) := (others => '0');
    signal lfo_phase   : unsigned(7 downto 0) := (others => '0');
    
    -- 4 estágios de all-pass filter
    type ap_array is array (0 to 3) of signed(31 downto 0);
    signal ap_out  : ap_array := (others => (others => '0'));
    signal ap_z1   : ap_array := (others => (others => '0'));
    
    -- Coeficiente modulado
    signal mod_coef : signed(15 downto 0) := (others => '0');
    signal sample_in_s : signed(15 downto 0);
    
    -- Tabela seno simplificada (32 valores)
    type sine_table_t is array (0 to 31) of signed(15 downto 0);
    constant SINE_TABLE : sine_table_t := (
        to_signed(0, 16), to_signed(6393, 16), to_signed(12539, 16), to_signed(18204, 16),
        to_signed(23170, 16), to_signed(27245, 16), to_signed(30273, 16), to_signed(32137, 16),
        to_signed(32767, 16), to_signed(32137, 16), to_signed(30273, 16), to_signed(27245, 16),
        to_signed(23170, 16), to_signed(18204, 16), to_signed(12539, 16), to_signed(6393, 16),
        to_signed(0, 16), to_signed(-6393, 16), to_signed(-12539, 16), to_signed(-18204, 16),
        to_signed(-23170, 16), to_signed(-27245, 16), to_signed(-30273, 16), to_signed(-32137, 16),
        to_signed(-32767, 16), to_signed(-32137, 16), to_signed(-30273, 16), to_signed(-27245, 16),
        to_signed(-23170, 16), to_signed(-18204, 16), to_signed(-12539, 16), to_signed(-6393, 16)
    );
    
begin
    sample_in_s <= signed(sample_in);
    
    process(clk)
        variable rate_inc   : unsigned(15 downto 0);
        variable depth_mult : signed(31 downto 0);
        variable ap_input   : signed(31 downto 0);
        variable ap_temp    : signed(31 downto 0);
        variable mixed      : signed(31 downto 0);
        variable mult_tmp   : signed(47 downto 0);
    begin
        if rising_edge(clk) then
            -- LFO: incrementar contador baseado na taxa
            rate_inc := to_unsigned(to_integer(unsigned(rate)) * 50 + 10, 16);
            lfo_counter <= lfo_counter + rate_inc;
            
            -- Obter valor do seno da tabela
            lfo_phase <= lfo_counter(23 downto 16);
            lfo_value <= SINE_TABLE(to_integer(lfo_phase(7 downto 3)));
            
            -- Modular coeficiente com profundidade
            depth_mult := lfo_value * to_signed(to_integer(unsigned(depth)) * 200, 16);
            mod_coef <= to_signed(8192, 16) + depth_mult(30 downto 15);
            
            -- Cascata de 4 all-pass filters
            -- Estágio 1
            ap_input := shift_left(resize(sample_in_s, 32), 8);  -- *256
            mult_tmp := (ap_input - ap_z1(0)) * mod_coef;
            ap_temp := mult_tmp(45 downto 14) + ap_z1(0);  -- /16384
            ap_out(0) <= ap_temp;
            ap_z1(0) <= ap_input;
            
            -- Estágio 2
            mult_tmp := (ap_out(0) - ap_z1(1)) * mod_coef;
            ap_temp := mult_tmp(45 downto 14) + ap_z1(1);
            ap_out(1) <= ap_temp;
            ap_z1(1) <= ap_out(0);
            
            -- Estágio 3
            mult_tmp := (ap_out(1) - ap_z1(2)) * mod_coef;
            ap_temp := mult_tmp(45 downto 14) + ap_z1(2);
            ap_out(2) <= ap_temp;
            ap_z1(2) <= ap_out(1);
            
            -- Estágio 4
            mult_tmp := (ap_out(2) - ap_z1(3)) * mod_coef;
            ap_temp := mult_tmp(45 downto 14) + ap_z1(3);
            ap_out(3) <= ap_temp;
            ap_z1(3) <= ap_out(2);
            
            -- Mixar sinal original com processado
            mixed := ap_input + ap_out(3);
            
            -- Saída com saturação
            if mixed(31) = '0' and mixed(24 downto 9) > 32767 then
                sample_out <= std_logic_vector(to_signed(32767, 16));
            elsif mixed(31) = '1' and mixed(24 downto 9) < -32768 then
                sample_out <= std_logic_vector(to_signed(-32768, 16));
            else
                sample_out <= std_logic_vector(mixed(24 downto 9));
            end if;
        end if;
    end process;
    
end architecture a;