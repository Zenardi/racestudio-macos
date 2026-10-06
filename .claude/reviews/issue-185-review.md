# Review: issue #185 — auto-sync from engine sound

**Reviewed**: 2026-10-06
**Branch**: feature/185-audio-auto-sync → main
**Decision**: SECOND_PASS_PENDING

## Summary

*Auto-sync from Engine Sound* estimates the video ↔ session offset by
matching the camera's engine sound against the session's `RPM` channel:

- a new Rust module, `racestudio-analysis::audio_sync`: a log-frequency
  salience map, a coarse FFT 2-D cross-correlation against the log-RPM curve,
  a sub-frame refinement and a confidence verdict;
- one FFI call, `SessionHandle::estimate_audio_sync`, with typed refusals;
- Core: the AVFoundation reader, a streaming decimator, the coordinator, the
  proposal / failure / availability types, the run on `VideoReviewModel`, and
  `SyncStatus.autoAudio` (additive, no schema bump);
- a thin shell control, ADR 0007, the handbook section and en + pt-BR strings.

The estimator deviates from the issue's hard-pitch plan; ADR 0007 records why
(the plan found the wrong offset on one of the two real clips).

## First pass — findings and resolution

Two independent reviewer agents (Swift and Rust) read
`git diff origin/main...HEAD`, alongside a self-review. All findings were fixed
in `9caabd2`.

### CRITICAL

None.

### HIGH

1. **Rust — a stray RPM timestamp exploded the resampled grid.** One sample at
   `t = 1e12` s stretched the RPM trace into a multi-terabyte grid. **Fixed**:
   - `rpm::usable()` filters to finite, positive values, sorts, and keeps the
     longest run without a gap over 30 min;
   - `resample` refuses a grid over 10⁸ points (empty, not a panic);
   - an RPM span over 3 h is invalid input.

   Pinned by `estimate_offset_ignores_a_stray_rpm_timestamp` (1e12 and 1e300)
   and `test_unrepresentable_grid_is_empty_not_a_panic`.

### MEDIUM

2. **Rust — unvalidated input reached allocations.** A huge sample rate, frame
   length or harmonic count sized buffers before any check, and NaN or
   inverted windows were not rejected. **Fixed**: `checked_input()` refuses NaN
   or inverted windows, rates over 384 kHz (lowered to 96 kHz in the second pass) and audio over 3 h (an infinite
   bound means "unbounded"). `LogGrid::new` returns `Option` with a candidate
   cap, `config_is_workable` bounds the frame length and harmonics, and
   `pitch_track` validates before allocating. The refined offset is clamped
   into the window.
3. **Rust — one glitch spike raised the stall floor**, so every real sample
   read as stalled. **Fixed**: the floor comes from the 99th percentile.
4. **Rust — long functions.** `coarse_search` and `refine` were split into
   `admissible_lags` / `best_shift_per_lag` / `rpm_columns` and
   `Probe` / `Scratch` / `accumulate`.
5. **Swift — a NaN or infinite asset duration could trap** in the capacity
   reservation. **Fixed**: the duration is sanitised and the reservation is
   capped at two hours.
6. **Swift — progress was published per decoded chunk** (thousands of main-actor
   hops). **Fixed**: whole percents, each once.
7. **Swift — the RPM channel was re-resolved on every render.** **Fixed**:
   `RPMChannelMemo` resolves it once per session.

### LOW

8. **Swift — cancellation could surface as a failure.** **Fixed**:
   `audioTrack` rethrows `CancellationError`; the coordinator checks
   cancellation before returning `.unavailable`; the reader checks once more
   after its loop.
9. **Swift — a chunk that failed to copy was dropped silently**, shortening the
   clip and skewing the offset. **Fixed**: it throws `unreadableAudio`.
   `startTime` is set only after a successful copy, and the scratch buffer is
   reused.
