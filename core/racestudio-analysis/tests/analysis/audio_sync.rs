//! Automatic video sync from engine sound (issue 9.8).
//!
//! - **Pitch front end** (`pitch_track_*`): the harmonic-salience pitch tracker
//!   finds a pure tone to within 1 Hz and marks silent / noisy frames unvoiced.
//! - **Offset** (`estimate_offset_*`): synthetic engine audio rendered from an
//!   RPM trace at a known offset is aligned to within one 29.97 fps frame,
//!   whatever the pitch/RPM ratio `k`, inside the search window; flat RPM,
//!   silence, short clips and bad input are typed errors, and noise never
//!   yields a confident proposal.
//! - **Threshold study** (`confidence_threshold_*`): the confidence rule
//!   accepts every true pairing of the fixture set and rejects every false one
//!   (it prints the score / ratio table the ADR records).
//! - **Property / performance**: random offsets across the window, the public
//!   sample's real RPM, and an ignored ten-minute end-to-end budget check.
//!
//! Every signal is synthesised in the test (see `support::engine_audio`); no
//! audio file is committed. The pitch tests and one alignment test run at the
//! production ~8 kHz; the rest at 4 kHz, which the method handles identically
//! (frames are sized in seconds) for a quarter of the debug-build cost.

use racestudio_analysis::audio_sync::{
    estimate_offset, pitch_track, AudioSyncError, PitchConfig, SyncEstimate,
    MIN_CONFIDENT_PEAK_RATIO, MIN_CONFIDENT_SCORE,
};

use crate::support::engine_audio::{fixture_rpm, kart_rpm, tone, white_noise, EngineAudio, Lcg};

/// The production decimated rate.
const FS: u32 = 8000;

/// The cheaper rate most alignment tests run at.
const TEST_FS: u32 = 4000;

/// One frame of 29.97 fps footage — the alignment tolerance.
const FRAME_S: f64 = 1001.0 / 30000.0;

/// The kart session the offset tests align against: nine laps of the
/// fixture-free profile, logged from t = 12.5 s (≈ 12.5…400 s).
fn session() -> Vec<(f64, f64)> {
    kart_rpm(12.5, 9, 11)
}

/// Assert `estimate` lands within one frame of `truth`.
fn assert_within_frame(estimate: &SyncEstimate, truth: f64, label: &str) {
    assert!(
        (estimate.offset_s - truth).abs() <= FRAME_S,
        "{label}: estimated {:.4} s, truth {truth} s (score {:.2}, ratio {:.2})",
        estimate.offset_s,
        estimate.score,
        estimate.peak_ratio
    );
}

// --------------------------------------------------------------------------- //
// Pitch front end
// --------------------------------------------------------------------------- //

#[test]
fn pitch_track_recovers_pure_tone() {
    for freq in [50.0, 100.0, 200.0] {
        let pcm = tone(freq, FS, 3.0, 0.5);

        let track = pitch_track(&pcm, FS, &PitchConfig::default());

        assert!(!track.is_empty(), "{freq} Hz: no frames");
        for point in &track {
            assert!(
                point.confidence > 0.0,
                "{freq} Hz: frame at {} unvoiced",
                point.t
            );
            assert!(
                (point.f0 - freq).abs() <= 1.0,
                "{freq} Hz: f0 {} at t {}",
                point.f0,
                point.t
            );
        }
    }
}

#[test]
fn pitch_track_frames_are_centred_on_a_uniform_hop() {
    let pcm = tone(100.0, FS, 3.0, 0.5);
    let cfg = PitchConfig::default();

    let track = pitch_track(&pcm, FS, &cfg);

    // A 0.5 s frame rounds to 4096 samples at 8 kHz, so frame i is centred at
    // (i·hop·fs + 2048) / fs.
    for (i, point) in track.iter().enumerate() {
        let expected = (i as f64 * (cfg.hop_s * f64::from(FS)).round() + 2048.0) / f64::from(FS);
        assert!(
            (point.t - expected).abs() < 1e-9,
            "frame {i}: t {}",
            point.t
        );
    }
}

