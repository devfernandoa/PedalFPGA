------------------------------------------------------------------------------------------------
--  distortion.vhd
------------------------------------------------------------------------------------------------
-- Efecto de overdrive.
-- Dado un valor parametrizado se recorta la senal para que no supere ese umbral.
-- El recorte se hace en la parte positiva y negativa de la senal.
------------------------------------------------------------------------------------------------
-- Jose Angel Gumiel
--  28/03/2016
------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity overdrive is
	port(
		--Datos:
		sample_in  : in std_logic_vector(15 downto 0);
		sample_out : out std_logic_vector(15 downto 0);
		--Parametros:
		gain : in std_logic_vector(15 downto 0);
		dist_pos : in std_logic_vector(15 downto 0)
	);
end entity overdrive;

architecture a of overdrive is

	component booster
		port (
			sample_in : in	std_logic_vector(15 downto 0);
			multiplier : in	std_logic_vector(15 downto 0);
			sample_out : out std_logic_vector(15 downto 0)
		);
	end component;

	signal dist_neg	: std_logic_vector(15 downto 0);
	signal signal_dist: std_logic_vector(15 downto 0);
begin
	dist_neg<= std_logic_vector(-signed(dist_pos)); --OJO CON ESTO!
	boost: process(dist_pos, dist_neg, sample_in)
	begin
		if (sample_in(15) = '1') then --resultado negativo
			if (signed(sample_in(15 downto 0))<signed(dist_neg(15 downto 0))) then
                -- Soft clipping: Threshold + (Input - Threshold) / 4 (continuous at the threshold)
				signal_dist <= std_logic_vector(signed(dist_neg) + (signed(sample_in) - signed(dist_neg)) / 4);
			else
				signal_dist <= sample_in;
			end if;
		else --resultado positivo
			if (signed(sample_in(15 downto 0))>signed(dist_pos(15 downto 0))) then
                -- Soft clipping: Threshold + (Input - Threshold) / 4
				signal_dist <= std_logic_vector(signed(dist_pos) + (signed(sample_in) - signed(dist_pos)) / 4);
			else
				signal_dist <= sample_in;
			end if;
		end if;
	end process;
	
	--La distorsion recorta la amplitud de onda, quiero amplificarla.
	s1 : booster
		port map (	sample_in => signal_dist,
				multiplier => gain,
				sample_out => sample_out 	
		);
end architecture a;
