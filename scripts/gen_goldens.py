#!/usr/bin/env python3
"""Generate deterministic golden JSON from .xrk files via libxrk — the decode
ORACLE for M1+ decode tests (issue 0.5).

libxrk is XRKConverter's pure-Python .xrk parser. For each input file this emits
small, stable summaries (not raw samples) so the goldens can be committed and
diffed:

    fixtures/golden/<name>.channels.json   channel inventory + per-channel stats
    fixtures/golden/<name>.gps.json        GPS lat/long/altitude summary
    fixtures/golden/<name>.laps.json       beacon lap table (index / start / end / duration)
    fixtures/golden/<name>.stats.json      per-channel whole-session statistics (3.4)

Output is sorted and rounded to each channel's own decimal precision, so
re-running on the same input is byte-identical.

Usage: gen_goldens.py OUT_DIR FILE.xrk [FILE2.xrk ...]
"""
from __future__ import annotations

import contextlib
import datetime
import json
import math
import os
import struct
import sys

import numpy as np
import pyarrow as pa
from libxrk import ChannelMetadata, aim_xrk


def _round(value, decimals):
    # Map None and non-finite floats (NaN/±Inf, seen on empty sensor channels)
    # to null so the goldens stay strict, portable JSON (serde rejects NaN/Inf).
    if value is None:
        return None
    value = float(value)
    if not math.isfinite(value):
        return None
    return round(value, decimals)


def _channel_summary(name, table, periods):
    meta = ChannelMetadata.from_channel_table(table)
    decimals = max(0, int(meta.dec_pts))
    values = table.column(name).to_numpy().astype(float)
    timecodes = table.column("timecodes").to_numpy()
    has = len(values) > 0
    # sample_rate_hz is present only for CHS-backed channels (the ones the 1.3
    # channel decoder produces); libxrk-synthesized GPS channels have no CHS and
    # so no native rate -> null, which lets 1.3 filter to its oracle set.
    period_us = periods.get(name)
    if period_us is None:
        sample_rate_hz = None
    elif period_us <= 0:
        sample_rate_hz = 0.0
    else:
        sample_rate_hz = round(1_000_000 / period_us, 3)
    return {
        "name": name,
        "units": meta.units or "",
        "decimals": decimals,
        "sample_rate_hz": sample_rate_hz,
        "samples": int(table.num_rows),
        "t_first_ms": int(timecodes[0]) if len(timecodes) else None,
        "t_last_ms": int(timecodes[-1]) if len(timecodes) else None,
        "min": _round(np.min(values), decimals) if has else None,
        "max": _round(np.max(values), decimals) if has else None,
        "first": _round(values[0], decimals) if has else None,
        "last": _round(values[-1], decimals) if has else None,
    }


def _chs_periods(data):
    """{long_name: sample_period_us} for CHS-backed channels, first-wins.

    Walks the CNF-nested CHS definitions (which all precede the first data
    message), keeping the first definition per name — mirroring the Rust channel
    decoder, so its `sample_rate_hz` can be checked against this golden.
    """
    periods = {}

    def walk(buf):
        off, n = 0, len(buf)
        while off + 2 <= n:
            if buf[off : off + 2] != b"\x3c\x68":  # stop at the first data message
                break
            if off + 12 > n:
                break
            token = struct.unpack_from("<I", buf, off + 2)[0]
            plen = struct.unpack_from("<i", buf, off + 6)[0]
            start, end = off + 12, off + 12 + plen
            if plen < 0 or end + 8 > n:
                break
            payload = buf[start:end]
            tok = _tokstr(token)
            if tok in ("CNF", "ENF"):
                walk(payload)
            elif tok == "CHS" and len(payload) >= 73:
                name = payload[32:56].split(b"\x00")[0].decode("ascii", "replace")
                if name not in periods:
                    periods[name] = struct.unpack_from("<I", payload, 64)[0]
            off = end + 8

    walk(data)
    return periods


def _channels_golden(log, data, fname):
    periods = _chs_periods(data)
    channels = [_channel_summary(n, log.channels[n], periods) for n in sorted(log.channels)]
    return {"file": fname, "channel_count": len(channels), "channels": channels}


