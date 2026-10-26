"""
Host-side driver for cfi_4, the four-channel external clock fault injector.

cfi_4 runs on a Digilent Nexys Video (Artix-7 XC7A200T) and is controlled over
its USB-UART bridge. It generates a glitched clock out on Pmod JA1 and takes a
trigger in on JA4; there is no design under test on the FPGA. Four independent
channels (A-D) each place one glitch of their own shape at their own offset,
all counting from the same trigger. Channels are single-shot: ARM must be
re-issued for every trigger.

Protocol (command byte, then payload; multi-byte fields little-endian;
`ch` = 0 (A) .. 3 (D)):
    0x00 RESET              zero all offsets/phases and the glitch counter
    0x01 SET_OFFSET  ch +4  offset in target clock cycles after trigger (0 disables)
    0x02 SET_PHASE1  ch +4  phase_1 in fine steps
    0x03 SET_PHASE2  ch +4  phase_2 in fine steps
    0x04 ARM         ch     arm channel (single-shot)
    0x05 GET_ARMED   ch ->1 channel still armed?
    0x06 GET_CONFIGURED ->1 all MMCMs locked and phases settled
    0x07 GET_PHASE_STEPS ->2 fine steps per target clock period
    0x08 GET_GLITCH_COUNT ->4 total glitches, all channels
    0x09 CLEAR_GLITCH_COUNT
    0x0A IDENTIFY        ->1 magic, 0x5c
    0x0B TRIGGER            soft trigger (bring-up, no external target)
"""

import serial
from serial.tools import list_ports

BAUDRATE = 1_000_000
IDENTIFY = 0x5c

# the Nexys Video's UART bridge carries a custom FTDI EEPROM
USB_VID = 0x1337
USB_PID = 0x0099

CMD_RESET             = 0x00
CMD_SET_OFFSET        = 0x01
CMD_SET_PHASE1        = 0x02
CMD_SET_PHASE2        = 0x03
CMD_ARM               = 0x04
CMD_GET_ARMED         = 0x05
CMD_GET_CONFIGURED    = 0x06
CMD_GET_PHASE_STEPS   = 0x07
CMD_GET_GLITCH_COUNT  = 0x08
CMD_CLEAR_GLITCH_COUNT = 0x09
CMD_IDENTIFY          = 0x0A
CMD_TRIGGER           = 0x0B

NUM_CHANNELS = 4


def find_port():
    """Return the device node of the cfi_4 UART bridge (by USB VID:PID)."""
    for p in list_ports.comports():
        if p.vid == USB_VID and p.pid == USB_PID:
            return p.device
    raise RuntimeError(f"no UART with VID:PID {USB_VID:04x}:{USB_PID:04x} found")


class Channel:
    """One glitch channel. offset/phase are write-only in hardware, so the
    last written value is mirrored locally for readback convenience."""

    def __init__(self, cfi, index: int):
        self._cfi    = cfi
        self._index  = index
        self._offset = 0
        self._phase_1 = 0
        self._phase_2 = 0

    @property
    def offset(self) -> int:
        return self._offset

    @offset.setter
    def offset(self, value: int) -> None:
        self._cfi._write(CMD_SET_OFFSET, self._index, value.to_bytes(4, 'little'))
        self._offset = value

    @property
    def phase_1(self) -> int:
        return self._phase_1

    @phase_1.setter
    def phase_1(self, value: int) -> None:
        self._cfi._write(CMD_SET_PHASE1, self._index, value.to_bytes(4, 'little'))
        self._phase_1 = value

    @property
    def phase_2(self) -> int:
        return self._phase_2

    @phase_2.setter
    def phase_2(self, value: int) -> None:
        self._cfi._write(CMD_SET_PHASE2, self._index, value.to_bytes(4, 'little'))
        self._phase_2 = value

    def arm(self) -> None:
        """Arm this channel for the next trigger (single-shot)."""
        self._cfi._write(CMD_ARM, self._index)

    @property
    def armed(self) -> bool:
        return self._cfi._query(CMD_GET_ARMED, 1, self._index)[0] != 0


class CFI:
    """The four-channel clock fault injector."""

    def __init__(self, port: str = None, baudrate: int = BAUDRATE, timeout: float = 0.3):
        self._ser = serial.Serial(port or find_port(), baudrate, timeout=timeout)
        self.channels = [Channel(self, i) for i in range(NUM_CHANNELS)]
        self.a, self.b, self.c, self.d = self.channels
        if self.identify() != IDENTIFY:
            raise RuntimeError("cfi_4 did not identify (wrong bitstream or port)")

    # -- transport --------------------------------------------------------

    def _write(self, cmd: int, *payload) -> None:
        buf = bytearray([cmd])
        for p in payload:
            buf += bytes([p]) if isinstance(p, int) else bytes(p)
        self._ser.write(buf)
        self._ser.flush()

    def _query(self, cmd: int, nbytes: int, *payload) -> bytes:
        self._ser.reset_input_buffer()
        self._write(cmd, *payload)
        r = self._ser.read(nbytes)
        if len(r) != nbytes:
            raise RuntimeError(f"short read for cmd {cmd:#04x}: {len(r)}/{nbytes}")
        return r

    def close(self) -> None:
        self._ser.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # -- status -----------------------------------------------------------

    def identify(self) -> int:
        return self._query(CMD_IDENTIFY, 1)[0]

    @property
    def configured(self) -> bool:
        return self._query(CMD_GET_CONFIGURED, 1)[0] != 0

    @property
    def phase_steps_per_period(self) -> int:
        return int.from_bytes(self._query(CMD_GET_PHASE_STEPS, 2), 'little')

    @property
    def glitch_count(self) -> int:
        return int.from_bytes(self._query(CMD_GET_GLITCH_COUNT, 4), 'little')

    # -- control ----------------------------------------------------------

    def reset(self) -> None:
        """Zero every channel's offset/phase and the glitch counter."""
        self._write(CMD_RESET)
        for ch in self.channels:
            ch._offset = ch._phase_1 = ch._phase_2 = 0

    def clear_glitch_count(self) -> None:
        self._write(CMD_CLEAR_GLITCH_COUNT)

    def trigger(self) -> None:
        """Soft trigger: fire armed channels without an external target."""
        self._write(CMD_TRIGGER)
