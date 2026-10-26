`timescale 1ns/1ps

module SYNCHRONIZER (
    input  logic clk,
    input  logic rst,
    input  logic signal_in,
    output logic signal_out
);

    logic signal_in_sampled;
    
    always_ff @(posedge clk) begin
        if (rst) begin
            signal_in_sampled   <= 'b0;
            signal_out          <= 'b0;
        end else begin 
            signal_in_sampled   <= signal_in;
            signal_out          <= signal_in_sampled;
        end
    end
    
endmodule