# GPS channel oracle (issue 1.4). libxrk synthesizes GPS channels from the
# 56-byte NAV-SOL messages: nine come straight from the record (Raw), three are
# differentiated/derived (Computed). Order is fixed and deterministic. Lat/lon
# keep 8 decimals so the 1e-8 acceptance can be checked; the rest use their
# display precision (which also matches libxrk's float32 storage exactly).
_GPS_RAW = (
    "GPS Latitude",
    "GPS Longitude",
    "GPS Altitude",
    "GPS Speed",
    "GPS_Satellites",
    "GPS_Fix",
    "GPS_pDOP",
    "GPS_Position_Accuracy",
    "GPS_Velocity_Accuracy",
)
_GPS_COMPUTED = ("GPS_InlineAcc", "GPS_LateralAcc", "GPS_Yaw_Rate")
_GPS_PRECISION = {
    "GPS Latitude": 8,
    "GPS Longitude": 8,
    "GPS Altitude": 6,
    "GPS Speed": 6,
}


def _gps_channel(log, name, kind):
    table = log.channels.get(name)
    if table is None:
        return None
    values = table.column(name).to_numpy().astype(float)
    if len(values) == 0:
        return None
    meta = ChannelMetadata.from_channel_table(table)
    decimals = _GPS_PRECISION.get(name, max(0, int(meta.dec_pts)))
    return {
        "name": name,
        "kind": kind,
        "unit": meta.units or "",
        "decimals": decimals,
        "samples": int(len(values)),
        "first": _round(values[0], decimals),
        "last": _round(values[-1], decimals),
        "min": _round(np.min(values), decimals),
        "max": _round(np.max(values), decimals),
    }


def _gps_golden(log, fname):
    channels = []
    for name in _GPS_RAW:
        ch = _gps_channel(log, name, "Raw")
        if ch is not None:
            channels.append(ch)
    for name in _GPS_COMPUTED:
        ch = _gps_channel(log, name, "Computed")
        if ch is not None:
            channels.append(ch)
    fix_count = channels[0]["samples"] if channels else 0
    return {
        "file": fname,
        "has_gps": bool(channels),
        "fix_count": fix_count,
        "channels": channels,
    }


# --------------------------------------------------------------------------- #
# Lap-marker golden (issue 1.5).
#
# The lap table is decoded from the container's LAP *marker* messages (the AiM
# logger's own recorded lap times), NOT libxrk's `log.laps` — which for these
# files is GPS-plane-crossing-refined and so differs from the beacon markers by
# tens of ms. The marker-table decode is what issue 1.5 specifies ("decodes the
# lap-marker table"); its lap COUNT is cross-validated against libxrk. Both this
# generator and the Rust `decode_laps` implement the same documented algorithm:
# keep whole-lap (segment 0) markers, drop duplicates, infer a single missed
# lap, and accumulate each marker's `duration` field into cumulative lap times.
# --------------------------------------------------------------------------- #


def _lap_markers(data):
    """Collect raw LAP markers `(segment, lap, duration_ms)` in file order,
    walking the framing and size-skipping data messages."""
    channel_sizes = {}
    group_sizes = {}
    markers = []

    def register(buf, top):
        off, n = 0, len(buf)
        while off + 2 <= n:
            if buf[off : off + 2] == b"\x3c\x68":
                if off + 12 > n:
                    break
                token = struct.unpack_from("<I", buf, off + 2)[0]
                plen = struct.unpack_from("<i", buf, off + 6)[0]
                start, end = off + 12, off + 12 + plen
                if plen < 0 or end + 8 > n:
                    break
                payload = buf[start:end]
                tok = _tokstr(token)
                if tok in ("CNF", "ENF"):
                    register(payload, top=False)
                elif tok == "CHS" and len(payload) >= 73:
                    channel_sizes[struct.unpack_from("<H", payload, 0)[0]] = payload[72]
                elif tok == "GRP" and len(payload) >= 4:
                    gidx = struct.unpack_from("<H", payload, 0)[0]
                    cnt = struct.unpack_from("<H", payload, 2)[0]
                    group_sizes[gidx] = sum(
                        channel_sizes.get(struct.unpack_from("<H", payload, 4 + 2 * i)[0], 0)
                        for i in range(cnt)
                        if 4 + 2 * i + 2 <= len(payload)
                    )
                elif tok == "LAP" and len(payload) >= 20:
                    segment = payload[1]
                    lap = struct.unpack_from("<H", payload, 2)[0]
                    duration = struct.unpack_from("<I", payload, 4)[0]
                    markers.append((segment, lap, duration))
                off = end + 8
            elif top and buf[off] == 0x28:
                nxt = _skip_data(buf, off, channel_sizes, group_sizes)
                if nxt is None or nxt <= off:
                    break
                off = nxt
            else:
                break

    register(data, top=True)
    return markers


