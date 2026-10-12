-- GHDL test of m65_floppy_port.vhd and floppy_probe.vhd with a simple drive model.
-- The model drive spins at 200 revolutions per second (5 ms instead of 200 ms), steps are 1 ms apart to keep the run short.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_floppy_port is
end entity tb_floppy_port;

architecture sim of tb_floppy_port is

   constant C_HZ     : natural := 32_083_333;
   constant C_PER    : time    := 1 sec / C_HZ;
   constant C_REV    : time    := 5 ms;

   signal clk        : std_logic := '0';
   signal rst        : std_logic := '1';
   signal done       : boolean   := false;

   signal cmd        : std_logic_vector(23 downto 0) := (others => '0');
   signal cmd_valid  : std_logic := '0';
   signal snap       : std_logic_vector(223 downto 0);

   signal sel_a, sel_b, motor, side, dir_in, step, density : std_logic;
   signal flux, rdata, index, track0, wprot, dskchg, step_busy, motor_on : std_logic;

   signal f_density, f_motora, f_motorb, f_selecta, f_selectb, f_side1 : std_logic;
   signal f_stepdir, f_step, f_wdata, f_wgate : std_logic;
   signal f_diskchanged : std_logic := '1';
   signal f_index       : std_logic := '1';
   signal f_rdata       : std_logic := '1';
   signal f_track0      : std_logic := '0';
   signal f_wprot       : std_logic := '1';

   signal head          : integer := 0;
   signal dir_changed   : time := 0 ns;

   -- second port with writing enabled, only for the interlock checks
   signal w_wgate_i, w_allow, w_sel, w_motor, w_wdata : std_logic := '0';
   signal w_wprot_pin   : std_logic := '1';
   signal w_f_wgate, w_f_wdata, w_f_motora : std_logic;

   function field(s : std_logic_vector; hi, lo : natural) return natural is
   begin
      return to_integer(unsigned(s(hi downto lo)));
   end function;

