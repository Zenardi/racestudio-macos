//! Synthetic engine audio for the audio-sync tests (issue 9.8).
//!
//! Everything here is generated in-test and deterministic (a seeded LCG), so no
//! audio file is ever committed. An "engine" is a sum of harmonics of a pitch
//! that tracks an RPM trace — `f0(t) = k·RPM(t − offset)` — buried under pink
//! noise, wind bursts and a 6 dB level change, the way an onboard camera hears
//! it. The RPM traces are either a fixture-free kart lap profile
//! ([`kart_rpm`]) or the public `aim_official_test.xrk` sample's real `RPM`
//! channel ([`fixture_rpm`]) — never a user's session.

use std::f64::consts::PI;

use racestudio_decode::decode_session;

use super::fixtures::fixture_path;

/// A tiny deterministic LCG, so every synthetic signal is reproducible.
pub struct Lcg(u64);

impl Lcg {
    pub fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(1))
    }

    /// A uniform value in `[0, 1)`.
    pub fn next_f64(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 11) as f64 / (1u64 << 53) as f64
    }

    /// A uniform value in `[lo, hi)`.
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.next_f64()
    }

    /// A zero-mean, unit-variance approximately Gaussian value (sum of 4 uniforms).
    pub fn gauss(&mut self) -> f64 {
        let s: f64 = (0..4).map(|_| self.next_f64()).sum();
        (s - 2.0) * (3.0_f64).sqrt()
    }
}

/// A pure sine of `freq` Hz and amplitude `amp`, `seconds` long at `fs` Hz.
pub fn tone(freq: f64, fs: u32, seconds: f64, amp: f64) -> Vec<f32> {
    let n = (seconds * f64::from(fs)) as usize;
    (0..n)
        .map(|i| (amp * (2.0 * PI * freq * i as f64 / f64::from(fs)).sin()) as f32)
        .collect()
}

/// White noise of RMS `rms`, `seconds` long at `fs` Hz.
pub fn white_noise(fs: u32, seconds: f64, rms: f64, seed: u64) -> Vec<f32> {
    let mut rng = Lcg::new(seed);
    let n = (seconds * f64::from(fs)) as usize;
    (0..n).map(|_| (rms * rng.gauss()) as f32).collect()
}

/// A fixture-free kart lap profile: `laps` laps of a five-corner track sampled
/// at 20 Hz from `t0` seconds, RPM between ~2 800 and ~6 200 (an RBC-Honda-like
/// four-stroke), each corner's entry speed and each straight's length jittered
/// lap to lap so no two laps are identical. `(seconds, rpm)` pairs.
pub fn kart_rpm(t0: f64, laps: usize, seed: u64) -> Vec<(f64, f64)> {
    let mut rng = Lcg::new(seed);
    // (straight length s, corner minimum rpm, corner length s) per corner.
    let corners = [
        (7.0, 3300.0, 1.6),
        (4.0, 4100.0, 1.2),
        (9.5, 2900.0, 2.0),
        (3.0, 4400.0, 0.9),
        (6.0, 3600.0, 1.4),
    ];
    let dt = 0.05;
    let mut out = Vec::new();
    let mut t = t0;
    let mut rpm = 3000.0;
    for _ in 0..laps {
        for &(straight, min_rpm, corner) in &corners {
            let straight = straight * rng.range(0.94, 1.06);
            let min_rpm = min_rpm + rng.range(-180.0, 180.0);
            let corner = corner * rng.range(0.9, 1.1);
            // Accelerate along the straight towards the governed top end.
            let mut s = 0.0;
            while s < straight {
                rpm += (6300.0 - rpm) * 0.35 * dt;
                out.push((t, rpm));
                t += dt;
                s += dt;
            }
            // Brake hard, then roll through the corner at its minimum.
            let mut s = 0.0;
            while s < corner {
                rpm += (min_rpm - rpm) * 2.6 * dt;
                out.push((t, rpm));
                t += dt;
                s += dt;
            }
        }
    }
    out
}

/// The public `aim_official_test.xrk` sample's real `RPM` channel as
/// `(seconds, rpm)` pairs, or `None` (with a skip note) when the git-ignored
/// sample has not been fetched (`make fixtures`).
pub fn fixture_rpm() -> Option<Vec<(f64, f64)>> {
    let path = fixture_path("aim_official_test.xrk");
    match std::fs::read(&path) {
        Ok(bytes) if bytes.starts_with(b"<h") => {}
        _ => {
            eprintln!(
                "skipping: {} is not a real .xrk sample — run `make fixtures` to fetch it",
                path.display()
            );
            return None;
        }
    }
    let session = decode_session(&path).expect("decode the public sample");
    let rpm = session
        .channels()
        .iter()
        .find(|c| c.name() == "RPM")
        .expect("the public sample logs RPM");
    Some(
        rpm.samples()
            .iter()
            .map(|&(ms, v)| (ms / 1000.0, v))
            .collect(),
    )
}