def _lap_table(markers):
    """Apply libxrk's LAP dedup (segment-0 only, skip duplicate lap numbers,
    infer a single missed lap) and accumulate each accepted marker's `duration`
    into cumulative lap times. Returns `(laps, best_index)`."""
    kept = []  # (lap_number, duration_ms)
    for segment, lap, duration in markers:
        if segment:
            continue
        if not kept:
            pass
        elif kept[-1][0] == lap:
            continue
        elif kept[-1][0] + 1 == lap:
            pass
        elif kept[-1][0] + 2 == lap:
            kept.append((lap - 1, duration))  # inferred missed lap
        else:
            raise ValueError(f"lap gap {kept[-1][0]} -> {lap}")
        kept.append((lap, duration))
    if not kept:
        return [], None
    base = min(n for n, _ in kept)
    laps = []
    cum = 0
    for num, duration in kept:
        start = cum
        cum += duration
        laps.append(
            {"index": num - base, "start_ms": start, "end_ms": cum, "duration_ms": duration}
        )
    best = min(range(len(laps)), key=lambda i: laps[i]["duration_ms"])
    return laps, laps[best]["index"]


def _laps_golden(data, fname):
    laps, best = _lap_table(_lap_markers(data))
    return {
        "file": fname,
        "lap_count": len(laps),
        "best_lap_index": best,
        "laps": laps,
    }


# --------------------------------------------------------------------------- #
# Resampling golden (issue 3.3).
#
# libxrk's `resample_to_timecodes` linearly interpolates channels flagged
# interpolate="True" onto a target timebase — the oracle for the Rust
# `to_distance_grid`/`resample_uniform` linear interpolation. We resample one
# such channel (the first present from a small preference list) onto a uniform
# timebase spanning the channel.
#
# Target times `t` are stored **relative to the channel's first sample**: the
# Rust and libxrk decoders assign the same per-sample values and spacing but a
# constant absolute-timecode origin offset (a decode detail outside 3.3's
# scope), so re-basing to the channel start isolates the interpolation itself.
# --------------------------------------------------------------------------- #

_RESAMPLE_PREF = ("AccelerometerX", "External Voltage", "GPS Speed")
_RESAMPLE_POINTS = 25


def _resample_golden(log, fname):
    channel = next((c for c in _RESAMPLE_PREF if c in log.channels), None)
    if channel is None:
        return {"file": fname, "channel": None, "points": []}
    timecodes = log.channels[channel].column("timecodes").to_numpy().astype(np.int64)
    if len(timecodes) < 2:
        return {"file": fname, "channel": channel, "points": []}
    origin = int(timecodes[0])
    targets = np.linspace(origin, int(timecodes[-1]), _RESAMPLE_POINTS).astype(np.int64)
    # De-duplicate in case the range is tiny (keeps target strictly increasing).
    targets = np.unique(targets)
    resampled = log.resample_to_timecodes(pa.array(targets, type=pa.int64()), [channel])
    values = resampled.channels[channel].column(channel).to_numpy().astype(float)
    points = [{"t": int(t) - origin, "v": _round(v, 6)} for t, v in zip(targets, values)]
    return {"file": fname, "channel": channel, "points": points}


# --------------------------------------------------------------------------- #
# Channel-statistics golden (issue 3.4).
#
# The oracle for `channel_stats`: per-channel summary statistics over the WHOLE
# session, computed independently with numpy so the Rust Welford implementation
# is cross-checked against a naive two-pass reference. Statistics are a function
# of the value array alone, so — unlike a per-lap or resampling golden — they are
# free of the constant timecode-origin offset between the two decoders; the Rust
# and libxrk value arrays are identical, so these match to full precision.
#
# Non-finite samples are dropped first, mirroring the Rust NaN-hole policy; a
# channel with no finite samples is skipped. `std_pop` divides by n (population),
# `std_sample` by n-1 (sample; 0.0 for a single sample, never NaN). `rms` is the
# quadratic mean. Values are stored at full float precision (deterministic
# shortest-repr) so the acceptance tolerance can be tight.
# --------------------------------------------------------------------------- #


