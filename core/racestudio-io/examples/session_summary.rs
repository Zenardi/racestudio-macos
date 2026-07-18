//! Import a CSV and print a deterministic structural summary of the resulting
//! `Session` as pretty JSON (issue 5.2). Used by `scripts/gen_session_golden.sh`
//! to (re)generate `fixtures/golden/fuji_0033.session.json`.
//!
//! The JSON shape here MUST match `tests/support::session_summary` so the golden
//! test compares like for like.
//!
//! Usage: `cargo run -p racestudio-io --example session_summary -- <input.csv>`

use racestudio_decode::Session;
use racestudio_io::read_csv;
use serde_json::json;

fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: session_summary <input.csv>");
        std::process::exit(2);
    };
    let file = match std::fs::File::open(&path) {
        Ok(file) => file,
        Err(err) => {
            eprintln!("error: cannot open {path}: {err}");
            std::process::exit(1);
        }
    };
    match read_csv(file) {
        Ok(session) => println!("{}", summary(&session)),
        Err(err) => {
            eprintln!("error: import failed: {err}");
            std::process::exit(1);
        }
    }
}

/// Keep in sync with `tests/support::session_summary`.
fn summary(session: &Session) -> String {
    let meta = session.metadata();
    let channels: Vec<_> = session
        .channels()
        .iter()
        .map(|c| json!({"name": c.name(), "unit": c.unit(), "samples": c.samples().len()}))
        .collect();
    let value = json!({
        "channel_count": session.channels().len(),
        "lap_count": session.laps().len(),
        "metadata": {
            "track": meta.track,
            "vehicle": meta.vehicle,
            "driver": meta.driver,
            "series": meta.series,
            "log_date": meta.log_date,
            "log_time": meta.log_time,
        },
        "channels": channels,
    });
    serde_json::to_string_pretty(&value).unwrap_or_default()
}
