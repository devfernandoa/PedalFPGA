-- filepath: reverb.vhd
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity reverb is
    port (
        clk         : in  std_logic;
        sample_in   : in  std_logic_vector(15 downto 0);
        room_size   : in  std_logic_vector(4 downto 0);  -- SW[9:5] - tamanho da sala
        damping     : in  std_logic_vector(4 downto 0);  -- SW[4:0] - absorção
        sample_out  : out std_logic_vector(15 downto 0)
    );
end entity reverb;

architecture a of reverb is
    -- 4 Comb filters em paralelo (delays primos para evitar ressonância)
    constant COMB1_SIZE : integer := 1557;
    constant COMB2_SIZE : integer := 1617;
    constant COMB3_SIZE : integer := 1491;
    constant COMB4_SIZE : integer := 1422;
    
    type comb1_buffer_t is array (0 to COMB1_SIZE-1) of signed(15 downto 0);
    type comb2_buffer_t is array (0 to COMB2_SIZE-1) of signed(15 downto 0);
    type comb3_buffer_t is array (0 to COMB3_SIZE-1) of signed(15 downto 0);
    type comb4_buffer_t is array (0 to COMB4_SIZE-1) of signed(15 downto 0);
    
    signal comb1_buf : comb1_buffer_t := (others => (others => '0'));
    signal comb2_buf : comb2_buffer_t := (others => (others => '0'));
    signal comb3_buf : comb3_buffer_t := (others => (others => '0'));
    signal comb4_buf : comb4_buffer_t := (others => (others => '0'));
    
    signal comb1_ptr : integer range 0 to COMB1_SIZE-1 := 0;
    signal comb2_ptr : integer range 0 to COMB2_SIZE-1 := 0;
    signal comb3_ptr : integer range 0 to COMB3_SIZE-1 := 0;
    signal comb4_ptr : integer range 0 to COMB4_SIZE-1 := 0;
    
    signal comb1_out, comb2_out, comb3_out, comb4_out : signed(15 downto 0) := (others => '0');
    signal comb1_filt, comb2_filt, comb3_filt, comb4_filt : signed(15 downto 0) := (others => '0');
    
    -- 2 All-pass filters em série
    constant AP1_SIZE : integer := 225;
    constant AP2_SIZE : integer := 341;
    
    type ap1_buffer_t is array (0 to AP1_SIZE-1) of signed(15 downto 0);
    type ap2_buffer_t is array (0 to AP2_SIZE-1) of signed(15 downto 0);
    
    signal ap1_buf : ap1_buffer_t := (others => (others => '0'));
    signal ap2_buf : ap2_buffer_t := (others => (others => '0'));
    
    signal ap1_ptr : integer range 0 to AP1_SIZE-1 := 0;
    signal ap2_ptr : integer range 0 to AP2_SIZE-1 := 0;
    
    signal ap1_out, ap2_out : signed(15 downto 0) := (others => '0');
    
    -- Coeficientes
    signal feedback_coef : signed(15 downto 0) := (others => '0');
    signal damp_coef     : signed(15 downto 0) := (others => '0');
    signal sample_in_s   : signed(15 downto 0);
    
