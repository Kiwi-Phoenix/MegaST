-- Replays a real flux capture (e.g. from a Greaseweazle, see run_flux_replay.sh) into the converted
-- WF1772IP (clock enable version, 32 MHz) and reads every sector of the track with "read sector".
-- Shows whether the floppy controller decodes what a real drive delivers: per sector the status and
-- the number of bytes that differ from the disk image.
--
-- Inputs (in the working directory): flux.txt = one flux interval in ns per line, 'I' marks an index
-- (the revolutions are replayed in a loop); expect.txt = the sector bytes of the track (hex, one per
-- line, sectors 1..G_SECTORS).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library wf_ce;

entity tb_flux_replay is
generic (
   G_TRACK   : natural := 3;
   G_SECTORS : natural := 10;
   G_PULSE   : time    := 400 ns       -- RDATA low time per flux transition
);
end entity tb_flux_replay;

architecture sim of tb_flux_replay is

   constant C_PER32 : time := 31.17 ns;          -- 32.083 MHz

   signal clk32     : std_logic := '0';
   signal ce        : std_logic := '0';
   signal resetn    : std_logic := '0';
   signal csn, rwn  : std_logic := '1';
   signal a         : std_logic_vector(1 downto 0) := "00";
   signal din, dout : std_logic_vector(7 downto 0) := (others => '0');
   signal drq, intrq : std_logic;
   signal rdata_n   : std_logic := '1';
   signal index_n   : std_logic := '1';
   signal rdn_sync  : std_logic_vector(3 downto 0) := (others => '1');

   -- flux intervals in ns, negative = index mark
   type int_arr is array (natural range <>) of integer;
   impure function load_flux return int_arr is
      file f      : text open read_mode is "flux.txt";
      variable l  : line;
      variable v  : integer;
      variable n  : natural := 0;
      variable r  : int_arr(0 to 1_999_999);
   begin
      while not endfile(f) loop
         readline(f, l);
         if l'length > 0 and l(l'low) = 'I' then
            r(n) := -1;
         else
            read(l, v);
            r(n) := v;
         end if;
         n := n + 1;
      end loop;
      return r(0 to n - 1);
   end function;
   type byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
   impure function load_expect return byte_arr is
      file f      : text open read_mode is "expect.txt";
      variable l  : line;
      variable v  : std_logic_vector(7 downto 0);
      variable r  : byte_arr(0 to G_SECTORS * 512 - 1);
   begin
      for i in r'range loop
         readline(f, l);
         hread(l, v);
         r(i) := v;
      end loop;
      return r;
   end function;
   constant C_EXPECT : byte_arr := load_expect;

begin

   p_clk : process
   begin
      clk32 <= '1';
      ce    <= not ce;
      wait for C_PER32 / 2;
      clk32 <= '0';
      wait for C_PER32 / 2;
   end process p_clk;

   -- the MEGA65 path (m65_floppy_port.vhd): two synchroniser flip-flops and a 2 cycle glitch filter
   p_sync : process (clk32)
   begin
      if rising_edge(clk32) then
         rdn_sync <= rdn_sync(2 downto 0) & rdata_n;
      end if;
   end process p_sync;

   -- the drive: one low pulse per flux transition, an index pulse at each 'I', revolutions in a loop
   p_drive : process
      constant C_FLUX : int_arr := load_flux;
   begin
      report "flux replay: " & integer'image(C_FLUX'length) & " entries";
      loop
         for i in C_FLUX'range loop
            if C_FLUX(i) < 0 then
               index_n <= '0', '1' after 2 ms;
            else
               wait for C_FLUX(i) * 1 ns - G_PULSE;
               rdata_n <= '0';
               wait for G_PULSE;
               rdata_n <= '1';
            end if;
         end loop;
      end loop;
   end process p_drive;

   i_fdc : entity wf_ce.WF1772IP_TOP_SOC
      port map (
         CLK => clk32, CE => ce, RESETn => resetn, CSn => csn, RWn => rwn, A1 => a(1), A0 => a(0),
         DATA_IN => din, DATA_OUT => dout, DATA_EN => open, RDn => rdn_sync(3), TR00n => '1',
         IPn => index_n, WPRTn => '1', DDEn => '0', HDTYPE => '0', MO => open, WG => open, WD => open,
         STEP => open, DIRC => open, DRQ => drq, INTRQ => intrq
      );

   p_cpu : process
      procedure wr(reg : natural; v : std_logic_vector(7 downto 0)) is
      begin
         a <= std_logic_vector(to_unsigned(reg, 2)); din <= v; rwn <= '0';
         wait for 125 ns; csn <= '0'; wait for 500 ns; csn <= '1'; wait for 125 ns; rwn <= '1';
         wait for 1 us;
      end procedure;
      procedure rd(reg : natural; v : out std_logic_vector(7 downto 0)) is
      begin
         a <= std_logic_vector(to_unsigned(reg, 2)); rwn <= '1';
         wait for 125 ns; csn <= '0'; wait for 450 ns; v := dout; wait for 50 ns; csn <= '1';
         wait for 250 ns;
      end procedure;
      variable st, v : std_logic_vector(7 downto 0);
      variable errs, got, bad : natural;
   begin
      wait for 1 us;
      resetn <= '1';
      wait for 2 us;
      wr(1, std_logic_vector(to_unsigned(G_TRACK, 8)));            -- track register = the captured track
      bad := 0;
      for sec in 1 to G_SECTORS loop
         wr(2, std_logic_vector(to_unsigned(sec, 8)));
         wr(0, x"88");                                              -- read sector, no spin-up
         errs := 0; got := 0;
         loop
            wait until drq = '1' or intrq = '1' for 1500 ms;
            exit when intrq = '1' or drq /= '1';
            rd(3, v);
            if got < 512 and v /= C_EXPECT((sec - 1) * 512 + got) then
               errs := errs + 1;
            end if;
            got := got + 1;
         end loop;
         if intrq /= '1' then
            wait until intrq = '1' for 1500 ms;
         end if;
         rd(0, st);
         report "sector " & integer'image(sec) & ": status " & to_hstring(st) & ", bytes " &
                integer'image(got) & ", byte errors " & integer'image(errs) & " at " & time'image(now);
         if (st and x"1C") /= x"00" or errs /= 0 or got /= 512 then
            bad := bad + 1;
         end if;
      end loop;
      report "flux replay: " & integer'image(bad) & " of " & integer'image(G_SECTORS) & " sectors failed";
      std.env.finish;
   end process p_cpu;

end architecture sim;
