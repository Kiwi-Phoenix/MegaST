----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- fdc_dsep: data separator for a real floppy drive (MFM, double density): decodes the flux timing and
-- plays it back to the floppy controller at an even speed
--
-- Some drives deliver the flux with a fast speed wobble of a few percent (measured on the MEGA65 R6
-- internal drive with tools/flux2scp.py: 74 ns per bit cell against 11 ns on a PC drive). The data
-- separator of WF1772IP then decides wrongly between 6 and 8 us and the sector fails its CRC.
--
-- * Decision: the interval since the previous transition is 2, 3 or 4 bit cells of the tracked cell
--   length (boundaries at 2.5 and 3.5 cells). The cell length follows the measured one with the gain
--   1/16 per bit cell (dev / (16 n)), limited to +-10 % of the nominal 2 us. A transition less than
--   1.5 cells after the previous one is impossible in MFM and dropped as a glitch; an interval longer
--   than 4.5 cells (splice, unformatted) is passed on as 4 cells.
-- * Peak shift compensation: magnetic pulses close together push each other apart, so an interval
--   followed by a short one reads too short (R6 drive: 80..110 ns, the 8 us intervals between two 4 us
--   ones up to 900 ns). Each interval is decided only when the next one has arrived, after subtracting the
--   learned mean deviation of its (previous, this, next) pattern (27 running means, gain 1/32). On the
--   weakest sector of a capture this doubles the margin (Jim Power track 68 side 0 sector 10: 68 -> 188 ns).
--   But on the R6 drive the 1.1-test1 core then failed track 1 side 0 sector 2 every time, which reads
--   without it: G_PEAKSHIFT (default false) until that is understood.
-- * Playback: the decisions go into a FIFO (an elastic buffer) and come out as pulses n output cells
--   apart. The output cell is the nominal 2 us, shortened or lengthened by 1/4096 per entry the FIFO is
--   above or below C_TARGET: the controller gets an even data rate, the FIFO absorbs the wobble (the
--   R6 drive hunts by +-8 % about 30 times per second: ~180 entries peak to peak) and the small
--   difference of the average speed. Latency: about C_TARGET entries (~1.3 ms; sectors arrive a few
--   degrees later than on a real ST, which software does not notice).
--
-- Verified with CORE/sim/real_floppy/run_flux_replay.sh against flux captures of the MEGA65 drive.
--
-- This machine is based on AtariST_MiSTer
-- Powered by MiSTer2MEGA65
-- MEGA65 port done by Chris Freeman in 2026 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fdc_dsep is
generic (
   G_CLK_HZ      : natural := 32_083_333;
   G_CELL_NS     : natural := 2000;              -- nominal bit cell (DD: 2 us)
   G_PULSE_NS    : natural := 250;               -- output pulse length
   G_PEAKSHIFT   : boolean := false              -- peak shift compensation (see above; off: it failed a
                                                 -- sector on the R6 drive that reads without it)
);
port (
   clk_i         : in  std_logic;
   rst_i         : in  std_logic;
   flux_i        : in  std_logic;                -- one cycle per flux transition
   rdata_o       : out std_logic                 -- re-timed pulses, active high
);
end entity fdc_dsep;

architecture synthesis of fdc_dsep is

   -- lengths in 1/16 clock cycles
   constant C_FRAC    : natural := 4;
   constant C_CELL    : natural := (G_CELL_NS * (G_CLK_HZ / 1000) * 2 ** C_FRAC + 500_000) / 1_000_000;
   constant C_CELL_LO : natural := C_CELL * 9 / 10;
   constant C_CELL_HI : natural := C_CELL * 11 / 10;
   constant C_PULSE   : natural := (G_PULSE_NS * (G_CLK_HZ / 1000) + 500_000) / 1_000_000;
   constant C_DEPTH   : natural := 512;          -- FIFO entries
   constant C_TARGET  : natural := 256;          -- FIFO fill the playback speed aims at
   constant C_START   : natural := 128;          -- playback starts (after running empty) at this fill

   -- decision
   signal iv          : unsigned(15 downto 0) := (others => '1');   -- time since the last transition
   signal cell        : unsigned(15 downto 0) := to_unsigned(C_CELL, 16);
   -- peak shift compensation: an interval is decided when the next one has arrived, corrected by the
   -- learned mean deviation of its (previous, this, next) pattern; tab holds 32 x the mean (1/16 cycles)
   type tab_t is array (0 to 26) of signed(17 downto 0);
   signal tab         : tab_t := (others => (others => '0'));
   signal pend_valid  : std_logic := '0';
   signal pend_iv     : signed(17 downto 0) := (others => '0');
   signal pend_nr     : natural range 2 to 4 := 2;          -- its class from the raw length
   signal pend_long   : std_logic := '0';                   -- longer than 4.5 cells
   signal prev_n      : natural range 2 to 4 := 3;          -- the previous decision

   -- FIFO of decisions (cells before each pulse)
   type fifo_t is array (0 to C_DEPTH - 1) of unsigned(2 downto 0);
   signal fifo        : fifo_t;
   signal wr_ptr      : unsigned(8 downto 0) := (others => '0');
   signal rd_ptr      : unsigned(8 downto 0) := (others => '0');
   signal fill        : natural range 0 to C_DEPTH := 0;

   -- playback
   signal playing     : std_logic := '0';
   signal remain      : signed(17 downto 0) := (others => '0');      -- time to the next pulse
   signal pulse_cnt   : natural range 0 to C_PULSE := 0;

