----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- floppy_probe: bring-up probe for the MEGA65's internal floppy drive (phase 0 of doc/real-floppy.md)
--
-- Drives m65_floppy_port from a command word (written through JTAG, see tools/probe4.tcl) and
-- measures what the drive sends back. No floppy controller is involved.
--
-- Command (cmd_i, taken when cmd_valid_i pulses and bits 15..8 are 0xA5):
--    0: motor   1: select A   2: side 1   3: direction in   4: clear the counters
--    5: density pin low       6: select B
--   23..16: number of step pulses to send now (6 ms apart)
--
-- Snapshot (snap_o, LSB first):
--    7..0    levels: 0 index, 1 track0, 2 write protect, 3 disk changed, 4 rdata, 5 motor on,
--            6 step busy, 7 0
--   15..8    command bits 7..0
--   31..16   index pulses
--   55..32   cycles between the last two index pulses (6.4 M = 300 rpm at 32 MHz)
--   79..56   flux transitions in the last revolution
--  175..80   histogram of the flux intervals in the last revolution, 6 x 16 bits:
--            < 1.5 us, 1.5 - 3.5 us, 3.5 - 5 us (4 us), 5 - 7 us (6 us), 7 - 9 us (8 us), >= 9 us
--  191..176  step pulses sent
--  199..192  edges of disk changed
--  207..200  edges of write protect
--  223..208  free running counter (bits 31..16 of a cycle counter)
--
-- This machine is based on AtariST_MiSTer
-- Powered by MiSTer2MEGA65
-- MEGA65 port done by Chris Freeman in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity floppy_probe is
generic (
   G_CLK_HZ      : natural := 32_083_333;
   G_STEP_MS     : natural := 6
);
port (
   clk_i         : in  std_logic;
   rst_i         : in  std_logic;
   cmd_i         : in  std_logic_vector(23 downto 0);
   cmd_valid_i   : in  std_logic;
   snap_o        : out std_logic_vector(223 downto 0);

   -- to/from m65_floppy_port
   sel_a_o       : out std_logic;
   sel_b_o       : out std_logic;
   motor_o       : out std_logic;
   side_o        : out std_logic;
   dir_in_o      : out std_logic;
   step_o        : out std_logic;
   density_o     : out std_logic;
   flux_i        : in  std_logic;
   rdata_i       : in  std_logic;
   index_i       : in  std_logic;
   track0_i      : in  std_logic;
   wprot_i       : in  std_logic;
   dskchg_i      : in  std_logic;
   step_busy_i   : in  std_logic;
   motor_on_i    : in  std_logic
);
end entity floppy_probe;

architecture synthesis of floppy_probe is

   constant C_CYC_US   : natural := G_CLK_HZ / 1_000_000;
   constant C_STEP_GAP : natural := (G_CLK_HZ / 1000) * G_STEP_MS;
   -- bin edges in cycles: 1.5, 3.5, 5, 7, 9 us
   constant C_E1       : natural := (G_CLK_HZ * 3) / 2_000_000;
   constant C_E2       : natural := (G_CLK_HZ * 7) / 2_000_000;
   constant C_E3       : natural := C_CYC_US * 5;
   constant C_E4       : natural := C_CYC_US * 7;
   constant C_E5       : natural := C_CYC_US * 9;

   type bins_t is array (0 to 5) of unsigned(15 downto 0);

   signal ctrl         : std_logic_vector(7 downto 0) := (others => '0');
   signal steps_left   : unsigned(7 downto 0) := (others => '0');
   signal step_gap     : natural range 0 to C_STEP_GAP := 0;
   signal step_req     : std_logic := '0';

   signal idx_old      : std_logic := '0';
   signal chg_old      : std_logic := '0';
   signal wp_old       : std_logic := '0';
   signal idx_cnt      : unsigned(15 downto 0) := (others => '0');
   signal per_run      : unsigned(23 downto 0) := (others => '0');
   signal per_last     : unsigned(23 downto 0) := (others => '0');
   signal flux_run     : unsigned(23 downto 0) := (others => '0');
   signal flux_last    : unsigned(23 downto 0) := (others => '0');
   signal ival         : unsigned(9 downto 0)  := (others => '1');
   signal bins_run     : bins_t := (others => (others => '0'));
   signal bins_last    : bins_t := (others => (others => '0'));
   signal step_total   : unsigned(15 downto 0) := (others => '0');
   signal chg_edges    : unsigned(7 downto 0)  := (others => '0');
   signal wp_edges     : unsigned(7 downto 0)  := (others => '0');
   signal free         : unsigned(31 downto 0) := (others => '0');

