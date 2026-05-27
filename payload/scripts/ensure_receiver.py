#!/usr/bin/env python3
"""Ensure ZED-F9P outputs UBX RAWX+SFRBX on UART1 at 115200 baud.

Prints the working baud rate to stdout on success, "FAILED" on failure.
Exit 0 = ready, exit 1 = failed.

v4 (2026-04-17): Rewritten after audit found multiple critical defects
in v3:
  - v3 configured UART2 keys, but the FTDI USB-serial on both deployed
    stations was physically wired to UART1. Every configuration write was
    addressing the wrong physical port.
  - v3's build_valset() silently dropped all L-type (sz==1) keys
    because it only handled sz==2 (U1) and sz==4 (U4). Both the UBX
    output protocol enables and the RAWX/SFRBX message enables are
    L-type keys, so configuration was a no-op even if UART2 had been
    right.
  - v3's docstring claimed VALSET baud changes are silently ignored.
    Demonstrated false on 2026-04-17: CFG-UART1-BAUDRATE=115200 at
    layer bitmask 0x07 (RAM|BBR|Flash) successfully switched the receiver's
    UART1 from 38400 to 115200 and persisted through the BBR/Flash
    layers. The receiver sends the VALSET-ACK at the *new* baud, so a
    reader still listening at the old baud sees no ACK — that's what
    fooled v3's docstring author.

v4 behaviour:
  1. Probe 115200 (target), 38400 (factory), 9600 (fallback) for UBX
     sync markers (0xB5 0x62). First baud with >= 2 syncs is reported.
  2. If no baud produces UBX (post-factory-reset state — receiver is
     emitting NMEA at 38400), connect at each factory baud in order
     and send the full UART1 configuration set at RAM|BBR|Flash:
       - CFG-UART1-BAUDRATE = 115200           (U4)
       - CFG-UART1INPROT-UBX = 1               (L)
       - CFG-UART1INPROT-NMEA = 0              (L)
       - CFG-UART1OUTPROT-UBX = 1              (L)
       - CFG-UART1OUTPROT-NMEA = 0             (L)
       - CFG-MSGOUT-UBX_RXM_RAWX_UART1 = 1     (U1, 1 Hz)
       - CFG-MSGOUT-UBX_RXM_SFRBX_UART1 = 1    (U1, 1 Hz)
       - CFG-MSGOUT-NMEA_{GGA,GSA,GSV,RMC,VTG,GLL}_UART1 = 0 (U1)
  3. After VALSET, verify by reading UBX at TARGET_BAUD (the receiver
     will have switched baud if the BAUDRATE write took).

Called by log_and_upload.sh when a capture produces no UBX data, and
by gnss-receiver.service at boot. Safe to run while str2str is not
holding /dev/ttyUSB0.
"""
import serial
import struct
import sys
import time

PORT = "/dev/ttyUSB0"
TARGET_BAUD = 115200

# --- u-blox CFG key IDs for ZED-F9P HPG 1.32 (PROTVER 27.31) ---
# Top nibble of 32-bit key ID encodes value size:
#   0x1 = L  (1-bit boolean, transmitted as 1 byte)
#   0x2 = U1/I1/E1/X1  (1 byte)
#   0x3 = U2/I2/E2/X2  (2 bytes)
#   0x4 = U4/I4/E4/X4/R4  (4 bytes)
#   0x5 = U8/I8/X8/R8  (8 bytes)
CFG_UART1_BAUDRATE             = 0x40520001  # U4
CFG_UART1INPROT_UBX            = 0x10730001  # L
CFG_UART1INPROT_NMEA           = 0x10730002  # L
CFG_UART1OUTPROT_UBX           = 0x10740001  # L
CFG_UART1OUTPROT_NMEA          = 0x10740002  # L
CFG_MSGOUT_UBX_RXM_RAWX_UART1  = 0x209102A5  # U1
CFG_MSGOUT_UBX_RXM_SFRBX_UART1 = 0x20910232  # U1
CFG_MSGOUT_NMEA_GGA_UART1      = 0x209100BB  # U1
CFG_MSGOUT_NMEA_GLL_UART1      = 0x209100CA  # U1
CFG_MSGOUT_NMEA_GSA_UART1      = 0x209100C0  # U1
CFG_MSGOUT_NMEA_GSV_UART1      = 0x209100C5  # U1
CFG_MSGOUT_NMEA_RMC_UART1      = 0x209100AC  # U1
CFG_MSGOUT_NMEA_VTG_UART1      = 0x209100B1  # U1

