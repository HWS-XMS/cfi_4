`timescale 1ns / 1ps

//
// Asynchronous set/reset latch, reset dominant.
//
// Deliberately a latch and not a flip flop. It catches the trigger pulse for
// OFFSET, and that pulse is generated in the pll_clk1 domain while OFFSET runs
// on the target clock. Whenever the target clock is slower than pll_clk1 a
// clocked capture would miss the pulse entirely; the latch cannot.
//
// A latch is a combinational loop by construction, so Verilator's UNOPTFLAT is
// expected here and is waived locally rather than globally.
//
/* verilator lint_off UNOPTFLAT */
module SR_LATCH (
    input   logic set,
    input   logic reset,
    output  logic q
);

    always_latch begin
        if (reset)      q = 1'b0;
        else if (set)   q = 1'b1;
    end

endmodule
/* verilator lint_on UNOPTFLAT */