10. **Swift — a malformed estimate reached the UI.** **Fixed**: a non-finite
    offset becomes `.unavailable(.estimationFailed)`, the confidence is
    clamped to `0...1`, and `applyAudioSync` refuses a non-finite offset.
11. **Swift — the shell owned the run.** **Fixed**: `VideoReviewModel` owns it.
    `startAutoSync` captures the generation synchronously, runs the work on a
    detached task under `withTaskCancellationHandler`, and every stop cancels
    it. The window's controller cancels it on close.
12. **Swift — accessibility.** The button now stays put, so focus and the
    popover keep their anchor. Only the bar and its line are combined; Escape
    is no longer bound; VoiceOver hears the result; and auto-sync has its own
    row.
13. **Swift — the decimator's margin was thinner than documented.** **Fixed**:
    cut at 40 % of the output rate with 24 taps per factor. It is flat
    (−0.02 dB) to 2.4 kHz and ≥ 55 dB down from the output Nyquist, pinned by
    two band-edge tests.
14. **Tests.** A deadline-based `eventually`; a stale-generation progress test;
    the media fixture fails fast when its writer fails; the WAV fixture writes
    interleaved frames; the threshold study gains another engine and circuit
    (ratio 1.03, not confident).

**Justified as is**: `AudioSyncFFITests` compiles only when the xcframework is
present (`testExcludes`), the repo's convention for FFI-backed tests. Its
real-footage check returns early without the two environment variables, so CI
never needs the operator's footage.

## Second pass — findings and resolution

The same two reviewer agents re-read the whole diff, with emphasis on
`9caabd2`. They found no regression from the first-pass fixes, and no CRITICAL
or HIGH issue. Everything below was fixed in the second-pass commit unless it
is marked as justified.

### MEDIUM

1. **Rust — the RPM upper tail was unbounded.** A 1e300 reading survived the
   stall floor and widened the log-RPM range to about 70 000 bins. The shift
   loop is O(bins²), so a single reading could cost seconds, and dense
   distinct spikes could reach gigabytes. **Fixed**: `usable()` also drops
   readings above 10× the 99th-percentile reference, so the range stays under
   about 230 bins. Pinned by `glitch_spikes_neither_raise_the_stall_floor_nor_survive`
   (unit) and `estimate_offset_ignores_rpm_glitch_spikes` (end to end).
2. **Swift — a late popover close could cancel a new run.** SwiftUI can write
   `false` to the popover binding after a new click has started a run, and
   `dismissAutoSync()` stopped whatever was running. **Fixed**: dismissing acts
   only on a finished result. Pinned by
   `test_dismissing_while_running_leaves_the_run_alone`.

### LOW (Rust)

3. **`longest_run` counted samples, so a dense corrupt cluster at one instant
   could outvote the trace.** **Fixed**: runs are ranked by time covered, then
   by count. Tested, together with a stray stamp inside the gap limit.
4. **The `InvalidInput` message named only the rate and window.** **Fixed**: it
   now reads "unsupported sample rate, search window or length". `TooShort`
   documents that only voiced audio over RPM without logging holes counts.
5. **The clamp test did not prove the clamp.** **Fixed**: the truth sits 0.1 s
   past the window. The test asserts the offset equals the bound, and it fails
   with the clamp removed (checked). The code comment says what a clamped
   result means.
6. **`MAX_CANDIDATES` (100 000) allowed a ~150 MB tap table, and its test hit
   the non-finite path instead.** **Fixed**: the cap is 4 096. A `1e-20` band
   hits the cap and a `1e-320` band hits the non-finite path, each tested.
7. **The rate cap bounded memory but not time.** **Fixed**: `MAX_SAMPLE_RATE`
   is lowered from 384 kHz to 96 kHz, any camera's native rate. The FFI doc
   and bindings are regenerated.
8. **Missing hostile-input tests.** **Fixed**: rate boundaries (800 / 801 /
   96 000 / 96 001) and the three-hour audio boundary are covered in a
   `checked_input` unit test. Also added: infinite windows on one side; FFI
   NaN windows, a rate over the cap, and audio over three hours.