# VALSET layer bitmask: RAM|BBR|Flash = 0x01 | 0x02 | 0x04 = 0x07
LAYERS_ALL = 0x07

# Configuration set applied during recovery (post-factory-reset).
CONFIG_VALUES = [
    (CFG_UART1_BAUDRATE,             TARGET_BAUD),
    (CFG_UART1INPROT_UBX,            1),
    (CFG_UART1INPROT_NMEA,           0),
    (CFG_UART1OUTPROT_UBX,           1),
    (CFG_UART1OUTPROT_NMEA,          0),
    (CFG_MSGOUT_UBX_RXM_RAWX_UART1,  1),
    (CFG_MSGOUT_UBX_RXM_SFRBX_UART1, 1),
    (CFG_MSGOUT_NMEA_GGA_UART1,      0),
    (CFG_MSGOUT_NMEA_GLL_UART1,      0),
    (CFG_MSGOUT_NMEA_GSA_UART1,      0),
    (CFG_MSGOUT_NMEA_GSV_UART1,      0),
    (CFG_MSGOUT_NMEA_RMC_UART1,      0),
    (CFG_MSGOUT_NMEA_VTG_UART1,      0),
]

PROBE_BAUDS = [115200, 38400, 9600]
CONFIG_BAUDS = [38400, 9600]


def ubx_checksum(data):
    a = b = 0
    for x in data:
        a = (a + x) & 0xFF
        b = (b + a) & 0xFF
    return bytes([a, b])


def build_valset(items, layers=LAYERS_ALL):
    """Build a UBX-CFG-VALSET (0x06 0x8A) frame covering all documented
    key sizes (L, U1, U2, U4, U8)."""
    payload = struct.pack("<BBH", 0, layers, 0)  # version, layers, reserved
    for key, val in items:
        sz = (key >> 28) & 0x0F
        if sz == 0x1:       # L (1-bit bool, encoded as 1 byte)
            payload += struct.pack("<IB", key, 1 if val else 0)
        elif sz == 0x2:     # U1/I1/E1/X1 (1 byte)
            payload += struct.pack("<IB", key, val & 0xFF)
        elif sz == 0x3:     # U2/I2/E2/X2 (2 bytes)
            payload += struct.pack("<IH", key, val & 0xFFFF)
        elif sz == 0x4:     # U4/I4/E4/X4/R4 (4 bytes)
            payload += struct.pack("<II", key, val & 0xFFFFFFFF)
        elif sz == 0x5:     # U8/I8/X8/R8 (8 bytes)
            payload += struct.pack("<IQ", key, val & 0xFFFFFFFFFFFFFFFF)
        else:
            raise ValueError(
                f"Unknown CFG key size nibble {sz:#x} for key {key:#010x}"
            )
    header = bytes([0xB5, 0x62, 0x06, 0x8A]) + struct.pack("<H", len(payload))
    return header + payload + ubx_checksum(header[2:] + payload)


def check_ubx(baud, duration=2.0):
    """Open serial at `baud` and count UBX sync markers over `duration` seconds."""
    try:
        s = serial.Serial(PORT, baud, timeout=0.2)
        s.reset_input_buffer()
        buf = b""
        end = time.time() + duration
        while time.time() < end:
            buf += s.read(4096)
        s.close()
        return buf.count(b"\xB5\x62")
    except Exception:
        return 0


def configure_at(send_baud):
    """Send full VALSET at `send_baud` to recover a receiver that has no
    UBX output. Verify at TARGET_BAUD after because the VALSET switches
    UART1 baud to 115200. Returns True on verified UBX output."""
    try:
        s = serial.Serial(PORT, send_baud, timeout=2)
        s.reset_input_buffer()
        s.write(build_valset(CONFIG_VALUES, layers=LAYERS_ALL))
        s.flush()
        # The receiver applies the config and switches baud. Allow time for
        # BBR+Flash writes to complete before closing and re-opening the port.
        time.sleep(2)
        s.close()
        time.sleep(1)
        return check_ubx(TARGET_BAUD, duration=3.0) >= 2
    except Exception:
        return False


def main():
    # 1. Probe for existing UBX output
    for baud in PROBE_BAUDS:
        if check_ubx(baud) >= 2:
            print(baud)
            return 0

    # 2. No UBX — attempt recovery at each factory baud
    for send_baud in CONFIG_BAUDS:
        if configure_at(send_baud):
            print(TARGET_BAUD)
            return 0

    print("FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
