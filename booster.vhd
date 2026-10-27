------------------------------------------------------------------------------------------------
--  booster.vhd
------------------------------------------------------------------------------------------------
-- Etapa de amplificacion limpia.
-- Dado un valor parametrizado multiplica la senal de entrada y retorna dicha senal amplificada.
-- Ganancia = multiplier/256; el resultado satura en +-32767 en vez de desbordar.
------------------------------------------------------------------------------------------------
-- Jose Angel Gumiel
--  25/11/2016
------------------------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_signed.all;

entity booster is
	port(
		--Datos:
		sample_in  : in std_logic_vector(15 downto 0);
		sample_out : out std_logic_vector(15 downto 0);
		--Parametros:
		multiplier : in std_logic_vector(15 downto 0)
	);
end entity booster;

architecture a of booster is
	signal signal_unnormalized: std_logic_vector(31 downto 0);
	begin
		
		signal_unnormalized<=signed(sample_in)*signed(multiplier);
		boost: process(signal_unnormalized)
		begin
			-- Resultado = producto / 256. Si no cabe en 16 bits (bits 31..23 distintos), satura.
			if signal_unnormalized(31 downto 23) = "000000000" or signal_unnormalized(31 downto 23) = "111111111" then
				sample_out <= signal_unnormalized(23 downto 8);
			elsif (signal_unnormalized(31) = '1') then --resultado negativo
				sample_out <= x"8000";
			else --resultado positivo
				sample_out <= x"7FFF";
			end if;
	end process;
	
end architecture a;