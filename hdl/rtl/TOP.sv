`timescale 1ns / 1ps

//
// External-target clock fault injection for the Digilent Nexys Video
// (Artix-7 XC7A200T). The FPGA generates a glitched clock and drives it out on
// a Pmod pin; the external target raises a trigger that comes back on another
// Pmod pin, and all four glitch channels count their offset from it.
//
//   host ──UART──▶ UART_RX ──▶ command FSM ──▶ CFI ──▶ target_clk_out (JA1)
//                                               ▲                         │
//                                               └──── trigger_in (JA4) ◀──┘
//
// There is no design under test on this FPGA. CFI is the whole payload: one
// shared target-clock generator plus NUM_CHANNELS independent glitch channels
// (2 MMCMs each), superimposed on the single clock that leaves the device.
//
// Follows the house UART-top pattern (see pattern_vfi / ascon HDL): UART_RX/TX
// wired with defparam, a command_t enum, a state_t FSM, and one big always_ff
// (reset block, then hold-all defaults, then case) walking multi-byte
// little-endian fields with uart_transmission_counter.
//
// Command protocol (command byte, then payload; multi-byte fields little-endian;
// `ch` is a single channel-select byte, 0 = A .. 3 = D):
//   CMD_RESET            0x00  -> zero all offsets/phases and the glitch counter
//   CMD_SET_OFFSET       0x01  + ch + 4  -> channel offset (target cycles after trigger; 0 disables)
//   CMD_SET_PHASE1       0x02  + ch + 4  -> channel phase_1 (fine steps)
//   CMD_SET_PHASE2       0x03  + ch + 4  -> channel phase_2 (fine steps)
//   CMD_ARM              0x04  + ch      -> arm channel (SINGLE-SHOT: one trigger,
//                                           one glitch, auto-disarm; re-issue to refire)
//   CMD_GET_ARMED        0x05  + ch      -> 1 byte  (channel still armed?)
//   CMD_GET_CONFIGURED   0x06            -> 1 byte  (all MMCMs locked, phases settled)
//   CMD_GET_PHASE_STEPS  0x07            -> 2 bytes (fine steps per target period)
//   CMD_GET_GLITCH_COUNT 0x08            -> 4 bytes (total glitches, all channels)
//   CMD_CLEAR_GLITCH_CNT 0x09            -> clear the glitch counter
//   CMD_IDENTIFY         0x0A            -> 1 byte  (magic, 0x5c)
//   CMD_TRIGGER          0x0B            -> soft trigger (bring-up, no external target)
//
module TOP (
    input   logic           sysclk,          // R4, 100 MHz board oscillator
    input   logic           uart_rx,         // V18  (uart_tx_in : host -> FPGA)
    output  logic           uart_tx,         // AA19 (uart_rx_out : FPGA -> host)
    input   logic           trigger_in,      // JA4 (AB18), trigger from the external target
    output  logic           target_clk_out,  // JA1 (AB22), glitched clock to the external target
    output  logic           trig_out,        // JA2 (AB21), trigger mirror for the scope
    output  logic [7:0]     led              // = glitch_count[7:0]
);

    localparam SYSTEMCLOCK   = 100_000_000;
    localparam BAUDRATE      =   1_000_000;
    localparam ELEMENT_WIDTH =           8;

    localparam NUM_CHANNELS  =  4;           // 1 shared MMCM + 4 phaser pairs = 9 of 10
    localparam OFFSET_WIDTH  = 32;
    localparam PHASE_WIDTH   = 32;

    localparam logic [7:0] IDENTIFY = 8'h5c;

    // 100 MHz in -> 50 MHz glitched target clock. VCO = 100*10/1 = 1000 MHz;
    // target = 1000/20 = 50 MHz. Phasers fed with the 50 MHz target: VCO = 1000
    // MHz, 56*PHS_DIV = 1120 fine steps/period.
    localparam real CLKIN_PERIOD = 10.000;
    localparam int  TGT_DIVCLK   =  1;
    localparam real TGT_MULT     = 10.000;
    localparam real TGT_DIV      = 20.000;
    localparam int  PHS_DIVCLK   =  1;
    localparam real PHS_MULT     = 20.000;
    localparam real PHS_DIV      = 20.000;
    localparam int  PHASE_STEPS_PER_PERIOD = int'(56.0 * PHS_DIV);

    //--------------------------------------------------------------------
    // System clock and power on reset
    //--------------------------------------------------------------------
    logic clk;
    logic sysclk_ibuf;
    IBUF  sysclk_ib (.I (sysclk), .O (sysclk_ibuf));
    BUFG  sysclk_bufg (.I (sysclk_ibuf), .O (clk));

    /* verilator lint_off PROCASSINIT */
    logic [7:0] por_counter = 8'd0;
    /* verilator lint_on PROCASSINIT */
    logic rst;
    always_ff @(posedge clk) begin
        if (por_counter != 8'hff)
            por_counter <= por_counter + 1;
    end
    assign rst = (por_counter != 8'hff);

    //--------------------------------------------------------------------
    // UART
    //--------------------------------------------------------------------
    logic [ELEMENT_WIDTH-1:0]   uart_rx_data;
    logic                       uart_rx_data_valid;
    UART_RX rx (
        .clk            (clk),
        .rst            (rst),
        .rx_line        (uart_rx),
        .rx_data        (uart_rx_data),
        .rx_data_valid  (uart_rx_data_valid)
    );
    defparam rx.SYSTEMCLOCK   = SYSTEMCLOCK;
    defparam rx.BAUDRATE      = BAUDRATE;
    defparam rx.ELEMENT_WIDTH = ELEMENT_WIDTH;

    logic                       uart_tx_en;
    logic [ELEMENT_WIDTH-1:0]   uart_tx_data;
    logic                       uart_tx_ready;
    UART_TX tx (
        .clk            (clk),
        .rst            (rst),
        .tx_en          (uart_tx_en),
        .tx_data        (uart_tx_data),
        .tx_line        (uart_tx),
        .tx_ready       (uart_tx_ready)
    );
    defparam tx.SYSTEMCLOCK   = SYSTEMCLOCK;
    defparam tx.BAUDRATE      = BAUDRATE;
    defparam tx.ELEMENT_WIDTH = ELEMENT_WIDTH;

    //--------------------------------------------------------------------
    // Clock fault injector
    //--------------------------------------------------------------------
    logic [NUM_CHANNELS-1:0][31:0]  cfi_offset;
    logic [NUM_CHANNELS-1:0][31:0]  cfi_phase_1;
    logic [NUM_CHANNELS-1:0][31:0]  cfi_phase_2;
    logic [NUM_CHANNELS-1:0]        cfi_arm;         // 1-cycle arm pulses
    logic [NUM_CHANNELS-1:0]        cfi_armed;
    logic [NUM_CHANNELS-1:0]        cfi_glitch_done;
    logic                           cfi_configured;
    logic                           soft_trigger;    // 1-cycle bring-up trigger

    CFI #(
        .NUM_CHANNELS   (NUM_CHANNELS),
        .OFFSET_WIDTH   (OFFSET_WIDTH),
        .PHASE_WIDTH    (PHASE_WIDTH),
        .CLKIN_PERIOD   (CLKIN_PERIOD),
        .TGT_DIVCLK     (TGT_DIVCLK),
        .TGT_MULT       (TGT_MULT),
        .TGT_DIV        (TGT_DIV),
        .PHS_DIVCLK     (PHS_DIVCLK),
        .PHS_MULT       (PHS_MULT),
        .PHS_DIV        (PHS_DIV)
    ) cfi (
        .clk                (clk),
        .rst                (rst),
        .trigger            (trigger_in | soft_trigger),
        .arm                (cfi_arm),
        .offset             (cfi_offset),
        .phase_1            (cfi_phase_1),
        .phase_2            (cfi_phase_2),
        .armed              (cfi_armed),
        .glitch_done        (cfi_glitch_done),
        .cfi_configured     (cfi_configured),
        .target_clock_out   (target_clk_out)
    );

    //--------------------------------------------------------------------
    // Glitch counter (sys clock domain; glitch_done is already crossed here)
    //--------------------------------------------------------------------
    logic                              glitch_clear;   // 1-cycle, from the FSM
    logic [$clog2(NUM_CHANNELS+1)-1:0] glitch_increment;
    logic [31:0]                       glitch_count;

    always_comb begin
        glitch_increment = '0;
        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            glitch_increment += cfi_glitch_done[ch];
    end

    always_ff @(posedge clk) begin
        if (rst || glitch_clear)    glitch_count <= 32'd0;
        else                        glitch_count <= glitch_count + 32'(glitch_increment);
    end

    //--------------------------------------------------------------------
    // Command FSM
    //--------------------------------------------------------------------
    typedef enum logic [7:0] {
        CMD_RESET            = 8'h00,
        CMD_SET_OFFSET       = 8'h01,
        CMD_SET_PHASE1       = 8'h02,
        CMD_SET_PHASE2       = 8'h03,
        CMD_ARM              = 8'h04,
        CMD_GET_ARMED        = 8'h05,
        CMD_GET_CONFIGURED   = 8'h06,
        CMD_GET_PHASE_STEPS  = 8'h07,
        CMD_GET_GLITCH_COUNT = 8'h08,
        CMD_CLEAR_GLITCH_CNT = 8'h09,
        CMD_IDENTIFY         = 8'h0A,
        CMD_TRIGGER          = 8'h0B
    } command_t;

    typedef enum {
        STATE_IDLE,
        STATE_SET_OFFSET,
        STATE_SET_PHASE1,
        STATE_SET_PHASE2,
        STATE_ARM,
        STATE_GET_ARMED_ADDR,
        STATE_GET_ARMED_SEND,
        STATE_GET_CONFIGURED,
        STATE_GET_PHASE_STEPS,
        STATE_GET_GLITCH_COUNT
    } state_t;
    state_t current_state;

    logic [31:0]  uart_transmission_counter;
    logic [1:0]   sel_ch;                     // channel selector, 0 = A .. 3 = D
    logic [1:0][7:0] phase_steps;
    assign phase_steps = 16'(PHASE_STEPS_PER_PERIOD);

    always_ff @(posedge clk) begin
        if (rst) begin
            current_state               <= STATE_IDLE;
            uart_tx_en                  <= 1'b0;
            uart_tx_data                <= 8'd0;
            uart_transmission_counter   <= 32'd0;
            sel_ch                      <= 2'd0;
            cfi_arm                     <= '0;
            soft_trigger                <= 1'b0;
            glitch_clear                <= 1'b0;
            for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
                cfi_offset[ch]  <= 32'd0;       // 0 = channel disabled
                cfi_phase_1[ch] <= 32'd0;
                cfi_phase_2[ch] <= 32'd0;
            end

        end else begin
            current_state               <= current_state;
            uart_tx_en                  <= 1'b0;
            uart_tx_data                <= uart_tx_data;
            uart_transmission_counter   <= uart_transmission_counter;
            sel_ch                      <= sel_ch;
            cfi_arm                     <= '0;
            soft_trigger                <= 1'b0;
            glitch_clear                <= 1'b0;

            case (current_state)

                STATE_IDLE: begin
                    if (uart_rx_data_valid) begin
                        uart_transmission_counter <= 32'd0;
                        case (uart_rx_data)
                            CMD_RESET: begin
                                glitch_clear <= 1'b1;
                                for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
                                    cfi_offset[ch]  <= 32'd0;
                                    cfi_phase_1[ch] <= 32'd0;
                                    cfi_phase_2[ch] <= 32'd0;
                                end
                            end
                            CMD_SET_OFFSET:       current_state <= STATE_SET_OFFSET;
                            CMD_SET_PHASE1:       current_state <= STATE_SET_PHASE1;
                            CMD_SET_PHASE2:       current_state <= STATE_SET_PHASE2;
                            CMD_ARM:              current_state <= STATE_ARM;
                            CMD_GET_ARMED:        current_state <= STATE_GET_ARMED_ADDR;
                            CMD_GET_CONFIGURED:   current_state <= STATE_GET_CONFIGURED;
                            CMD_GET_PHASE_STEPS:  current_state <= STATE_GET_PHASE_STEPS;
                            CMD_GET_GLITCH_COUNT: current_state <= STATE_GET_GLITCH_COUNT;
                            CMD_CLEAR_GLITCH_CNT: glitch_clear  <= 1'b1;
                            CMD_IDENTIFY: begin
                                uart_tx_data  <= IDENTIFY;
                                uart_tx_en    <= 1'b1;
                            end
                            CMD_TRIGGER:          soft_trigger  <= 1'b1;
                            default: ;
                        endcase
                    end
                end

                // byte 0 = channel; bytes 1..4 = offset (LE)
                STATE_SET_OFFSET: begin
                    if (uart_rx_data_valid) begin
                        if (uart_transmission_counter == 0)
                            sel_ch <= uart_rx_data[1:0];
                        else
                            cfi_offset[sel_ch][8*(uart_transmission_counter-1) +: 8] <= uart_rx_data;
                        if (uart_transmission_counter >= 4) current_state <= STATE_IDLE;
                        uart_transmission_counter <= uart_transmission_counter + 1;
                    end
                end

                STATE_SET_PHASE1: begin
                    if (uart_rx_data_valid) begin
                        if (uart_transmission_counter == 0)
                            sel_ch <= uart_rx_data[1:0];
                        else
                            cfi_phase_1[sel_ch][8*(uart_transmission_counter-1) +: 8] <= uart_rx_data;
                        if (uart_transmission_counter >= 4) current_state <= STATE_IDLE;
                        uart_transmission_counter <= uart_transmission_counter + 1;
                    end
                end

                STATE_SET_PHASE2: begin
                    if (uart_rx_data_valid) begin
                        if (uart_transmission_counter == 0)
                            sel_ch <= uart_rx_data[1:0];
                        else
                            cfi_phase_2[sel_ch][8*(uart_transmission_counter-1) +: 8] <= uart_rx_data;
                        if (uart_transmission_counter >= 4) current_state <= STATE_IDLE;
                        uart_transmission_counter <= uart_transmission_counter + 1;
                    end
                end

                // single channel byte, then a one-cycle arm pulse
                STATE_ARM: begin
                    if (uart_rx_data_valid) begin
                        cfi_arm[uart_rx_data[1:0]] <= 1'b1;
                        current_state              <= STATE_IDLE;
                    end
                end

                STATE_GET_ARMED_ADDR: begin
                    if (uart_rx_data_valid) begin
                        sel_ch        <= uart_rx_data[1:0];
                        current_state <= STATE_GET_ARMED_SEND;
                    end
                end

                STATE_GET_ARMED_SEND: begin
                    if (uart_tx_ready) begin
                        uart_tx_data  <= {7'b0, cfi_armed[sel_ch]};
                        uart_tx_en    <= 1'b1;
                        current_state <= STATE_IDLE;
                    end
                end

                STATE_GET_CONFIGURED: begin
                    if (uart_tx_ready) begin
                        uart_tx_data  <= {7'b0, cfi_configured};
                        uart_tx_en    <= 1'b1;
                        current_state <= STATE_IDLE;
                    end
                end

                STATE_GET_PHASE_STEPS: begin
                    if (uart_transmission_counter >= 2) begin
                        current_state <= STATE_IDLE;
                    end else if (uart_tx_ready) begin
                        uart_tx_data              <= phase_steps[uart_transmission_counter[0]];
                        uart_tx_en                <= 1'b1;
                        uart_transmission_counter <= uart_transmission_counter + 1;
                    end
                end

                STATE_GET_GLITCH_COUNT: begin
                    if (uart_transmission_counter >= 4) begin
                        current_state <= STATE_IDLE;
                    end else if (uart_tx_ready) begin
                        uart_tx_data              <= glitch_count[8*uart_transmission_counter[1:0] +: 8];
                        uart_tx_en                <= 1'b1;
                        uart_transmission_counter <= uart_transmission_counter + 1;
                    end
                end

                default: current_state <= STATE_IDLE;

            endcase
        end
    end

    //--------------------------------------------------------------------
    // Outputs
    //--------------------------------------------------------------------
    assign trig_out = trigger_in;       // scope mirror
    assign led      = glitch_count[7:0];

endmodule
