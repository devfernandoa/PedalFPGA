-- Cabinet simulator: 512-tap FIR (10.7 ms impulse response), one tap per clock cycle, so a sample
-- takes ~515 cycles after ce (done pulses when sample_out is new). The impulse response is an
-- original voicing designed in sim/fx_model.py (cab_ir, cab_coefs: Q15, regenerate with --vhdl).
-- Same integer math as cab() in sim/fx_model.py: 48-bit accumulator, >> 15, saturate.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sat_pkg.all;

entity cab is
    port (
        clk        : in  std_logic;
        ce         : in  std_logic;                     -- 1 pulse per sample
        sample_in  : in  std_logic_vector(15 downto 0);
        sample_out : out std_logic_vector(15 downto 0);
        done       : out std_logic                      -- 1-cycle pulse: sample_out updated
    );
end entity cab;

architecture rtl of cab is
    constant TAPS : integer := 512;
    type coef_t is array (0 to TAPS - 1) of integer range -32768 to 32767;
    constant COEF : coef_t := (
           21,   188,   795,  2119,  4036,  5905,  6939,  6697,  5276,  3162,   942,  -921, -2190, -2832, -2951, -2707,
        -2255, -1721, -1191,  -715,  -322,   -19,   194,   324,   382,   381,   336,   263,   176,    86,     3,   -66,
         -117,  -150,  -164,  -163,  -150,  -130,  -105,   -81,   -59,   -41,   -29,   -23,   -22,   -27,   -37,   -49,
          -64,   -79,   -94,  -109,  -123,  -135,  -146,  -156,  -164,  -171,  -178,  -184,  -190,  -196,  -202,  -208,
         -214,  -220,  -226,  -233,  -239,  -245,  -251,  -256,  -261,  -266,  -270,  -274,  -278,  -281,  -284,  -287,
         -289,  -291,  -293,  -295,  -296,  -297,  -298,  -299,  -300,  -300,  -301,  -301,  -301,  -301,  -300,  -300,
         -299,  -298,  -297,  -296,  -295,  -294,  -293,  -291,  -290,  -288,  -286,  -284,  -283,  -281,  -279,  -277,
         -275,  -273,  -270,  -268,  -266,  -264,  -261,  -259,  -257,  -254,  -252,  -250,  -247,  -245,  -242,  -240,
         -237,  -235,  -232,  -230,  -227,  -225,  -222,  -220,  -217,  -215,  -212,  -210,  -207,  -205,  -202,  -200,
         -197,  -194,  -192,  -189,  -187,  -184,  -182,  -179,  -177,  -174,  -172,  -169,  -167,  -164,  -162,  -159,
         -156,  -154,  -151,  -149,  -146,  -144,  -141,  -139,  -136,  -134,  -131,  -129,  -126,  -124,  -121,  -119,
         -116,  -114,  -111,  -109,  -106,  -104,  -102,   -99,   -97,   -94,   -92,   -89,   -87,   -84,   -82,   -80,
          -77,   -75,   -73,   -70,   -68,   -65,   -63,   -61,   -58,   -56,   -54,   -51,   -49,   -47,   -45,   -42,
          -40,   -38,   -36,   -34,   -31,   -29,   -27,   -25,   -23,   -21,   -19,   -16,   -14,   -12,   -10,    -8,
           -6,    -4,    -2,     0,     2,     4,     6,     7,     9,    11,    13,    15,    17,    18,    20,    22,
           24,    25,    27,    29,    30,    32,    34,    35,    37,    38,    40,    41,    43,    44,    46,    47,
           49,    50,    51,    53,    54,    55,    57,    58,    59,    60,    62,    63,    64,    65,    66,    67,
           68,    69,    71,    72,    73,    73,    74,    75,    76,    77,    78,    79,    80,    80,    81,    82,
           83,    83,    84,    85,    86,    86,    87,    87,    88,    89,    89,    90,    90,    91,    91,    91,
           92,    92,    93,    93,    93,    94,    94,    94,    95,    95,    95,    95,    95,    96,    96,    96,
           96,    96,    96,    96,    96,    96,    96,    96,    96,    96,    96,    96,    96,    96,    96,    96,
           96,    95,    95,    95,    95,    95,    94,    94,    94,    94,    93,    93,    93,    92,    92,    92,
           91,    91,    91,    90,    90,    89,    89,    89,    88,    88,    87,    87,    86,    86,    85,    85,
           84,    84,    83,    82,    82,    81,    81,    80,    80,    79,    78,    78,    77,    76,    76,    75,
           74,    74,    73,    72,    72,    71,    70,    70,    69,    68,    67,    67,    66,    65,    65,    64,
           63,    62,    62,    61,    60,    59,    58,    58,    57,    56,    55,    55,    54,    53,    52,    52,
           51,    50,    49,    48,    48,    47,    46,    45,    44,    44,    43,    42,    41,    41,    40,    39,
           38,    37,    37,    36,    35,    34,    34,    33,    32,    31,    30,    30,    29,    28,    27,    27,
           26,    25,    24,    24,    23,    22,    21,    20,    19,    18,    18,    17,    16,    15,    14,    13,
           12,    12,    11,    10,     9,     8,     8,     7,     6,     6,     5,     4,     4,     3,     3,     3,
            2,     2,     1,     1,     1,     0,     0,     0,     0,     0,     0,     0,    -1,    -1,    -1,    -1,
           -1,    -1,    -1,    -1,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0,     0);

    type ram_t is array (0 to TAPS - 1) of signed(15 downto 0);
    signal dl : ram_t := (others => (others => '0'));   -- delay line, newest at base
    signal wp, base, addr : unsigned(8 downto 0) := (others => '0');
    signal k, kk : integer range 0 to TAPS - 1 := 0;
    signal running : std_logic := '0';
    -- pipeline: 0 address, 1 RAM/ROM read, 2 multiply, 3 accumulate
    signal v0, v1, v2, last0, last1, last2 : std_logic := '0';
    signal d_r, c_r : signed(15 downto 0) := (others => '0');
    signal prod : signed(31 downto 0) := (others => '0');
    signal acc : signed(47 downto 0) := (others => '0');
begin
    process (clk)
        variable acc_n : signed(47 downto 0);
    begin
        if rising_edge(clk) then
            done <= '0';
            v0 <= '0';
            last0 <= '0';
            if ce = '1' then
                dl(to_integer(wp)) <= signed(sample_in);
                base <= wp;
                wp <= wp + 1;
                k <= 0;
                running <= '1';
                acc <= (others => '0');
            elsif running = '1' then
                addr <= base - to_unsigned(k, 9);           -- x[n - k]
                kk <= k;
                v0 <= '1';
                if k = TAPS - 1 then
                    running <= '0';
                    last0 <= '1';
                else
                    k <= k + 1;
                end if;
            end if;

            d_r <= dl(to_integer(addr));
            c_r <= to_signed(COEF(kk), 16);
            v1 <= v0;
            last1 <= last0;

            prod <= d_r * c_r;
            v2 <= v1;
            last2 <= last1;

            if v2 = '1' then
                acc_n := acc + prod;
                acc <= acc_n;
                if last2 = '1' then
                    sample_out <= std_logic_vector(sat16(shift_right(acc_n, 15)));
                    done <= '1';
                end if;
            end if;
        end if;
    end process;
end architecture rtl;
