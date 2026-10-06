#!/usr/bin/env python3
"""Generate the telemetry-frame golden from an .xrk via libxrk — the ORACLE for
the Swift `TelemetryTimeline` (issue 9.9 / #186).

For a handful of chosen instants this records what a `TelemetryFrame` must
carry, computed independently of the code under test: libxrk decodes the
sample values (not the Rust decoder) and numpy evaluates the frame contract:

    speed_kmh   GPS Speed (m/s) linearly interpolated at t, x 3.6
    rpm         RPM linearly interpolated at t (the frame interpolates every
                continuous role, although libxrk flags this RPM sample-held)
    lat_g/lon_g GPS_LateralAcc / GPS_InlineAcc linearly interpolated at t
    lap_*       the beacon lap table: lap number, elapsed time, last lap, best
                lap (fastest, earliest on a tie), best-so-far, out/in-lap flags
    delta_s     the live delta to the best lap: the 3.2 delta-t series (numpy
                port of `delta_t`: unclamped trapezoidal distance per lap, time
                re-based to the lap's first GPS Speed sample, the comparison lap
                read at the proportional distance), read at the fraction of the
                lap the kart has covered at t

Everything is placed on the **raw logger clock** the app's session time uses:

- CHS channels: libxrk subtracts a constant `time_offset` from every timecode;
  it is recovered from the GPS stream's first record, which no repair moves
  (`raw record timecode − libxrk timecode`), and added back.
- GPS channels: the raw record timecodes, with an out-of-order record repaired
  as docs/DECODE_TOLERANCES.md and the decoder document (issue 164: the record
  and everything after it shift to one median step past its predecessor).
  libxrk repairs the same record with a different step, which would otherwise
  offset the whole GPS stream from the CHS channels by tens of milliseconds.
- Laps: the beacon table (the LAP markers' own durations, as the `laps` golden
  reads them) from the first LAP marker's `end_time − duration`.

Instants are stored as `(lap_index, offset_s)` — seconds past that lap's beacon
— and the Swift test re-anchors them on the decoder's own lap starts. Every
value is checked to lie outside any sample gap (> 0.5 s), so none of the
goldens is a "nil" case.

Usage: gen_telemetry_golden.py OUT_DIR FILE.xrk
"""
from __future__ import annotations

import contextlib
import json
import os
import struct
import sys

import numpy as np
from libxrk import aim_xrk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_goldens  # noqa: E402  (the shared container walkers and beacon lap table)

# (lap index, ms past the beacon): the out-lap, a beacon instant, flying laps,
# the best (reference) lap itself and the in-lap.
_INSTANTS = (
    (0, 70_000),
    (1, 0),
    (1, 12_345),
    (2, 31_250),
    (3, 25_000),
    (5, 7_777),
    (6, 45_678),
    (8, 20_000),
    (9, 33_333),
    (10, 15_000),
)
_MAX_GAP_MS = 500
_WRAP_THRESHOLD = 32_768
_GPS_RECORD = 56


def _values(log, name):
    table = log.channels[name]
    return (table.column("timecodes").to_numpy().astype(np.int64),
            table.column(name).to_numpy().astype(np.float64))


