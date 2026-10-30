library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;
USE ieee.NUMERIC_STD.all;

-- Audio path: codec -> DC blocker -> noise gate -> effects -> codec.
-- Effect selection and knobs come from pedal_regs (written by the HPS), see pedal_regs.vhd.
entity pedal_core is
 port(		CLOCK_50 	:  in  std_logic;
		--====CONTROL (pedal_regs)====--
		chain 		:  in  std_logic_vector(31 downto 0);
		params 		:  in  std_logic_vector(109 downto 0);
		cfg 		:  in  std_logic_vector(1 downto 0);   -- CONFIG: bit 0 mic input, bit 1 cab on
		volume 		:  in  std_logic_vector(4 downto 0);   -- VOLUME: 31 = 0 dB, 1.5 dB/step, 0 = mute
		cap_sample 	:  out std_logic_vector(15 downto 0);  -- input samples for the tuner capture
		cap_valid 	:  out std_logic;
		--====AUDIO====--
		AUD_BCLK 	:  in  std_logic;
		AUD_ADCLRCK 	:  in  std_logic;
		AUD_DACLRCK 	:  in  std_logic;
		AUD_ADCDAT 	:  in  std_logic;
		AUD_DACDAT 	:  out std_logic;
		FPGA_I2C_SCLK 	:  out std_logic;
		FPGA_I2C_SDAT 	:  inout  std_logic;
		LEDR 		: out  std_logic_vector(9 downto 0);
		--====HEXADECIMAL====--
		HEX0 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX1 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX2 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX3 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX4 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX5 : OUT STD_LOGIC_VECTOR(0 TO 6)	);
end pedal_core;