begin

   clk <= not clk after C_PER / 2 when not done;

   i_port : entity work.m65_floppy_port
      generic map (G_CLK_HZ => C_HZ, G_WDOG_MS => 25)
      port map (
         clk_i => clk, rst_i => rst,
         sel_a_i => sel_a, sel_b_i => sel_b, motor_i => motor, side_i => side, dir_in_i => dir_in,
         step_i => step, wgate_i => '1', wdata_i => '1', write_allow_i => '1', density_i => density,
         flux_o => flux, rdata_o => rdata, index_o => index, track0_o => track0, wprot_o => wprot,
         dskchg_o => dskchg, step_busy_o => step_busy, motor_on_o => motor_on, wgate_on_o => open,
         f_density_o => f_density, f_motora_o => f_motora, f_motorb_o => f_motorb,
         f_selecta_o => f_selecta, f_selectb_o => f_selectb, f_side1_o => f_side1,
         f_stepdir_o => f_stepdir, f_step_o => f_step, f_wdata_o => f_wdata, f_wgate_o => f_wgate,
         f_diskchanged_i => f_diskchanged, f_index_i => f_index, f_rdata_i => f_rdata,
         f_track0_i => f_track0, f_writeprotect_i => f_wprot);

   i_probe : entity work.floppy_probe
      generic map (G_CLK_HZ => C_HZ, G_STEP_MS => 1)
      port map (
         clk_i => clk, rst_i => rst, cmd_i => cmd, cmd_valid_i => cmd_valid, snap_o => snap,
         sel_a_o => sel_a, sel_b_o => sel_b, motor_o => motor, side_o => side, dir_in_o => dir_in,
         step_o => step, density_o => density,
         flux_i => flux, rdata_i => rdata, index_i => index, track0_i => track0, wprot_i => wprot,
         dskchg_i => dskchg, step_busy_i => step_busy, motor_on_i => motor_on);

   i_wport : entity work.m65_floppy_port
      generic map (G_CLK_HZ => C_HZ, G_WRITE_ENABLE => true, G_WDOG_MS => 0)
      port map (
         clk_i => clk, rst_i => rst,
         sel_a_i => w_sel, sel_b_i => '0', motor_i => w_motor, side_i => '0', dir_in_i => '0',
         step_i => '0', wgate_i => w_wgate_i, wdata_i => w_wdata, write_allow_i => w_allow, density_i => '1',
         f_motora_o => w_f_motora, f_wgate_o => w_f_wgate, f_wdata_o => w_f_wdata,
         f_diskchanged_i => '1', f_index_i => '1', f_rdata_i => '1', f_track0_i => '1',
         f_writeprotect_i => w_wprot_pin);

   ------------------------------------------------------------------------------------------------
   -- drive model
   ------------------------------------------------------------------------------------------------

   p_dir : process (f_stepdir)
   begin
      dir_changed <= now;
   end process p_dir;

   p_head : process
      variable t_fall : time;
   begin
      wait until falling_edge(f_step);
      t_fall := now;
      assert now - dir_changed >= 2 us report "direction setup time too short" severity failure;
      wait until rising_edge(f_step);
      assert now - t_fall >= 3900 ns report "step pulse too short: " & time'image(now - t_fall) severity failure;
      if f_selecta = '0' then
         if f_stepdir = '0' then
            head <= head + 1;
         elsif head > 0 then
            head <= head - 1;
         end if;
      end if;
   end process p_head;

   f_track0 <= '0' when head = 0 else '1';

   p_index : process
   begin
      wait until f_motora = '0';
      while f_motora = '0' loop
         f_index <= '0';
         wait for 1 ms;
         f_index <= '1';
         wait for C_REV - 1 ms;
      end loop;
   end process p_index;

   -- flux pattern 4, 6, 8, 4 us (low pulses of 400 ns), plus a 30 ns glitch after every 8 us gap
   p_rdata : process
      type ivals_t is array (0 to 3) of time;
      constant C_IV : ivals_t := (4 us, 6 us, 8 us, 4 us);
   begin
      if f_motora = '0' and f_selecta = '0' then
         for i in 0 to 3 loop
            f_rdata <= '0';
            wait for 400 ns;
            f_rdata <= '1';
            if i = 2 then
               wait for 3 us;
               f_rdata <= '0';
               wait for 30 ns;
               f_rdata <= '1';
               wait for C_IV(i) - 3030 ns - 400 ns;
            else
               wait for C_IV(i) - 400 ns;
            end if;
         end loop;
      else
         wait for 1 us;
      end if;
   end process p_rdata;

   ------------------------------------------------------------------------------------------------
   -- test sequence
   ------------------------------------------------------------------------------------------------

   p_test : process
      procedure send(c : std_logic_vector(23 downto 0)) is
      begin
         wait until rising_edge(clk);
         cmd       <= c;
         cmd_valid <= '1';
         wait until rising_edge(clk);
         cmd_valid <= '0';
      end procedure;
      variable per, fl, b0, b1, b2, b3, b4, b5 : natural;
   begin
      wait for 1 us;
      wait until rising_edge(clk);
      rst <= '0';
      wait for 1 us;

      -- 1. idle: every output inactive
      assert f_motora = '1' and f_selecta = '1' and f_step = '1' and f_wgate = '1' and f_wdata = '1' and
             f_density = '1' and f_selectb = '1' report "outputs not idle after reset" severity failure;

      -- 2. a command without the magic byte is ignored
      send(x"00" & x"00" & x"03");
      wait for 1 us;
      assert f_motora = '1' report "command without magic accepted" severity failure;

      -- 3. motor and select A; read three revolutions
      send(x"00" & x"A5" & x"03");
      wait for 1 us;
      assert f_motora = '0' and f_selecta = '0' report "motor/select not on" severity failure;
      assert f_wgate = '1' and f_wdata = '1' report "write lines active in the read-only port" severity failure;
      wait for 3 * C_REV + 1 ms;
      per := field(snap, 55, 32);
      fl  := field(snap, 79, 56);
      b0 := field(snap, 95, 80);   b1 := field(snap, 111, 96);  b2 := field(snap, 127, 112);
      b3 := field(snap, 143, 128); b4 := field(snap, 159, 144); b5 := field(snap, 175, 160);
      report "index " & integer'image(field(snap, 31, 16)) & " period " & integer'image(per) &
             " flux " & integer'image(fl) & " bins " & integer'image(b0) & "/" & integer'image(b1) & "/" &
             integer'image(b2) & "/" & integer'image(b3) & "/" & integer'image(b4) & "/" & integer'image(b5);
      assert field(snap, 31, 16) >= 3 report "index pulses missing" severity failure;
      assert abs(per - 160417) < 10 report "index period wrong" severity failure;
      assert b0 = 0 and b1 = 0 and b5 = 0 report "glitch passed the filter or bad interval" severity failure;
      assert abs(b2 - 2 * b3) <= 2 and abs(b3 - b4) <= 1 report "histogram wrong" severity failure;
      assert abs(fl - 909) <= 2 and fl = b2 + b3 + b4 report "flux count wrong" severity failure;
      assert snap(1) = '1' report "track0 not reported" severity failure;

      -- 4. three steps in, then five out (the head stops at track 0)
      send(x"03" & x"A5" & x"0B");
      wait for 5 ms;
      assert head = 3 report "head not on track 3: " & integer'image(head) severity failure;
      assert snap(1) = '0' and field(snap, 191, 176) = 3 report "track0/step count wrong" severity failure;
      send(x"05" & x"A5" & x"03");
      wait for 7 ms;
      assert head = 0 and snap(1) = '1' report "head not back on track 0" severity failure;

      -- 5. write protect and disk changed are reported, with edge counters
      f_wprot <= '0';
      f_diskchanged <= '0';
      wait for 1 us;
      assert snap(2) = '1' and snap(3) = '1' and field(snap, 207, 200) = 1 and field(snap, 199, 192) = 1
         report "wprot/dskchg not reported" severity failure;
      f_wprot <= '1';
      f_diskchanged <= '1';

      -- 6. motor watchdog (25 ms in this test): steps keep the motor on, idling switches it off
      send(x"02" & x"A5" & x"0B");
      wait for 20 ms;
      assert f_motora = '0' report "watchdog tripped too early" severity failure;
      wait for 12 ms;
      assert f_motora = '1' and snap(5) = '0' report "watchdog did not stop the motor" severity failure;
      send(x"00" & x"A5" & x"02");      -- motor off clears the watchdog
      send(x"00" & x"A5" & x"03");
      wait for 1 us;
      assert f_motora = '0' report "motor not on again after the watchdog" severity failure;

      -- 7. reset switches everything off
      rst <= '1';
      wait for 1 us;
      assert f_motora = '1' and f_selecta = '1' report "reset did not stop the drive" severity failure;
      rst <= '0';
      wait for 1 us;

      -- 8. write interlock of the port with writing enabled
      w_wgate_i <= '1'; w_wdata <= '1'; w_allow <= '1'; w_sel <= '1'; w_motor <= '1';
      wait for 1 us;
      assert w_f_wgate = '0' and w_f_wdata = '0' report "write not possible with all conditions" severity failure;
      w_wprot_pin <= '0';
      wait for 1 us;
      assert w_f_wgate = '1' and w_f_wdata = '1' report "write to a protected disk" severity failure;
      w_wprot_pin <= '1'; w_allow <= '0';
      wait for 1 us;
      assert w_f_wgate = '1' report "write without write_allow" severity failure;
      w_allow <= '1'; w_motor <= '0';
      wait for 1 us;
      assert w_f_wgate = '1' report "write with the motor off" severity failure;
      w_motor <= '1'; w_sel <= '0';
      wait for 1 us;
      assert w_f_wgate = '1' report "write without a selected drive" severity failure;

      report "all floppy port tests passed";
      done <= true;
      std.env.finish;
   end process p_test;

end architecture sim;
