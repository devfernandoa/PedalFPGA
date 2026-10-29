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
        rate        : in  std_logic_vector(4 downto 0);  -- knob A: sweep rate 0.1 .. 6 Hz
        depth       : in  std_logic_vector(4 downto 0);  -- knob B: sweep depth
        sample_out  : out std_logic_vector(15 downto 0)
    );
end entity phaser;

architecture a of phaser is
    -- LFO: 32-bit phase accumulator -> triangle (tri15), 0.1 .. 6 Hz. Same math as phaser() in sim/fx_model.py.
    constant PHS_INC : int_table := (
        8948, 10211, 11653, 13298, 15176, 17319, 19764, 22555,
        25739, 29374, 33521, 38254, 43655, 49819, 56853, 64881,
        74041, 84496, 96426, 110041, 125578, 143309, 163543, 186635,
        212986, 243059, 277378, 316542, 361236, 412240, 470446, 536871);
    signal phase : unsigned(31 downto 0) := (others => '0');

    -- 4 estágios de all-pass filter
    type ap_array is array (0 to 3) of signed(31 downto 0);
    signal ap_x1   : ap_array := (others => (others => '0'));  -- x[n-1] de cada estágio
    signal ap_y1   : ap_array := (others => (others => '0'));  -- y[n-1] de cada estágio
    
    -- All-pass coefficient a (Q14) = 1 - k, k = 0.02 + depth * lfo^2: the all-pass corner sweeps
    -- 154 Hz .. 4 kHz, spending more time low where a guitar phaser lives
    signal mod_coef : signed(15 downto 0) := to_signed(16384 - 328, 16);
    signal sample_in_s : signed(15 downto 0);

begin
    sample_in_s <= signed(sample_in);
    
    process(clk)
        variable t          : signed(15 downto 0);
        variable t2         : signed(31 downto 0);
        variable ap_input   : signed(31 downto 0);
        variable ap_temp    : signed(31 downto 0);
        variable x_v        : signed(31 downto 0);
        variable mixed      : signed(31 downto 0);
        variable mult_tmp   : signed(47 downto 0);
    begin
        if rising_edge(clk) then
            if ce = '1' then
                -- LFO -> coefficient for the next sample
                t  := tri15(phase);
                t2 := shift_right(t * t, 15);
                mod_coef <= to_signed(16384 - 328, 16)
                            - resize(shift_right(to_signed(to_integer(unsigned(depth)) * 211, 16) * resize(t2, 16), 15), 16);
                phase <= phase + to_unsigned(PHS_INC(to_integer(unsigned(rate))), 32);

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