def _repaired(tc):
    """Unwrap genuine 16-bit wraps, then shift an out-of-order record (and all
    after it) to one median positive step past its predecessor (issue 164)."""
    tc = tc.astype(np.int64)
    if np.all(np.diff(tc) >= 0):
        return tc
    masked = (tc & 0xFFFF) + (tc[0] - (tc[0] & 0xFFFF))
    wraps = np.concatenate([[0], np.cumsum((masked[:-1] - masked[1:]) > _WRAP_THRESHOLD)])
    out = masked + 65536 * wraps
    steps = np.sort(np.diff(out)[np.diff(out) > 0])
    nominal = int(steps[len(steps) // 2]) if len(steps) else 1
    shift = 0
    for i in range(1, len(out)):
        out[i] += shift
        if out[i] <= out[i - 1]:
            correction = out[i - 1] + nominal - out[i]
            out[i] += correction
            shift += correction
    return out


def _gps_times(raw):
    gps = gen_goldens._gather_gps_payloads(raw)
    count = len(gps) // _GPS_RECORD
    return np.array([struct.unpack_from("<i", gps, _GPS_RECORD * i)[0] for i in range(count)], dtype=np.int64)


def _first_lap_origin(raw):
    """The first LAP marker's `end_time − duration` (raw ms) — the decoder's
    `first_lap_origin_ms`, where lap time 0 falls on the samples' clock."""
    channel_sizes, group_sizes, first = {}, {}, []

    def walk(buf, top):
        off, n = 0, len(buf)
        while off + 2 <= n and not first:
            if buf[off : off + 2] != b"\x3c\x68":
                nxt = gen_goldens._skip_data(buf, off, channel_sizes, group_sizes) if top and buf[off] == 0x28 else None
                if nxt is None or nxt <= off:
                    break
                off = nxt
                continue
            token = struct.unpack_from("<I", buf, off + 2)[0]
            plen = struct.unpack_from("<i", buf, off + 6)[0]
            start, end = off + 12, off + 12 + plen
            if plen < 0 or end + 8 > n:
                break
            payload, tok = buf[start:end], gen_goldens._tokstr(token)
            if tok in ("CNF", "ENF"):
                walk(payload, False)
            elif tok == "CHS" and len(payload) >= 73:
                channel_sizes[struct.unpack_from("<H", payload, 0)[0]] = payload[72]
            elif tok == "GRP" and len(payload) >= 4:
                gidx, cnt = struct.unpack_from("<HH", payload, 0)
                group_sizes[gidx] = sum(
                    channel_sizes.get(struct.unpack_from("<H", payload, 4 + 2 * i)[0], 0)
                    for i in range(cnt) if 4 + 2 * i + 2 <= len(payload))
            elif tok == "LAP" and len(payload) >= 20:
                first.append(struct.unpack_from("<I", payload, 16)[0] - struct.unpack_from("<I", payload, 4)[0])
            off = end + 8

    walk(raw, True)
    assert first, "no LAP marker"
    return first[0]


def _at(tc, values, t):
    """Linear interpolation at t, asserting t sits inside the samples, not in a gap."""
    upper = int(np.searchsorted(tc, t, side="right"))
    assert 0 < upper <= len(tc), f"t={t} outside the channel"
    if upper < len(tc):
        assert tc[upper] - tc[upper - 1] <= _MAX_GAP_MS, f"t={t} inside a sample gap"
    return float(np.interp(t, tc, values))


def _distance(speed_ms, tc):
    """Unclamped cumulative trapezoid (m) from 0 — Rust `cumulative_trapezoid(.., false)`."""
    step = 0.5 * (speed_ms[:-1] + speed_ms[1:]) * (np.diff(tc) / 1000.0)
    return np.concatenate([[0.0], np.cumsum(step)])


def _delta_series(ref, cmp):
    """(grid, dt) of lap `cmp` vs lap `ref` — a numpy port of `delta_t`."""
    (ref_tc, ref_speed), (cmp_tc, cmp_speed) = ref, cmp
    grid = _distance(ref_speed, ref_tc)
    cmp_dist = _distance(cmp_speed, cmp_tc)
    scale = cmp_dist[-1] / grid[-1] if grid[-1] > 0 else 0.0
    t_ref = np.interp(grid, grid, (ref_tc - ref_tc[0]) / 1000.0)
    t_cmp = np.interp(grid * scale, cmp_dist, (cmp_tc - cmp_tc[0]) / 1000.0)
    return grid, t_cmp - t_ref


def _live_delta(laps_speed, ref_index, lap_index, t):
    if lap_index == ref_index:
        return 0.0
    grid, dt = _delta_series(laps_speed[ref_index], laps_speed[lap_index])
    tc, speed = laps_speed[lap_index]
    dist = _distance(speed, tc)
    covered = float(np.interp(t, tc, dist))  # clamps to [0, lap length]
    return float(np.interp(covered * grid[-1] / dist[-1], grid, dt))


def _round(value, places=6):
    return None if value is None else round(value, places)


def _telemetry_golden(log, raw, fname):
    beacon, _ = gen_goldens._lap_table(gen_goldens._lap_markers(raw))
    origin = _first_lap_origin(raw)
    starts = [origin + lap["start_ms"] for lap in beacon]
    ends = [origin + lap["end_ms"] for lap in beacon]
    durations = [lap["duration_ms"] / 1000.0 for lap in beacon]
    count = len(durations)

    def best_of(indices):
        valid = [i for i in indices if durations[i] > 0]
        return min(valid, key=lambda i: (durations[i], i)) if valid else None

    def timing(i):
        return None if i is None else {"index": i, "number": i + 1, "time_s": _round(durations[i], 3)}

    raw_gps = _gps_times(raw)
    lib_gps_tc, speed = _values(log, "GPS Speed")
    assert len(raw_gps) == len(lib_gps_tc), "one GPS record per libxrk fix"
    time_offset = int(raw_gps[0] - lib_gps_tc[0])
    gps_tc = _repaired(raw_gps)
    rpm_tc, rpm = _values(log, "RPM")
    rpm_tc = rpm_tc + time_offset
    lat = (gps_tc, _values(log, "GPS_LateralAcc")[1])
    lon = (gps_tc, _values(log, "GPS_InlineAcc")[1])
    laps_speed = [(gps_tc[(gps_tc >= s) & (gps_tc < e)], speed[(gps_tc >= s) & (gps_tc < e)])
                  for s, e in zip(starts, ends)]

    best = best_of(range(count))
    frames = []
    for lap, offset_ms in _INSTANTS:
        t = float(starts[lap] + offset_ms)
        frames.append({
            "lap_index": lap,
            "offset_s": offset_ms / 1000.0,
            "lap_number": lap + 1,
            "elapsed_s": offset_ms / 1000.0,
            "is_out_lap": lap == 0,
            "is_in_lap": lap == count - 1,
            "last_lap": timing(lap - 1 if lap > 0 else None),
            "best_so_far": timing(best_of(range(lap))),
            "speed_kmh": _round(_at(gps_tc, speed, t) * 3.6),
            "rpm": _round(_at(rpm_tc, rpm, t), 3),
            "lat_g": _round(_at(*lat, t)),
            "lon_g": _round(_at(*lon, t)),
            "delta_s": _round(_live_delta(laps_speed, best, lap, t)),
        })
    return {"file": fname, "best_lap": timing(best), "lap_count": count, "frames": frames}


def main(argv):
    if len(argv) != 3:
        print("usage: gen_telemetry_golden.py OUT_DIR FILE.xrk", file=sys.stderr)
        return 2
    out_dir, xrk = argv[1], argv[2]
    fname = os.path.basename(xrk)
    stem = fname[:-4] if fname.lower().endswith(".xrk") else fname
    with contextlib.redirect_stdout(sys.stderr):
        log = aim_xrk(xrk)
    with open(xrk, "rb") as handle:
        raw = handle.read()
    path = os.path.join(out_dir, f"{stem}.telemetry.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(_telemetry_golden(log, raw, fname), handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")
    print(f"  golden  {stem}.telemetry.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
