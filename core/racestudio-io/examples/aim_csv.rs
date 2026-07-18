//! Decode an `.xrk` and write a RaceChrono-compatible AiM CSV to stdout (issue
//! 5.1). Used by `scripts/gen_csv_golden.sh` to (re)generate the byte golden.
//!
//! Usage: `cargo run -p racestudio-io --example aim_csv -- <input.xrk> [rate_hz]`

use std::io::{self, Write};

use racestudio_decode::decode_session;
use racestudio_io::{write_aim_csv, ExportOptions};

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(path) = args.next() else {
        eprintln!("usage: aim_csv <input.xrk> [rate_hz]");
        std::process::exit(2);
    };
    let rate_hz = args
        .next()
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(20.0);

    let session = match decode_session(&path) {
        Ok(session) => session,
        Err(err) => {
            eprintln!("error: failed to decode {path}: {err}");
            std::process::exit(1);
        }
    };

    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    match write_aim_csv(&session, &mut out, &ExportOptions { rate_hz }) {
        Ok(report) => {
            let _ = out.flush();
            eprintln!(
                "wrote {} samples, {} channels, {} laps, gps={}, {:.3}s",
                report.samples, report.channels, report.laps, report.has_gps, report.duration_s
            );
        }
        Err(err) => {
            eprintln!("error: failed to write CSV: {err}");
            std::process::exit(1);
        }
    }
}
