//! Criterion benches for lazy channel opening vs eager decoding (issue 7.2).
//!
//! Tracked benchmark (`scripts/bench_thresholds.json`):
//! - `open/channel_index` — open a ~1M-sample container and build its lazy
//!   channel index without materializing a single sample vector (the fast path a
//!   large session takes on open).
//!
//! For contrast the bench also measures `open/decode_all` (eager
//! [`decode_channels`]). The `.xrk` is synthesized in-memory and written to a temp
//! file once, so the bench is self-contained and needs no fixture.

use std::path::PathBuf;

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use racestudio_decode::{decode_channels, open_container};

const MAGIC: [u8; 2] = [0x3C, 0x68];
const CHANNELS: u16 = 8;
const SAMPLES_PER_CHANNEL: i32 = 125_000; // 8 * 125k = 1M samples
const BURST: usize = 2_500;

fn token_to_u32(token: &str) -> u32 {
    let mut bytes = token.as_bytes().to_vec();
    while bytes.len() < 4 {
        bytes.push(b' ');
    }
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
    let tok = token_to_u32(token);
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&tok.to_le_bytes());
    out.extend_from_slice(&(payload.len() as i32).to_le_bytes());
    out.push(0);
    out.push(b'>');
    out.extend_from_slice(payload);
    out.push(b'<');
    out.extend_from_slice(&tok.to_le_bytes());
    let checksum = (payload.iter().map(|&b| u32::from(b)).sum::<u32>() & 0xFFFF) as u16;
    out.extend_from_slice(&checksum.to_le_bytes());
    out.push(b'>');
    out
}

fn chs(index: u16, name: &str, decoder: u8, data_size: u8, period_us: u32) -> Vec<u8> {
    let mut p = vec![0u8; 112];
    p[0..2].copy_from_slice(&index.to_le_bytes());
    p[12] = 16; // km/h — an arbitrary interpolated unit
    p[20] = decoder;
    let nb = name.as_bytes();
    p[32..32 + nb.len()].copy_from_slice(nb);
    p[64..68].copy_from_slice(&period_us.to_le_bytes());
    p[72] = data_size;
    p
}

/// An `.xrk` with `CHANNELS` f32 channels at 100 Hz, `SAMPLES_PER_CHANNEL` each,
/// carried as `(M` bursts of `BURST` samples so the file stays compact.
fn synthetic_xrk() -> Vec<u8> {
    let mut cnf = Vec::new();
    for ch in 0..CHANNELS {
        cnf.extend(frame("CHS", &chs(ch, &format!("ch{ch}"), 6, 4, 10_000)));
    }
    let mut file = frame("CNF", &cnf);
    for ch in 0..CHANNELS {
        let mut tc = 0i32;
        while tc < SAMPLES_PER_CHANNEL * 10 {
            let mut m = vec![b'(', b'M'];
            m.extend_from_slice(&tc.to_le_bytes());
            m.extend_from_slice(&ch.to_le_bytes());
            m.extend_from_slice(&(BURST as u16).to_le_bytes());
            for j in 0..BURST {
                let v = ((tc as f64 + j as f64) * 0.001).sin() as f32;
                m.extend_from_slice(&v.to_le_bytes());
            }
            m.push(b')');
            file.extend(m);
            tc += (BURST as i32) * 10;
        }
    }
    file
}

fn write_synthetic() -> PathBuf {
    let path = std::env::temp_dir().join("racestudio_bench_lazy_open.xrk");
    std::fs::write(&path, synthetic_xrk()).expect("write synthetic bench .xrk");
    path
}

fn bench_open(c: &mut Criterion) {
    let path = write_synthetic();
    let mut group = c.benchmark_group("open");

    group.bench_function("channel_index", |b| {
        b.iter(|| {
            let container = open_container(black_box(&path)).expect("open");
            // Building the index must not decode samples — the measured fast path.
            black_box(container.channel_index().expect("index").len())
        });
    });

    group.bench_function("decode_all", |b| {
        b.iter(|| {
            let container = open_container(black_box(&path)).expect("open");
            black_box(decode_channels(&container).expect("decode").len())
        });
    });

    group.finish();
}

criterion_group!(benches, bench_open);
criterion_main!(benches);
