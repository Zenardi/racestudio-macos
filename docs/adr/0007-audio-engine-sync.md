# ADR 0007 — Video sync from engine sound: log-frequency salience matched to the log-RPM curve

- **Status:** Accepted
- **Date:** 2026-10-06
- **Milestone:** M7 (issue 9.8, #185; epic #145). Builds on the 9.5–9.7 video
  sync (`VideoSyncModel`, `SyncStatus`, `VideoReviewModel`).

## Context

Onboard kart footage rarely carries usable sync metadata. There is no GPMF
track; a re-exported file carries its export date; and the camera and logger
are started by hand at different moments. Every clip does record the
**engine**, though, and the logger records its `RPM` (a MyChron 6 at 20 Hz).
An engine's sound is a harmonic series whose fundamental is proportional to
RPM: `f0 = k·RPM`. For example, `k = 1/120` is a four-stroke single's firing
rate and `1/60` its crank. `k` depends on the engine (stroke, cylinders) and on
which harmonic is loudest, which we do not want the operator to configure.

The issue's plan was:

1. track a pitch per audio frame (harmonic product spectrum);
2. then run a normalised (Pearson) cross-correlation of `ln pitch` against
   `ln RPM`. Because `ln(k·RPM) = ln k + ln RPM`, the correlation does not
   depend on `k`.

## Decision

Keep the scale-invariance argument, but apply it to the **whole log-frequency
salience map** rather than to a per-frame pitch decision. Concretely
(`core/racestudio-analysis/src/audio_sync/`):

1. **Salience front end** (`salience.rs`):
   - mono PCM, decimated by the app to ~8 kHz;
   - 0.5 s Hann frames (the 3.7 `Window`), FFT;
   - the log-magnitude spectrum is **whitened** (minus its 60 Hz moving
     average, clipped at 0), so wind, road noise and AGC level changes flatten
     and only narrow lines stand out;
   - the salience of a candidate fundamental `f` is the mean whitened level at
     its harmonics `h·f`;
   - candidates sit on a grid evenly spaced in `ln f` (15–400 Hz);
   - each frame's row is z-scored;
   - `pitch_track` is the per-frame argmax of this map, with decaying
     subharmonic-summation weights and a voicing threshold.
2. **Coarse search** (`search.rs`). The engine is heard where
   `ln f0 = c + ln rpm(t − τ)`, with `c = ln k` and `τ` the offset. So the mean
   salience along that curve,
   `score(τ, c) = Σ_t w(t)·Z(t + τ, c + ln rpm(t)) / W(τ)`,
   is a **2-D cross-correlation** of the salience map with an image of the
   log-RPM curve.
   - In log frequency, `k` is a pure **shift**: the search finds it rather
     than being told it.
   - Locking onto another harmonic only moves the peak along `c`, never
     along `τ`.
   - The correlation runs by FFT along time for every shift `c`
     (`O(N log N)`), with 0.1 s frames, 2 % pitch bins and six flat-weighted
     harmonics. High harmonics are sharper in `ln f`, so they sharpen the
     match.
   - `w(t) = 0.05 + |d ln rpm/dt|` weights the instants that carry timing:
     braking and acceleration. A governed top speed looks the same a lap later
     and pins nothing.
   - Each lag's mean is shrunk by a 40 s pseudo-count of zero-score frames, so
     a short overlap cannot score high by chance.
3. **Refinement** (`refine.rs`): the same score is evaluated directly
   - on 20 ms frames, a 0.5 % pitch grid and a 5 ms offset grid,
     ±0.2 s around the coarse peak;
   - then parabolically interpolated.

   The pass is streamed frame by frame, scoring only the band of candidates
   the examined offsets can reach.
4. **Confidence**:
   - `score` is the matched mean salience;
   - `peak_ratio` is the winning coarse peak over the best rival lag at least
     **2 s** away.
   - The winner must lie in the search window, but the rival may lie anywhere.
     A window that excludes the true alignment therefore finds that alignment
     as a stronger rival, instead of crowning a lap-shifted look-alike.
   - `is_confident` requires `score ≥ 0.5` and `peak_ratio ≥ 1.4`.
   - `confidence()` maps the ratio onto a `0…1` bar: 0.5 at the threshold,
     1 at 4:1, never above ½ when rejected.
5. **Never auto-applied.** A confident estimate becomes a one-click proposal
   that the operator applies (`SyncStatus.autoAudio(confidence)`). Anything
   weaker reads *"No confident match"*.

### Why not the hard pitch track

The plan was prototyped first, on the operator's two real onboard clips (RBC
Honda four-stroke, wind-dominated audio, other karts audible). Per-frame pitch
decisions landed on any harmonic of the true RPM only 35–50 % of the time, even
with whitening, harmonic summation, 1 s frames or Viterbi smoothing. Octave and
harmonic errors are ±0.7–1.1 in `ln f`, against a ±0.25 spread of `ln RPM`, so
they dominate a Pearson correlation of `ln pitch`. The results:

| Prototype (real footage) | T1 ↔ stint-1 | T2 ↔ stint-2 | Mismatched pairs |
| --- | --- | --- | --- |
| Hard pitch + NCC of `ln f0` | right offset, ratio 1.17 | **wrong** offset | ratio 1.05–1.2 |
| Hard pitch + NCC of `d ln f0/dt` (Viterbi) | right, ratio 2.1 | **wrong** | a false 1.41 |
| Salience × log-RPM curve (this ADR) | right, ratio 3.7 | right, ratio 3.4 | ratio 1.03–1.07 |

