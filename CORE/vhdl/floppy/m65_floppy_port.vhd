----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- m65_floppy_port: the MEGA65's internal 3.5" floppy drive (34-pin PC drive cable)
--
-- Owns the 15 drive pins. A core never drives the pins directly, it talks to this entity:
-- * inputs are synchronised; RDATA is glitch filtered and turned into a one-cycle flux_o
--   pulse per flux transition
-- * the step pulse is stretched to G_STEP_US, after G_DIR_SETUP_US of direction setup time
-- * write interlock: WGATE only goes low when G_WRITE_ENABLE is true and write_allow_i is set
--   and drive A or B is selected and the motor runs and the disk is not write protected.
--   With G_WRITE_ENABLE = false the write lines are constant, a core bug cannot damage a disk.
-- * motor watchdog: the motor is switched off when it ran G_WDOG_MS without a step, a select
--   change or a write; it stays off until motor_i goes low once (0 = no watchdog)
-- * rst_i switches everything off
--
-- All pins are active low; all core side signals are active high.
-- The core side outputs are in the clk_i domain.
--
-- This machine is based on AtariST_MiSTer
-- Powered by MiSTer2MEGA65
-- MEGA65 port done by Chris Freeman in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity m65_floppy_port is
generic (
   G_CLK_HZ       : natural := 32_083_333;
   G_WRITE_ENABLE : boolean := false;
   G_STEP_US      : natural := 4;
   G_DIR_SETUP_US : natural := 2;
   G_GLITCH       : natural := 2;           -- RDATA must be stable this many cycles
   G_WDOG_MS      : natural := 30_000
);
port (
   clk_i            : in  std_logic;
   rst_i            : in  std_logic;

   -- core side (active high)
   sel_a_i          : in  std_logic;        -- internal drive
   sel_b_i          : in  std_logic;        -- spare drive B connector
   motor_i          : in  std_logic;        -- motor of both drives (like the ST's WD1772 MO output)
   side_i           : in  std_logic;        -- '1' = side 1
   dir_in_i         : in  std_logic;        -- '1' = step in (towards higher tracks)
   step_i           : in  std_logic;        -- rising edge requests one step pulse
   wgate_i          : in  std_logic;
   wdata_i          : in  std_logic;        -- '1' = write a flux transition
   write_allow_i    : in  std_logic;        -- e.g. a menu item "allow writes"
   density_i        : in  std_logic;        -- level of the density pin ('1' = idle, as the MEGA65 core)

   flux_o           : out std_logic;        -- one cycle per flux transition (falling edge of RDATA)
   rdata_o          : out std_logic;        -- synchronised RDATA level (active high = low at the pin)
   index_o          : out std_logic;
   track0_o         : out std_logic;
   wprot_o          : out std_logic;
   dskchg_o         : out std_logic;
   step_busy_o      : out std_logic;        -- a step pulse (with direction setup) is in progress
   motor_on_o       : out std_logic;        -- motor really on (after the watchdog)
   wgate_on_o       : out std_logic;        -- WGATE really active (after the interlock)

   -- drive pins (active low)
   f_density_o      : out std_logic;
   f_motora_o       : out std_logic;
   f_motorb_o       : out std_logic;
   f_selecta_o      : out std_logic;
   f_selectb_o      : out std_logic;
   f_side1_o        : out std_logic;
   f_stepdir_o      : out std_logic;
   f_step_o         : out std_logic;
   f_wdata_o        : out std_logic;
   f_wgate_o        : out std_logic;
   f_diskchanged_i  : in  std_logic;
   f_index_i        : in  std_logic;
   f_rdata_i        : in  std_logic;
   f_track0_i       : in  std_logic;
   f_writeprotect_i : in  std_logic
);
end entity m65_floppy_port;

architecture synthesis of m65_floppy_port is

   constant C_CYC_US     : natural := G_CLK_HZ / 1_000_000;
   constant C_SETUP      : natural := G_DIR_SETUP_US * C_CYC_US;
   constant C_STEP       : natural := C_SETUP + G_STEP_US * C_CYC_US;
   constant C_WDOG       : natural := (G_CLK_HZ / 1000) * G_WDOG_MS;

   -- two flip-flop synchronisers: index 0 = diskchanged, 1 = index, 2 = rdata, 3 = track0, 4 = wprot
   signal sync1, sync2   : std_logic_vector(4 downto 0) := (others => '1');
   attribute ASYNC_REG   : string;
   attribute ASYNC_REG of sync1 : signal is "TRUE";
   attribute ASYNC_REG of sync2 : signal is "TRUE";

   signal rd_cnt         : natural range 0 to G_GLITCH := 0;
   signal rd_level       : std_logic := '0';    -- filtered, active high

   signal step_old       : std_logic := '0';
   signal step_cnt       : natural range 0 to C_STEP := 0;
   signal step_pin       : std_logic := '1';

   signal sel_old        : std_logic_vector(1 downto 0) := "00";
   signal wdog_cnt       : natural range 0 to C_WDOG := 0;
   signal wdog_trip      : std_logic := '0';
   signal motor_on       : std_logic := '0';
   signal wgate_on       : std_logic := '0';

begin

   p_inputs : process (clk_i)
   begin
      if rising_edge(clk_i) then
         sync1 <= f_writeprotect_i & f_track0_i & f_rdata_i & f_index_i & f_diskchanged_i;
         sync2 <= sync1;

         -- RDATA glitch filter: a new level must be stable for G_GLITCH cycles
         flux_o <= '0';
         if (not sync2(2)) = rd_level then
            rd_cnt <= 0;
         elsif rd_cnt = G_GLITCH - 1 then
            rd_cnt   <= 0;
            rd_level <= not sync2(2);
            if sync2(2) = '0' then
               flux_o <= '1';
            end if;
         else
            rd_cnt <= rd_cnt + 1;
         end if;
      end if;
   end process p_inputs;

   rdata_o  <= rd_level;
   dskchg_o <= not sync2(0);
   index_o  <= not sync2(1);
   track0_o <= not sync2(3);
   wprot_o  <= not sync2(4);

   p_step : process (clk_i)
   begin
      if rising_edge(clk_i) then
         step_old <= step_i;
         if step_cnt /= 0 then
            step_cnt <= step_cnt - 1;
            if step_cnt = C_STEP - C_SETUP then
               step_pin <= '0';                          -- direction setup time is over
            end if;
            if step_cnt = 1 then
               step_pin <= '1';
            end if;
         elsif step_i = '1' and step_old = '0' then
            step_cnt <= C_STEP;
         end if;
         if rst_i = '1' then
            step_cnt <= 0;
            step_pin <= '1';
         end if;
      end if;
   end process p_step;

   step_busy_o <= '1' when step_cnt /= 0 else '0';

   p_motor : process (clk_i)
   begin
      if rising_edge(clk_i) then
         sel_old <= sel_b_i & sel_a_i;
         if motor_i = '0' then
            wdog_cnt  <= 0;
            wdog_trip <= '0';
         elsif (step_i = '1' and step_old = '0') or sel_old /= (sel_b_i & sel_a_i) or wgate_on = '1' then
            wdog_cnt <= 0;
         elsif G_WDOG_MS /= 0 and wdog_cnt = C_WDOG then
            wdog_trip <= '1';
         elsif G_WDOG_MS /= 0 then
            wdog_cnt <= wdog_cnt + 1;
         end if;
         if rst_i = '1' then
            wdog_cnt  <= 0;
            wdog_trip <= '1';                            -- motor stays off until motor_i drops
         end if;
      end if;
   end process p_motor;

   motor_on <= motor_i and not wdog_trip and not rst_i;

   wgate_on <= '1' when G_WRITE_ENABLE and write_allow_i = '1' and wgate_i = '1' and rst_i = '0' and
                        (sel_a_i = '1' or sel_b_i = '1') and motor_on = '1' and sync2(4) = '1'
               else '0';

   motor_on_o  <= motor_on;
   wgate_on_o  <= wgate_on;

   f_density_o <= density_i;
   f_motora_o  <= not motor_on;
   f_motorb_o  <= not motor_on;
   f_selecta_o <= not (sel_a_i and not rst_i);
   f_selectb_o <= not (sel_b_i and not rst_i);
   f_side1_o   <= not side_i;
   f_stepdir_o <= not dir_in_i;
   f_step_o    <= step_pin;
   f_wgate_o   <= not wgate_on;
   f_wdata_o   <= not (wdata_i and wgate_on);

end architecture synthesis;
