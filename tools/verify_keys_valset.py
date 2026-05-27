#!/usr/bin/env python3
"""Verify ZED-F9P CFG key IDs via UBX-CFG-VALSET with ACK/NAK test.

For each key, writes a single-key VALSET to RAM layer with a benign value
and listens for ACK-ACK (0x05/0x01) or ACK-NAK (0x05/0x00). This is the
authoritative test — NAK means the key ID is wrong for this firmware.

Run only when /dev/ttyUSB0 is FREE (no str2str capture in progress).
"""
import struct
import sys
import time

import serial

PORT = '/dev/ttyUSB0'
BAUD = 115200

# (name, key, type, test_value) — test_value chosen to be non-disruptive when
# possible. MSGOUT keys use 0 (disable) since the receiver is expected idle.
# Caller must restore receiver config afterwards via ensure_receiver.py.
KEYS = [
    ("CFG-UART1-BAUDRATE",             0x40520001, "U4", 115200),
    ("CFG-UART1INPROT-UBX",            0x10730001, "L",  1),
    ("CFG-UART1INPROT-NMEA",           0x10730002, "L",  0),
    ("CFG-UART1OUTPROT-UBX",           0x10740001, "L",  1),
    ("CFG-UART1OUTPROT-NMEA",          0x10740002, "L",  0),
    ("CFG-MSGOUT-UBX_RXM_RAWX_UART1",  0x209102A5, "U1", 1),
    ("CFG-MSGOUT-UBX_RXM_SFRBX_UART1", 0x20910232, "U1", 1),
    ("CFG-MSGOUT-NMEA_ID_GGA_UART1",   0x209100BB, "U1", 0),
    ("CFG-MSGOUT-NMEA_ID_GLL_UART1",   0x209100CA, "U1", 0),
    ("CFG-MSGOUT-NMEA_ID_GSA_UART1",   0x209100C0, "U1", 0),
    ("CFG-MSGOUT-NMEA_ID_GSV_UART1",   0x209100C5, "U1", 0),
    ("CFG-MSGOUT-NMEA_ID_RMC_UART1",   0x209100AC, "U1", 0),
    ("CFG-MSGOUT-NMEA_ID_VTG_UART1",   0x209100B1, "U1", 0),
]

LAYER_RAM = 0x01  # bitmask for VALSET


def ck(data):
    a = b = 0
    for x in data:
        a = (a + x) & 0xFF
        b = (b + a) & 0xFF
    return bytes([a, b])


def ubx(cls_id, msg_id, payload):
    h = bytes([0xB5, 0x62, cls_id, msg_id]) + struct.pack('<H', len(payload))
    return h + payload + ck(h[2:] + payload)


def valset(key, value, layers=LAYER_RAM):
    header = struct.pack('<BBH', 0, layers, 0)
    sz = (key >> 28) & 0xF
    if sz == 0x1:
        kv = struct.pack('<IB', key, 1 if value else 0)
    elif sz == 0x2:
        kv = struct.pack('<IB', key, value & 0xFF)
    elif sz == 0x3:
        kv = struct.pack('<IH', key, value & 0xFFFF)
    elif sz == 0x4:
        kv = struct.pack('<II', key, value & 0xFFFFFFFF)
    elif sz == 0x5:
        kv = struct.pack('<IQ', key, value & 0xFFFFFFFFFFFFFFFF)
    else:
        raise ValueError(f"unknown size nibble for key 0x{key:08X}")
    return ubx(0x06, 0x8A, header + kv)


def read_frames_for(s, t=2.0):
    """Collect UBX frames for `t` seconds. Robust against interleaved NMEA."""
    buf = b""
    end = time.time() + t
    frames = []
    while time.time() < end:
        chunk = s.read(s.in_waiting or 1)
        if chunk:
            buf += chunk
        while True:
            i = buf.find(b"\xB5\x62")
            if i < 0:
                # Preserve last byte in case of partial sync at end
                if len(buf) > 1:
                    buf = buf[-1:]
                break
            buf = buf[i:]
            if len(buf) < 8:
                break
            cls_id, msg_id, ln = buf[2], buf[3], struct.unpack('<H', buf[4:6])[0]
            if len(buf) < 8 + ln:
                break
            frame = buf[:8+ln]
            buf = buf[8+ln:]
            frames.append((cls_id, msg_id, frame[6:6+ln]))
    return frames


def check_key(s, name, key, typ, value):
    # Drain any pending input
    time.sleep(0.1)
    s.reset_input_buffer()
    s.write(valset(key, value))
    s.flush()
    frames = read_frames_for(s, t=2.0)
    ack = None
    for cls, msg, pl in frames:
        if cls == 0x05 and msg == 0x01 and len(pl) >= 2 and pl[0] == 0x06 and pl[1] == 0x8A:
            ack = "ACK"
            break
        if cls == 0x05 and msg == 0x00 and len(pl) >= 2 and pl[0] == 0x06 and pl[1] == 0x8A:
            ack = "NAK"
            break
    if ack is None:
        return "TIMEOUT"
    return ack


def main():
    s = serial.Serial(PORT, BAUD, timeout=0.2)
    # Settle
    time.sleep(0.3)
    print(f"{'NAME':<36} {'KEY':<12} {'TYPE':<4} {'VAL':<6} {'RESULT'}")
    n_ack = n_nak = n_to = 0
    for name, key, typ, val in KEYS:
        r = check_key(s, name, key, typ, val)
        print(f"{name:<36} 0x{key:08X} {typ:<4} {val!s:<6} {r}")
        if r == "ACK":
            n_ack += 1
        elif r == "NAK":
            n_nak += 1
        else:
            n_to += 1
    s.close()
    print(f"\nACK={n_ack}  NAK={n_nak}  TIMEOUT={n_to}   total={len(KEYS)}")
    return 0 if n_ack == len(KEYS) else 1


if __name__ == "__main__":
    sys.exit(main())
