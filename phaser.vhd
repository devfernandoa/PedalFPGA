-- filepath: phaser.vhd
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity phaser is
    port (
        clk         : in  std_logic;
        ce          : in  std_logic;  -- 1 pulse por amostra (48 kHz)
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
    signal ap_x1   : ap_array := (others => (others => '0'));  -- x[n-1] de cada estágio
    signal ap_y1   : ap_array := (others => (others => '0'));  -- y[n-1] de cada estágio
    
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
        variable x_v        : signed(31 downto 0);
        variable mixed      : signed(31 downto 0);
        variable mult_tmp   : signed(47 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                -- LFO: incrementar contador baseado na taxa
                rate_inc := to_unsigned(to_integer(unsigned(rate)) * 50 + 10, 16);
                lfo_counter <= lfo_counter + rate_inc;
            
                -- Obter valor do seno da tabela
                lfo_phase <= lfo_counter(23 downto 16);
                lfo_value <= SINE_TABLE(to_integer(lfo_phase(7 downto 3)));
            
                -- Modular coeficiente com profundidade
                depth_mult := lfo_value * to_signed(to_integer(unsigned(depth)) * 200, 16);
                mod_coef <= to_signed(8192, 16) + depth_mult(30 downto 15);
            
                -- Cascata de 4 all-pass de 1a ordem: y[n] = a*(y[n-1] - x[n]) + x[n-1], a = mod_coef/16384
                -- (calculados no mesmo passo: registradores entre estágios somariam atrasos fixos)
                ap_input := shift_left(resize(sample_in_s, 32), 8);  -- *256
                ap_temp := ap_input;
                for k in 0 to 3 loop
                    x_v := ap_temp;
                    mult_tmp := (ap_y1(k) - x_v) * mod_coef;
                    ap_temp := mult_tmp(45 downto 14) + ap_x1(k);  -- /16384
                    ap_x1(k) <= x_v;
                    ap_y1(k) <= ap_temp;
                end loop;

                -- Mixar sinal original com processado
                mixed := ap_input + ap_temp;
            
                -- Saída com saturação
                sample_out <= std_logic_vector(sat16(shift_right(mixed, 9)));
            end if;
        end if;
    end process;
    
end architecture a;