begin

   p_dsep : process (clk_i)
      variable c, half, ivs, dev, upd : signed(17 downto 0);
      variable x, d, t   : signed(17 downto 0);
      variable n, nr     : natural range 2 to 4;
      variable key       : natural range 0 to 26;
      variable push, pop : boolean;
      variable cell_out  : signed(17 downto 0);
      variable next_n    : signed(17 downto 0);
   begin
      if rising_edge(clk_i) then
         if iv(15 downto 14) /= "11" then
            iv <= iv + 2 ** C_FRAC;
         end if;
         if pulse_cnt /= 0 then
            pulse_cnt <= pulse_cnt - 1;
         end if;
         push := false;
         pop  := false;

         -- decision
         if flux_i = '1' then
            c    := signed(resize(cell, 18));
            half := shift_right(c, 1);
            ivs  := signed(resize(iv, 18));
            if ivs >= c + half then                               -- else: glitch, ignore
               iv <= to_unsigned(2 ** C_FRAC, 16);                -- this cycle belongs to the next interval
               -- class of this interval from its raw length (only the pattern of the waiting one needs it)
               if ivs < 2 * c + half then
                  nr := 2;
               elsif ivs < 3 * c + half then
                  nr := 3;
               else
                  nr := 4;
               end if;
               -- decide the waiting interval, now that its successor is known
               if pend_valid = '1' then
                  key := (prev_n - 2) * 9 + (pend_nr - 2) * 3 + (nr - 2);
                  t   := tab(key);
                  if pend_long = '1' then
                     n := 4;                                       -- too long for MFM: pass on as 4 cells
                  else
                     if G_PEAKSHIFT then
                        x := pend_iv - shift_right(t, 5);          -- peak shift corrected
                     else
                        x := pend_iv;
                     end if;
                     if x < 2 * c + half then
                        n := 2;
                     elsif x < 3 * c + half then
                        n := 3;
                     else
                        n := 4;
                     end if;
                     dev := x - resize(to_signed(n, 4) * c, 18);
                     -- cell += dev / (16 n); 1/48 is approximated by 1/64 + 1/256 + 1/1024
                     case n is
                        when 2      => upd := shift_right(dev, 5);
                        when 3      => upd := shift_right(dev, 6) + shift_right(dev, 8) + shift_right(dev, 10);
                        when others => upd := shift_right(dev, 6);
                     end case;
                     if c + upd < C_CELL_LO then
                        cell <= to_unsigned(C_CELL_LO, 16);
                     elsif c + upd > C_CELL_HI then
                        cell <= to_unsigned(C_CELL_HI, 16);
                     else
                        cell <= unsigned(resize(c + upd, 16));
                     end if;
                     -- learn the pattern: mean += (raw deviation - mean) / 32
                     d        := pend_iv - resize(to_signed(n, 4) * c, 18);
                     tab(key) <= t + d - shift_right(t, 5);
                  end if;
                  prev_n <= n;
                  if fill < C_DEPTH then
                     fifo(to_integer(wr_ptr)) <= to_unsigned(n, 3);
                     wr_ptr <= wr_ptr + 1;
                     push := true;
                  end if;
               end if;
               pend_valid <= '1';
               pend_iv    <= ivs;
               pend_nr    <= nr;
               if ivs >= 4 * c + half then
                  pend_long <= '1';
               else
                  pend_long <= '0';
               end if;
            end if;
         end if;

         -- playback: a pulse n output cells after the previous one; the output cell keeps the FIFO near
         -- C_TARGET (C_CELL / 4096 = 1/4 of the 1/16 cycle unit per entry: scaled by 4 to stay exact)
         cell_out := shift_right(to_signed(C_CELL * 4, 18) - to_signed(fill - C_TARGET, 11), 2);
         next_n   := resize(to_signed(to_integer(fifo(to_integer(rd_ptr))), 4) * cell_out, 18);
         if playing = '0' then
            if fill >= C_START then
               playing <= '1';
               remain  <= next_n;
               rd_ptr  <= rd_ptr + 1;
               pop     := true;
            end if;
         elsif remain > 2 ** C_FRAC then
            remain <= remain - 2 ** C_FRAC;
         else
            pulse_cnt <= C_PULSE;
            if fill = 0 then
               playing <= '0';                                     -- ran empty: wait for C_START again
            else
               remain <= remain - 2 ** C_FRAC + next_n;            -- keeps the fraction: no drift
               rd_ptr <= rd_ptr + 1;
               pop    := true;
            end if;
         end if;

         if push and not pop then
            fill <= fill + 1;
         elsif pop and not push then
            fill <= fill - 1;
         end if;

         if rst_i = '1' then
            wr_ptr    <= (others => '0');
            rd_ptr    <= (others => '0');
            fill      <= 0;
            playing   <= '0';
            pulse_cnt <= 0;
            cell      <= to_unsigned(C_CELL, 16);
            pend_valid <= '0';
            tab       <= (others => (others => '0'));
         end if;
      end if;
   end process p_dsep;

   rdata_o <= '1' when pulse_cnt /= 0 else '0';

end architecture synthesis;
