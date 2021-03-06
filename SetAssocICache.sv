/* vim: tabstop=4:softtabstop=4:shiftwidth=4:noexpandtab
 *
 * N-way set associative cache
 * ---------------------------
 * Block size is 64 bytes.
 * 'addr' can be decomposed to
 * tag[63:indexBits+6], index[indexBits+5:6], block offset[5:0]
 * 
 * Design:
 * Each way in N-way set associative cache is composed of 2 SRAM modules:
 * (1) For state and tag
 * (2) For data
 */

module SetAssocICache (
	input reset,
	input clk,
	/* verilator lint_off UNUSED */
	/* verilator lint_off UNDRIVEN */
	Muskbus.Top bus,
	/* verilator lint_on UNDRIVEN */
	/* verilator lint_on UNUSED */
	input logic reqcyc,
	/* verilator lint_off UNUSED */
	input logic [63:0] addr,
	/*verilator lint_on UNUSED */
	output logic respcyc,
	output logic [0:64*8-1] read_data
);
	parameter N = 4
	, indexBits = 9; // ** Keep <= 9
	                 // DESIGNED to avoid access delays

	`define tagBits (64-indexBits-6)
	`define tagr(x) (readMdata[x][`tagBits-1:0])
	`define tagw(x) writeMdata[x][`tagBits-1:0]
	`define stateBits (2)
	`define validr(x) (readMdata[x][`tagBits:`tagBits])
	`define validw(x) writeMdata[x][`tagBits:`tagBits]
	`define dirtyr(x) (readMdata[x][`tagBits+1:`tagBits+1])
	`define dirtyw(x) writeMdata[x][`tagBits+1:`tagBits+1]
	`define mdataBits `tagBits+`stateBits

	logic [`tagBits-1:0] reqTag;
	assign reqTag = addr[63:indexBits+6];
	logic [indexBits-1:0] index;
	assign index = addr[indexBits+5:6];
	//logic [2:0] offset;
	//assign offset = addr[5:3];
	logic [63:0] addr_aligned;
	assign addr_aligned = {reqTag, index, 6'h0};

	// data
	logic [64*8-1:0] readData[N];
	logic [64*8-1:0] writeData[N];
	logic [7:0] writeDEnable[N];

	generate
		genvar cgi;
		for(cgi = 0; cgi < N; cgi += 1) begin
			SRAM #(.logDepth(indexBits)) cache(clk, reset, index,
				readData[cgi], index, writeData[cgi], writeDEnable[cgi]);
		end
	endgenerate

	// state and tag (metadata)
	logic [`mdataBits-1:0] readMdata[N];
	logic [`mdataBits-1:0] writeMdata[N];
	logic writeMdEnable[N];
	int rrcounter, rrcounterCb;
	logic respcycCb;

	generate
		genvar mgi;
		for(mgi = 0; mgi < N; mgi += 1) begin
			SRAM #(.width(`mdataBits), .logDepth(indexBits),
				.wordsize(`mdataBits)) mdata(clk, reset, index,
				readMdata[mgi], index, writeMdata[mgi], writeMdEnable[mgi]);
		end
	endgenerate

	// interface with memory

	logic memrdreqcyc;
	logic [63:0] memrdaddr;
	logic memrdrespcyc;
	logic [0:64*8-1] memrddata;

	MuskbusReader memread(reset, clk, bus, memrdreqcyc, memrdaddr,
		memrdrespcyc, memrddata);

	// the cache hardware
	enum {idle, readMem, readCache, cchWrDelay} stateFf, stateCb;

	always_ff @ (posedge clk) begin
		if(reset) begin
			stateFf <= idle;
			rrcounter <= 0;
		end else begin
			stateFf <= stateCb;
			respcyc <= respcycCb;
			rrcounter <= rrcounterCb;
			if(stateFf == idle && reqcyc) begin
				stateFf <= readCache;
			end
		end
	end

	function automatic int cacheBlock();
		int chi;
		for(chi = 0; chi < N; chi += 1) begin
			if(reqTag == `tagr(chi) && `validr(chi)) begin
				return chi;
			end
		end
		return chi;
	endfunction

	function automatic int freeBlock();
		int fbi;
		for(fbi = 0; fbi < N; fbi += 1) begin
			if(!`validr(fbi)) begin
				return fbi;
			end
		end
		return fbi;
	endfunction

	function automatic int evictBlock();
		return rrcounter % N;
	endfunction

	function automatic void reqMemRead(int afb,
		/* verilator lint_off UNUSED */
		int aeb
		/* verilator lint_on UNUSED */
	);
		if(afb >= N) begin
			`validw(aeb) = 1'b0;
			writeMdEnable[aeb] = 1'b1;
			stateCb = cchWrDelay;
		end else begin
			memrdreqcyc = 1'b1;
			memrdaddr = addr_aligned;
			stateCb = readMem;
		end
	endfunction

	always_comb begin
		int si;
		int cb = cacheBlock();
		int fb = freeBlock();
		int eb = evictBlock();

		stateCb = stateFf;
		rrcounterCb = rrcounter;

		// default values
		for(si = 0; si < N; si += 1) begin
			writeMdata[si] = readMdata[si];
			writeDEnable[si] = 8'h0;
			writeMdEnable[si] = 1'b0;
		end

		unique case(stateFf)
			readCache: begin
				if(cb < N) begin
					read_data = readData[cb];
					if(respcyc == 1'b0) begin
						respcycCb = 1'b1;
					end
					else begin
						respcycCb = 1'b0;
						stateCb = idle;
					end
				end
				else begin
					reqMemRead(fb, eb);
				end
			end
			readMem: begin
				if(memrdrespcyc) begin
					writeData[fb] = memrddata;
					writeDEnable[fb] = 8'b11111111;
					`tagw(fb) = reqTag;
					`validw(fb) = 1'b1;
					`dirtyw(fb) = 1'b0;
					memrdreqcyc = 1'b0;
					writeMdEnable[fb] = 1'b1;
					stateCb = cchWrDelay;
				end
			end
			cchWrDelay: begin
				if(reqcyc) begin
					stateCb = readCache;
				end
			end
		endcase
		if(reset) begin
			memrdreqcyc = 1'b0;
		end

		
	end

endmodule

