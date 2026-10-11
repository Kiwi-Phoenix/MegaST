----------------------------------------------------------------------------------
-- Atari ST/STe for MEGA65 (MegaST)
--
-- Right mouse button on pin 9 (a pot line) of the mouse port
--
-- The pot inputs of the MEGA65 have no pull-up, so an open pin 9 reads as pressed, just like a
-- pressed button: a USB mouse adapter like the mouSTer (issue #17) or a joystick in the mouse port
-- held the right button down. An optical Amiga mouse (issue #5) or a mouSTer with activepotlines=true
-- drives the pin high while the button is released.
-- So the button only counts after pin 9 was released for G_ARM_MS; pressed for G_DISARM_MS or a
-- change of the port (disarm_i) needs that release again (e.g. the mouse was replaced by an adapter).
--
-- Click mode (click_i, used for the Atari mouse): an Atari mouse does not pull pin 9 up either, its
-- button only grounds the pin. After a release the open line takes 10-13 s to float back up (measured
-- on an R6), so the release can not be seen. In click mode a press counts for G_CLICK_MS only: a right
-- click works, holding the button does not, and the next click needs the line to have floated up.
--
-- This machine is based on AtariST_MiSTer
-- Powered by MiSTer2MEGA65
-- MEGA65 port done by Chris Freeman in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity rmb_guard is
   generic (
      G_CLK_SPEED : natural;
      G_ARM_MS    : natural := 50;
      G_DISARM_MS : natural := 10_000;
      G_CLICK_MS  : natural := 200
   );
   port (
      clk_i     : in  std_logic;
      disarm_i  : in  std_logic;                   -- e.g. the mouse port changed
      click_i   : in  std_logic;                   -- click mode: a press counts for G_CLICK_MS only
      pin_i     : in  std_logic;                   -- pin 9 reads pressed (low or open)
      rmb_o     : out std_logic                    -- right button pressed
   );
end entity rmb_guard;

architecture synthesis of rmb_guard is

   constant C_ARM    : natural := G_CLK_SPEED / 1000 * G_ARM_MS;
   constant C_DISARM : natural := G_CLK_SPEED / 1000 * G_DISARM_MS;
   constant C_CLICK  : natural := G_CLK_SPEED / 1000 * G_CLICK_MS;

   signal armed : std_logic := '0';
   signal cnt   : natural range 0 to C_DISARM := 0;
   signal held  : natural range 0 to C_CLICK := 0;   -- time pressed, for the click mode

begin

   rmb_o <= pin_i and armed when click_i = '0' or held /= C_CLICK else '0';

   process(clk_i)
   begin
      if rising_edge(clk_i) then
         if pin_i = armed then
            -- released while disarmed, or pressed while armed
            if (armed = '0' and cnt = C_ARM) or cnt = C_DISARM then
               armed <= not armed;
               cnt   <= 0;
            else
               cnt   <= cnt + 1;
            end if;
         else
            cnt <= 0;
         end if;

         if pin_i = '0' then
            held <= 0;
         elsif held /= C_CLICK then
            held <= held + 1;
         end if;

         if disarm_i = '1' then
            armed <= '0';
            cnt   <= 0;
         end if;
      end if;
   end process;

end architecture synthesis;
