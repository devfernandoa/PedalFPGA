library ieee;
use ieee.std_logic_1164.all;
USE ieee.NUMERIC_STD.all;
-- use ieee.std_logic_signed.all;

entity testaudio_DE10SoC is 
 port(		CLOCK_50 	:  in  std_logic;
		KEY 		:  in  std_logic_vector(3 downto 0);
		--====AUDIO====--
		AUD_XCK 	:  out std_logic;
		AUD_BCLK 	:  in  std_logic;
		AUD_ADCLRCK 	:  in  std_logic;
		AUD_DACLRCK 	:  in  std_logic;
		AUD_ADCDAT 	:  in  std_logic;
		AUD_DACDAT 	:  out std_logic;
		FPGA_I2C_SCLK 	:  out std_logic;
		FPGA_I2C_SDAT 	:  inout  std_logic;
		--====ADC====--
		SW 		: in  std_logic_vector(9 downto 0); -- canal a visulizar en LEDR
		LEDR 		: out  std_logic_vector(9 downto 0);
		ADC_SCLK  	: out std_logic;
		ADC_CS_N  	: out std_logic;
		ADC_DOUT  	: in  std_logic;
		ADC_DIN	 	: out std_logic;
		--====HEXADECIMAL====--
		HEX0 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX1 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX2 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX3 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX4 : OUT STD_LOGIC_VECTOR(0 TO 6);
		HEX5 : OUT STD_LOGIC_VECTOR(0 TO 6)	);
end testaudio_DE10SoC;

architecture a of testaudio_DE10SoC is 

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

	signal sample_boost : std_logic_vector(15 downto 0);
	signal sample_od : std_logic_vector(15 downto 0);
	signal sample_dis : std_logic_vector(15 downto 0);
	signal sample_trm : std_logic_vector(15 downto 0);
	signal sample_out : std_logic_vector(15 downto 0);
	
    -- Control Signals
	signal multiplier : std_logic_vector(15 downto 0);
	signal pot_distor : std_logic_vector(15 downto 0);
    signal dist_gain  : std_logic_vector(15 downto 0);
    
	--TREMOLO FX SIGNALS
	signal velocidad, ataque: std_logic_vector(15 downto 0);
	signal onda	  	: std_logic_vector(1 downto 0);
    
    -- Effect State
    signal current_effect : integer range 0 to 3 := 0;

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

    -- Effect Switching Logic
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            if KEY(0) = '0' then current_effect <= 0; end if; -- Booster
            if KEY(1) = '0' then current_effect <= 1; end if; -- Distortion
            if KEY(2) = '0' then current_effect <= 2; end if; -- Overdrive
            if KEY(3) = '0' then current_effect <= 3; end if; -- Tremolo
        end if;
    end process;

    -- Parameter Calculation Process
    process(CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            -- 1. BOOSTER GAIN (SW 9-5 Coarse, SW 4-0 Fine)
            -- Base 256 (1x).
            -- SW 9-5: 0 to 31 * 900 = 27900.
            -- SW 4-0: 0 to 31 * 100 = 3100.
            -- Max Total: 256 + 27900 + 3100 = 31256 (Safe < 32767).
            multiplier <= std_logic_vector(to_unsigned(256, 16) 
                                         + resize(unsigned(SW(9 downto 5)) * to_unsigned(900, 11), 16)
                                         + resize(unsigned(SW(4 downto 0)) * to_unsigned(100, 11), 16));

            -- 2. DISTORTION/OVERDRIVE DRIVE (SW 9-5)
            -- Threshold: High SW = Low Threshold (More Dist).
            -- Range: 3000 down to ~55.
            pot_distor <= std_logic_vector(to_unsigned(3000, 16) - resize(unsigned(SW(9 downto 5)) * to_unsigned(95, 11), 16));

            -- 3. DISTORTION/OVERDRIVE LEVEL (SW 4-0)
            -- Gain: Base 256 (1x) + SW * 900. 
            -- Max: 256 + 31*900 = 28156 (Safe < 32767).
            -- Prevents sign flip in booster component.
            dist_gain <= std_logic_vector(to_unsigned(256, 16) + resize(unsigned(SW(4 downto 0)) * to_unsigned(900, 11), 16));

            -- 4. TREMOLO RATE (SW 9-5)
            velocidad <= std_logic_vector(to_unsigned(2400, 16) + resize(unsigned(SW(9 downto 5)) * to_unsigned(512, 11), 16));

            -- 5. TREMOLO DEPTH (SW 4-0)
            ataque <= std_logic_vector(resize(unsigned(SW(4 downto 0)) * to_unsigned(1024, 11), 16));
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
		LEDR <= SW;
		
        -- Effect Display (Active Low: 0=ON, 1=OFF)
        -- Mapping: a b c d e f g
        HEX5 <= "1100000" when current_effect = 0 else -- b (c,d,e,f,g)
                "1000010" when current_effect = 1 else -- d (b,c,d,e,g)
                "0000001" when current_effect = 2 else -- O (a,b,c,d,e,f)
                "1110000"; -- t (d,e,f,g)

        HEX4 <= "0000001" when current_effect = 0 else -- O (bO)
                "1001111" when current_effect = 1 else -- 1 (d1) (b,c)
                "1000010" when current_effect = 2 else -- d (Od)
                "1111010"; -- r (tr) (e,g)

		HEX3<=seg7("000" & SW(9));
		HEX2<=seg7(SW(8 downto 5));
		HEX1<=seg7("000" & SW(4));
		HEX0<=seg7(SW(3 downto 0));
        
        -- Multiplexer
        sample_out <= sample_boost when current_effect = 0 else
                      sample_dis   when current_effect = 1 else
                      sample_od    when current_effect = 2 else
                      sample_trm;

        inst_booster : booster
        port map (	
                sample_in => sample_gated,
                multiplier => multiplier, -- Uses SW 9-5 (1x to 16x)
                sample_out => sample_boost 	
        );

        inst_distortion : distortion
        port map (	
                sample_in => sample_gated,
                gain => dist_gain,
                dist_pos => pot_distor,
                sample_out => sample_dis 	
        );

        inst_overdrive : overdrive
        port map (	
                sample_in => sample_gated,
                gain => dist_gain,
                dist_pos => pot_distor,
                sample_out => sample_od 	
        );

        inst_tremolo : tremolo
        port map (
                sample_in  => sample_gated,
                sample_out => sample_trm,
                LD_Sample  => in_ready,
                clk 	   => CLOCK_50,
                cl 	   => reset,
                rate 	   => velocidad, -- Rate: SW 9-5
                atack 	   => ataque,    -- Depth: SW 4-0
                wave 	   => onda       -- Triangle
        );




END a;