The soft search keeps every frame's full salience profile, so weak evidence
accumulates along the true curve instead of being lost to a per-frame argmax.
It also recovers `k = 1/119.99`, the textbook four-stroke firing rate, which is
an independent sign that the match is real.

## Threshold study

Every fixture is synthesised in the tests (`tests/analysis/audio_sync.rs`,
`support/engine_audio.rs`):

- harmonics of `k·RPM` with randomised timbre;
- buried under pink noise, wind gusts and a 6 dB AGC step;
- rendered from a fixture-free kart lap profile, or from the public
  `aim_official_test.xrk` RPM;
- at known offsets. No audio file is committed.

The study's rows:

| Fixture | Truth | Score | Ratio | Verdict |
| --- | --- | --- | --- | --- |
| k = 1/120, 1/60, 1/30 (9 lap session) | −37.3 s | 5.1–5.4 | 2.42–2.92 | confident, ≤ 12 ms |
| offsets −120, −3.2, 0, +47.5 s (8 kHz) | as given | 5.0–5.1 | 1.94–3.09 | confident, ≤ 8 ms |
| random offsets (property sweep) | as drawn | 5.0–5.3 | 1.83–2.73 | confident, ≤ 9 ms |
| public sample RPM, k = 1/60, 1/120 | −200, −350 s | 3.7–3.9 | 2.06–2.59 | confident, ≤ 14 ms |
| weak engine (level 0.012) | −60 s | 1.85 | 2.16 | confident, 5 ms |
| 75 s clip (≈ 2 laps) | −200 s | 5.16 | 1.70 | confident, 6 ms |
| a second kart 15 s behind in the audio | −90 s | 4.61 | 1.71 | confident, 9 ms |
| ten-minute clip (ignored bench) | −80 s | 5.02 | 2.20 | confident, 3 ms |
| audio vs another session, same track (×3) | — | 1.6–2.1 | **1.09–1.26** | not confident |
| noise only (×2) | — | 0.12–0.15 | 1.01–1.02 | not confident |
| window excluding the truth | — | 1.64 | 0.34 | not confident |
| **Real:** T1 (606 s) ↔ stint-1 | manual check | 3.09 | **3.59** | confident, k = 1/119.99 |
| **Real:** T2 (358 s) ↔ stint-2 | manual check | 2.46 | **3.30** | confident |
| **Real:** T1 ↔ stint-2, T2 ↔ stint-1 | — | 0.75–0.84 | **1.03–1.07** | not confident |

True matches start at ratio 1.68, and no false one reached 1.26. The threshold
of **1.4** sits between them, with margin either side, and real footage clears
it by 2.5×. The score floor of 0.5 is three times the noise cases and rejects a
silent or engine-less clip whatever its ratio.

## Failure modes

- **Few, identical laps.** Racing laps repeat (real lap-lag correlation of
  `ln RPM` is 0.84–0.92), so the usual rival is the same curve one lap off. A
  clip covering only one or two racing laps can therefore fall below 1.4. That
  is reported honestly as *"No confident match"*; out-laps, in-laps, traffic and
  the slope weighting are what separate real sessions.
- **Another engine dominates** the audio (a kart close behind for most of the
  clip). Its curve is a time-shifted copy of a similar RPM trace. The ratio
  drops; the fixture with a quieter second kart still clears 1.4.
- **Logger RPM latency.** If the logger's RPM is filtered with a lag, the
  estimate carries that lag. It cannot be measured from audio alone; the
  operator's line-crossing anchor and two-point sync remain the reference.
- **Clock drift.** One offset is estimated at equal clocks: applying it resets
  the two-point rate to 1, and two-point sync can be layered on top.
- **No engine audio, or no RPM channel.** The button is disabled with the
  reason in its help text. Silent audio, constant RPM and overlaps under 20 s
  are typed errors, never a guess.

## Consequences

- **Rust core.** `audio_sync` (≈ 1 750 lines with unit tests) and one FFI call,
  `SessionHandle::estimate_audio_sync(rpm_channel, pcm, sample_rate, min, max)`,
  which returns the estimate plus `confident` and `confidence`. The thresholds
  live in Rust only.
- **Swift.**
  - `AVAssetAudioPCMSource` decodes with `AVAssetReader`, and `PCMDecimator`
    downmixes and decimates chunk by chunk through `vDSP_desamp`, zero-phase.
    The source-rate track is never held; the ~8.8 kHz mono output costs about
    2 MB per minute.
  - `AudioSyncCoordinator` moves the result onto the video clock and checks
    cancellation between steps.
  - `VideoReviewModel` publishes `autoSyncState` and applies a proposal only
    on `applyAudioSync`.
- **Performance** (release, Apple silicon): the real 606 s clip is decoded,
  decimated and matched in **0.87 s** (decode 0.31 s, match 0.63 s), well inside
  the 5 s budget.
- **Persistence:** `SyncStatus.autoAudio(confidence)` is additive, with no
  schema bump. Builds from before 9.8 read it, through the lenient status
  decode, as *not synced*.
