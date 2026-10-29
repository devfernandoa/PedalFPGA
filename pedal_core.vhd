library ieee;
use ieee.std_logic_1164.all;
USE ieee.NUMERIC_STD.all;
-- use ieee.std_logic_signed.all;

-- Audio path: codec -> DC blocker -> noise gate -> effects -> codec.
-- Effect selection and knobs come from pedal_regs (written by the HPS), see pedal_regs.vhd.
entity pedal_core is
 port(		CLOCK_50 	:  in  std_logic;
		--====CONTROL (pedal_regs)====--
		chain 		:  in  std_logic_vector(31 downto 0);
		params 		:  in  std_logic_vector(79 downto 0);
		--====AUDIO====--
		AUD_XCK 	:  out std_logic;
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

	component au_setup
	 generic	(
			SAMPLE_RATE	: integer range 1 to 3 );
	 port(	reset 	 : in std_logic;
		clk_50	 : in std_logic;
		mic_lin	 : in std_logic;
		i2c_sdat : inout std_logic;
		i2c_sclk : out std_logic;
		aud_xck	 : out std_logic	);
	end component;

	component au_in
	 port (
			clk, reset : in	std_logic;
			adclrc 	: in	std_logic;
			bclk 	: in	std_logic;
			adcdat 	: in	std_logic;
			sample 	: out	std_logic_vector(15 downto 0);
			ready 	: out	std_logic	);
	end component;

	component au_out
	 port (
			clk, reset : in	std_logic;
			daclrc	: in	std_logic;
			bclk 	: in	std_logic;
			sample 	: in	std_logic_vector(15 downto 0);
			dacdat 	: out	std_logic;
			ready	: out	std_logic	);
	end component;

	-- ADC Component Removed (DE10-Standard uses LTC2308, not AD7928)
	-- component AD7928_cyclic ...

	component booster
	 port (
			sample_in : in	std_logic_vector(15 downto 0);
			multiplier : in	std_logic_vector(15 downto 0);
			sample_out : out std_logic_vector(15 downto 0)
		);
	end component;

	component distortion
	 port (
			sample_in : in	std_logic_vector(15 downto 0);
			sample_out : out std_logic_vector(15 downto 0);
			gain : in	std_logic_vector(15 downto 0);
			dist_pos : in	std_logic_vector(15 downto 0)
		);
	end component;

	component tremolo
	 port (
			sample_in  : in	std_logic_vector(15 downto 0);
			sample_out : out std_logic_vector(15 downto 0);
			LD_Sample  : in std_logic;
			clk 	   : in std_logic;
			cl 	   : in std_logic;
			--Parametros:
			rate 	: in std_logic_vector(15 downto 0); --Velocidad del tremolo
			atack 	: in std_logic_vector(15 downto 0);--Define el corte Brusco o suave?
			wave 	: in std_logic_vector(1 downto 0)  --Forma de la onda. Seno, cuadrada, triangular?
		);
	end component;


	component overdrive
	 port (
			sample_in : in	std_logic_vector(15 downto 0);
			sample_out : out std_logic_vector(15 downto 0);
			gain : in	std_logic_vector(15 downto 0);
			dist_pos : in	std_logic_vector(15 downto 0)
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
			frequency   : in  std_logic_vector(4 downto 0);
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
	signal reset 	  : std_logic;
	signal in_ready   : std_logic;
	signal out_ready  : std_logic;
	signal sample_in  : std_logic_vector(15 downto 0);
    
    -- DC Blocker Signals
    signal sample_dc  : std_logic_vector(15 downto 0);
    signal prev_sample, prev_dc : signed(15 downto 0) := (others => '0');
    
    -- Noise Gate Signals
    signal sample_gated : std_logic_vector(15 downto 0);
    constant GATE_THRESH : integer := 10; -- Lowered threshold
    signal gate_timer : integer range 0 to 24000 := 0;

	type sample_array is array (0 to 7) of std_logic_vector(15 downto 0);
	signal fx_out     : sample_array;                    -- output of each effect, indexed by id
	signal sample_out : std_logic_vector(15 downto 0) := (others => '0');
	
    -- Control Signals
	signal multiplier : std_logic_vector(15 downto 0);
	signal pot_distor : std_logic_vector(15 downto 0);
    signal dist_gain  : std_logic_vector(15 downto 0);
	signal od_thresh  : std_logic_vector(15 downto 0);
    signal od_gain    : std_logic_vector(15 downto 0);
    
	--TREMOLO FX SIGNALS
	signal velocidad, ataque: std_logic_vector(15 downto 0);
	signal onda	  	: std_logic_vector(1 downto 0);
    
    -- Effect ids (same as pedal_regs.vhd); PARAM[e]: bits 9..5 = knob A, 4..0 = knob B
    constant FX_BOOST : integer := 0;
    constant FX_DIST  : integer := 1;
    constant FX_OD    : integer := 2;
    constant FX_TREM  : integer := 3;
    constant FX_DLY   : integer := 4;
    constant FX_WAH   : integer := 5;
    constant FX_PHS   : integer := 6;
    constant FX_REV   : integer := 7;
    type param_array is array (0 to 7) of std_logic_vector(9 downto 0);
    -- params_s only changes on in_ready, a few cycles before the chain starts (see PedalFPGA.sdc multicycle paths)
    signal params_s : std_logic_vector(79 downto 0) := (others => '0');
    signal p        : param_array;
    signal p_cur    : std_logic_vector(9 downto 0);

    -- First effect in the chain (shown on HEX5/4 + its knobs on HEX3-0/LEDR); >= 8 = empty
    signal current_effect : integer range 0 to 15 := 15;

    -- Effect chain (see the chain process)
    constant SLOT_WAIT : integer := 3;  -- chain_x is stable SLOT_WAIT+2 cycles before ce (sdc multicycle = 4)
    type chain_state_t is (CH_IDLE, CH_WAIT, CH_FIRE, CH_LATCH);
    signal ch_state   : chain_state_t := CH_IDLE;
    signal chain_x    : std_logic_vector(15 downto 0) := (others => '0');  -- sample travelling down the chain
    signal chain_sh   : std_logic_vector(31 downto 0) := (others => '1');  -- CHAIN snapshot, current slot in bits 3..0
    signal slot       : integer range 0 to 8 := 0;
    signal wait_cnt   : integer range 0 to SLOT_WAIT := 0;
    signal fx_ce      : std_logic_vector(7 downto 0) := (others => '0');
    signal in_ready_d : std_logic := '0';

    -- Distortion/overdrive make-up gain: the clip threshold is 3000 - 95*drive, so a fixed
    -- gain makes more drive = louder. MAKEUP(drive) = 256*CLIP_PEAK/threshold brings the
    -- clipped peak back to CLIP_PEAK (gain is x/256 in booster); knob B scales it by (B+1)/32.
    constant CLIP_PEAK : integer := 16000;  -- clipped peak at B=31; tune by ear
    type makeup_t is array (0 to 31) of integer;
    function makeup_init return makeup_t is
        variable t : makeup_t;
    begin
        for d in 0 to 31 loop
            t(d) := 256 * CLIP_PEAK / (3000 - 95 * d);
        end loop;
        return t;
    end function;
    constant MAKEUP : makeup_t := makeup_init;

    function clip_gain(knobs : std_logic_vector(9 downto 0)) return std_logic_vector is
        variable g : integer;
    begin
        g := MAKEUP(to_integer(unsigned(knobs(9 downto 5)))) * (to_integer(unsigned(knobs(4 downto 0))) + 1) / 32;
        if g > 32767 then  -- booster multiplier is signed
            g := 32767;
        end if;
        return std_logic_vector(to_unsigned(g, 16));
    end function;

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
	
	reset <= '0'; -- Disabled reset as requested
    
    -- DC Blocker Process
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            if reset = '1' then
                prev_sample <= (others => '0');
                prev_dc <= (others => '0');
                sample_dc <= (others => '0');
            elsif in_ready = '1' then
                -- y[n] = x[n] - x[n-1] + 0.996 * y[n-1]
                prev_dc <= signed(sample_in) - prev_sample + prev_dc - (prev_dc / 256);
                prev_sample <= signed(sample_in);
                sample_dc <= std_logic_vector(prev_dc);
            end if;
        end if;
    end process;

    -- Noise Gate Process with Hold (Hysteresis)
    -- Prevents chopping zero-crossings (distortion) and adds sustain
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            if in_ready = '1' then
                if abs(signed(sample_dc)) > to_signed(GATE_THRESH, 16) then
                    gate_timer <= 24000; -- Reset timer (~0.5s hold)
                    sample_gated <= sample_dc;
                else
                    if gate_timer > 0 then
                        gate_timer <= gate_timer - 1;
                        sample_gated <= sample_dc;
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

    gen_p: for e in 0 to 7 generate
        p(e) <= params_s(10*e+9 downto 10*e);
    end generate;

    current_effect <= to_integer(unsigned(chain(3 downto 0)));
    p_cur <= p(current_effect mod 8) when current_effect < 8 else (others => '0');

    -- Parameter Calculation Process
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            -- 1. BOOSTER GAIN: A (coarse) and B (fine) form one 10-bit number = gain*256,
            -- so 0..4x; A=8 B=0 is 1x, the mid setting (A=16 B=16) is about 2x.
            multiplier <= "000000" & p(FX_BOOST);

            -- 2. DISTORTION/OVERDRIVE DRIVE (knob A/B)
            -- Threshold: High knob A = Low Threshold (More Dist).
            -- Range: 3000 down to ~55.
            pot_distor <= std_logic_vector(to_unsigned(3000, 16) - resize(unsigned(p(FX_DIST)(9 downto 5)) * to_unsigned(95, 11), 16));
            od_thresh  <= std_logic_vector(to_unsigned(3000, 16) - resize(unsigned(p(FX_OD)(9 downto 5)) * to_unsigned(95, 11), 16));

            -- 3. DISTORTION/OVERDRIVE LEVEL (knob B), independent of the drive (see MAKEUP)
            dist_gain <= clip_gain(p(FX_DIST));
            od_gain   <= clip_gain(p(FX_OD));

            -- 4. TREMOLO RATE (knob A/B)
            velocidad <= std_logic_vector(to_unsigned(2400, 16) + resize(unsigned(p(FX_TREM)(9 downto 5)) * to_unsigned(512, 11), 16));

            -- 5. TREMOLO DEPTH (knob A/B)
            ataque <= std_logic_vector(resize(unsigned(p(FX_TREM)(4 downto 0)) * to_unsigned(1024, 11), 16));
        end if;
    end process;
    
    onda <= "10"; -- Triangular Wave
	
	inst1: au_setup
		generic map	(SAMPLE_RATE => 3)
		port map(	reset => reset,
				clk_50 => CLOCK_50,
				mic_lin	=> '0',
				i2c_sdat => FPGA_I2C_SDAT,
				i2c_sclk => FPGA_I2C_SCLK,
				aud_xck => AUD_XCK	);
	
	inst2: au_in
		port map(	reset => reset,
				clk => CLOCK_50,
				adclrc	=> AUD_ADCLRCK,
				bclk => AUD_BCLK,
				adcdat => AUD_ADCDAT,
				sample => sample_in,
				ready => in_ready	);
	
	inst3: au_out
		port map(	reset => reset,
				clk => CLOCK_50,
				daclrc	=> AUD_DACLRCK,
				bclk => AUD_BCLK,
				sample => sample_out,
				dacdat => AUD_DACDAT,
				ready => out_ready	);


	-- ADC Instantiation Removed (Incompatible with DE10-Standard)
	-- inst4 : AD7928_cyclic ...



-------------Varlores potenciometros-------------
-- Removed old concurrent assignments
-------------DISTOR-------------
		LEDR <= p_cur;
		
        -- Effect Display (Active Low: 0=ON, 1=OFF)
        -- Bank A: bO=Booster, d1=Distortion, Od=Overdrive, tr=Tremolo
        -- Bank B: dL=Delay, UA=Wah, PH=Phaser, rE=Reverb
        HEX5 <= "1100000" when current_effect = 0 else -- b (Booster)
                "1000010" when current_effect = 1 else -- d (Distortion)
                "0000001" when current_effect = 2 else -- O (Overdrive)
                "1110000" when current_effect = 3 else -- t (Tremolo)
                "1000010" when current_effect = 4 else -- d (Delay)
                "1000001" when current_effect = 5 else -- U (Wah)
                "0001100" when current_effect = 6 else -- P (Phaser)
                "1111010" when current_effect = 7 else -- r (Reverb)
                "1111110";                             -- - (bypass)

        HEX4 <= "0000001" when current_effect = 0 else -- O (bO)
                "1001111" when current_effect = 1 else -- 1 (d1)
                "1000010" when current_effect = 2 else -- d (Od)
                "1111010" when current_effect = 3 else -- r (tr)
                "1110001" when current_effect = 4 else -- L (dL)
                "0001000" when current_effect = 5 else -- A (UA)
                "0001001" when current_effect = 6 else -- H (PH)
                "0110000" when current_effect = 7 else -- E (rE)
                "1111110";                             -- - (bypass)

		HEX3<=seg7("000" & p_cur(9));
		HEX2<=seg7(p_cur(8 downto 5));
		HEX1<=seg7("000" & p_cur(4));
		HEX0<=seg7(p_cur(3 downto 0));
        
        -- Effect chain: once per sample, run chain_x through CHAIN slots 0..7 in order.
        -- Per slot: hold chain_x for SLOT_WAIT+1 cycles, pulse that effect's ce for one cycle,
        -- then latch the effect's output (registered, or combinational for booster/distortion/
        -- overdrive/tremolo) back into chain_x. Empty slots (id >= 8) are skipped.
        -- Each effect exists once: an id repeated in CHAIN steps that effect twice per sample.
        process(CLOCK_50)
            variable fx : integer range 0 to 15;
        begin
            if rising_edge(CLOCK_50) then
                fx := to_integer(unsigned(chain_sh(3 downto 0)));
                fx_ce <= (others => '0');
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
                            sample_out <= chain_x;
                            ch_state   <= CH_IDLE;
                        elsif fx >= 8 then           -- empty slot
                            chain_sh <= x"F" & chain_sh(31 downto 4);
                            slot     <= slot + 1;
                        elsif wait_cnt = SLOT_WAIT then
                            fx_ce(fx mod 8) <= '1';
                            wait_cnt <= 0;
                            ch_state <= CH_FIRE;
                        else
                            wait_cnt <= wait_cnt + 1;
                        end if;
                    when CH_FIRE =>                  -- ce is high now; the effect registers update at the end of this cycle
                        ch_state <= CH_LATCH;
                    when CH_LATCH =>
                        chain_x  <= fx_out(fx mod 8);
                        chain_sh <= x"F" & chain_sh(31 downto 4);
                        slot     <= slot + 1;
                        ch_state <= CH_WAIT;
                end case;
            end if;
        end process;

        inst_booster : booster
        port map (	
                sample_in => chain_x,
                multiplier => multiplier, -- knob A coarse, knob B fine
                sample_out => fx_out(FX_BOOST) 	
        );

        inst_distortion : distortion
        port map (	
                sample_in => chain_x,
                gain => dist_gain,
                dist_pos => pot_distor,
                sample_out => fx_out(FX_DIST) 	
        );

        inst_overdrive : overdrive
        port map (	
                sample_in => chain_x,
                gain => od_gain,
                dist_pos => od_thresh,
                sample_out => fx_out(FX_OD) 	
        );

        inst_tremolo : tremolo
        port map (
                sample_in  => chain_x,
                sample_out => fx_out(FX_TREM),
                LD_Sample  => in_ready,
                clk 	   => CLOCK_50,
                cl 	   => reset,
                rate 	   => velocidad, -- Rate: knob A
                atack 	   => ataque,    -- Depth: knob B
                wave 	   => onda       -- Triangle
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
                frequency  => p(FX_WAH)(9 downto 5),  -- Center frequency
                resonance  => p(FX_WAH)(4 downto 0),  -- Resonance (Q)
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




END a;