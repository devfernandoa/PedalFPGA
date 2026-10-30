-- pedal_regs.vhd as the HPS sees it (Avalon reads with readLatency 1, a few idle cycles between
-- accesses like the lightweight bridge). Run by sim/test_vhdl.py.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_regs is
end entity tb_regs;

architecture sim of tb_regs is
    signal clk : std_logic := '0';
    signal done_sim : boolean := false;
    signal address : std_logic_vector(4 downto 0) := (others => '0');
    signal rd, wr : std_logic := '0';
    signal wdata, rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal chain : std_logic_vector(31 downto 0);
    signal params : std_logic_vector(109 downto 0);
    signal volume : std_logic_vector(4 downto 0);
    signal cfg : std_logic_vector(1 downto 0);
    signal cap_sample : std_logic_vector(15 downto 0) := (others => '0');
    signal cap_valid : std_logic := '0';
    signal n_in : integer := 0;            -- samples fed so far
begin
    clk <= not clk after 10 ns when not done_sim;

    dut: entity work.pedal_regs
        port map (clk => clk, reset => '0', avs_address => address, avs_read => rd, avs_write => wr,
                  avs_writedata => wdata, avs_readdata => rdata, chain => chain, params => params,
                  cfg => cfg, volume => volume, cap_sample => cap_sample, cap_valid => cap_valid);

    -- audio side: a new sample (value = 3*n - 5000) every 20 cycles
    process
    begin
        wait until rising_edge(clk);
        for i in 1 to 19 loop wait until rising_edge(clk); end loop;
        cap_sample <= std_logic_vector(to_signed(3 * n_in - 5000, 16));
        cap_valid <= '1';
        wait until rising_edge(clk);
        cap_valid <= '0';
        n_in <= n_in + 1;
    end process;

    process
        variable v : std_logic_vector(31 downto 0);
        variable first : integer;

        procedure write(a : integer; d : std_logic_vector(31 downto 0)) is
        begin
            address <= std_logic_vector(to_unsigned(a, 5)); wdata <= d; wr <= '1';
            wait until rising_edge(clk);
            wr <= '0';
            for i in 1 to 4 loop wait until rising_edge(clk); end loop;
        end procedure;

        procedure read(a : integer; d : out std_logic_vector(31 downto 0)) is
        begin
            address <= std_logic_vector(to_unsigned(a, 5)); rd <= '1';
            wait until rising_edge(clk);
            rd <= '0';
            wait until rising_edge(clk);
            d := rdata;                         -- readLatency 1
            for i in 1 to 3 loop wait until rising_edge(clk); end loop;
        end procedure;
    begin
        for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        read(0, v);  assert v = x"50ED0003" report "ID" severity failure;
        write(1, x"FFFFF210");
        read(1, v);  assert v = x"FFFFF210" and chain = x"FFFFF210" report "CHAIN" severity failure;
        write(4, x"00000123");
        read(4, v);  assert v = x"00000123" and params(29 downto 20) = "0100100011" report "PARAM[2]" severity failure;
        write(12, x"000003FF");
        read(12, v); assert v = x"000003FF" and params(109 downto 100) = "1111111111" report "PARAM[10]" severity failure;
        write(13, x"00000003");
        read(13, v); assert v = x"00000003" and cfg = "11" report "CONFIG" severity failure;
        read(14, v); assert v = x"0000001F" and volume = "11111" report "VOLUME reset" severity failure;
        write(14, x"00000007");
        read(14, v); assert v = x"00000007" and volume = "00111" report "VOLUME" severity failure;

        -- capture: done only after 4096 samples, then they read back in order
        read(15, v); assert v(0) = '0' report "CAPTURE done before any capture" severity failure;
        write(15, x"00000001");
        first := n_in;
        read(15, v); assert v(0) = '0' report "CAPTURE done too early" severity failure;
        loop
            read(15, v);
            exit when v(0) = '1';
        end loop;
        assert n_in - first >= 4096 and n_in - first <= 4098 report "CAPTURE done after the wrong count" severity failure;
        for i in 0 to 4095 loop
            read(16, v);
            assert signed(v) = 3 * (first + i) - 5000 report "CAPDATA " & integer'image(i) severity failure;
        end loop;
        write(16, x"00000000");                 -- rewind
        read(16, v); assert signed(v) = 3 * first - 5000 report "CAPDATA rewind" severity failure;
        read(16, v); assert signed(v) = 3 * first - 4997 report "CAPDATA after rewind" severity failure;

        report "regs ok: CHAIN, PARAM, CONFIG, VOLUME, 4096-sample capture";
        done_sim <= true;
        wait;
    end process;
end architecture sim;
