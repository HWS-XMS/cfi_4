module OFFSET
#(
	parameter OFFSET_WIDTH 	= 32
)(
	input 	logic 							clk,
	input 	logic 							rst,
	input 	logic 							trigger,
	input 	logic [OFFSET_WIDTH-1:0] 		offset,
	output 	logic 							offset_reached
);

	logic [OFFSET_WIDTH-1:0] 		sampled_offset;
	logic [OFFSET_WIDTH-1:0] 		cycle_counter;

	typedef enum {
		STATE_IDLE,
		STATE_COUNTING
	} state_t;
	state_t current_state;
	
	assign offset_reached = (cycle_counter == sampled_offset) & (sampled_offset != 0);
    
    logic en;
    SR_LATCH latch (
		.set 	(trigger),
		.reset 	(offset_reached | rst),
		.q 		(en)
	);

	always_ff @(posedge clk) begin
		if (rst) begin
			current_state 			<= STATE_IDLE;
			sampled_offset			<= 'd0;
			cycle_counter			<= 'd0;
		end else begin
			current_state 			<= current_state;
			cycle_counter			<= cycle_counter;
			sampled_offset			<= sampled_offset;

			case (current_state)
			
				STATE_IDLE: begin
					if (en) begin
						current_state 	<= STATE_COUNTING;
						cycle_counter 	<= 'd1;
						sampled_offset	<= offset;
					end
				end

				STATE_COUNTING: begin
					cycle_counter 		<= cycle_counter + 1;
					if ((cycle_counter >= sampled_offset) & ~en) begin
						current_state 	<= STATE_IDLE;
						sampled_offset	<= 'd0;
					end
				end
			endcase
		end
	end
endmodule
