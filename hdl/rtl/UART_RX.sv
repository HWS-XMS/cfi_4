`timescale 1ns/1ps

module UART_RX
  #(
    parameter  ELEMENT_WIDTH     =           8,
    parameter  BAUDRATE          =     250_000,
    parameter  SYSTEMCLOCK       = 100_000_000,
    localparam LB_DATA_WIDTH     = $clog2(ELEMENT_WIDTH),
    localparam PULSE_WIDTH       = SYSTEMCLOCK / BAUDRATE,
    localparam LB_PULSE_WIDTH    = $clog2(PULSE_WIDTH),
    localparam HALF_PULSE_WIDTH  = PULSE_WIDTH / 2)
   (
      input    logic                      clk,
      input    logic                      rst,
      input    logic                      rx_line,
      output   logic [ELEMENT_WIDTH-1:0]  rx_data,
      output   logic                      rx_data_valid
   );

   function majority5(input [4:0] val);
      case(val)
        5'b00000: majority5 = 0;
        5'b00001: majority5 = 0;
        5'b00010: majority5 = 0;
        5'b00100: majority5 = 0;
        5'b01000: majority5 = 0;
        5'b10000: majority5 = 0;
        5'b00011: majority5 = 0;
        5'b00101: majority5 = 0;
        5'b01001: majority5 = 0;
        5'b10001: majority5 = 0;
        5'b00110: majority5 = 0;
        5'b01010: majority5 = 0;
        5'b10010: majority5 = 0;
        5'b01100: majority5 = 0;
        5'b10100: majority5 = 0;
        5'b11000: majority5 = 0;
        default:  majority5 = 1;
      endcase
   endfunction

   
   
   logic [1:0] sampling_cnt;
   logic [4:0] sig_q;
   logic       sig_r;

   always_ff @(posedge clk) begin
      if(rst) begin
         sampling_cnt <= 0;
         sig_q        <= 5'b11111;
         sig_r        <= 1;
      end
      else begin
         if(sampling_cnt == 0) begin
            sig_q     <= {rx_line, sig_q[4:1]};
         end
         sig_r        <= majority5(sig_q);
         sampling_cnt <= sampling_cnt + 1;
      end
   end

   
   
   typedef enum {
      STATE_DATA,
      STATE_STOP,
      STATE_WAIT
   } state_t;
   state_t state;

   logic [ELEMENT_WIDTH-1:0]data_tmp_r;
   logic [LB_DATA_WIDTH:0]  data_cnt;
   logic [LB_PULSE_WIDTH:0] clk_cnt;
   logic                    rx_done;

   always_ff @(posedge clk) begin
      if(rst) begin
         state      <= STATE_WAIT;
         data_tmp_r <= 0;
         data_cnt   <= 0;
         clk_cnt    <= 0;
      end
      else begin

         
         
         case(state)

           STATE_DATA: begin
              if(clk_cnt > 0) begin
                 clk_cnt <= clk_cnt - 1;
              end else begin
                 data_tmp_r <= {sig_r, data_tmp_r[ELEMENT_WIDTH-1:1]};
                 clk_cnt    <= PULSE_WIDTH;
                 if(data_cnt >= ELEMENT_WIDTH-1) begin
                    state <= STATE_STOP;
                 end else begin
                    data_cnt <= data_cnt + 1;
                 end
              end
           end

           STATE_STOP: begin
              if(clk_cnt > 0) begin
                 clk_cnt <= clk_cnt - 1;
              end else if(sig_r) begin
                 state <= STATE_WAIT;
              end
           end

           STATE_WAIT: begin
              if(sig_r == 0) begin
                 clk_cnt  <= PULSE_WIDTH + HALF_PULSE_WIDTH;
                 data_cnt <= 0;
                 state    <= STATE_DATA;
              end
           end

           default: begin
              state <= STATE_WAIT;
           end
         endcase
      end
   end

   assign rx_done = (state == STATE_STOP) && (clk_cnt == 0);

   always_ff @(posedge clk) begin
      if(rst) begin
         rx_data        <= 0;
         rx_data_valid  <= 0;
      end else if(rx_done && !rx_data_valid) begin
         rx_data_valid  <= 1;
         rx_data        <= data_tmp_r;
      end else if(rx_data_valid) begin
         rx_data_valid  <= 0;
      end
   end

endmodule
