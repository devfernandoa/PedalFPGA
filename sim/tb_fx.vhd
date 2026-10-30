-- Runs one effect over the samples in IN_FILE (one integer per line) and writes its output to OUT_FILE.
-- Driven by sim/test_vhdl.py, which compares the result with sim/fx_model.py sample by sample.
-- FX uses the effect ids of pedal_regs.vhd; 8 is the cabinet (cab.vhd). Timing matches the chain in pedal_core.vhd:
-- input held SLOT_WAIT+1 cycles, one ce pulse, output read after the registers update.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_fx is
    generic (FX : integer := 0; A, B : integer := 16; IN_FILE : string := "in.txt"; OUT_FILE : string := "out.txt");
end entity tb_fx;

architecture sim of tb_fx is
    signal clk : std_logic := '0';
    signal ce  : std_logic := '0';
    signal x, y : std_logic_vector(15 downto 0) := (others => '0');
    signal ka, kb : std_logic_vector(4 downto 0);
    signal mult : std_logic_vector(15 downto 0);
    signal done : boolean := false;
    signal fx_done : std_logic := '0';
begin
    clk <= not clk after 10 ns when not done;
    ka <= std_logic_vector(to_unsigned(A, 5));
    kb <= std_logic_vector(to_unsigned(B, 5));
    mult <= "000000" & ka & kb;   -- booster gain*256, as in pedal_core.vhd

    g0: if FX = 0 generate
        dut: entity work.booster port map (sample_in => x, sample_out => y, multiplier => mult);
    end generate;
    g1: if FX = 1 or FX = 2 generate
        dut: entity work.drive generic map (OVERDRIVE => FX = 2)
            port map (clk => clk, ce => ce, sample_in => x, drive_k => ka, level_k => kb, sample_out => y);
    end generate;
    g3: if FX = 3 generate
        dut: entity work.tremolo port map (clk => clk, ce => ce, sample_in => x, rate => ka, depth => kb, sample_out => y);
    end generate;
    g4: if FX = 4 generate
        dut: entity work.delay port map (clk => clk, ce => ce, sample_in => x, delay_time => ka, feedback => kb, sample_out => y);
    end generate;
    g5: if FX = 5 generate
        dut: entity work.wah port map (clk => clk, ce => ce, sample_in => x, sensitivity => ka, resonance => kb, sample_out => y);
    end generate;
    g6: if FX = 6 generate
        dut: entity work.phaser port map (clk => clk, ce => ce, sample_in => x, rate => ka, depth => kb, sample_out => y);
    end generate;
    g7: if FX = 7 generate
        dut: entity work.reverb port map (clk => clk, ce => ce, sample_in => x, room_size => ka, damping => kb, sample_out => y);
    end generate;

    g8: if FX = 8 generate   -- not a chain slot: the cabinet stage after the chain
        dut: entity work.cab port map (clk => clk, ce => ce, sample_in => x, sample_out => y, done => fx_done);
    end generate;

    process
        file fin  : text open read_mode is IN_FILE;
        file fout : text open write_mode is OUT_FILE;
        variable lin, lout : line;
        variable v : integer;
    begin
        while not endfile(fin) loop
            readline(fin, lin);
            read(lin, v);
            x <= std_logic_vector(to_signed(v, 16));
            for i in 1 to 4 loop wait until rising_edge(clk); end loop;   -- SLOT_WAIT+1
            ce <= '1';
            wait until rising_edge(clk);
            ce <= '0';
            if FX = 8 then
                wait until rising_edge(clk) and fx_done = '1';
            end if;
            wait until rising_edge(clk);
            write(lout, to_integer(signed(y)));
            writeline(fout, lout);
        end loop;
        done <= true;
        wait;
    end process;
end architecture sim;
