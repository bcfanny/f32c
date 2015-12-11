--
-- Copyright (c) 2013, 2014 Marko Zec, University of Zagreb
-- Copyright (c) 2015 Davor Jadrijevic
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--
-- THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
-- FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
-- LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
-- OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
-- SUCH DAMAGE.
--
-- $Id$
--

-- asynchronous FIFO adapter from system memory
-- running at CPU clock (around 100 MHz) with
-- unpredictable access time to
-- to video system, running at pixel clock (25 MHz)
-- which must have constant data rate

-- allows compositing (thin h-sprites)

-- every 17th 32-bit word is compositing word. 
-- it can be either positive or negative, it will be added to fifo
-- write address for 16 following 32-bit words, which will
-- effectively horizontally displace thin sprite left or right
-- on the 640x480 8bpp it can be 9600 thin h-sprites

-- memory map (continuously repeats this pattern):
-- +---------+---------+-------------+-------------+
-- | x-offset| x-offset| bitmap      | bitmap      |
-- | sprite 0| sprite 1| sprite 0    | sprite 1    |
-- | int16_t | int16_t | uint32_t[8] | uint32_t[8] |
-- +---------+---------+-------------+-------------+

-- or in C:
-- struct thin_sprite
-- {
--   int16_t[2] offset;
--   uint32_t[2][8] bitmap;
-- };

-- when x-offset is set to 0 the bitmap will be on its
-- original sequential position on the screen
-- pixel plot routine should just skip offset words
-- and leave them at 0

-- offset values:
-- Negative value: move to the left,
-- positive value: move to the right.

-- priority:

-- visual overlapping priority of thin sprites:
-- compositing reads data from external RAM sequentially.
-- first are placed data from the lowest RAM address
-- then they may be overwritten with another data
-- which are read after,
-- so higher memory addresses have higher priority.
 
-- by looking at original position of the bitmap
-- on the screen (when offset=0) then
-- lowest priority:  left side of the screen
-- highest priority: right side of the screen

-- 2 thin sprites can easily join and move together by writing
-- both offsets with equal 16-bit value
-- in a single 32-bit CPU write cycle.

-- offsets refer to a move in bytes, but currently only 32-bit
-- moves are implemented (lowest 2 bits of offset ignored)
-- so move will snap to a full 4-byte position

-- TODO: increase x-offset resolution using finer grain
-- 16-bit or 8-bit compositing. (looking for some efficient
-- way to do that, please contribute :-)

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