#[test]
fn pitch_track_marks_silence_unvoiced() {
    let silence = vec![0.0_f32; 3 * FS as usize];

    let track = pitch_track(&silence, FS, &PitchConfig::default());

    assert!(!track.is_empty());
    assert!(track.iter().all(|p| p.confidence == 0.0 && p.f0 == 0.0));
}

#[test]
fn pitch_track_marks_broadband_noise_unvoiced() {
    let noise = white_noise(FS, 10.0, 0.2, 7);

    let track = pitch_track(&noise, FS, &PitchConfig::default());

    let voiced = track.iter().filter(|p| p.confidence > 0.0).count();
    assert!(
        voiced * 20 <= track.len(),
        "{voiced} of {} noise frames voiced",
        track.len()
    );
}

#[test]
fn pitch_track_is_empty_for_audio_shorter_than_a_frame() {
    let short = tone(100.0, FS, 0.1, 0.5);

    assert!(pitch_track(&short, FS, &PitchConfig::default()).is_empty());
    assert!(pitch_track(&[], FS, &PitchConfig::default()).is_empty());
    assert!(pitch_track(&short, 0, &PitchConfig::default()).is_empty());
}

// --------------------------------------------------------------------------- //
// Offset estimation
// --------------------------------------------------------------------------- //

#[test]
fn estimate_offset_recovers_known_offset_within_one_frame() {
    let rpm = session();
    for (seed, offset) in [-120.0, -3.2, 0.0, 47.5].into_iter().enumerate() {
        let pcm = EngineAudio::default().render(&rpm, offset, 90.0, FS, 100 + seed as u64);

        let estimate = estimate_offset(&pcm, FS, &rpm, (-400.0, 200.0)).expect("estimate");

        assert_within_frame(&estimate, offset, &format!("offset {offset}"));
        assert!(estimate.is_confident(), "offset {offset}: {estimate:?}");
    }
}

#[test]
fn estimate_offset_is_invariant_to_harmonic_ratio() {
    let rpm = session();
    let truth = -37.3;
    for k in [1.0 / 60.0, 1.0 / 120.0, 2.0 / 60.0] {
        let pcm = EngineAudio::default()
            .with_k(k)
            .render(&rpm, truth, 90.0, TEST_FS, 7);

        let estimate = estimate_offset(&pcm, TEST_FS, &rpm, (-400.0, 200.0)).expect("estimate");

        assert_within_frame(&estimate, truth, &format!("k = {k}"));
        assert!(estimate.is_confident(), "k = {k}: {estimate:?}");
    }
}

#[test]
fn estimate_offset_rejects_flat_rpm() {
    let flat: Vec<(f64, f64)> = (0..6000).map(|i| (i as f64 * 0.05, 5000.0)).collect();
    let pcm = EngineAudio::default().render(&flat, 0.0, 90.0, TEST_FS, 3);

    let result = estimate_offset(&pcm, TEST_FS, &flat, (-300.0, 120.0));

    assert_eq!(result.unwrap_err(), AudioSyncError::FlatSignal);
}

#[test]
fn estimate_offset_respects_search_window() {
    let rpm = session();
    let truth = -40.0;
    let pcm = EngineAudio::default().render(&rpm, truth, 90.0, TEST_FS, 21);

    let inside = estimate_offset(&pcm, TEST_FS, &rpm, (-50.0, -30.0)).expect("inside");
    let outside = estimate_offset(&pcm, TEST_FS, &rpm, (0.0, 100.0)).expect("outside");

    assert_within_frame(&inside, truth, "window around the truth");
    assert!(
        (0.0..=100.0).contains(&outside.offset_s),
        "outside: {outside:?}"
    );
    assert!(
        !outside.is_confident(),
        "a window without the truth must not be confident: {outside:?}"
    );
}

