# Test fixtures

Golden data for decode tests (issue 0.5). Decode correctness in M1+ is defined
against **libxrk** — XRKConverter's pure-Python `.xrk` parser, used here as the
decode **oracle**.

## Layout

```
fixtures/
  aim_official_test.xrk        # sample .xrk (git-ignored — fetched locally)
  fuji_0033.xrk                # sample .xrk (git-ignored)
  fuji_0033_reference.csv      # RaceStudio reference CSV (git-ignored)
  golden/                      # committed, deterministic oracle JSON
    <name>.channels.json       # channel inventory + per-channel summary stats,
                               #   incl. sample_rate_hz for CHS-backed channels (1.3)
    <name>.gps.json            # GPS channel inventory: 9 Raw + 3 Computed
                               #   channels (lat/lon/alt/speed/accuracy/sats) (1.4)
    <name>.laps.json           # beacon lap table: per-lap cumulative times +
                               #   best-lap index, decoded from LAP markers (1.5)
    <name>.metadata.json       # container header metadata + structural counts (1.2)
    <name>.resample.json       # one channel linearly resampled onto a uniform
                               #   timebase via resample_to_timecodes (3.3)
    <name>.stats.json          # per-channel whole-session statistics with the
                               #   libxrk storage dtype per channel (3.4)
    <name>.derived.json        # GPS-derived channels window: heading, yaw_rate,
                               #   inline/lateral accel — inputs + outputs (3.6)
    fuji_0033.csv              # byte golden: the RaceChrono AiM CSV this repo's
                               #   writer emits for fuji_0033.xrk (5.1)
```

- **`*.xrk` / `*.csv`** are large and binary, so they stay **local** and are
  git-ignored. Fetch them with `make fixtures` (or `bash scripts/fetch_fixtures.sh`),
  which downloads them from the libxrk repo (idempotent + cached).
- **`golden/*.json`** are small, sorted, and deterministic, so they are
  **committed**. They are regenerated from the `.xrk` files by
  `scripts/gen_goldens.py` (run via `make fixtures`).

## Loading fixtures in tests

- **Rust:** `support::fixtures::fixture_path(name)` and
  `support::fixtures::load_golden::<T>(name, aspect)`
  (`core/racestudio-decode/tests/support/fixtures.rs`).
- **Swift:** `FixtureLoader.url(for:)` and `FixtureLoader.golden(_:aspect:)`
  (`app/Tests/RaceStudioCoreTests/Support/FixtureLoader.swift`).

Both resolve this directory relative to the repo root and fail with a clear,
actionable error when a fixture is missing.

## The AiM CSV byte golden (`golden/fuji_0033.csv`, issue 5.1)

Unlike the JSON goldens (libxrk-derived), the CSV golden is the deterministic
output of **this repo's own** writer (`racestudio-io::write_aim_csv`) for
`fuji_0033.xrk`. It is committed (git compresses it in the packfile) and the
`test_fuji_export_matches_byte_golden` test asserts the writer still reproduces
it byte-for-byte — a regression lock. Independent correctness is proven
separately: `test_speed_within_half_kmh_of_reference` /
`test_position_within_one_meter_of_reference` compare the same output
field-by-field against the RaceStudio reference CSV (`fuji_0033_reference.csv`,
git-ignored, fetched) over 200–1600 s, agreeing to within 0.5 km/h and 1.0 m.

## Regenerating goldens

```sh
make fixtures                    # fetch .xrk samples + regenerate golden/*.json via libxrk
bash scripts/gen_csv_golden.sh   # regenerate the AiM CSV byte golden from fuji_0033.xrk
```

Goldens are byte-identical across runs on the same input; review any diff as a
decode- or writer-behaviour change.
