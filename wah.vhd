-- filepath: wah.vhd
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wah is
    port (
        clk         : in  std_logic;
        sample_in   : in  std_logic_vector(15 downto 0);
        frequency   : in  std_logic_vector(4 downto 0);  -- SW[9:5] - frequência central
        resonance   : in  std_logic_vector(4 downto 0);  -- SW[4:0] - ressonância (Q)
        sample_out  : out std_logic_vector(15 downto 0)
    );
end entity wah;

architecture a of wah is
    -- Coeficientes do filtro passa-banda (state variable filter)
    signal bp_out    : signed(31 downto 0) := (others => '0');
    signal lp_out    : signed(31 downto 0) := (others => '0');
    signal hp_out    : signed(31 downto 0) := (others => '0');
    
    signal bp_z1     : signed(31 downto 0) := (others => '0');
    signal lp_z1     : signed(31 downto 0) := (others => '0');
    
    signal freq_coef : signed(15 downto 0) := (others => '0');
    signal q_coef    : signed(15 downto 0) := (others => '0');
    signal sample_in_s : signed(15 downto 0);
    
begin
    sample_in_s <= signed(sample_in);
    
    process(clk)
        variable input_ext : signed(31 downto 0);
        variable freq_val  : integer;
        variable q_val     : integer;
        variable bp_scaled : signed(31 downto 0);
        variable lp_new    : signed(31 downto 0);
        variable bp_new    : signed(31 downto 0);
        variable mult_tmp  : signed(47 downto 0);
    begin
        if rising_edge(clk) then
            -- Frequência de corte: 300Hz a 2500Hz mapeado
            freq_val := 500 + to_integer(unsigned(frequency)) * 70;
            freq_coef <= to_signed(freq_val, 16);
            
            -- Ressonância Q: 1 a 15
            q_val := 2000 + to_integer(unsigned(resonance)) * 400;
            q_coef <= to_signed(q_val, 16);
            
            -- Extensão do sinal de entrada (shift left 8 = *256)
            input_ext := shift_left(resize(sample_in_s, 32), 8);
            
            -- State Variable Filter (SVF)
            -- HP = input - LP - Q*BP
            mult_tmp := bp_z1 * q_coef;
            bp_scaled := mult_tmp(44 downto 13);  -- /8192
            hp_out <= input_ext - lp_z1 - bp_scaled;
            
            -- BP = HP * freq + BP_z1
            mult_tmp := hp_out * freq_coef;
            bp_new := mult_tmp(45 downto 14) + bp_z1;  -- /16384
            bp_out <= bp_new;
            
            -- LP = BP * freq + LP_z1
            mult_tmp := bp_new * freq_coef;
            lp_new := mult_tmp(45 downto 14) + lp_z1;  -- /16384
            lp_out <= lp_new;
            
            -- Atualizar registradores
            bp_z1 <= bp_new;
            lp_z1 <= lp_new;
            
            -- Saída: passa-banda (efeito wah clássico)
            if bp_new(31) = '0' and bp_new(23 downto 8) > 32767 then
                sample_out <= std_logic_vector(to_signed(32767, 16));
            elsif bp_new(31) = '1' and bp_new(23 downto 8) < -32768 then
                sample_out <= std_logic_vector(to_signed(-32768, 16));
            else
                sample_out <= std_logic_vector(bp_new(23 downto 8));
            end if;
        end if;
    end process;
    
end architecture a;