#[test]
fn estimate_offset_never_confident_on_noise() {
    let rpm = session();
    let noise = EngineAudio {
        engine_level: 0.0,
        ..EngineAudio::default()
    }
    .render(&rpm, 0.0, 90.0, TEST_FS, 5);

    match estimate_offset(&noise, TEST_FS, &rpm, (-400.0, 200.0)) {
        Ok(estimate) => assert!(!estimate.is_confident(), "noise: {estimate:?}"),
        Err(error) => assert_eq!(error, AudioSyncError::NoPitch),
    }
}

#[test]
fn estimate_offset_rejects_audio_shorter_than_twenty_seconds() {
    let rpm = session();
    let pcm = EngineAudio::default().render(&rpm, -60.0, 15.0, TEST_FS, 1);

    let result = estimate_offset(&pcm, TEST_FS, &rpm, (-400.0, 200.0));

    assert_eq!(result.unwrap_err(), AudioSyncError::TooShort);
}

#[test]
fn estimate_offset_rejects_rpm_shorter_than_twenty_seconds() {
    let rpm: Vec<(f64, f64)> = session().into_iter().take(200).collect(); // 10 s
    let pcm = EngineAudio::default().render(&rpm, 0.0, 60.0, TEST_FS, 1);

    let result = estimate_offset(&pcm, TEST_FS, &rpm, (-100.0, 100.0));

    assert_eq!(result.unwrap_err(), AudioSyncError::TooShort);
}

#[test]
fn estimate_offset_rejects_a_window_without_enough_overlap() {
    let rpm = session();
    let pcm = EngineAudio::default().render(&rpm, -60.0, 60.0, TEST_FS, 1);

    // Every offset in the window leaves the clip far from the session.
    let result = estimate_offset(&pcm, TEST_FS, &rpm, (-5000.0, -4000.0));

    assert_eq!(result.unwrap_err(), AudioSyncError::TooShort);
}

#[test]
fn estimate_offset_rejects_missing_rpm() {
    let pcm = white_noise(TEST_FS, 60.0, 0.1, 2);
    let stalled: Vec<(f64, f64)> = (0..2000).map(|i| (i as f64 * 0.05, 0.0)).collect();

    for rpm in [Vec::new(), stalled, vec![(0.0, f64::NAN), (1.0, -5.0)]] {
        let result = estimate_offset(&pcm, TEST_FS, &rpm, (-100.0, 100.0));

        assert_eq!(result.unwrap_err(), AudioSyncError::NoRpm);
    }
}

#[test]
fn estimate_offset_rejects_silent_audio() {
    let silence = vec![0.0_f32; 60 * TEST_FS as usize];

    let result = estimate_offset(&silence, TEST_FS, &session(), (-400.0, 200.0));

    assert_eq!(result.unwrap_err(), AudioSyncError::NoPitch);
}

#[test]
fn estimate_offset_rejects_invalid_input() {
    let rpm = session();
    let pcm = white_noise(TEST_FS, 30.0, 0.1, 2);

    for (rate, window) in [
        (0, (-10.0, 10.0)),
        (TEST_FS, (10.0, -10.0)),
        (TEST_FS, (f64::NAN, 10.0)),
        (TEST_FS, (-10.0, f64::INFINITY)),
    ] {
        let result = estimate_offset(&pcm, rate, &rpm, window);

        assert_eq!(
            result.unwrap_err(),
            AudioSyncError::InvalidInput,
            "rate {rate}, window {window:?}"
        );
    }
}

// --------------------------------------------------------------------------- //
// Threshold study, property sweep, performance
// --------------------------------------------------------------------------- //

/// One fixture of the threshold study: its name, the audio, the RPM trace it
/// is matched against, the search window and — for a true pairing — the offset
/// it must recover.
struct Case {
    name: String,
    pcm: Vec<f32>,
    rpm: Vec<(f64, f64)>,
    window: (f64, f64),
    truth: Option<f64>,
}

