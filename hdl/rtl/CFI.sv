`timescale 1ns / 1ps

//
// Clock fault injector: a shared target clock generator and NUM_CHANNELS
// independent glitch channels, superimposed on the one clock the DuT runs on.
//
//   pll_clk1 ─▶ target_clock_gen ─▶ target_clock ─┬─▶ GLITCH_CHANNEL[0] ─┐
//              (shared, 1 MMCM)                    ├─▶ GLITCH_CHANNEL[1] ─┤
//                                                  ⋮                      ⋮
//                                                        XOR-combined ────┴─▶ target_clock_out
//
//   target_clock_out = target_clock ^ (^ contributions)
//
// The generator and the output pin are shared because the DuT has exactly one
// clock, and two clocks from two different MMCMs would not be edge aligned.
// Everything else per channel is independent: its own phaser pair (so its own
// phase_1 / phase_2 shape), its own offset, its own arm. All channels count
// their offset from the same trigger.
//
// Each channel costs 2 MMCMs; with the shared generator that is 1 + 2*N MMCMs.
// The XC7A200T has 10, so NUM_CHANNELS = 4 (9 MMCMs) is the ceiling here. The
// XC7A100T has 6 and could carry only 2.
//
// The glitched net goes straight to the OBUF: no BUFG, no ODDR clock
// forwarding. Both have a minimum pulse width and would swallow exactly the
// narrow pulses this module exists to produce.
//
module CFI
#(
    parameter  NUM_CHANNELS     =  4,
    parameter  OFFSET_WIDTH     = 32,
    parameter  PHASE_WIDTH      = 32,

    // stable input clock (CW305 CDCE906, 50 MHz); TOP overrides these
    parameter real CLKIN_PERIOD = 20.000,

    // target clock generator: f_target = f_in * TGT_MULT / (TGT_DIVCLK * TGT_DIV)
    // VCO = f_in * TGT_MULT / TGT_DIVCLK must stay within 600..1440 MHz (50*20 = 1000)
    parameter int  TGT_DIVCLK   =  1,
    parameter real TGT_MULT     = 20.000,
    parameter real TGT_DIV      = 20.000,

    // phasers, all identical, fed with the target clock
    parameter int  PHS_DIVCLK   =  1,
    parameter real PHS_MULT     = 20.000,
    parameter real PHS_DIV      = 20.000
)(
    input  logic                                        clk,
    input  logic                                        rst,
    input  logic                                        trigger,        // shared external trigger

    input  logic [NUM_CHANNELS-1:0]                     arm,
    input  logic [NUM_CHANNELS-1:0][OFFSET_WIDTH-1:0]   offset,
    input  logic [NUM_CHANNELS-1:0][PHASE_WIDTH-1:0]    phase_1,
    input  logic [NUM_CHANNELS-1:0][PHASE_WIDTH-1:0]    phase_2,

    output logic [NUM_CHANNELS-1:0]                     armed,
    output logic [NUM_CHANNELS-1:0]                     glitch_done,
    output logic                                        cfi_configured, // all channels ready
    output logic                                        target_clock_out
);

    localparam real TARGET_PERIOD = (CLKIN_PERIOD * TGT_DIVCLK * TGT_DIV) / TGT_MULT;

    //--------------------------------------------------------------------
    // Shared target clock generator
    //--------------------------------------------------------------------
    logic target_clock_unbuffered;
    logic target_clock_feedback;
    logic target_clock_feedback_buf;
    logic target_clock_locked;
    logic target_clock;

    MMCME2_ADV #(
        .BANDWIDTH              ("OPTIMIZED"),
        .CLKIN1_PERIOD          (CLKIN_PERIOD),
        .DIVCLK_DIVIDE          (TGT_DIVCLK),
        .CLKFBOUT_MULT_F        (TGT_MULT),
        .CLKFBOUT_PHASE         (0.0),
        .CLKOUT0_DIVIDE_F       (TGT_DIV),
        .CLKOUT0_DUTY_CYCLE     (0.5),
        .CLKOUT0_PHASE          (0.0),
        .CLKOUT4_CASCADE        ("FALSE"),
        .COMPENSATION           ("ZHOLD"),
        .STARTUP_WAIT           ("FALSE"),
        .CLKFBOUT_USE_FINE_PS   ("FALSE"),
        .CLKOUT0_USE_FINE_PS    ("FALSE")
    ) target_clock_gen (
        .CLKOUT0                (target_clock_unbuffered),
        .CLKOUT0B               (),
        .CLKOUT1                (),
        .CLKOUT1B               (),
        .CLKOUT2                (),
        .CLKOUT2B               (),
        .CLKOUT3                (),
        .CLKOUT3B               (),
        .CLKOUT4                (),
        .CLKOUT5                (),
        .CLKOUT6                (),
        .CLKFBOUT               (target_clock_feedback),
        .CLKFBOUTB              (),
        .CLKFBSTOPPED           (),
        .CLKINSTOPPED           (),
        .LOCKED                 (target_clock_locked),
        .CLKIN1                 (clk),
        .CLKIN2                 (1'b0),
        .CLKINSEL               (1'b1),
        .PWRDWN                 (1'b0),
        .RST                    (rst),
        .DADDR                  (7'd0),
        .DCLK                   (1'b0),
        .DEN                    (1'b0),
        .DI                     (16'd0),
        .DWE                    (1'b0),
        .DO                     (),
        .DRDY                   (),
        .PSCLK                  (1'b0),
        .PSEN                   (1'b0),
        .PSINCDEC               (1'b0),
        .PSDONE                 (),
        .CLKFBIN                (target_clock_feedback_buf)
    );

    // ZHOLD feedback: deskew through a BUFG that mimics the output buffer delay
    BUFG target_clock_fb_buffer (
        .I                      (target_clock_feedback),
        .O                      (target_clock_feedback_buf)
    );

    BUFG target_clock_buffer (
        .I                      (target_clock_unbuffered),
        .O                      (target_clock)
    );

    //--------------------------------------------------------------------
    // Independent glitch channels
    //--------------------------------------------------------------------
    logic [NUM_CHANNELS-1:0] contribution;
    logic [NUM_CHANNELS-1:0] channel_configured;

    genvar c;
    generate
        for (c = 0; c < NUM_CHANNELS; c++) begin : channel
            GLITCH_CHANNEL #(
                .OFFSET_WIDTH   (OFFSET_WIDTH),
                .PHASE_WIDTH    (PHASE_WIDTH),
                .TARGET_PERIOD  (TARGET_PERIOD),
                .PHS_DIVCLK     (PHS_DIVCLK),
                .PHS_MULT       (PHS_MULT),
                .PHS_DIV        (PHS_DIV)
            ) ch (
                .clk                    (clk),
                .rst                    (rst),
                .target_clock           (target_clock),
                .arm                    (arm[c]),
                .keep_armed             (1'b0),         // single-shot: ARM must be re-issued per trigger
                .trigger                (trigger),
                .offset                 (offset[c]),
                .phase_1                (phase_1[c]),
                .phase_2                (phase_2[c]),
                .armed                  (armed[c]),
                .configured             (channel_configured[c]),
                .glitch_contribution    (contribution[c]),
                .glitch_done            (glitch_done[c])
            );
        end
    endgenerate

    //--------------------------------------------------------------------
    // Superimpose every channel's glitch on the one output clock
    //--------------------------------------------------------------------
    assign target_clock_out = target_clock ^ (^contribution);
    assign cfi_configured   = target_clock_locked & (&channel_configured);

endmodule
