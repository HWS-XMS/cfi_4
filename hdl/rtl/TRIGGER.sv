`timescale 1ns/1ps

module TRIGGER (
    input   logic       clk,
    input   logic       rst,
    input   logic       arm,
    input   logic       single,
    input   logic       rising_edge,
    input   logic       signal_in,
    output  logic       trigger_out,
    output  logic       armed
);

    logic signal_in_synchronized;
    SYNCHRONIZER synchronizer (
        .clk        (clk),
        .rst        (rst),
        .signal_in  (signal_in),
        .signal_out (signal_in_synchronized)
    );

    logic signal_in_bb;
    logic signal_in_b;
    always_ff @(posedge clk) begin
        if (rst) begin
            signal_in_b     <= 'b0;
            signal_in_bb    <= 'b0;
            armed           <= 'b0;
            
        end else begin
            signal_in_b     <= signal_in_synchronized;
            signal_in_bb    <= signal_in_b;
            
            if (arm) begin
                armed <= 'b1;
            end else begin
                if (trigger_out) begin
                    if (single) begin
                        armed <= 'b0;
                    end
                end
            end
        end
    end
    assign trigger_out = armed ? (rising_edge & (~signal_in_bb & signal_in_b)) | (~rising_edge & (signal_in_bb & ~signal_in_b)) : 'b0;

endmodule
