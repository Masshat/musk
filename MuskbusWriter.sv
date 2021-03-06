module MuskbusWriter (
	input reset,
	input clk,
	/* verilator lint_off UNUSED */
	Muskbus.Top bus,
	/* verilator lint_on UNUSED */
	input logic reqcyc,
	input logic [63:0] addr,
	output logic respcyc,
	input logic [0:64*8-1] data
);

	enum { idle, writing } state_ff, new_state_cb;
	int offset_ff;
	logic got_first_ack_ff;

	always_ff @ (posedge clk) begin
		if (reset) begin
			state_ff <= idle;
			offset_ff <= 0;
			got_first_ack_ff <= 0;
		end else begin
			state_ff <= new_state_cb;

			if (got_first_ack_ff) begin
				offset_ff <= offset_ff + 64;
			end

			if (bus.reqack) got_first_ack_ff <= 1;

			if (new_state_cb == idle) begin
				offset_ff <= 0;
				got_first_ack_ff <= 0;
			end
		end
	end

	always_comb begin
		new_state_cb = state_ff;
		unique case(state_ff)
			idle : if (reqcyc) new_state_cb = writing;
			writing : if (offset_ff == 64 * 8) new_state_cb = idle;
		endcase

		bus.bid = 0;
		bus.reqcyc = 0;
		bus.reqtag = 0;
		bus.req = 0;
		bus.respack = 0;

		respcyc = 0;

		if (state_ff == writing) bus.bid = 1;

		if (state_ff == writing && !got_first_ack_ff) begin
			bus.reqcyc = 1;
			bus.reqtag = MUSKBUS::WRITE_MEM_TAG;
			bus.req = addr;
		end

		if (state_ff == writing && got_first_ack_ff && offset_ff < 64 * 8) begin
			bus.reqcyc = 1;
			bus.reqtag = MUSKBUS::WRITE_MEM_TAG;
			bus.req = data[offset_ff +: 64];
		end

		if (offset_ff == 64 * 8) begin
			respcyc = 1;
		end
	end

endmodule
