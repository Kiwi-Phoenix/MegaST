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
	input        wprot
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

endmodule