entity videofifo is
    generic (
        C_synclen: integer := 3; -- bits in cpu-to-pixel clock synchronizer
        -- (0: disable rewind and be ordinary sequential fifo)
        -- (>0: fifo will be loaded from RAM in full steps
        -- each full step is a count of 32-bit words.
        -- rewind signal can again output data stream from fifo
        -- starting from last full step it was filled from RAM,
        -- saves RAM bandwidth during text mode or bitmap vertial line doubling
        -- set it to 17*10 = 170 for compositing 640x480 with 17 word length
        C_step: integer := 0;
        -- postpone step fetch by N 32-bit words
        -- set it to 1-3 for bandwidth saving with soft scroll
        -- set it a few words than step for when compositing e.g. 17*10-4=166
        C_postpone_step: integer := 0;
        -- define the length of horizontal compositing slice (words)
        -- word count includes offset word and following bitmap data
        -- this option should be used together with C_width of sufficient
        -- size for 2 scan lines and C_postpone_step for 1 scan line
        -- 0 to disable, 17 is standard value
        C_compositing_length: integer := 0;
        -- defines the length of the FIFO: 4 * 2^C_length bytes
        -- default value of 4: length = 16 * 32 bits = 16 * 4 bytes = 64 bytes
        C_width: integer := 4 -- bits width of fifo address
    );
    port (
	clk, clk_pixel: in std_logic;
	addr_strobe: out std_logic;
	addr_out: out std_logic_vector(29 downto 2);
	base_addr: in std_logic_vector(29 downto 2);
	-- debug_rd_addr: out std_logic_vector(29 downto 2);
	data_ready: in std_logic;
	data_in: in std_logic_vector(31 downto 0);
	data_out: out std_logic_vector(31 downto 0);
	start: in std_logic; -- rising edge sensitive will reset fifo RAM to base address, value 1 allows start of reading
	frame: out std_logic; -- output CPU clock synchronous start edge detection (1 CPU-clock wide pulse for FB interrupt)
	rewind: in std_logic := '0'; -- rising edge sets output data pointer to the start of last full step
	-- rewind is useful to re-read text line, saving RAM bandwidth.
	-- rewind is possible at any time but is be normally issued
	-- during H-blank period - connected to hsync signal.
	fetch_next: in std_logic -- edge sensitive fetch next value (current data consumed)
    );
end videofifo;

architecture behavioral of videofifo is
    -- Types
    constant C_length: integer := 2**C_width; -- 1 sll C_width - shift logical left

    -- Internal state
    signal R_sram_addr: std_logic_vector(29 downto 2);
    signal R_pixbuf_rd_addr, R_pixbuf_wr_addr, S_pixbuf_wr_addr_next: std_logic_vector(C_width-1 downto 0);
    signal R_pixbuf_out_addr: std_logic_vector(C_width-1 downto 0);
    signal S_pixbuf_out_mem_addr: std_logic_vector(C_width-1 downto 0);
    signal S_pixbuf_in_mem_addr: std_logic_vector(C_width-1 downto 0);
    signal R_delay_fetch: integer range 0 to 2*C_step;
    signal S_bram_write: std_logic;
    signal S_need_refill: std_logic;
    signal S_fetch_compositing_offset: std_logic := '0';
    signal S_compositing_erase: std_logic := '0';
    signal R_compositing_active_offset: std_logic_vector(C_width-1 downto 0) := (others => '0');
    signal R_compositing_second_offset: std_logic_vector(C_width-1 downto 0) := (others => '0');
    signal R_compositing_countdown: integer range 0 to C_compositing_length := 0;
    -- signal need_refill: boolean;
    signal toggle_read_complete: std_logic;
    signal clksync, startsync, rewindsync: std_logic_vector(C_synclen-1 downto 0);
    -- clean start: '1' will reset fifo to its base address
    --              '0' will allow fifo normal sequential operation
    signal clean_start, clean_fetch: std_logic;
    -- clean rewind: '1' will rewind fifo to its last full step
    --               '0' will allow fifo normal sequential operation
    signal clean_rewind: std_logic;
begin
    S_pixbuf_wr_addr_next <= R_pixbuf_wr_addr + 1;

    -- clk-to-clk_pixel synchronizer:
    -- clk_pixel rising edge is detected using shift register
    -- edge detection happens after delay (clk * synclen)
    -- then rd is set high for one clk cycle
    -- intiating fetch of new data from RAM fifo
    process(clk_pixel)
    begin
      if rising_edge(clk_pixel) and fetch_next = '1' then
        toggle_read_complete <= not toggle_read_complete;
      end if;
    end process;

    -- start signal which resets fifo
    -- can be clock asynchronous and may
    -- lead to unclean or partial fifo reset which results
    -- in early fetch and visually whole picure flickers
    -- by shifting one byte left
    -- input start is passed it through a flip-flop
    -- it generates clean_start and we got rid of the flicker
    process(clk)
    begin
      if rising_edge(clk) then
        -- synchronize clk_pixel to clk with shift register
        clksync <= clksync(C_synclen-2 downto 0) & toggle_read_complete;
        startsync <= startsync(C_synclen-2 downto 0) & start;
        rewindsync <= rewindsync(C_synclen-2 downto 0) & rewind;
      end if;
    end process;

    -- XOR: difference in 2 consecutive clksync values
    -- create a short pulse that lasts one CPU clk period.
    -- This signal is request to fetch new data
    clean_fetch <= clksync(C_synclen-2) xor clksync(C_synclen-1);

    -- clean start produced from a delay thru clock synchronous shift register
    -- clean_start <= startsync(C_synclen-1); -- level
    clean_start <= startsync(C_synclen-2) and not startsync(C_synclen-1); -- rising edge

    -- at start of frame generate pulse of 1 CPU clock
    -- rising edge detection of start signal
    -- useful for VSYNC frame interrupt
    frame <= clean_start; -- must be rising edge for CPU interrupt, not level

    -- Refill the circular buffer with fresh data from SRAM-a
    -- h-compositing of thin sprites on the fly
    process(clk)
    begin
        if rising_edge(clk) then
          if clean_start = '1' then
            R_sram_addr <= base_addr;
            R_pixbuf_wr_addr <= (others => '0');
            R_compositing_countdown <= 0;
          else
            if data_ready = '1' and S_need_refill = '1' then -- BRAM must use this
	    -- if data_ready = '1' then -- may work with SDRAM?
              if C_compositing_length > 0 then
                -- compositing enabled
                if S_fetch_compositing_offset = '1' then
                  R_compositing_countdown <= C_compositing_length - 1; -- init countdown to fetch bitmap
                  -- at this point we will fetch a 32-bit word that
                  -- contains 2 offsets for following 2 thin sprites
                  -- each offset is max 16 bits long
                  -- intented to point to a 8-bit (byte) address.
                  -- lower 2 bits are currently ignored,
                  -- which means that compositing movement will snap to
                  -- a full 32-bit word (4 bytes = 4 pixels of 8bpp)
                  -- (reserved for future enhancement of h-resolution)

                  -- offest for first sprite (active offset):
                  R_compositing_active_offset <= data_in(C_width+1 downto 2);
                  -- offset for second sprite (later it will be copied to active offset):
                  R_compositing_second_offset <= data_in(C_width+17 downto 18);
                else
                  R_compositing_countdown <= R_compositing_countdown - 1; -- bitmap fetching countdown
                  R_pixbuf_wr_addr <= S_pixbuf_wr_addr_next; -- next sequential address to store bitmap
                  -- compositing offset will be added to this address
                end if;
                if R_compositing_countdown = C_compositing_length/2 + 1 then
                  -- when countdown reaches half of the compositing width,
                  -- copy second thin sprite offset to the active offset
                  R_compositing_active_offset <= R_compositing_second_offset;
                end if;
              else
                R_pixbuf_wr_addr <= S_pixbuf_wr_addr_next; -- no compositing
	      end if;
              R_sram_addr <= R_sram_addr + 1; -- sequential read from external RAM
            end if;
          end if;
        end if;
    end process;

    S_need_refill <= '1' when clean_start = '0' and S_pixbuf_wr_addr_next /= R_pixbuf_rd_addr else '0';
    addr_strobe <= S_need_refill;
    addr_out <= R_sram_addr;
    
    -- Dequeue pixel data from the circular buffer
    -- by incrementing R_pixbuf_rd_addr on rising edge of clk
    process(clk)
      begin
        if rising_edge(clk) then
          if clean_start = '1' then
            R_pixbuf_rd_addr <= (others => '0');  -- this will read data from RAM
            if C_step /= 0 then
              R_pixbuf_out_addr <= (others => '0'); -- this will output buffered data
              R_delay_fetch <= 2*C_step-1;
            end if;
          else
            if clean_fetch = '1' then
              if C_step = 0 then
                R_pixbuf_rd_addr <= R_pixbuf_rd_addr + 1; -- R_pixbuf_out_addr + 1 ??
              end if;
              if C_step /= 0 then
                R_pixbuf_out_addr <= R_pixbuf_out_addr + 1;
                if R_delay_fetch = 0 then
                  R_delay_fetch <= C_step - 1; -- delay fetch will actually delay C_step+1 steps
                else
                  R_delay_fetch <= R_delay_fetch - 1;
                end if;
                if R_delay_fetch = C_step - 2 - C_postpone_step then
                  -- C_step-2 will fetch at begin of new line
                  -- C_step-3 will fetch 1 word after begin of new line.
                  -- that is for soft scroll bandiwdth saving.
                  -- old line consumed, new line currently displayed
                  -- rd_addr is also rewind point,
                  -- incrementing it will discard old data from fifo
                  R_pixbuf_rd_addr <= R_pixbuf_rd_addr + C_step; -- R_pixbuf_out_addr + 1 ??
                end if;
              end if;
	    end if;
            if C_step /= 0 then
              if clean_rewind = '1' then
                R_pixbuf_out_addr <= R_pixbuf_rd_addr; -- R_pixbuf_rd_addr-1 ??
                R_delay_fetch <= 2 * C_step - 1;
                -- delay fetch will actually delay C_step+1 steps
                -- we should be allowed to rewind after we fetch complete line
                -- and fifo pointer jumps to next line
                -- take care not to discard old data immediately after we jump
	      end if;
            end if;
          end if;
        end if;
      end process;


    we_no_compositing: if C_compositing_length = 0 generate
      -- S_compositing_erase <= '0'; -- never erase (allows rewind to used data)
      S_bram_write <= data_ready and S_need_refill and not clean_start;
      -- writing to buffer sequentially
      S_pixbuf_in_mem_addr <= R_pixbuf_wr_addr;
    end generate;

    -- writing to line memory
    we_with_compositing: if C_compositing_length /= 0 generate
      S_fetch_compositing_offset <= '1' when R_compositing_countdown = 0 else '0';
      -- compositing must erase stale data after use
      -- needs clean memory for compositing fresh data
      -- (erasing is done when clean_fetch signal is detected)
      -- rewind can not work together with compositing (data erased)
      S_compositing_erase <= clean_fetch; -- erase immediately after use
      S_bram_write <= data_ready and S_need_refill and (not S_fetch_compositing_offset) and (not clean_start);
      -- writing to buffer randomly (compositing)
      S_pixbuf_in_mem_addr <= R_pixbuf_wr_addr + R_compositing_active_offset;
    end generate;

    -- reading from line memory
    rewind_disabled: if C_step = 0 generate
      S_pixbuf_out_mem_addr <= R_pixbuf_rd_addr;
    end generate;
    rewind_enabled: if C_step /= 0 generate
      clean_rewind <= rewindsync(C_synclen-2) and not rewindsync(C_synclen-1); -- rising edge
      S_pixbuf_out_mem_addr <= R_pixbuf_out_addr;
    end generate;

    linememory: entity work.bram_true2p_1clk
    generic map (
        dual_port => True, -- one port takes data from RAM, other port outputs to video
        data_width => 32, -- full cpu bus width
        addr_width => C_width
    )
    port map (
        clk => clk,
        we_a => S_bram_write,
        we_b => S_compositing_erase, -- compositing must erase after use (rewind won't work with compositing)
        addr_a => S_pixbuf_in_mem_addr,
        addr_b => S_pixbuf_out_mem_addr,
        data_in_a => data_in,
        data_in_b => (others => '0'), -- erase value for compositing
        data_out_a => open,
        data_out_b => data_out
    );
end;
