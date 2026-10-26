`timescale 1ns/1ps

module UART_TX 
#(
    parameter  SYSTEMCLOCK                  = 100_000_000, 
    parameter  BAUDRATE                     = 250_000,
    parameter  ELEMENT_WIDTH                = 8,
    localparam CLOCK_COUNTER_WIDTH          = 32,
    localparam CLOCKS_PER_BAUD              = SYSTEMCLOCK / BAUDRATE
)(
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     tx_en,
    input  logic [ELEMENT_WIDTH-1:0] tx_data,
    output logic                     tx_line,
    output logic                     tx_ready
);
    typedef enum {
        STATE_IDLE, 
        STATE_START_BIT, 
        STATE_TRANSFER_ELEMENT,
        STATE_STOP_BIT
    } state_t;
    state_t current_state;
    
    logic [$clog2(ELEMENT_WIDTH):0]     bit_counter    = 'b0;
    logic [CLOCK_COUNTER_WIDTH:0]       clock_counter  = 'b0;
    
    logic clocks_per_baud_reached;
    assign clocks_per_baud_reached  = (clock_counter >= CLOCKS_PER_BAUD);
    assign tx_ready = (current_state == STATE_IDLE) && !tx_en;
    always_ff @(posedge clk) begin
        if (rst) begin
            current_state       <= STATE_IDLE;
            bit_counter         <= 'd0;
            clock_counter       <= 'd0;
            tx_line             <= 'b1;
            
        end else begin
            current_state       <= current_state;
            bit_counter         <= bit_counter;
            clock_counter       <= clock_counter + 1;
            tx_line             <= tx_line;
            
            case (current_state)
                STATE_IDLE: begin
                    if (tx_en) begin
                        current_state       <= STATE_START_BIT;
                        clock_counter       <= 'd0;
                        tx_line             <= 'b0;
                        bit_counter         <= 'd0;
                    end else begin
                        tx_line             <= 'b1;
                    end
                end
                
                STATE_START_BIT: begin
                    if (clocks_per_baud_reached) begin
                        current_state       <= STATE_TRANSFER_ELEMENT;
                        clock_counter       <= 'd0;
                        tx_line             <= tx_data[bit_counter];
                        bit_counter         <= bit_counter + 1;
                    end
                end
                
                STATE_TRANSFER_ELEMENT: begin
                    if (bit_counter > ELEMENT_WIDTH) begin
                        current_state       <= STATE_STOP_BIT;

                        tx_line             <= 'b1;
                        clock_counter       <= 'd0;
                    end else if(clocks_per_baud_reached) begin
                        clock_counter       <= 'd0;
                        tx_line             <= tx_data[bit_counter];
                        bit_counter         <= bit_counter + 1;
                    end
                end
                
                STATE_STOP_BIT: begin
                    if(clocks_per_baud_reached) begin
                       current_state       <= STATE_IDLE;
                    end
                end
                
            endcase
        end
    end
endmodule