def _channel_stats(name, table):
    column = table.column(name)
    values = column.to_numpy().astype(float)
    values = values[np.isfinite(values)]
    n = int(len(values))
    if n == 0:
        return None
    minimum = float(np.min(values))
    maximum = float(np.max(values))
    return {
        "name": name,
        # libxrk's storage type for this channel. `double` and the integer types
        # are lossless relative to the Rust float64 decode (match to ~1e-12);
        # `float` (float32) channels differ by up to float32 epsilon (~1e-7), so
        # the Rust test loosens the tolerance for them. See _stats_golden.
        "dtype": str(column.type),
        "count": n,
        "min": minimum,
        "max": maximum,
        "mean": float(np.mean(values)),
        "std_pop": float(np.std(values, ddof=0)),
        "std_sample": float(np.std(values, ddof=1)) if n > 1 else 0.0,
        "rms": float(np.sqrt(np.mean(np.square(values)))),
        "range": maximum - minimum,
    }


def _stats_golden(log, fname):
    # Every channel with at least one finite sample is included; each carries its
    # libxrk storage `dtype` so the Rust cross-check can pick a tolerance that
    # matches the reference's precision (1e-9 for float64/integer channels,
    # float32-epsilon for `float` channels). Statistics depend only on the value
    # array, so they are free of the timecode-origin offset between decoders.
    channels = [
        stats
        for name in sorted(log.channels)
        if (stats := _channel_stats(name, log.channels[name])) is not None
    ]
    return {"file": fname, "channel_count": len(channels), "channels": channels}


# --------------------------------------------------------------------------- #
# Container metadata golden (issue 1.2).
#
# Metadata *strings* come from libxrk's public `log.metadata` (the authoritative
# oracle); structural *counts* come from a byte-level walk of the message framing
# that mirrors the Rust `open_container` decoder exactly (distinct CHS channel
# definitions, GPS-message presence, raw LAP-marker count). Keeping both in one
# golden lets 1.2 assert the decoder reproduces libxrk's metadata AND the
# structural facts 1.3-1.5 consume.
# --------------------------------------------------------------------------- #

_META_TOKENS = ("RCR", "VEH", "TMD", "TMT", "VTY", "CMP")


def _tokstr(token):
    out = ""
    while token:
        out += chr(token & 0xFF)
        token >>= 8
    return out.rstrip(" ")


def _epoch_utc(date_str, time_str):
    """`MM/DD/YYYY` + `HH:MM:SS` (logger wall-clock, treated as UTC) -> epoch s."""
    if not date_str or not time_str:
        return 0
    try:
        naive = datetime.datetime.strptime(f"{date_str} {time_str}", "%m/%d/%Y %H:%M:%S")
    except ValueError:
        return 0
    return int(naive.replace(tzinfo=datetime.timezone.utc).timestamp())


def _container_walk(data):
    """Byte-level structural walk of the XRK message framing (mirrors Rust).

    Returns distinct CHS channel count, GPS presence, and raw LAP-marker count.
    Skips data messages ((S/(M/(G/(c) using per-channel data sizes so the walk
    reaches EOF and sees the late (last-wins) header re-transmissions.
    """
    channel_sizes = {}
    group_sizes = {}
    chs_indices = set()
    counts = {"gps": 0, "lap": 0}

    def u16(off):
        return struct.unpack_from("<H", data, off)[0]

    def register(buf, top):
        off, n = 0, len(buf)
        while off + 2 <= n:
            op = buf[off : off + 2]
            if op == b"\x3c\x68":  # '<h' header
                if off + 12 > n:
                    break
                token = struct.unpack_from("<I", buf, off + 2)[0]
                plen = struct.unpack_from("<i", buf, off + 6)[0]
                start, end = off + 12, off + 12 + plen
                if plen < 0 or end + 8 > n:
                    break
                payload = buf[start:end]
                tok = _tokstr(token)
                if tok in ("CNF", "ENF"):
                    register(payload, top=False)
                elif tok == "CHS" and len(payload) >= 73:
                    idx = struct.unpack_from("<H", payload, 0)[0]
                    channel_sizes[idx] = payload[72]
                    chs_indices.add(idx)
                elif tok == "GRP" and len(payload) >= 4:
                    gidx = struct.unpack_from("<H", payload, 0)[0]
                    cnt = struct.unpack_from("<H", payload, 2)[0]
                    total = 0
                    for i in range(cnt):
                        if 4 + 2 * i + 2 <= len(payload):
                            total += channel_sizes.get(
                                struct.unpack_from("<H", payload, 4 + 2 * i)[0], 0
                            )
                    group_sizes[gidx] = total
                elif tok in ("GPS", "GPS1"):
                    counts["gps"] += 1
                elif tok == "LAP":
                    counts["lap"] += 1
                off = end + 8
            elif top and buf[off] == 0x28:  # '(' data message
                nxt = _skip_data(buf, off, channel_sizes, group_sizes)
                if nxt is None or nxt <= off:
                    break
                off = nxt
            else:
                break

    register(data, top=True)
    return {
        "channels": len(chs_indices),
        "has_gps": counts["gps"] > 0,
        "lap_markers": counts["lap"],
    }


