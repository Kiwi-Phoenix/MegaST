----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- flux_capture: records the raw flux of the MEGA65's internal floppy drive for debugging
-- (read out through JTAG, see tools/probe4.tcl FLUX=arm / FLUX=dump and tools/flux2scp.py)
--
-- After arm_i, every flux transition (flux_i, one cycle per transition) writes one byte: the cycles since
-- the previous transition divided by 2 (62.3 ns units at 32 MHz), saturated at 255 (15.9 us), at least 1.
-- Each rising edge of index_i writes a 00 marker. Recording stops when the buffer is full. The capture
-- only listens: whoever drives the drive (the core or the JTAG probe) chooses track, side and motor.
--
-- The buffer is a simple dual port RAM: written on clk_i, read on rd_clk_i (the JTAG TCK); read it
-- only after done_o.
--
-- This machine is based on AtariST_MiSTer
-- Powered by MiSTer2MEGA65
-- MEGA65 port done by Chris Freeman in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity flux_capture is
generic (
   G_ADDR_BITS : natural := 17                     -- buffer size 2 ** G_ADDR_BITS bytes
);
port (
   clk_i     : in  std_logic;
   rst_i     : in  std_logic;
   arm_i     : in  std_logic;                      -- start a new capture (one cycle)
   flux_i    : in  std_logic;
   index_i   : in  std_logic;
   count_o   : out std_logic_vector(G_ADDR_BITS downto 0);   -- bytes written
   busy_o    : out std_logic;
   done_o    : out std_logic;

   rd_clk_i  : in  std_logic;
   rd_addr_i : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
   rd_data_o : out std_logic_vector(7 downto 0)    -- one rd_clk_i cycle after rd_addr_i
);
end entity flux_capture;

architecture synthesis of flux_capture is

   type ram_t is array (0 to 2 ** G_ADDR_BITS - 1) of std_logic_vector(7 downto 0);
   signal ram       : ram_t;
   attribute ram_style : string;
   attribute ram_style of ram : signal is "block";

   signal count     : unsigned(G_ADDR_BITS downto 0) := (others => '0');
   signal busy      : std_logic := '0';
   signal done      : std_logic := '0';
   signal cycles    : unsigned(8 downto 0) := (others => '0');
   signal idx_old   : std_logic := '0';
   signal we        : std_logic;
   signal wdata     : std_logic_vector(7 downto 0);

begin

   -- a flux transition wins over an index edge in the same cycle (practically never happens)
   we    <= busy and (flux_i or (index_i and not idx_old));
   wdata <= x"01" when flux_i = '1' and cycles < 2 else
            std_logic_vector(cycles(8 downto 1)) when flux_i = '1' else
            x"00";

   p_capture : process (clk_i)
   begin
      if rising_edge(clk_i) then
         idx_old <= index_i;
         if cycles /= 511 then
            cycles <= cycles + 1;
         end if;
         if flux_i = '1' then
            cycles <= to_unsigned(1, cycles'length);   -- this cycle already belongs to the next interval
         end if;

         if we = '1' then
            ram(to_integer(count(G_ADDR_BITS - 1 downto 0))) <= wdata;
            count <= count + 1;
            if count = 2 ** G_ADDR_BITS - 1 then
               busy <= '0';
               done <= '1';
            end if;
         end if;

         if arm_i = '1' then
            count <= (others => '0');
            busy  <= '1';
            done  <= '0';
         end if;
         if rst_i = '1' then
            busy <= '0';
         end if;
      end if;
   end process p_capture;

   p_read : process (rd_clk_i)
   begin
      if rising_edge(rd_clk_i) then
         rd_data_o <= ram(to_integer(unsigned(rd_addr_i)));
      end if;
   end process p_read;

   count_o <= std_logic_vector(count);
   busy_o  <= busy;
   done_o  <= done;

end architecture synthesis;
