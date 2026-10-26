`timescale 1ns / 1ps

//
// One independent clock fault injection channel.
//
// A channel is a self-contained FI tool: its own phaser pair (two cascaded
// MMCME2_ADV, so phase_1 and phase_2 move independently at runtime), its own
// trigger/offset counter, its own arm state. It shares only the clean
// target_clock reference handed in from the parent, and combines into the one
// physical output clock via glitch_contribution.
//
//   target_clock ─▶ phaser_1 (phase_1) ─▶ phaser_2 (phase_2)
//                        │                     │
//                        └──── AND ────────────┘ = glitch_stream (the shape)
//
//   glitch_contribution = offset_reached ? glitch_stream : 0
//
// The parent forms target_clock_out = target_clock ^ (sum of contributions),
// so N channels superimpose N independently shaped glitches on the one clock
// the DuT runs on. Two channels with different offsets glitch two different
// cycles; that is the dual fault a single-fault countermeasure cannot survive.
//
module GLITCH_CHANNEL #(
    parameter  OFFSET_WIDTH     = 32,
    parameter  PHASE_WIDTH      = 32,

    // phaser clocking, both MMCMs identical, fed with the shared target clock
    parameter real TARGET_PERIOD = 10.000,
    parameter int  PHS_DIVCLK    =  1,
    parameter real PHS_MULT      = 10.000,
    parameter real PHS_DIV       = 10.000
)(
    input  logic                        clk,            // control clock (pll_clk1)
    input  logic                        rst,
    input  logic                        target_clock,   // shared clean target clock

    input  logic                        arm,
    input  logic                        keep_armed,
    input  logic                        trigger,        // DuT trigger, shared across channels
    input  logic [OFFSET_WIDTH-1:0]     offset,
    input  logic [PHASE_WIDTH-1:0]      phase_1,
    input  logic [PHASE_WIDTH-1:0]      phase_2,

    output logic                        armed,
    output logic                        configured,
    output logic                        glitch_contribution,
    output logic                        glitch_done
);

    //--------------------------------------------------------------------
    // Phaser 1: shifted copy of the target clock
    //--------------------------------------------------------------------
    logic phaser_1_unbuffered;
    logic phaser_1_feedback;
    logic phaser_1_feedback_buf;
    logic phaser_1_locked;
    logic phaser_1_clk;
    logic phaser_1_psen;
    logic phaser_1_psincdec;
    logic phaser_1_psdone;

    MMCME2_ADV #(
        .BANDWIDTH              ("OPTIMIZED"),
        .CLKIN1_PERIOD          (TARGET_PERIOD),
        .DIVCLK_DIVIDE          (PHS_DIVCLK),
        .CLKFBOUT_MULT_F        (PHS_MULT),
        .CLKFBOUT_PHASE         (0.0),
        .CLKOUT0_DIVIDE_F       (PHS_DIV),
        .CLKOUT0_DUTY_CYCLE     (0.5),
        .CLKOUT0_PHASE          (0.0),
        .CLKOUT4_CASCADE        ("FALSE"),
        .COMPENSATION           ("ZHOLD"),
        .STARTUP_WAIT           ("FALSE"),
        .CLKFBOUT_USE_FINE_PS   ("FALSE"),
        .CLKOUT0_USE_FINE_PS    ("TRUE")
    ) phaser_1_mmcm (
        .CLKOUT0                (phaser_1_unbuffered),
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
        .CLKFBOUT               (phaser_1_feedback),
        .CLKFBOUTB              (),
        .CLKFBSTOPPED           (),
        .CLKINSTOPPED           (),
        .LOCKED                 (phaser_1_locked),
        .CLKIN1                 (target_clock),
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
        .PSCLK                  (clk),
        .PSEN                   (phaser_1_psen),
        .PSINCDEC               (phaser_1_psincdec),
        .PSDONE                 (phaser_1_psdone),
        .CLKFBIN                (phaser_1_feedback_buf)
    );

    // ZHOLD feedback: deskew through a BUFG that mimics the output buffer delay
    BUFG phaser_1_fb_buffer (
        .I                      (phaser_1_feedback),
        .O                      (phaser_1_feedback_buf)
    );

    BUFG phaser_1_buffer (
        .I                      (phaser_1_unbuffered),
        .O                      (phaser_1_clk)
    );

    //--------------------------------------------------------------------
    // Phaser 2: cascaded on phaser 1, gives the second glitch edge
    //--------------------------------------------------------------------
    logic phaser_2_unbuffered;
    logic phaser_2_feedback;
    logic phaser_2_feedback_buf;
    logic phaser_2_locked;
    logic phaser_2_clk;
    logic phaser_2_psen;
    logic phaser_2_psincdec;
    logic phaser_2_psdone;

    MMCME2_ADV #(
        .BANDWIDTH              ("OPTIMIZED"),
        .CLKIN1_PERIOD          (TARGET_PERIOD),
        .DIVCLK_DIVIDE          (PHS_DIVCLK),
        .CLKFBOUT_MULT_F        (PHS_MULT),
        .CLKFBOUT_PHASE         (0.0),
        .CLKOUT0_DIVIDE_F       (PHS_DIV),
        .CLKOUT0_DUTY_CYCLE     (0.5),
        .CLKOUT0_PHASE          (0.0),
        .CLKOUT4_CASCADE        ("FALSE"),
        .COMPENSATION           ("ZHOLD"),
        .STARTUP_WAIT           ("FALSE"),
        .CLKFBOUT_USE_FINE_PS   ("FALSE"),
        .CLKOUT0_USE_FINE_PS    ("TRUE")
    ) phaser_2_mmcm (
        .CLKOUT0                (phaser_2_unbuffered),
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
        .CLKFBOUT               (phaser_2_feedback),
        .CLKFBOUTB              (),
        .CLKFBSTOPPED           (),
        .CLKINSTOPPED           (),
        .LOCKED                 (phaser_2_locked),
        .CLKIN1                 (phaser_1_clk),
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
        .PSCLK                  (clk),
        .PSEN                   (phaser_2_psen),
        .PSINCDEC               (phaser_2_psincdec),
        .PSDONE                 (phaser_2_psdone),
        .CLKFBIN                (phaser_2_feedback_buf)
    );

    // ZHOLD feedback: deskew through a BUFG that mimics the output buffer delay
    BUFG phaser_2_fb_buffer (
        .I                      (phaser_2_feedback),
        .O                      (phaser_2_feedback_buf)
    );

    BUFG phaser_2_buffer (
        .I                      (phaser_2_unbuffered),
        .O                      (phaser_2_clk)
    );

    //--------------------------------------------------------------------
    // Trigger and offset
    //--------------------------------------------------------------------
    logic trigger_detected;
    TRIGGER t (
        .clk            (clk),
        .rst            (rst),
        .arm            (arm),
        .single         (~keep_armed),
        .rising_edge    (1'b1),
        .signal_in      (trigger),
        .trigger_out    (trigger_detected),
        .armed          (armed)
    );

    logic offset_reached;
    OFFSET #(
        .OFFSET_WIDTH   (OFFSET_WIDTH)
    ) o (
        .clk            (target_clock),
        .rst            (rst),
        .trigger        (trigger_detected),
        .offset         (offset),
        .offset_reached (offset_reached)
    );

    //--------------------------------------------------------------------
    // Phase shift control, one FSM per phaser
    //--------------------------------------------------------------------
    typedef enum {
        STATE_IDLE,
        STATE_UPDATE,
        STATE_WAIT
    } state_t;

    logic [PHASE_WIDTH-1:0] current_phase_1;
    logic                   phaser_1_update_required;
    state_t                 current_state_phaser_1;
    assign phaser_1_update_required = (current_phase_1 != phase_1);

    always_ff @(posedge clk) begin
        if (rst) begin
            current_state_phaser_1      <= STATE_IDLE;
            phaser_1_psen               <= 'b0;
            phaser_1_psincdec           <= 'b0;
            current_phase_1             <= 'd0;

        end else begin
            current_state_phaser_1      <= current_state_phaser_1;
            phaser_1_psen               <= 'b0;
            phaser_1_psincdec           <= phaser_1_psincdec;
            current_phase_1             <= current_phase_1;

            case (current_state_phaser_1)

                STATE_IDLE: begin
                    if (phaser_1_update_required) begin
                        current_state_phaser_1  <= STATE_UPDATE;
                    end
                end

                STATE_UPDATE: begin
                    phaser_1_psen           <= 'b1;
                    phaser_1_psincdec       <= (phase_1 > current_phase_1) ? 1'b1 : 1'b0;
                    current_phase_1         <= (phase_1 > current_phase_1) ? (current_phase_1 + 1) : (current_phase_1 - 1);
                    current_state_phaser_1  <= STATE_WAIT;
                end

                STATE_WAIT: begin
                    if (phaser_1_psdone) begin
                        current_state_phaser_1  <= phaser_1_update_required ? STATE_UPDATE : STATE_IDLE;
                    end
                end

            endcase
        end
    end

    logic [PHASE_WIDTH-1:0] current_phase_2;
    logic                   phaser_2_update_required;
    state_t                 current_state_phaser_2;
    assign phaser_2_update_required = (current_phase_2 != phase_2);

    always_ff @(posedge clk) begin
        if (rst) begin
            current_state_phaser_2      <= STATE_IDLE;
            phaser_2_psen               <= 'b0;
            phaser_2_psincdec           <= 'b0;
            current_phase_2             <= 'd0;

        end else begin
            current_state_phaser_2      <= current_state_phaser_2;
            phaser_2_psen               <= 'b0;
            phaser_2_psincdec           <= phaser_2_psincdec;
            current_phase_2             <= current_phase_2;

            case (current_state_phaser_2)

                STATE_IDLE: begin
                    if (phaser_2_update_required) begin
                        current_state_phaser_2  <= STATE_UPDATE;
                    end
                end

                STATE_UPDATE: begin
                    phaser_2_psen           <= 'b1;
                    phaser_2_psincdec       <= (phase_2 > current_phase_2) ? 1'b1 : 1'b0;
                    current_phase_2         <= (phase_2 > current_phase_2) ? (current_phase_2 + 1) : (current_phase_2 - 1);
                    current_state_phaser_2  <= STATE_WAIT;
                end

                STATE_WAIT: begin
                    if (phaser_2_psdone) begin
                        current_state_phaser_2  <= phaser_2_update_required ? STATE_UPDATE : STATE_IDLE;
                    end
                end

            endcase
        end
    end

    //--------------------------------------------------------------------
    // Glitch contribution
    //--------------------------------------------------------------------
    logic glitch_stream;
    assign glitch_stream        = phaser_1_clk & phaser_2_clk;

    assign glitch_contribution  = offset_reached ? glitch_stream : 1'b0;
    assign configured           = phaser_1_locked & phaser_2_locked
                                & ~phaser_1_update_required & ~phaser_2_update_required;

    // offset_reached is a one-cycle pulse in the target_clock domain. Counting
    // it directly in the pll_clk1 domain is unreliable: both clocks are the
    // same frequency with a constant phase offset, so the sample can be missed
    // on every cycle. Cross it with a toggle synchroniser so each glitch is
    // counted exactly once.
    CDC_PULSE u_glitch_done (
        .rst        (rst),
        .src_clk    (target_clock),
        .src_pulse  (offset_reached),
        .dst_clk    (clk),
        .dst_pulse  (glitch_done)
    );

endmodule