/// The study's fixtures: the hardest true pairings — a weak engine, a short
/// clip, a second kart's engine in the audio (the easy ones are the offset and
/// invariance tests above) — then false ones: each pitch ratio's audio against
/// another session on the same track, noise, and a window that excludes the
/// truth.
fn study_cases() -> Vec<Case> {
    let rpm = session();
    let other = kart_rpm(3.0, 9, 99);
    let wide = (-400.0, 200.0);
    let mut cases = Vec::new();
    let mut add = |name: &str, pcm, rpm: &[(f64, f64)], window, truth| {
        let (name, rpm) = (name.to_string(), rpm.to_vec());
        cases.push(Case {
            name,
            pcm,
            rpm,
            window,
            truth,
        });
    };
    let weak = EngineAudio {
        engine_level: 0.012,
        ..EngineAudio::default()
    };
    add(
        "weak engine (level 0.012)",
        weak.render(&rpm, -60.0, 90.0, TEST_FS, 32),
        &rpm,
        wide,
        Some(-60.0),
    );
    let short = EngineAudio::default().render(&rpm, -200.0, 75.0, TEST_FS, 33);
    add("75 s clip", short, &rpm, wide, Some(-200.0));
    let ours = EngineAudio::default().render(&rpm, -90.0, 90.0, TEST_FS, 41);
    let theirs = EngineAudio {
        engine_level: 0.03,
        pink_rms: 0.0,
        wind_rms: 0.0,
        ..EngineAudio::default()
    }
    .render(&rpm, -75.0, 90.0, TEST_FS, 42);
    let both = ours.iter().zip(&theirs).map(|(a, b)| a + b).collect();
    add("a second kart 15 s behind", both, &rpm, wide, Some(-90.0));
    for (k, offset, seed) in [
        (1.0 / 120.0, -37.3, 7),
        (1.0 / 60.0, 12.0, 8),
        (2.0 / 60.0, -150.0, 9),
    ] {
        let pcm = EngineAudio::default()
            .with_k(k)
            .render(&rpm, offset, 90.0, TEST_FS, seed);
        add(
            &format!("k=1/{:.0} vs another session", 1.0 / k),
            pcm,
            &other,
            wide,
            None,
        );
    }
    let noise = EngineAudio {
        engine_level: 0.0,
        ..EngineAudio::default()
    };
    for seed in [1, 2] {
        add(
            &format!("noise {seed}"),
            noise.render(&rpm, 0.0, 90.0, TEST_FS, seed),
            &rpm,
            wide,
            None,
        );
    }
    add("window without the truth", ours, &rpm, (-30.0, 200.0), None);
    cases
}