begin
    sample_in_s <= signed(sample_in);
    
    process(clk)
        variable comb_sum   : signed(31 downto 0);
        variable fb_mult    : signed(31 downto 0);
        variable damp_mult  : signed(31 downto 0);
        variable ap_temp    : signed(31 downto 0);
        variable mixed      : signed(31 downto 0);
        variable filt_diff  : signed(31 downto 0);
    begin
        if rising_edge(clk) then
            -- Calcular coeficientes baseados nos controles
            -- Room size -> feedback (0.7 a 0.95)
            feedback_coef <= to_signed(22937 + to_integer(unsigned(room_size)) * 327, 16);
            -- Damping -> filtro passa-baixa (0.1 a 0.7)
            damp_coef <= to_signed(3276 + to_integer(unsigned(damping)) * 655, 16);
            
            -- === COMB FILTERS (paralelo) ===
            
            -- Comb 1
            comb1_out <= comb1_buf(comb1_ptr);
            filt_diff := (comb1_out - comb1_filt) * damp_coef;
            comb1_filt <= comb1_filt + filt_diff(30 downto 15);
            fb_mult := comb1_filt * feedback_coef;
            comb1_buf(comb1_ptr) <= sample_in_s + fb_mult(30 downto 15);
            if comb1_ptr = COMB1_SIZE - 1 then
                comb1_ptr <= 0;
            else
                comb1_ptr <= comb1_ptr + 1;
            end if;
            
            -- Comb 2
            comb2_out <= comb2_buf(comb2_ptr);
            filt_diff := (comb2_out - comb2_filt) * damp_coef;
            comb2_filt <= comb2_filt + filt_diff(30 downto 15);
            fb_mult := comb2_filt * feedback_coef;
            comb2_buf(comb2_ptr) <= sample_in_s + fb_mult(30 downto 15);
            if comb2_ptr = COMB2_SIZE - 1 then
                comb2_ptr <= 0;
            else
                comb2_ptr <= comb2_ptr + 1;
            end if;
            
            -- Comb 3
            comb3_out <= comb3_buf(comb3_ptr);
            filt_diff := (comb3_out - comb3_filt) * damp_coef;
            comb3_filt <= comb3_filt + filt_diff(30 downto 15);
            fb_mult := comb3_filt * feedback_coef;
            comb3_buf(comb3_ptr) <= sample_in_s + fb_mult(30 downto 15);
            if comb3_ptr = COMB3_SIZE - 1 then
                comb3_ptr <= 0;
            else
                comb3_ptr <= comb3_ptr + 1;
            end if;
            
            -- Comb 4
            comb4_out <= comb4_buf(comb4_ptr);
            filt_diff := (comb4_out - comb4_filt) * damp_coef;
            comb4_filt <= comb4_filt + filt_diff(30 downto 15);
            fb_mult := comb4_filt * feedback_coef;
            comb4_buf(comb4_ptr) <= sample_in_s + fb_mult(30 downto 15);
            if comb4_ptr = COMB4_SIZE - 1 then
                comb4_ptr <= 0;
            else
                comb4_ptr <= comb4_ptr + 1;
            end if;
            
            -- Somar saídas dos comb filters
            comb_sum := resize(comb1_out, 32) + resize(comb2_out, 32) + 
                        resize(comb3_out, 32) + resize(comb4_out, 32);
            
            -- === ALL-PASS FILTERS (série) ===
            
            -- All-pass 1
            ap_temp := comb_sum / 4;
            ap1_out <= ap1_buf(ap1_ptr) + ap_temp(15 downto 0);
            ap1_buf(ap1_ptr) <= ap_temp(15 downto 0) - (ap1_out / 2);
            if ap1_ptr = AP1_SIZE - 1 then
                ap1_ptr <= 0;
            else
                ap1_ptr <= ap1_ptr + 1;
            end if;
            
            -- All-pass 2
            ap2_out <= ap2_buf(ap2_ptr) + ap1_out;
            ap2_buf(ap2_ptr) <= ap1_out - (ap2_out / 2);
            if ap2_ptr = AP2_SIZE - 1 then
                ap2_ptr <= 0;
            else
                ap2_ptr <= ap2_ptr + 1;
            end if;
            
            -- Mixar sinal seco com reverb (50/50)
            mixed := shift_left(resize(sample_in_s, 32), 13) + shift_left(resize(ap2_out, 32), 13);
            
            -- Saída com saturação
            if mixed(31) = '0' and mixed(30 downto 15) > 32767 then
                sample_out <= std_logic_vector(to_signed(32767, 16));
            elsif mixed(31) = '1' and mixed(30 downto 15) < -32768 then
                sample_out <= std_logic_vector(to_signed(-32768, 16));
            else
                sample_out <= std_logic_vector(mixed(30 downto 15));
            end if;
        end if;
    end process;
    
end architecture a;