9. **Nits.** `FULL_CONFIDENCE_RATIO` now sits with the other constants;
   `reduce(f64::max)`; the `log_ks` bounds use `first()`/`last()`; `sample`
   guards with `saturating_sub`.

**Justified as is**:
- More than 1 % of the readings being spikes can still make a spike the
  reference, which masks the real trace. That ends in a typed refusal, never a
  wrong offset. A median or 90th-percentile reference was tried, but it moves
  the stall floor on real sessions (the public-sample errors changed). The
  validated real-footage results depend on that floor, so it stays at the
  99th percentile, documented.
- `resample` returning an empty grid when the grid is over the cap is
  documented and `#[must_use]`. Its other callers are unaffected.

### LOW (Swift)

10. **`Int(mSampleRate)` could trap on NaN or ∞, and absurd formats sized huge
    filters or reservations.** **Fixed**: a non-finite or out-of-range rate
    reads as no audio. `PCMDecimator` refuses rates over 384 kHz and more than
    64 channels. The reservation is capped in samples (16 M), not seconds.
11. **`applyAudioSync` stored any confidence**, so a NaN would throw on save
    and an out-of-range value would drop the status on reload. **Fixed**: a
    non-finite confidence is refused, and the rest is held to `0…1`. Tested.
12. **`try?` swallowed every error.** **Fixed**: a cancellation returns to
    idle, and any other escape reads as "could not estimate".
13. **The button could be enabled with nothing behind it.** This happened when
    the RPM channel had no readable samples. **Fixed**: `RPMChannelMemo` only
    reports a channel whose samples span session time, so the button is
    disabled with its reason. Tested.
14. **Cancel could not interrupt a blocked read.** **Fixed**: the read loop
    runs under `withTaskCancellationHandler`, which calls `cancelReading()`.
15. **Progress reports hop on unordered tasks.** **Fixed**: `report` only moves
    forward (reading grows, and matching never returns to reading). This is
    unit-tested directly and deterministically, including a retired run's
    report. The timing-based late-progress test and its fake are gone.
16. **Docs.** `autoSyncState` is driven by `startAutoSync`. `runAutoSync` is
    `internal` and test-only, and its doc says `cancelAutoSync()` does not stop
    its work. The controller's run handle doc is fixed. "The sixth harmonic"
    is now exact. The decimator stop-band test is tightened to −66 dB.
17. **Policy in the shell.** **Fixed**: the announcement text is
    `AutoSyncState.announcement(locale:)` in Core, and it is tested.
18. **Tests.**
    - The mid-read cancel test now cancels after the first progress report.
    - The truncated-file test names the accepted failures.
    - The AAC length tolerance (±5 %) no longer depends on priming trimming.
19. **Smaller items.**
    - `VideoReviewModel.swift` drops to 378 lines: the readout labels moved to
      `+Readout`.
    - Public inits are documented.
    - The result popover keeps its frame while it closes.
    - The button stays enabled during a run, so focus is not lost; a click
      starts over.
    - The progress bar is hidden from VoiceOver, so the percentage is spoken
      once.
    - The `NoEnginePitch` message now says "No engine sound was found in the
      video's audio" (en + pt-BR).
    - The FFI error mapping is exhaustive.

**Justified as is**:
- *The decode and the FFI call block a cooperative thread.* That is one run at
  a time, and it is now documented on the model.
- *`elapsed < 30` in the FFI end-to-end test.* It takes 3 s locally, so the
  bound has 10× headroom.
- *`hasAudioTrack` reads a load error as "no audio track".* A file that cannot
  be loaded already shows the player's own failure and cannot be synced
  either way.
- *An unknown asset duration shows "Reading… 0 %" for the whole decode.* Local
  camera files always carry a duration.
- *`RPMChannelMemo` "resolved once" is not observable.* The session's channel
  listing is immutable, and the test covers the answers.