#[test]
fn confidence_threshold_separates_true_from_false_matches() {
    let mut failures = Vec::new();
    for case in study_cases() {
        let result = estimate_offset(&case.pcm, TEST_FS, &case.rpm, case.window);
        let Ok(estimate) = result else {
            eprintln!("{:<32} error {:?}", case.name, result);
            if case.truth.is_some() {
                failures.push(format!("{}: {:?}", case.name, result));
            }
            continue;
        };
        eprintln!(
            "{:<32} offset {:>9.3}  score {:>5.2}  ratio {:>5.2}  confident {}",
            case.name,
            estimate.offset_s,
            estimate.score,
            estimate.peak_ratio,
            estimate.is_confident()
        );
        match case.truth {
            Some(truth)
                if (estimate.offset_s - truth).abs() > FRAME_S || !estimate.is_confident() =>
            {
                failures.push(format!("{}: missed {truth} with {estimate:?}", case.name));
            }
            None if estimate.is_confident() => {
                failures.push(format!("{}: confident false match {estimate:?}", case.name));
            }
            _ => {}
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn estimate_offset_recovers_random_offsets_across_the_window() {
    // Deterministic sweep (an in-test LCG, as the FFT tests do, rather than
    // proptest — see tests/analysis/fft.rs).
    let rpm = session();
    let mut rng = Lcg::new(2024);
    for draw in 0..3 {
        let offset = rng.range(-250.0, 60.0);
        let k = [1.0 / 120.0, 1.0 / 60.0, 2.0 / 60.0][draw % 3];
        let pcm =
            EngineAudio::default()
                .with_k(k)
                .render(&rpm, offset, 90.0, TEST_FS, 500 + draw as u64);

        let estimate = estimate_offset(&pcm, TEST_FS, &rpm, (-400.0, 90.0)).expect("estimate");

        assert_within_frame(&estimate, offset, &format!("draw {draw}"));
        assert!(estimate.is_confident(), "draw {draw}: {estimate:?}");
    }
}

#[test]
fn estimate_offset_aligns_the_public_sample_rpm() {
    let Some(rpm) = fixture_rpm() else {
        return;
    };
    for (k, offset, seed) in [(1.0 / 60.0, -200.0, 5), (1.0 / 120.0, -350.0, 6)] {
        let pcm = EngineAudio::default()
            .with_k(k)
            .render(&rpm, offset, 90.0, TEST_FS, seed);

        let estimate = estimate_offset(&pcm, TEST_FS, &rpm, (-600.0, 120.0)).expect("estimate");

        assert_within_frame(&estimate, offset, &format!("public sample, k = {k}"));
        assert!(
            estimate.is_confident(),
            "public sample, k = {k}: {estimate:?}"
        );
    }
}

/// A ten-minute clip against a twelve-minute session, end to end — the issue's
/// ≤ 5 s budget. Ignored by default (debug builds are ~50× slower); run with
/// `cargo test --release -p racestudio-analysis --test analysis -- --ignored
/// ten_minute`.
#[test]
#[ignore]
fn ten_minute_clip_estimates_within_budget() {
    let rpm = kart_rpm(5.0, 20, 77);
    let pcm = EngineAudio::default().render(&rpm, -80.0, 600.0, FS, 78);

    let start = std::time::Instant::now();
    let estimate = estimate_offset(&pcm, FS, &rpm, (-800.0, 600.0)).expect("estimate");
    let elapsed = start.elapsed();

    eprintln!("10-minute clip: {elapsed:?}, {estimate:?}");
    assert_within_frame(&estimate, -80.0, "ten-minute clip");
    assert!(elapsed.as_secs_f64() < 5.0, "took {elapsed:?}");
}

#[test]
fn confidence_level_is_half_at_the_threshold_and_full_at_four_to_one() {
    let at = |score: f64, peak_ratio: f64| SyncEstimate {
        offset_s: 0.0,
        score,
        peak_ratio,
        pitch_per_rpm: 1.0 / 120.0,
    };
    let threshold = at(2.0, MIN_CONFIDENT_PEAK_RATIO);

    assert!((threshold.confidence() - 0.5).abs() < 1e-12);
    assert_eq!(at(2.0, 4.0).confidence(), 1.0);
    assert_eq!(at(2.0, 9.0).confidence(), 1.0, "saturates");
    assert_eq!(at(2.0, 1.0).confidence(), 0.0, "no better than its rival");
    assert_eq!(at(2.0, 0.5).confidence(), 0.0, "worse than its rival");
    assert!(at(2.0, 2.0).confidence() > 0.5 && at(2.0, 2.0).confidence() < 1.0);
    assert!(at(2.0, 1.2).confidence() > 0.0 && at(2.0, 1.2).confidence() < 0.5);
    // A rejected estimate never reads as confident, whatever its ratio.
    let weak_score = at(MIN_CONFIDENT_SCORE / 2.0, 3.0);
    assert!(!weak_score.is_confident());
    assert!(weak_score.confidence() < 0.5);
}

#[test]
fn audio_sync_errors_read_as_sentences() {
    for (error, text) in [
        (
            AudioSyncError::TooShort,
            "too little overlapping audio and RPM to align",
        ),
        (
            AudioSyncError::NoPitch,
            "no engine pitch found in the audio",
        ),
        (
            AudioSyncError::NoRpm,
            "the RPM channel has no usable samples",
        ),
        (
            AudioSyncError::FlatSignal,
            "the RPM never changes, so there is nothing to align",
        ),
        (
            AudioSyncError::InvalidInput,
            "invalid sample rate or search window",
        ),
    ] {
        assert_eq!(error.to_string(), text);
    }
}
