#!/usr/bin/env python3
"""Generate the synthetic 5M-sample `.xrk` fixture + its decimation golden (7.2).

The `.xrk` is a minimal but valid AiM container — one f32 channel at 100 Hz,
carried as `(M` sample bursts — sized to 5,000,000 samples so the large-session
performance work has a realistic input. It is git-ignored (large).

The golden `synthetic_5m.decimated.json` is the brute-force min/max decimation
envelope of that channel at a fixed bucket count: the independent oracle for
`racestudio_analysis::min_max_decimate`, computed here straight from the source
samples (never via the Rust implementation under test). It is small and committed.

Values are rounded through IEEE-754 float32 exactly as the container stores them,
so the golden matches the decoded/decimated Rust output to full precision.

Usage: gen_synthetic.py <fixtures_dir>
"""
import json
import math
import os
import struct
import sys

N = 5_000_000
CHANNEL = "Speed"
BUCKETS = 1920
PERIOD_US = 10_000        # 100 Hz logging
MMS = PERIOD_US // 1000   # 10 ms between consecutive samples
BURST = 50_000            # samples per (M message (u16 count fits)
MAGIC = b"\x3c\x68"


def token(tok):
    padded = tok.encode() + b" " * (4 - len(tok))
    return padded[:4]


def frame(tok, payload):
    tok_bytes = token(tok)
    out = bytearray()
    out += MAGIC
    out += tok_bytes
    out += struct.pack("<i", len(payload))
    out += b"\x00"  # version
    out += b">"
    out += payload
    out += b"<"
    out += tok_bytes
    out += struct.pack("<H", sum(payload) & 0xFFFF)  # checksum (not verified)
    out += b">"
    return bytes(out)


def chs(index, name, unit_type, decoder, data_size, period_us):
    payload = bytearray(112)
    payload[0:2] = struct.pack("<H", index)
    payload[12] = unit_type
    payload[20] = decoder
    name_bytes = name.encode()
    payload[32:32 + len(name_bytes)] = name_bytes
    payload[64:68] = struct.pack("<I", period_us)
    payload[72] = data_size
    return bytes(payload)


def f32(value):
    """Round a float through IEEE-754 float32, matching what the decoder reads."""
    return struct.unpack("<f", struct.pack("<f", value))[0]


def value_at(index):
    return f32(math.sin(index * 0.0007) * 80.0 + (index % 613) * 0.05)


def build_xrk(path):
    cnf = frame("CHS", chs(0, CHANNEL, 16, 6, 4, PERIOD_US))  # decoder 6 = f32
    with open(path, "wb") as handle:
        handle.write(frame("CNF", cnf))
        start = 0
        while start < N:
            count = min(BURST, N - start)
            body = bytearray()
            body += b"(M"
            body += struct.pack("<i", start * MMS)  # burst base timecode
            body += struct.pack("<H", 0)            # channel index 0
            body += struct.pack("<H", count)
            for k in range(count):
                body += struct.pack("<f", value_at(start + k))
            body += b")"
            handle.write(body)
            start += count


def decimation_golden():
    """Two `[time_ms, value]` points per bucket, in time order — the exact shape
    `min_max_decimate` emits, computed by brute force."""
    envelope = []
    for bucket in range(BUCKETS):
        lo = bucket * N // BUCKETS
        hi = (bucket + 1) * N // BUCKETS
        min_i = max_i = lo
        min_v = max_v = value_at(lo)
        for i in range(lo + 1, hi):
            v = value_at(i)
            if v < min_v:
                min_v, min_i = v, i
            if v > max_v:
                max_v, max_i = v, i
        first, second = (min_i, max_i) if min_i <= max_i else (max_i, min_i)
        envelope.append([float(first * MMS), value_at(first)])
        envelope.append([float(second * MMS), value_at(second)])
    return envelope


def main():
    if len(sys.argv) != 2:
        print("usage: gen_synthetic.py <fixtures_dir>", file=sys.stderr)
        sys.exit(2)
    fixtures_dir = sys.argv[1]
    golden_dir = os.path.join(fixtures_dir, "golden")
    os.makedirs(golden_dir, exist_ok=True)

    xrk_path = os.path.join(fixtures_dir, "synthetic_5m.xrk")
    print(f"  writing {xrk_path} ({N:,} samples)")
    build_xrk(xrk_path)

    golden = {
        "file": "synthetic_5m.xrk",
        "channel": CHANNEL,
        "buckets": BUCKETS,
        "sample_count": N,
        "envelope": decimation_golden(),
    }
    golden_path = os.path.join(golden_dir, "synthetic_5m.decimated.json")
    with open(golden_path, "w") as handle:
        json.dump(golden, handle)
    print(f"  wrote {golden_path} ({os.path.getsize(xrk_path):,} bytes of .xrk)")


if __name__ == "__main__":
    main()