/// The trace's value at `t` by linear interpolation, or `None` outside it.
fn rpm_at(rpm: &[(f64, f64)], t: f64) -> Option<f64> {
    let first = rpm.first()?;
    let last = rpm.last()?;
    if t < first.0 || t > last.0 {
        return None;
    }
    let i = rpm.partition_point(|&(ts, _)| ts <= t);
    if i == 0 {
        return Some(first.1);
    }
    if i >= rpm.len() {
        return Some(last.1);
    }
    let (t0, v0) = rpm[i - 1];
    let (t1, v1) = rpm[i];
    let w = if t1 > t0 { (t - t0) / (t1 - t0) } else { 0.0 };
    Some(v0 + (v1 - v0) * w)
}

/// How an onboard camera hears an engine. `pitch_per_rpm` is the unknown `k` of
/// `f0 = k·RPM` (1/120 for a four-stroke single's firing rate, 1/60 for its
/// crank); the harmonic amplitudes are the engine's timbre; everything else is
/// what buries it.
#[derive(Debug, Clone)]
pub struct EngineAudio {
    pub pitch_per_rpm: f64,
    pub harmonics: Vec<f64>,
    pub engine_level: f64,
    pub pink_rms: f64,
    pub wind_rms: f64,
    /// Apply a 6 dB gain step halfway through (a camera's AGC kicking in).
    pub level_change: bool,
}

impl Default for EngineAudio {
    fn default() -> Self {
        Self {
            pitch_per_rpm: 1.0 / 120.0,
            harmonics: vec![0.55, 1.0, 0.6, 0.45, 0.3, 0.2],
            engine_level: 0.05,
            pink_rms: 0.08,
            wind_rms: 0.25,
            level_change: true,
        }
    }
}

impl EngineAudio {
    /// The same engine with pitch `k·RPM`.
    pub fn with_k(mut self, k: f64) -> Self {
        self.pitch_per_rpm = k;
        self
    }

    /// `duration` seconds of camera audio at `fs`, aligned so that video time
    /// `t` hears the engine at session time `t − offset` (no engine before or
    /// after the trace). `seed` fixes the noise and the timbre's jitter.
    pub fn render(
        &self,
        rpm: &[(f64, f64)],
        offset: f64,
        duration: f64,
        fs: u32,
        seed: u64,
    ) -> Vec<f32> {
        let mut rng = Lcg::new(seed);
        let fsf = f64::from(fs);
        let n = (duration * fsf) as usize;
        let amps: Vec<f64> = self
            .harmonics
            .iter()
            .map(|a| a * rng.range(0.8, 1.2) * self.engine_level)
            .collect();
        let mut phases: Vec<f64> = amps.iter().map(|_| rng.range(0.0, 2.0 * PI)).collect();
        let wind = wind_envelope(duration, &mut rng);
        let mut pink = PinkNoise::default();
        let mut brown = 0.0;
        let mut out = Vec::with_capacity(n);
        for i in 0..n {
            let t = i as f64 / fsf;
            let mut s = 0.0;
            if let Some(r) = rpm_at(rpm, t - offset) {
                let f0 = self.pitch_per_rpm * r;
                for (h, (amp, phase)) in amps.iter().zip(phases.iter_mut()).enumerate() {
                    let f = f0 * (h + 1) as f64;
                    if f < fsf / 2.0 {
                        s += amp * phase.sin();
                    }
                    *phase = (*phase + 2.0 * PI * f / fsf) % (2.0 * PI);
                }
            }
            s += self.pink_rms * pink.next(&mut rng);
            // Wind: low-passed (brown) noise gated by the burst envelope.
            brown = 0.995 * brown + 0.1 * rng.gauss();
            s += self.wind_rms * wind_at(&wind, t) * brown;
            if self.level_change && t >= duration / 2.0 {
                s *= 2.0;
            }
            out.push(s as f32);
        }
        out
    }
}

/// Wind gusts: `(start, length)` bursts of 1–4 s every ~10 s.
fn wind_envelope(duration: f64, rng: &mut Lcg) -> Vec<(f64, f64)> {
    let mut bursts = Vec::new();
    let mut t = rng.range(0.0, 8.0);
    while t < duration {
        let len = rng.range(1.0, 4.0);
        bursts.push((t, len));
        t += len + rng.range(4.0, 12.0);
    }
    bursts
}

fn wind_at(bursts: &[(f64, f64)], t: f64) -> f64 {
    for &(start, len) in bursts {
        if t >= start && t < start + len {
            // A raised-cosine gust.
            return 0.5 - 0.5 * (2.0 * PI * (t - start) / len).cos();
        }
    }
    0.0
}

/// Paul Kellet's economy pink-noise filter over white noise (≈ −3 dB/octave).
#[derive(Default)]
struct PinkNoise {
    b0: f64,
    b1: f64,
    b2: f64,
}

impl PinkNoise {
    fn next(&mut self, rng: &mut Lcg) -> f64 {
        let white = rng.gauss();
        self.b0 = 0.99765 * self.b0 + white * 0.099_046;
        self.b1 = 0.963 * self.b1 + white * 0.296_516_4;
        self.b2 = 0.57 * self.b2 + white * 1.052_691_3;
        (self.b0 + self.b1 + self.b2 + white * 0.1848) * 0.25
    }
}
