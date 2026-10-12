-- Flux level model of a 3.5" DD floppy drive with an Atari ST formatted disk, for GHDL tests.
--
-- Builds the MFM bit cells of the track under the head (IBM format as the ST writes it: gap 4E,
-- 12 x 00, 3 x A1 sync, ID address mark FE, track, side, sector, size 2, CRC, gap, 3 x A1, data
-- address mark FB, 512 bytes, CRC, gap) and sends one low pulse on rdata_n per flux transition,
-- 2 us per bit cell (250 kbit/s). One revolution is the track length, the index pulse comes at
-- its start. The head follows step_n/dir_n (only while selected), track0_n reports cylinder 0.
-- The sector contents come from sector_byte, so a test can check every byte it reads.
--
-- G_SECTORS sectors per track; G_TRACK_BYTES is the track length in bytes (6250 = 200 ms = 300 rpm).
-- Tests use short tracks to keep the simulation time down.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package floppy_model_pkg is
   function sector_byte(track, side, sector, i : natural) return std_logic_vector;
end package floppy_model_pkg;

package body floppy_model_pkg is
   function sector_byte(track, side, sector, i : natural) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((track * 7 + side * 13 + sector * 31 + i * 5 + i / 256) mod 256, 8));
   end function;
end package body floppy_model_pkg;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.floppy_model_pkg.all;

entity floppy_model is
generic (
   G_SECTORS     : natural := 10;
   G_TRACK_BYTES : natural := 6250;
   G_TRACKS      : natural := 82;
   G_CELL        : time    := 2 us;
   G_PULSE       : time    := 400 ns;
   G_INDEX       : time    := 2 ms;
   G_WPROT       : boolean := false
);
port (
   sel_n     : in  std_logic;
   motor_n   : in  std_logic;
   side_n    : in  std_logic;
   dir_n     : in  std_logic;              -- '0' = step in
   step_n    : in  std_logic;
   rdata_n   : out std_logic;
   index_n   : out std_logic;
   track0_n  : out std_logic;
   wprot_n   : out std_logic;
   head_o    : out natural
);
end entity floppy_model;

architecture sim of floppy_model is

   constant C_CELLS : natural := G_TRACK_BYTES * 16;
   type cells_t is array (0 to C_CELLS - 1) of std_logic;

   signal head      : natural := 0;
   signal rev_start : std_logic := '0';      -- toggles at every index

begin

   head_o   <= head;
   track0_n <= '0' when head = 0 and sel_n = '0' else '1';
   wprot_n  <= '0' when G_WPROT and sel_n = '0' else '1';

   p_head : process
   begin
      wait until falling_edge(step_n);
      if sel_n = '0' then
         if dir_n = '0' and head < G_TRACKS - 1 then
            head <= head + 1;
         elsif dir_n = '1' and head > 0 then
            head <= head - 1;
         end if;
      end if;
   end process p_head;

   p_spin : process
      variable cells   : cells_t;
      variable pos     : natural;           -- next cell
      variable last    : std_logic;         -- last data bit (for the MFM clock bit)
      variable crc     : std_logic_vector(15 downto 0);
      variable side    : natural;
      variable trk     : integer := -1;
      variable sd      : integer := -1;

      procedure crc_byte(variable c : inout std_logic_vector(15 downto 0); b : std_logic_vector(7 downto 0)) is
      begin
         for k in 7 downto 0 loop
            if (c(15) xor b(k)) = '1' then
               c := (c(14 downto 0) & '0') xor x"1021";
            else
               c := c(14 downto 0) & '0';
            end if;
         end loop;
      end procedure;

      procedure put_byte(variable cl : inout cells_t; variable p : inout natural; variable l : inout std_logic;
                         variable c : inout std_logic_vector(15 downto 0); b : std_logic_vector(7 downto 0)) is
      begin
         for k in 7 downto 0 loop
            if p < C_CELLS - 1 then
               cl(p)     := not (l or b(k));                -- clock bit
               cl(p + 1) := b(k);                            -- data bit
            end if;
            p := p + 2;
            l := b(k);
         end loop;
         crc_byte(c, b);
      end procedure;

      procedure put_sync(variable cl : inout cells_t; variable p : inout natural; variable l : inout std_logic;
                         variable c : inout std_logic_vector(15 downto 0)) is
         constant C_A1 : std_logic_vector(15 downto 0) := x"4489";   -- A1 with a missing clock bit
      begin
         for k in 15 downto 0 loop
            if p < C_CELLS then
               cl(p) := C_A1(k);
            end if;
            p := p + 1;
         end loop;
         l := '1';
         crc_byte(c, x"A1");
      end procedure;

      procedure build(variable cl : inout cells_t; t, s : natural) is
         variable p : natural := 0;
         variable l : std_logic := '0';
         variable c : std_logic_vector(15 downto 0) := x"FFFF";
      begin
         for k in 1 to 60 loop put_byte(cl, p, l, c, x"4E"); end loop;
         for sec in 1 to G_SECTORS loop
            for k in 1 to 12 loop put_byte(cl, p, l, c, x"00"); end loop;
            c := x"FFFF";
            for k in 1 to 3 loop put_sync(cl, p, l, c); end loop;
            put_byte(cl, p, l, c, x"FE");
            put_byte(cl, p, l, c, std_logic_vector(to_unsigned(t, 8)));
            put_byte(cl, p, l, c, std_logic_vector(to_unsigned(s, 8)));
            put_byte(cl, p, l, c, std_logic_vector(to_unsigned(sec, 8)));
            put_byte(cl, p, l, c, x"02");
            crc := c;
            put_byte(cl, p, l, c, crc(15 downto 8));
            put_byte(cl, p, l, c, crc(7 downto 0));
            for k in 1 to 22 loop put_byte(cl, p, l, c, x"4E"); end loop;
            for k in 1 to 12 loop put_byte(cl, p, l, c, x"00"); end loop;
            c := x"FFFF";
            for k in 1 to 3 loop put_sync(cl, p, l, c); end loop;
            put_byte(cl, p, l, c, x"FB");
            for i in 0 to 511 loop put_byte(cl, p, l, c, sector_byte(t, s, sec, i)); end loop;
            crc := c;
            put_byte(cl, p, l, c, crc(15 downto 8));
            put_byte(cl, p, l, c, crc(7 downto 0));
            for k in 1 to 40 loop put_byte(cl, p, l, c, x"4E"); end loop;
         end loop;
         assert p <= C_CELLS report "floppy_model: track too short for the sectors" severity failure;
         while p < C_CELLS loop put_byte(cl, p, l, c, x"4E"); end loop;
      end procedure;

   begin
      rdata_n <= '1';
      index_n <= '1';
      if motor_n = '0' then
         pos := 0;
         index_n <= '0' when sel_n = '0' else '1';
         while pos < C_CELLS and motor_n = '0' loop
            if pos * G_CELL >= G_INDEX then
               index_n <= '1';
            end if;
            side := 1 when side_n = '0' else 0;
            if head /= trk or side /= sd then                -- new track under the head
               build(cells, head, side);
               trk := head;
               sd  := side;
            end if;
            if cells(pos) = '1' and sel_n = '0' then
               rdata_n <= '0';
               wait for G_PULSE;
               rdata_n <= '1';
               wait for G_CELL - G_PULSE;
            else
               wait for G_CELL;
            end if;
            pos := pos + 1;
         end loop;
      else
         wait until motor_n = '0';
      end if;
   end process p_spin;

end architecture sim;
