// WD1772 for a real floppy drive: WF1772IP (CORE/vhdl/floppy/wf1772ip, converted to a clock enable)
// behind the CPU interface of the MiSTer fdc1772.sv (cpu_sel/addr/rw/din/dout, irq, drq).
//
// * The IP runs on clk_32 with a clock enable at half rate (its 16 MHz timing).
// * The IP samples its bus only on enabled edges. The DMA chip selects the FDC for a data byte only
//   until the next 8 MHz enable (dma.v, fdc_dma_sel), which can be a single clk_32 cycle, so a select
//   is stretched by 3 cycles with the address, direction and data held: every access spans at least
//   two enabled edges. Read data is a combinational multiplexer in the IP, valid during the select.
// * Drive side: all signals active high; rdata is the filtered RDATA level from m65_floppy_port.vhd.
//
// This machine is based on AtariST_MiSTer
// Powered by MiSTer2MEGA65
// MEGA65 port done by Chris Freeman in 2026 and licensed under GPL v3

module wd1772_m65 (
	input        clk_32,
	input        reset,

	input        cpu_sel,
	input  [1:0] cpu_addr,
	input        cpu_rw,
	input  [7:0] cpu_din,
	output [7:0] cpu_dout,
	output       irq,
	output       drq,

	output       motor,
	output       step,
	output       dir_in,       // 1 = step in (towards higher tracks)
	output       wgate,
	output       wdata,
	input        rdata,
	input        index,
	input        track0,
	input        wprot,
	input        side,         // 1 = side 1 (only for the command log)

	// debugging (JTAG probe in mega65.vhd): log of the last 256 commands, entry dbg_idx, see below
	input  [7:0] dbg_idx,
	output [55:0] dbg_entry,
	output [15:0] dbg_count     // number of commands logged so far
);

reg       ce = 1'b0;
reg [1:0] hold = 2'd0;
reg [1:0] addr_l;
reg       rw_l;
reg [7:0] din_l;

always @(posedge clk_32) begin
	ce <= ~ce;
	if (cpu_sel) begin
		hold   <= 2'd3;
		addr_l <= cpu_addr;
		rw_l   <= cpu_rw;
		din_l  <= cpu_din;
	end else if (hold != 2'd0)
		hold <= hold - 2'd1;
end

wire       cs   = cpu_sel | (hold != 2'd0);
wire [1:0] addr = cpu_sel ? cpu_addr : addr_l;
wire       rw   = cpu_sel ? cpu_rw   : rw_l;
wire [7:0] din  = cpu_sel ? cpu_din  : din_l;

WF1772IP_TOP_SOC fdc (
	.CLK      ( clk_32    ),
	.CE       ( ce        ),
	.RESETn   ( ~reset    ),
	.CSn      ( ~cs       ),
	.RWn      ( rw        ),
	.A1       ( addr[1]   ),
	.A0       ( addr[0]   ),
	.DATA_IN  ( din       ),
	.DATA_OUT ( cpu_dout  ),
	.DATA_EN  (           ),
	.RDn      ( ~rdata    ),
	.TR00n    ( ~track0   ),
	.IPn      ( ~index    ),
	.WPRTn    ( ~wprot    ),
	.DDEn     ( 1'b0      ),   // MFM (double density)
	.HDTYPE   ( 1'b0      ),   // DD timing
	.MO       ( motor     ),
	.WG       ( wgate     ),
	.WD       ( wdata     ),
	.STEP     ( step      ),
	.DIRC     ( dir_in    ),
	.DRQ      ( drq       ),
	.INTRQ    ( irq       )
);

// Command log for the JTAG probe. An entry is written when a command ends (INTRQ) and updated with the
// first status the CPU reads after it. Entry bits: 7..0 command, 15..8 track (shadow of the track
// register at the start), 23..16 data register, 31..24 sector register, 39..32 status read by the CPU
// (FF: none yet), 49..40 bytes read by DMA, 50 side, 55..51 0.
reg  [55:0] log_mem [0:255];
reg  [15:0] log_cnt = 16'd0;
reg  [55:0] log_cur;
reg   [7:0] log_last;
reg         log_wait = 1'b0;
reg   [7:0] sh_trk = 8'd0, sh_data = 8'd0, sh_sec = 8'd0, sh_cmd = 8'd0;
reg   [9:0] sh_dma = 10'd0;
reg         sh_side = 1'b0, sh_dir_in = 1'b1;
reg         sel_d = 1'b0, sel_dd = 1'b0, irq_d = 1'b0;

assign dbg_entry = log_mem[dbg_idx];
assign dbg_count = log_cnt;

// one write port: a new entry at the end of a command, or the status of the last entry
wire        log_new  = irq & ~irq_d & ~reset;
wire        log_st   = sel_d & ~sel_dd & rw_l & addr_l == 2'd0 & log_wait & ~reset;
wire [55:0] log_ent  = { 5'd0, sh_side, sh_dma, 8'hFF, sh_sec, sh_data, sh_trk, sh_cmd };

always @(posedge clk_32)
	if (log_new)     log_mem[log_cnt[7:0]] <= log_ent;
	else if (log_st) log_mem[log_last]     <= { log_cur[55:40], cpu_dout, log_cur[31:0] };

always @(posedge clk_32) begin
	sel_d  <= cpu_sel;
	sel_dd <= sel_d;
	irq_d  <= irq;
	if (reset) begin
		log_wait <= 1'b0;
	end else begin
		// CPU and DMA accesses: the IP keeps address and data for 3 cycles (hold), read data one cycle later
		if (cpu_sel & ~sel_d & ~cpu_rw) case (cpu_addr)
			2'd0: begin sh_cmd <= cpu_din; sh_dma <= 10'd0; sh_side <= side; log_wait <= 1'b0;
			            if (cpu_din[7:5] == 3'b010) sh_dir_in <= 1'b1;        // step in
			            if (cpu_din[7:5] == 3'b011) sh_dir_in <= 1'b0;        // step out
			      end
			2'd1: sh_trk  <= cpu_din;
			2'd2: sh_sec  <= cpu_din;
			2'd3: sh_data <= cpu_din;
		endcase
		if (cpu_sel & ~sel_d & cpu_rw & cpu_addr == 2'd3 & ~&sh_dma) sh_dma <= sh_dma + 10'd1;
		if (log_st) log_wait <= 1'b0;
		// end of a command: log it, then update the track shadow like the WD1772 does
		if (log_new) begin
			log_cur  <= log_ent;
			log_last <= log_cnt[7:0];
			log_cnt  <= log_cnt + 16'd1;
			log_wait <= 1'b1;
			if (sh_cmd[7:4] == 4'h0) sh_trk <= 8'd0;                       // restore
			else if (sh_cmd[7:4] == 4'h1) sh_trk <= sh_data;               // seek
			else if (~sh_cmd[7] & sh_cmd[4]) begin                         // step with update
				if (sh_cmd[7:5] == 3'b010 || (sh_cmd[7:5] == 3'b001 && sh_dir_in)) sh_trk <= sh_trk + 8'd1;
				else sh_trk <= sh_trk - 8'd1;
			end
		end
	end
end

endmodule
