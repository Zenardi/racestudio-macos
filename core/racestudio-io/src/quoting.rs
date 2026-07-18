//! CSV field quoting and segment-time formatting (issue 5.1).
//!
//! RaceChrono's AiM importer requires two things the sibling `xrk2csv.py`
//! already honours and this module reproduces: **every** field is double-quoted
//! (`csv.QUOTE_ALL`) and **no** row ends in a trailing comma.

/// Join `fields` into one RFC-4180 record with every field double-quoted
/// (`QUOTE_ALL`) and embedded quotes doubled. Fields are comma-separated with no
/// trailing comma; the row has no line terminator (the caller appends it).
///
/// An empty slice yields the empty string — a blank CSV row.
#[must_use]
pub fn quote_all(fields: &[&str]) -> String {
    let mut out = String::new();
    for (i, field) in fields.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('"');
        for ch in field.chars() {
            if ch == '"' {
                out.push('"'); // RFC-4180: double an embedded quote
            }
            out.push(ch);
        }
        out.push('"');
    }
    out
}

/// Format a duration in milliseconds as `M:SS.mmm` — the AiM CSV `Segment Times`
/// format (e.g. `193611.0` → `"3:13.611"`).
#[must_use]
pub fn fmt_seg_time(ms: f64) -> String {
    // Round to whole milliseconds first, then split, so the seconds field can
    // never round up to `60.000` (e.g. `59_999.6` → `1:00.000`, not `0:60.000`).
    let total_ms = ms.round().max(0.0) as i64;
    let minutes = total_ms / 60_000;
    let seconds = (total_ms % 60_000) as f64 / 1000.0;
    // `{:06.3}` → zero-padded width 6 (SS.mmm) at 3 decimals.
    format!("{minutes}:{seconds:06.3}")
}
