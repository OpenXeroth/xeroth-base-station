#!/usr/bin/env python3
"""Parse UBX-RXM-RAWX from a .ubx file and enumerate unique (gnssId, sigId)
pairs with their SV counts. Confirms dual-frequency tracking."""
import struct
import sys
from collections import Counter

GNSS_NAMES = {0: "GPS", 1: "SBAS", 2: "Galileo", 3: "BeiDou",
              4: "IMES", 5: "QZSS", 6: "GLONASS", 7: "NavIC"}

# u-blox F9P HPG 1.32 sigId names (docs: UBX-18010854)
SIG_NAMES = {
    0: {0: "L1C/A", 3: "L2 CL", 4: "L2 CM"},
    1: {0: "L1C/A"},
    2: {0: "E1 C", 1: "E1 B", 5: "E5b I", 6: "E5b Q"},
    3: {0: "B1I D1", 1: "B1I D2", 2: "B2I D1", 3: "B2I D2",
        5: "B1C", 7: "B2a"},
    5: {0: "L1C/A", 1: "L1 S", 4: "L2 CM", 5: "L2 CL"},
    6: {0: "L1 OF", 2: "L2 OF"},
    7: {0: "L5 A", 1: "L5 B"},
}

def parse_rawx(path):
    sv_pairs = Counter()           # (gnssId, sigId, svId) -> occurrences
    rawx_count = 0
    with open(path, "rb") as f:
        data = f.read()
    i = 0
    L = len(data)
    while i + 8 <= L:
        if data[i] != 0xB5 or data[i+1] != 0x62:
            i += 1
            continue
        cls_ = data[i+2]
        msg_ = data[i+3]
        plen = struct.unpack_from("<H", data, i+4)[0]
        if i + 8 + plen > L:
            break
        pl = data[i+6:i+6+plen]
        # skip checksum, advance
        i += 6 + plen + 2
        if cls_ == 0x02 and msg_ == 0x15:      # UBX-RXM-RAWX
            if len(pl) < 16:
                continue
            numMeas = pl[11]
            rawx_count += 1
            off = 16
            for _k in range(numMeas):
                if off + 32 > len(pl):
                    break
                gnssId = pl[off + 20]
                svId   = pl[off + 21]
                sigId  = pl[off + 22]
                sv_pairs[(gnssId, sigId, svId)] += 1
                off += 32
    # Collapse to (gnssId, sigId) with count of distinct SVs observed
    gs = {}
    for (g, s, sv), _count in sv_pairs.items():
        gs.setdefault((g, s), set()).add(sv)
    return rawx_count, {k: len(v) for k, v in gs.items()}, sv_pairs

def main():
    path = sys.argv[1]
    rawx_count, pair_svs, _ = parse_rawx(path)
    print(f"file: {path}")
    print(f"UBX-RXM-RAWX messages: {rawx_count}")
    if not pair_svs:
        print("NO RAWX DATA")
        sys.exit(1)
    print("(gnssId:sigId)  sig-name             distinct-SVs")
    by_gnss = {}
    for (g, s), n in pair_svs.items():
        by_gnss.setdefault(g, []).append((s, n))
    dual = {}
    for g in sorted(by_gnss):
        sigs = sorted(by_gnss[g])
        dual[g] = sigs
        for s, n in sigs:
            name = SIG_NAMES.get(g, {}).get(s, "?")
            print(f"  {g}:{s:<3}           {GNSS_NAMES.get(g,'?'):<8} {name:<10}  {n}")
    print()
    print("Dual-frequency assessment:")
    # GPS: sigId 0 is L1; 3/4 are L2
    # Galileo: 0/1 are E1; 5/6 are E5b
    # BeiDou: 0/1 are B1I; 2/3 are B2I
    # GLONASS: 0 is L1; 2 is L2
    status = {}
    def has(g, sids):
        return any(s in sids for s, n in dual.get(g, []))
    status["GPS"]     = (has(0, {0}), has(0, {3, 4}))
    status["Galileo"] = (has(2, {0, 1}), has(2, {5, 6}))
    status["BeiDou"]  = (has(3, {0, 1}), has(3, {2, 3}))
    status["GLONASS"] = (has(6, {0}), has(6, {2}))
    for k, (b1, b2) in status.items():
        tag = "DUAL" if (b1 and b2) else ("L1-only" if b1 else ("L2-only" if b2 else "absent"))
        print(f"  {k:<8} L1={b1}  L2/E5b/B2I={b2}  -> {tag}")

if __name__ == "__main__":
    main()
