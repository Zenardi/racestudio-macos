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
    let total = ms / 1000.0;
    let minutes = (total / 60.0).floor() as i64;
    let seconds = total - (minutes as f64) * 60.0;
    // `{:06.3}` → zero-padded width 6 (SS.mmm) at 3 decimals.
    format!("{minutes}:{seconds:06.3}")
}
