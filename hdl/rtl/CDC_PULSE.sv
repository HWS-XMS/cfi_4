`timescale 1ns / 1ps

//
// Single cycle pulse from src_clk into dst_clk, via a toggle so the pulse
// cannot be missed when dst_clk is slower than src_clk.
//
// Stands in for the reference design's cdc_pulse, which is not published in
// the ChipWhisperer HDL tree.
//
// Only for infrequent events (start, arm, clear). Pulses closer together than
// two dst_clk periods will be swallowed.
//
module CDC_PULSE (
    input  logic    rst,
    input  logic    src_clk,
    input  logic    src_pulse,
    input  logic    dst_clk,
    output logic    dst_pulse
);

    logic src_toggle;
    always_ff @(posedge src_clk) begin
        if (rst)            src_toggle <= 1'b0;
        else if (src_pulse) src_toggle <= ~src_toggle;
    end

    (* ASYNC_REG = "TRUE" *) logic [2:0] dst_sync;
    always_ff @(posedge dst_clk) begin
        if (rst) dst_sync <= 3'b0;
        else     dst_sync <= {dst_sync[1:0], src_toggle};
    end

    assign dst_pulse = dst_sync[2] ^ dst_sync[1];

endmodule