def _skip_data(buf, off, channel_sizes, group_sizes):
    """Return the offset just past the data message at `off`, or None."""
    op = buf[off + 1]
    if op == 0x53:  # (S
        size = channel_sizes.get(struct.unpack_from("<H", buf, off + 6)[0])
        return None if size is None else off + 9 + size
    if op == 0x4D:  # (M
        size = channel_sizes.get(struct.unpack_from("<H", buf, off + 6)[0])
        if size is None:
            return None
        count = struct.unpack_from("<H", buf, off + 8)[0]
        return off + 11 + size * count
    if op == 0x47:  # (G
        size = group_sizes.get(struct.unpack_from("<H", buf, off + 6)[0])
        return None if size is None else off + 9 + size
    if op == 0x63:  # (c expansion channel (unk1 at byte 2, unk4 at byte 6)
        unk1, unk4 = buf[off + 2], buf[off + 6]
        if unk1 == 0x00 and unk4 == 0x06:
            size = channel_sizes.get(struct.unpack_from("<H", buf, off + 3)[0] >> 3)
            return None if size is None else off + 12 + size
        if unk1 == 0x00 and unk4 == 0x08:
            return off + 16
        if unk1 == 0x01 and unk4 == 0x02:
            return off + 10
    return None


def _metadata_golden(log, data, fname):
    md = log.metadata
    walk = _container_walk(data)
    log_date = md.get("Log Date", "")
    log_time = md.get("Log Time", "")
    return {
        "file": fname,
        "driver": md.get("Driver", ""),
        "vehicle": md.get("Vehicle", ""),
        "track": md.get("Venue", ""),
        "session": md.get("Session", ""),
        "series": md.get("Series", ""),
        "log_date": log_date,
        "log_time": log_time,
        "datetime_utc": _epoch_utc(log_date, log_time),
        "channel_count": walk["channels"],
        "has_gps": walk["has_gps"],
        "lap_marker_count": walk["lap_markers"],
    }


def _write_json(path, obj):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(obj, handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")


def main(argv):
    if len(argv) < 3:
        print("usage: gen_goldens.py OUT_DIR FILE.xrk [FILE2.xrk ...]", file=sys.stderr)
        return 2
    out_dir = argv[1]
    os.makedirs(out_dir, exist_ok=True)
    for xrk in argv[2:]:
        fname = os.path.basename(xrk)
        stem = fname[:-4] if fname.lower().endswith(".xrk") else fname
        # libxrk prints channel chatter to stdout; keep our output clean.
        with contextlib.redirect_stdout(sys.stderr):
            log = aim_xrk(xrk)
        with open(xrk, "rb") as handle:
            raw = handle.read()
        _write_json(os.path.join(out_dir, f"{stem}.channels.json"), _channels_golden(log, raw, fname))
        _write_json(os.path.join(out_dir, f"{stem}.gps.json"), _gps_golden(log, fname))
        _write_json(os.path.join(out_dir, f"{stem}.laps.json"), _laps_golden(raw, fname))
        _write_json(os.path.join(out_dir, f"{stem}.metadata.json"), _metadata_golden(log, raw, fname))
        _write_json(os.path.join(out_dir, f"{stem}.resample.json"), _resample_golden(log, fname))
        _write_json(os.path.join(out_dir, f"{stem}.stats.json"), _stats_golden(log, fname))
        print(f"  golden  {stem}.{{channels,gps,laps,metadata,resample,stats}}.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