begin

   p_cmd : process (clk_i)
   begin
      if rising_edge(clk_i) then
         step_req <= '0';
         if cmd_valid_i = '1' and cmd_i(15 downto 8) = x"A5" then
            ctrl       <= cmd_i(7 downto 0);
            steps_left <= unsigned(cmd_i(23 downto 16));
            step_gap   <= 0;
         elsif step_gap /= 0 then
            step_gap <= step_gap - 1;
         elsif steps_left /= 0 then
            step_req   <= '1';
            steps_left <= steps_left - 1;
            step_gap   <= C_STEP_GAP;
         end if;
         if rst_i = '1' then
            ctrl       <= (others => '0');
            steps_left <= (others => '0');
         end if;
      end if;
   end process p_cmd;

   motor_o   <= ctrl(0);
   sel_a_o   <= ctrl(1);
   side_o    <= ctrl(2);
   dir_in_o  <= ctrl(3);
   density_o <= not ctrl(5);
   sel_b_o   <= ctrl(6);
   step_o    <= step_req;

   p_measure : process (clk_i)
      variable b : natural range 0 to 5;
   begin
      if rising_edge(clk_i) then
         idx_old <= index_i;
         chg_old <= dskchg_i;
         wp_old  <= wprot_i;
         free    <= free + 1;

         if per_run /= x"FFFFFF" then
            per_run <= per_run + 1;
         end if;
         if ival /= "1111111111" then
            ival <= ival + 1;
         end if;

         if flux_i = '1' then
            if    ival < C_E1 then b := 0;
            elsif ival < C_E2 then b := 1;
            elsif ival < C_E3 then b := 2;
            elsif ival < C_E4 then b := 3;
            elsif ival < C_E5 then b := 4;
            else                   b := 5;
            end if;
            if bins_run(b) /= x"FFFF" then
               bins_run(b) <= bins_run(b) + 1;
            end if;
            flux_run <= flux_run + 1;
            ival     <= (others => '0');
         end if;

         -- a new revolution starts at the leading edge of the index pulse
         if index_i = '1' and idx_old = '0' then
            idx_cnt   <= idx_cnt + 1;
            per_last  <= per_run;
            per_run   <= (others => '0');
            flux_last <= flux_run;
            flux_run  <= (others => '0');
            bins_last <= bins_run;
            bins_run  <= (others => (others => '0'));
         end if;

         if step_req = '1' then
            step_total <= step_total + 1;
         end if;
         if dskchg_i /= chg_old then
            chg_edges <= chg_edges + 1;
         end if;
         if wprot_i /= wp_old then
            wp_edges <= wp_edges + 1;
         end if;

         if (cmd_valid_i = '1' and cmd_i(15 downto 8) = x"A5" and cmd_i(4) = '1') or rst_i = '1' then
            idx_cnt    <= (others => '0');
            step_total <= (others => '0');
            chg_edges  <= (others => '0');
            wp_edges   <= (others => '0');
         end if;
      end if;
   end process p_measure;

   snap_o <= std_logic_vector(free(31 downto 16)) &
             std_logic_vector(wp_edges) & std_logic_vector(chg_edges) & std_logic_vector(step_total) &
             std_logic_vector(bins_last(5)) & std_logic_vector(bins_last(4)) & std_logic_vector(bins_last(3)) &
             std_logic_vector(bins_last(2)) & std_logic_vector(bins_last(1)) & std_logic_vector(bins_last(0)) &
             std_logic_vector(flux_last) & std_logic_vector(per_last) & std_logic_vector(idx_cnt) &
             ctrl &
             '0' & step_busy_i & motor_on_i & rdata_i & dskchg_i & wprot_i & track0_i & index_i;

end architecture synthesis;
