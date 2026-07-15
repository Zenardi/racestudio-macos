#!/usr/bin/env python3
"""Generate deterministic golden JSON from .xrk files via libxrk — the decode
ORACLE for M1+ decode tests (issue 0.5).

libxrk is XRKConverter's pure-Python .xrk parser. For each input file this emits
small, stable summaries (not raw samples) so the goldens can be committed and
diffed:

    fixtures/golden/<name>.channels.json   channel inventory + per-channel stats
    fixtures/golden/<name>.gps.json        GPS lat/long/altitude summary
    fixtures/golden/<name>.laps.json       lap beacons (num / start / end)

Output is sorted and rounded to each channel's own decimal precision, so
re-running on the same input is byte-identical.

Usage: gen_goldens.py OUT_DIR FILE.xrk [FILE2.xrk ...]
"""
from __future__ import annotations

import contextlib
import json
import math
import os
import sys

import numpy as np
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


def _channel_summary(name, table):
    meta = ChannelMetadata.from_channel_table(table)
    decimals = max(0, int(meta.dec_pts))
    values = table.column(name).to_numpy().astype(float)
    timecodes = table.column("timecodes").to_numpy()
    has = len(values) > 0
    return {
        "name": name,
        "units": meta.units or "",
        "decimals": decimals,
        "samples": int(table.num_rows),
        "t_first_ms": int(timecodes[0]) if len(timecodes) else None,
        "t_last_ms": int(timecodes[-1]) if len(timecodes) else None,
        "min": _round(np.min(values), decimals) if has else None,
        "max": _round(np.max(values), decimals) if has else None,
        "first": _round(values[0], decimals) if has else None,
        "last": _round(values[-1], decimals) if has else None,
    }


def _channels_golden(log, fname):
    channels = [_channel_summary(n, log.channels[n]) for n in sorted(log.channels)]
    return {"file": fname, "channel_count": len(channels), "channels": channels}


def _gps_stat(log, name):
    table = log.channels.get(name)
    if table is None:
        return None
    values = table.column(name).to_numpy().astype(float)
    if len(values) == 0:
        return None
    return {
        "count": int(len(values)),
        "first": _round(values[0], 8),
        "last": _round(values[-1], 8),
        "min": _round(np.min(values), 8),
        "max": _round(np.max(values), 8),
    }


def _gps_golden(log, fname):
    latitude = _gps_stat(log, "GPS Latitude")
    longitude = _gps_stat(log, "GPS Longitude")
    altitude = _gps_stat(log, "GPS Altitude")
    return {
        "file": fname,
        "has_gps": latitude is not None and longitude is not None,
        "latitude": latitude,
        "longitude": longitude,
        "altitude": altitude,
    }


def _laps_golden(log, fname):
    lap_dict = log.laps.to_pydict()
    laps = []
    numbers = lap_dict.get("num", [])
    for i, number in enumerate(numbers):
        start = int(lap_dict["start_time"][i])
        end = int(lap_dict["end_time"][i])
        laps.append({"num": int(number), "start_ms": start, "end_ms": end,
                     "duration_ms": end - start})
    return {"file": fname, "lap_count": len(laps), "laps": laps}


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
        _write_json(os.path.join(out_dir, f"{stem}.channels.json"), _channels_golden(log, fname))
        _write_json(os.path.join(out_dir, f"{stem}.gps.json"), _gps_golden(log, fname))
        _write_json(os.path.join(out_dir, f"{stem}.laps.json"), _laps_golden(log, fname))
        print(f"  golden  {stem}.{{channels,gps,laps}}.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
