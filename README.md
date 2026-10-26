# cfi_4

Nexys Video Multiple-CFI project. Injects up to four independent clock faults.

The FPGA generates a glitched clock out on Pmod JA1 and takes a trigger in on
JA4. There is no design under test on the FPGA. Four channels (A-D) each place
one glitch of their own shape at their own offset, all from the same trigger.
Each channel uses two MMCMs plus one shared target-clock generator, `1 + 2*4 = 9`
of the XC7A200T's 10. Channels are single-shot: `ARM` is re-issued per trigger.

```
 host ──UART──▶ UART_RX ──▶ command FSM ──▶ CFI ──▶ target_clk_out (JA1) ──▶ target
                                             ▲                                  │
                                             └──────── trigger_in (JA4) ◀───────┘
```

## Board and pins (Nexys Video, XC7A200T-1SBG484C)

| signal           | pin  | note                                     |
|------------------|------|------------------------------------------|
| `sysclk`         | R4   | 100 MHz board oscillator                 |
| `uart_rx`        | V18  | host → FPGA                              |
| `uart_tx`        | AA19 | FPGA → host                              |
| `target_clk_out` | AB22 | JA1, glitched clock to the target        |
| `trig_out`       | AB21 | JA2, trigger mirror for the scope        |
| `trigger_in`     | AB18 | JA4, trigger from the target (PULLDOWN)  |
| `led[7:0]`       | …    | low 8 bits of the glitch counter         |

Target clock is 50 MHz (100 MHz in, VCO 1000 MHz). One target period is
`56 * PHS_DIV = 1120` fine phase-shift steps, one step ≈ 17.86 ps. `phase_1`
and `phase_2` place the two edges of a channel's glitch. `offset` counts
target-clock cycles from the trigger; `offset = 0` disables that channel.

## UART protocol

1 Mbaud, 8N1. Command byte, then payload; multi-byte fields little-endian;
`ch` is a single channel-select byte, 0 = A .. 3 = D.

| cmd  | name               | payload | reply    |
|------|--------------------|---------|----------|
| 0x00 | RESET              | –       | –        |
| 0x01 | SET_OFFSET         | ch + 4  | –        |
| 0x02 | SET_PHASE1         | ch + 4  | –        |
| 0x03 | SET_PHASE2         | ch + 4  | –        |
| 0x04 | ARM                | ch      | –        |
| 0x05 | GET_ARMED          | ch      | 1        |
| 0x06 | GET_CONFIGURED     | –       | 1        |
| 0x07 | GET_PHASE_STEPS    | –       | 2        |
| 0x08 | GET_GLITCH_COUNT   | –       | 4        |
| 0x09 | CLEAR_GLITCH_COUNT | –       | –        |
| 0x0A | IDENTIFY           | –       | 1 (0x5c) |
| 0x0B | TRIGGER            | –       | – (soft) |

## Layout

```
hdl/rtl/      TOP.sv  CFI.sv  GLITCH_CHANNEL.sv  OFFSET.sv  TRIGGER.sv
              SYNCHRONIZER.sv  SR_LATCH.sv  CDC_PULSE.sv  UART_RX.sv  UART_TX.sv
hdl/constrs/  NexysVideo.xdc
scripts/      build.tcl
api/          cfi_4.py
```

## Build

```
vivado -mode batch -source scripts/build.tcl
```

`build/cfi_4.bit` and the reports land in `build/`.

## Host

```python
from cfi_4 import CFI
c = CFI()                      # auto-finds the UART by USB VID:PID 1337:0099
assert c.configured
c.a.offset = 120               # 120 target cycles after the trigger
c.a.phase_1 = 280              # glitch edges, in fine steps
c.a.phase_2 = 250
c.a.arm()                      # single-shot: re-arm for each trigger
print(c.glitch_count)
```