architecture a of pedal_core is 


	component booster
	 port (
			sample_in : in	std_logic_vector(15 downto 0);
			multiplier : in	std_logic_vector(15 downto 0);
			sample_out : out std_logic_vector(15 downto 0)
		);
	end component;

	component delay
	 port (
			clk         : in  std_logic;
			ce          : in  std_logic;
			sample_in   : in  std_logic_vector(15 downto 0);
			delay_time  : in  std_logic_vector(4 downto 0);
			feedback    : in  std_logic_vector(4 downto 0);
			sample_out  : out std_logic_vector(15 downto 0)
		);
	end component;

	component wah
	 port (
			clk         : in  std_logic;
			ce          : in  std_logic;
			sample_in   : in  std_logic_vector(15 downto 0);
			sensitivity : in  std_logic_vector(4 downto 0);
			resonance   : in  std_logic_vector(4 downto 0);
			sample_out  : out std_logic_vector(15 downto 0)
		);
	end component;

	component phaser
	 port (
			clk         : in  std_logic;
			ce          : in  std_logic;
			sample_in   : in  std_logic_vector(15 downto 0);
			rate        : in  std_logic_vector(4 downto 0);
			depth       : in  std_logic_vector(4 downto 0);
			sample_out  : out std_logic_vector(15 downto 0)
		);
	end component;

	component reverb
	 port (
			clk         : in  std_logic;
			ce          : in  std_logic;
			sample_in   : in  std_logic_vector(15 downto 0);
			room_size   : in  std_logic_vector(4 downto 0);
			damping     : in  std_logic_vector(4 downto 0);
			sample_out  : out std_logic_vector(15 downto 0)
		);
	end component;

	--AUDIO SIGNALS
	signal in_ready   : std_logic;
	signal codec_rx, codec_tx : std_logic_vector(23 downto 0);
	signal rx_round   : signed(24 downto 0);
	signal sample_in  : std_logic_vector(15 downto 0);

    -- Output volume, applied on the 24-bit codec word so quiet settings keep their resolution
    type vol_table is array (0 to 31) of integer;
    function vol_gains return vol_table is
        variable t : vol_table;
    begin
        t(0) := 0;
        for v in 1 to 31 loop
            t(v) := integer(round(32767.0 * 10.0 ** (real(v - 31) * 1.5 / 20.0)));   -- Q15
        end loop;
        return t;
    end function;
    constant VOL_GAIN : vol_table := vol_gains;
    signal vol_g : signed(15 downto 0) := to_signed(32767, 16);
    
    -- Noise Gate Signals
    signal sample_gated : std_logic_vector(15 downto 0);
    constant GATE_THRESH : integer := 10; -- Lowered threshold
    signal gate_timer : integer range 0 to 24000 := 0;

	constant N_FX : integer := 11;
	type sample_array is array (0 to N_FX - 1) of std_logic_vector(15 downto 0);
	signal fx_out     : sample_array;                    -- output of each effect, indexed by id
	signal sample_out : std_logic_vector(15 downto 0) := (others => '0');
	
    -- Booster gain (knob A coarse, B fine)
	signal multiplier : std_logic_vector(15 downto 0);

    -- Effect ids (same as pedal_regs.vhd); PARAM[e]: bits 9..5 = knob A, 4..0 = knob B
    constant FX_BOOST : integer := 0;
    constant FX_DIST  : integer := 1;
    constant FX_OD    : integer := 2;
    constant FX_TREM  : integer := 3;
    constant FX_DLY   : integer := 4;
    constant FX_WAH   : integer := 5;
    constant FX_PHS   : integer := 6;
    constant FX_REV   : integer := 7;
    constant FX_COMP  : integer := 8;
    constant FX_CHO   : integer := 9;
    constant FX_FLA   : integer := 10;
    type param_array is array (0 to N_FX - 1) of std_logic_vector(9 downto 0);
    -- params_s only changes on in_ready, a few cycles before the chain starts (see PedalFPGA.sdc multicycle paths)
    signal params_s : std_logic_vector(109 downto 0) := (others => '0');
    signal p        : param_array;
    signal p_cur    : std_logic_vector(9 downto 0);

    -- First effect in the chain (shown on HEX5/4 + its knobs on HEX3-0/LEDR); >= N_FX = empty
    signal current_effect : integer range 0 to 15 := 15;

    -- Effect chain (see the chain process)
    constant SLOT_WAIT : integer := 3;  -- chain_x is stable SLOT_WAIT+2 cycles before ce (sdc multicycle = 4)
    type chain_state_t is (CH_IDLE, CH_WAIT, CH_FIRE, CH_LATCH);
    signal ch_state   : chain_state_t := CH_IDLE;
    signal chain_x    : std_logic_vector(15 downto 0) := (others => '0');  -- sample travelling down the chain
    signal chain_sh   : std_logic_vector(31 downto 0) := (others => '1');  -- CHAIN snapshot, current slot in bits 3..0
    signal slot       : integer range 0 to 8 := 0;
    signal wait_cnt   : integer range 0 to SLOT_WAIT := 0;
    signal fx_ce      : std_logic_vector(N_FX - 1 downto 0) := (others => '0');
    signal in_ready_d : std_logic := '0';
    -- Cabinet stage after the chain
    signal cab_ce, cab_done : std_logic := '0';
    signal cab_y : std_logic_vector(15 downto 0);

    function seg7(i : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        case i is
            when "0000" => return "0000001"; -- 0
            when "0001" => return "1001111"; -- 1
            when "0010" => return "0010010"; -- 2
            when "0011" => return "0000110"; -- 3
            when "0100" => return "1001100"; -- 4
            when "0101" => return "0100100"; -- 5
            when "0110" => return "0100000"; -- 6
            when "0111" => return "0001111"; -- 7
            when "1000" => return "0000000"; -- 8
            when "1001" => return "0000100"; -- 9
            when "1010" => return "0001000"; -- A
            when "1011" => return "1100000"; -- b
            when "1100" => return "0110001"; -- C
            when "1101" => return "1000010"; -- d
            when "1110" => return "0110000"; -- E
            when "1111" => return "0111000"; -- F
            when others => return "1111111";
        end case;
    end function;

begin 
	
    
    -- (DC offset is removed by the codec's own ADC high-pass filter, R5 in codec.vhd)

    -- Noise Gate Process with Hold (Hysteresis)
    -- Prevents chopping zero-crossings (distortion) and adds sustain
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            if in_ready = '1' then
                if abs(signed(sample_in)) > to_signed(GATE_THRESH, 16) then
                    gate_timer <= 24000; -- Reset timer (~0.5s hold)
                    sample_gated <= sample_in;
                else
                    if gate_timer > 0 then
                        gate_timer <= gate_timer - 1;
                        sample_gated <= sample_in;
                    else
                        sample_gated <= (others => '0');
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Register the HPS-written knobs once per sample, so they change in step with the audio
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            if in_ready = '1' then
                params_s <= params;
            end if;
        end if;
    end process;

    gen_p: for e in 0 to N_FX - 1 generate
        p(e) <= params_s(10*e+9 downto 10*e);
    end generate;

    current_effect <= to_integer(unsigned(chain(3 downto 0)));
    p_cur <= p(current_effect) when current_effect < N_FX else (others => '0');

    -- Booster gain; the other effects map their knobs themselves
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            -- 1. BOOSTER GAIN: A (coarse) and B (fine) form one 10-bit number = gain*256,
            -- so 0..4x; A=8 B=0 is 1x, the mid setting (A=16 B=16) is about 2x.
            multiplier <= "000000" & p(FX_BOOST);

        end if;
    end process;
    
	inst_cfg: entity work.codec_cfg
		port map(	clk => CLOCK_50,
				mic => cfg(0),
				i2c_sclk => FPGA_I2C_SCLK,
				i2c_sdat => FPGA_I2C_SDAT,
				done => open	);

	inst_i2s: entity work.codec_i2s
		port map(	clk => CLOCK_50,
				bclk => AUD_BCLK,
				adclrck => AUD_ADCLRCK,
				adcdat => AUD_ADCDAT,
				daclrck => AUD_DACLRCK,
				dacdat => AUD_DACDAT,
				rx => codec_rx,
				rx_ready => in_ready,
				tx => codec_tx	);

	-- The codec runs at 24 bits; the effects at 16. Round in (saturating the one case that would
	-- wrap, +full scale), pad out.
	rx_round  <= resize(signed(codec_rx), 25) + 128;
	sample_in <= x"7FFF" when rx_round(24 downto 23) = "01" else std_logic_vector(rx_round(23 downto 8));
	process(CLOCK_50)
	begin
		if rising_edge(CLOCK_50) then
			vol_g <= to_signed(VOL_GAIN(to_integer(unsigned(volume))), 16);
		end if;
	end process;
	-- |sample_out * vol_g| < 2^30, so >> 7 fits the 24-bit word (0 dB = the 16-bit sample << 8)
	codec_tx  <= std_logic_vector(resize(shift_right(signed(sample_out) * vol_g, 7), 24));


	-- Display: first effect in the chain and its knobs
		LEDR <= p_cur;
		
        -- Effect Display (Active Low: 0=ON, 1=OFF)
        -- Bank A: bO=Booster, d1=Distortion, Od=Overdrive, tr=Tremolo
        -- Bank B: dL=Delay, UA=Wah, PH=Phaser, rE=Reverb
        -- Bank C: Co=Compressor, Ch=Chorus, FL=Flanger
        HEX5 <= "1100000" when current_effect = 0 else -- b (Booster)
                "1000010" when current_effect = 1 else -- d (Distortion)
                "0000001" when current_effect = 2 else -- O (Overdrive)
                "1110000" when current_effect = 3 else -- t (Tremolo)
                "1000010" when current_effect = 4 else -- d (Delay)
                "1000001" when current_effect = 5 else -- U (Wah)
                "0001100" when current_effect = 6 else -- P (Phaser)
                "1111010" when current_effect = 7 else -- r (Reverb)
                "0110001" when current_effect = 8 else -- C (Compressor)
                "0110001" when current_effect = 9 else -- C (Chorus)
                "0111000" when current_effect = 10 else -- F (Flanger)
                "1111110";                             -- - (bypass)

        HEX4 <= "0000001" when current_effect = 0 else -- O (bO)
                "1001111" when current_effect = 1 else -- 1 (d1)
                "1000010" when current_effect = 2 else -- d (Od)
                "1111010" when current_effect = 3 else -- r (tr)
                "1110001" when current_effect = 4 else -- L (dL)
                "0001000" when current_effect = 5 else -- A (UA)
                "0001001" when current_effect = 6 else -- H (PH)
                "0110000" when current_effect = 7 else -- E (rE)
                "1100010" when current_effect = 8 else -- o (Co)
                "1101000" when current_effect = 9 else -- h (Ch)
                "1110001" when current_effect = 10 else -- L (FL)
                "1111110";                             -- - (bypass)

		HEX3<=seg7("000" & p_cur(9));
		HEX2<=seg7(p_cur(8 downto 5));
		HEX1<=seg7("000" & p_cur(4));
		HEX0<=seg7(p_cur(3 downto 0));
        
        -- Effect chain: once per sample, run chain_x through CHAIN slots 0..7 in order.
        -- Per slot: hold chain_x for SLOT_WAIT+1 cycles, pulse that effect's ce for one cycle,
        -- then latch the effect's output (registered, or combinational for booster/distortion/
        -- overdrive/tremolo) back into chain_x. Empty slots (id >= N_FX) are skipped.
        -- Each effect exists once: an id repeated in CHAIN steps that effect twice per sample.
        process(CLOCK_50)
            variable fx : integer range 0 to 15;
        begin
            if rising_edge(CLOCK_50) then
                fx := to_integer(unsigned(chain_sh(3 downto 0)));
                fx_ce <= (others => '0');
                cab_ce <= '0';
                in_ready_d <= in_ready;
                case ch_state is
                    when CH_IDLE =>
                        if in_ready_d = '1' then     -- sample_gated was updated by in_ready
                            chain_x  <= sample_gated;
                            chain_sh <= chain;
                            slot     <= 0;
                            wait_cnt <= 0;
                            ch_state <= CH_WAIT;
                        end if;
                    when CH_WAIT =>
                        if slot = 8 then
                            if cfg(1) = '1' then
                                cab_ce <= '1';       -- sample_out comes from the cab ~515 cycles later
                            else
                                sample_out <= chain_x;
                            end if;
                            ch_state   <= CH_IDLE;
                        elsif fx >= N_FX then        -- empty slot
                            chain_sh <= x"F" & chain_sh(31 downto 4);
                            slot     <= slot + 1;
                        elsif wait_cnt = SLOT_WAIT then
                            fx_ce(fx) <= '1';
                            wait_cnt <= 0;
                            ch_state <= CH_FIRE;
                        else
                            wait_cnt <= wait_cnt + 1;
                        end if;
                    when CH_FIRE =>                  -- ce is high now; the effect registers update at the end of this cycle
                        ch_state <= CH_LATCH;
                    when CH_LATCH =>
                        chain_x  <= fx_out(fx);
                        chain_sh <= x"F" & chain_sh(31 downto 4);
                        slot     <= slot + 1;
                        ch_state <= CH_WAIT;
                end case;
                if cab_done = '1' and cfg(1) = '1' then
                    sample_out <= cab_y;
                end if;
            end if;
        end process;

        inst_cab : entity work.cab
        port map (clk => CLOCK_50, ce => cab_ce, sample_in => chain_x, sample_out => cab_y, done => cab_done);

        -- tuner capture: the input before the noise gate (quiet notes still count)
        cap_sample <= sample_in;
        cap_valid  <= in_ready;

        inst_booster : booster
        port map (	
                sample_in => chain_x,
                multiplier => multiplier, -- knob A coarse, knob B fine
                sample_out => fx_out(FX_BOOST) 	
        );

        inst_distortion : entity work.drive
        generic map (OVERDRIVE => false)
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_DIST),
                sample_in  => chain_x,
                drive_k    => p(FX_DIST)(9 downto 5),
                level_k    => p(FX_DIST)(4 downto 0),
                sample_out => fx_out(FX_DIST)
        );

        inst_overdrive : entity work.drive
        generic map (OVERDRIVE => true)
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_OD),
                sample_in  => chain_x,
                drive_k    => p(FX_OD)(9 downto 5),
                level_k    => p(FX_OD)(4 downto 0),
                sample_out => fx_out(FX_OD)
        );

        inst_tremolo : entity work.tremolo
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_TREM),
                sample_in  => chain_x,
                rate       => p(FX_TREM)(9 downto 5),
                depth      => p(FX_TREM)(4 downto 0),
                sample_out => fx_out(FX_TREM)
        );

        inst_delay : delay
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_DLY),
                sample_in  => chain_x,
                delay_time => p(FX_DLY)(9 downto 5),  -- Delay time
                feedback   => p(FX_DLY)(4 downto 0),  -- Feedback amount
                sample_out => fx_out(FX_DLY)
        );

        inst_wah : wah
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_WAH),
                sample_in  => chain_x,
                sensitivity => p(FX_WAH)(9 downto 5),
                resonance  => p(FX_WAH)(4 downto 0),
                sample_out => fx_out(FX_WAH)
        );

        inst_phaser : phaser
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_PHS),
                sample_in  => chain_x,
                rate       => p(FX_PHS)(9 downto 5),  -- LFO rate
                depth      => p(FX_PHS)(4 downto 0),  -- Depth
                sample_out => fx_out(FX_PHS)
        );

        inst_reverb : reverb
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_REV),
                sample_in  => chain_x,
                room_size  => p(FX_REV)(9 downto 5),  -- Room size
                damping    => p(FX_REV)(4 downto 0),  -- Damping
                sample_out => fx_out(FX_REV)
        );

        inst_compressor : entity work.compressor
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_COMP),
                sample_in  => chain_x,
                sustain    => p(FX_COMP)(9 downto 5),
                level_k    => p(FX_COMP)(4 downto 0),
                sample_out => fx_out(FX_COMP)
        );

        inst_chorus : entity work.moddelay
        generic map (FLANGER => false)
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_CHO),
                sample_in  => chain_x,
                rate       => p(FX_CHO)(9 downto 5),
                depth      => p(FX_CHO)(4 downto 0),
                sample_out => fx_out(FX_CHO)
        );

        inst_flanger : entity work.moddelay
        generic map (FLANGER => true)
        port map (
                clk        => CLOCK_50,
                ce         => fx_ce(FX_FLA),
                sample_in  => chain_x,
                rate       => p(FX_FLA)(9 downto 5),
                depth      => p(FX_FLA)(4 downto 0),
                sample_out => fx_out(FX_FLA)
        );




END a;