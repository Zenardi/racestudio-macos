//! Lap-timing decoding (issue 1.5): the container's `LAP` marker messages
//! decoded into a typed [`LapData`] — per-lap times and the best (fastest) lap.
//!
//! AiM loggers record lap crossings as `LAP` marker messages. Each 32-byte
//! marker carries a **segment** number (0 = a whole-lap crossing; 1, 2, … =
//! intermediate splits), a **lap number**, and the **lap duration** in
//! milliseconds. [`decode_laps`] reproduces libxrk's marker-table logic:
//!
//! - keep only whole-lap (segment 0) markers,
//! - drop duplicates (same lap number retransmitted),
//! - infer a single missed lap when the lap number jumps by two, and
//! - accumulate each accepted marker's duration into cumulative per-lap times.
//!
//! It then reports the **best lap** as the minimum-duration lap (the out/in laps,
//! being longer, are never selected).
//!
//! These beacon durations are the logger's own recorded lap times; the decoded
//! lap **count** matches libxrk's `log.laps` (which is GPS-plane-crossing-refined
//! and so has slightly different per-lap times). Delta-t between laps and
//! lap-based resampling (analysis-crate work) and the unified `Session` (1.6) are
//! out of scope.

use std::collections::HashMap;

use crate::container::{le_u16, le_u32, read_header, tokstr, Container, MAGIC};
use crate::error::DecodeError;

/// The minimum LAP marker payload size (segment, lap number, duration, and the
/// reserved/end-time tail). Shorter markers are treated as truncated.
const LAP_MIN_PAYLOAD: usize = 20;

/// One decoded lap.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Lap {
    index: u32,
    start_time_s: f64,
    duration_s: f64,
}

impl Lap {
    /// Zero-based lap index within the session.
    #[must_use]
    pub fn index(&self) -> u32 {
        self.index
    }

    /// Session-relative start time in seconds (cumulative across earlier laps).
    #[must_use]
    pub fn start_time_s(&self) -> f64 {
        self.start_time_s
    }

    /// Lap duration in seconds.
    #[must_use]
    pub fn duration_s(&self) -> f64 {
        self.duration_s
    }

    /// Session-relative end time in seconds (`start + duration`).
    #[must_use]
    pub fn end_time_s(&self) -> f64 {
        self.start_time_s + self.duration_s
    }
}

/// Decoded lap timing for a session: the per-lap list plus the best-lap index.
#[derive(Debug, Clone)]
pub struct LapData {
    laps: Vec<Lap>,
    best_lap_index: Option<u32>,
}

impl LapData {
    /// The decoded laps, in order.
    #[must_use]
    pub fn laps(&self) -> &[Lap] {
        &self.laps
    }

    /// The index of the fastest lap, or `None` when there are no laps.
    #[must_use]
    pub fn best_lap_index(&self) -> Option<u32> {
        self.best_lap_index
    }

    /// The fastest lap, or `None` when there are no laps.
    #[must_use]
    pub fn best_lap(&self) -> Option<&Lap> {
        let index = self.best_lap_index?;
        self.laps.iter().find(|lap| lap.index == index)
    }

    /// Number of laps.
    #[must_use]
    pub fn len(&self) -> usize {
        self.laps.len()
    }

    /// Whether there are no laps.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.laps.is_empty()
    }
}

/// Decode the lap timing of an opened container.
///
/// Returns an empty [`LapData`] (zero laps, no best lap) when the container has
/// no LAP markers.
///
/// # Errors
/// [`DecodeError::TruncatedLaps`] if a LAP marker is too short to hold its
/// timing fields. Malformed input never panics.
pub fn decode_laps(container: &Container) -> Result<LapData, DecodeError> {
    Ok(decode_laps_and_origin(container)?.0)
}

/// Decode the lap timing **and** the raw first-lap origin in a single walk.
///
/// The origin is the first LAP marker's `end_time − duration` (raw logger ms) —
/// libxrk's primary `time_offset` candidate, the recording origin the AiM CSV
/// export (5.1) normalizes to; `None` when the container has no LAP markers.
/// [`decode_laps`] is the thin public wrapper; [`decode_session`](crate::decode_session)
/// uses this to avoid walking the message stream twice.
///
/// # Errors
/// [`DecodeError::TruncatedLaps`] if a LAP marker is too short.
pub(crate) fn decode_laps_and_origin(
    container: &Container,
) -> Result<(LapData, Option<i64>), DecodeError> {
    let mut gatherer = Gatherer::default();
    gatherer.walk(container.raw(), true);
    if gatherer.truncated {
        return Err(DecodeError::TruncatedLaps);
    }
    Ok((build_laps(&gatherer.markers), gatherer.first_origin))
}

/// Walks the message stream collecting `(segment, lap, duration_ms)` from every
/// LAP marker, size-skipping data messages so all markers are reached.
#[derive(Default)]
struct Gatherer {
    channel_sizes: HashMap<u16, usize>,
    group_sizes: HashMap<u16, usize>,
    markers: Vec<(u8, u16, u32)>,
    /// The first LAP marker's `end_time − duration` (raw recording origin).
    first_origin: Option<i64>,
    truncated: bool,
}

impl Gatherer {
    fn walk(&mut self, bytes: &[u8], top: bool) {
        let mut off = 0;
        while off + 2 <= bytes.len() {
            if bytes[off..off + 2] == MAGIC {
                let Some(header) = read_header(bytes, off) else {
                    break;
                };
                self.register(header.token, header.payload);
                off = header.next;
            } else if top && bytes[off] == b'(' {
                match self.skip_data(bytes, off) {
                    Some(next) if next > off => off = next,
                    _ => break,
                }
            } else {
                break;
            }
        }
    }

    fn register(&mut self, token: u32, payload: &[u8]) {
        match tokstr(token).as_str() {
            "CNF" | "ENF" => self.walk(payload, false),
            "CHS" => {
                if payload.len() >= 73 {
                    let index = u16::from_le_bytes([payload[0], payload[1]]);
                    self.channel_sizes.insert(index, payload[72] as usize);
                }
            }
            "GRP" => self.register_group(payload),
            "LAP" => {
                // LAP payload: [_pad, segment, lap(2), duration(4), _pad(8), end_time(4), …].
                if payload.len() < LAP_MIN_PAYLOAD {
                    self.truncated = true;
                } else {
                    let segment = payload[1];
                    let lap = le_u16(payload, 2).unwrap_or(0);
                    let duration = le_u32(payload, 4).unwrap_or(0);
                    if self.first_origin.is_none() {
                        // libxrk caches the first marker's start (end − duration)
                        // as the recording origin, regardless of segment.
                        let end_time = le_u32(payload, 16).unwrap_or(0);
                        self.first_origin = Some(i64::from(end_time) - i64::from(duration));
                    }
                    self.markers.push((segment, lap, duration));
                }
            }
            _ => {}
        }
    }

    fn register_group(&mut self, payload: &[u8]) {
        let (Some(gidx), Some(count)) = (le_u16(payload, 0), le_u16(payload, 2)) else {
            return;
        };
        let mut total = 0;
        for pair in payload
            .get(4..)
            .unwrap_or_default()
            .chunks_exact(2)
            .take(count as usize)
        {
            let channel = u16::from_le_bytes([pair[0], pair[1]]);
            total += self.channel_sizes.get(&channel).copied().unwrap_or(0);
        }
        self.group_sizes.insert(gidx, total);
    }

    fn skip_data(&self, bytes: &[u8], off: usize) -> Option<usize> {
        match *bytes.get(off + 1)? {
            b'S' => Some(off + 9 + self.channel_sizes.get(&le_u16(bytes, off + 6)?).copied()?),
            b'M' => {
                let size = self.channel_sizes.get(&le_u16(bytes, off + 6)?).copied()?;
                Some(off + 11 + size * le_u16(bytes, off + 8)? as usize)
            }
            b'G' => Some(off + 9 + self.group_sizes.get(&le_u16(bytes, off + 6)?).copied()?),
            b'c' => match (*bytes.get(off + 2)?, *bytes.get(off + 6)?) {
                (0x00, 0x06) => Some(
                    off + 12
                        + self
                            .channel_sizes
                            .get(&(le_u16(bytes, off + 3)? >> 3))
                            .copied()?,
                ),
                (0x00, 0x08) => Some(off + 16),
                (0x01, 0x02) => Some(off + 10),
                _ => None,
            },
            _ => None,
        }
    }
}

/// Apply the lap-marker dedup and accumulate cumulative per-lap times.
fn build_laps(markers: &[(u8, u16, u32)]) -> LapData {
    let mut kept: Vec<(u16, u32)> = Vec::new();
    for &(segment, lap, duration) in markers {
        if segment != 0 {
            continue; // intermediate split, not a whole-lap crossing
        }
        match kept.last().map(|&(n, _)| n) {
            None => {}
            Some(last) if last == lap => continue, // duplicate retransmission
            Some(last) if last + 1 == lap => {}    // next lap
            Some(last) if last + 2 == lap => kept.push((lap - 1, duration)), // infer missed lap
            Some(_) => continue,                   // out-of-order / gap: skip
        }
        kept.push((lap, duration));
    }
    if kept.is_empty() {
        return LapData {
            laps: Vec::new(),
            best_lap_index: None,
        };
    }
    let base = kept.iter().map(|&(n, _)| n).min().unwrap_or(0);
    let mut laps = Vec::with_capacity(kept.len());
    let mut cum_ms: u64 = 0;
    for &(num, duration) in &kept {
        let start_ms = cum_ms;
        cum_ms += u64::from(duration);
        laps.push(Lap {
            index: u32::from(num - base),
            start_time_s: start_ms as f64 / 1000.0,
            duration_s: f64::from(duration) / 1000.0,
        });
    }
    let best_lap_index = laps
        .iter()
        .min_by(|a, b| a.duration_s.total_cmp(&b.duration_s))
        .map(Lap::index);
    LapData {
        laps,
        best_lap_index,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAGIC_BYTES: [u8; 2] = MAGIC;

    fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
        let mut tb = token.as_bytes().to_vec();
        while tb.len() < 4 {
            tb.push(0);
        }
        let tok = u32::from_le_bytes([tb[0], tb[1], tb[2], tb[3]]);
        let mut out = Vec::new();
        out.extend_from_slice(&MAGIC_BYTES);
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

    /// A 32-byte LAP marker: segment, lap number, duration (ms).
    fn lap_marker(segment: u8, lap: u16, duration_ms: u32) -> Vec<u8> {
        let mut p = vec![0u8; 32];
        p[1] = segment;
        p[2..4].copy_from_slice(&lap.to_le_bytes());
        p[4..8].copy_from_slice(&duration_ms.to_le_bytes());
        p
    }

    fn decode(bytes: &[u8]) -> Result<LapData, DecodeError> {
        let mut g = Gatherer::default();
        g.walk(bytes, true);
        if g.truncated {
            return Err(DecodeError::TruncatedLaps);
        }
        Ok(build_laps(&g.markers))
    }

    /// Concatenate several LAP-marker frames.
    fn laps_file(markers: &[(u8, u16, u32)]) -> Vec<u8> {
        let mut file = Vec::new();
        for &(seg, lap, dur) in markers {
            file.extend(frame("LAP", &lap_marker(seg, lap, dur)));
        }
        file
    }

    #[test]
    fn test_three_consecutive_laps() {
        let data = decode(&laps_file(&[
            (0, 1, 60_000),
            (0, 2, 55_000),
            (0, 3, 58_000),
        ]))
        .expect("decode");
        assert_eq!(data.len(), 3);
        assert!(!data.is_empty());
        let laps = data.laps();
        assert_eq!(laps[0].index(), 0);
        assert_eq!(laps[1].index(), 1);
        assert_eq!(laps[2].index(), 2);
        // Cumulative start times, durations in seconds.
        assert!((laps[0].start_time_s() - 0.0).abs() < 1e-9);
        assert!((laps[0].duration_s() - 60.0).abs() < 1e-9);
        assert!((laps[1].start_time_s() - 60.0).abs() < 1e-9);
        assert!((laps[2].start_time_s() - 115.0).abs() < 1e-9);
        assert!((laps[2].end_time_s() - 173.0).abs() < 1e-9);
        // Best lap is the fastest (lap 1, 55 s).
        assert_eq!(data.best_lap_index(), Some(1));
        assert_eq!(data.best_lap().unwrap().index(), 1);
        assert!((data.best_lap().unwrap().duration_s() - 55.0).abs() < 1e-9);
    }

    #[test]
    fn test_segments_and_duplicates_are_filtered() {
        // Segment 1/2 markers and a duplicate lap number are dropped; only
        // whole-lap (segment 0) markers with distinct lap numbers count.
        let markers = [
            (1, 0, 20_000), // segment split → skip
            (2, 0, 40_000), // segment split → skip
            (0, 1, 60_000), // lap 1
            (1, 1, 18_000), // segment split → skip
            (0, 1, 60_050), // duplicate lap 1 → skip
            (0, 2, 55_000), // lap 2
        ];
        let data = decode(&laps_file(&markers)).expect("decode");
        assert_eq!(data.len(), 2, "two whole laps after filtering");
        assert_eq!(data.laps()[0].index(), 0);
        assert!((data.laps()[0].duration_s() - 60.0).abs() < 1e-9);
    }

    #[test]
    fn test_missed_lap_is_inferred() {
        // Lap number jumps 1 → 3: a single missed lap (2) is inferred, so three
        // laps are produced from two markers.
        let data = decode(&laps_file(&[(0, 1, 60_000), (0, 3, 58_000)])).expect("decode");
        assert_eq!(data.len(), 3, "inferred the missed lap");
        assert_eq!(
            data.laps().iter().map(Lap::index).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
    }

    #[test]
    fn test_out_of_order_marker_is_skipped() {
        // A lap number that jumps by more than two is skipped (no miscount).
        let data = decode(&laps_file(&[
            (0, 1, 60_000),
            (0, 9, 40_000),
            (0, 2, 55_000),
        ]))
        .expect("decode");
        assert_eq!(data.len(), 2, "the far-jump marker is dropped");
        assert_eq!(
            data.laps().iter().map(Lap::index).collect::<Vec<_>>(),
            vec![0, 1]
        );
    }

    #[test]
    fn test_lap_number_base_is_normalised() {
        // Lap numbers starting at 5 normalise to 0-based indices.
        let data = decode(&laps_file(&[(0, 5, 60_000), (0, 6, 55_000)])).expect("decode");
        assert_eq!(
            data.laps().iter().map(Lap::index).collect::<Vec<_>>(),
            vec![0, 1]
        );
        assert_eq!(data.best_lap_index(), Some(1));
    }

    #[test]
    fn test_no_markers_is_empty() {
        let data = decode(&frame("RCR", b"BOB\0")).expect("decode");
        assert!(data.is_empty());
        assert_eq!(data.best_lap_index(), None);
        assert!(data.best_lap().is_none());
        assert_eq!(data.len(), 0);
    }

    #[test]
    fn test_first_lap_origin_is_end_minus_duration() {
        // The first LAP marker's end_time (offset 16) minus its duration is the
        // recording origin. Two markers: only the first is used.
        let mut m1 = lap_marker(0, 1, 10_000);
        m1[16..20].copy_from_slice(&30_015u32.to_le_bytes()); // end_time
        let mut m2 = lap_marker(0, 2, 55_000);
        m2[16..20].copy_from_slice(&85_015u32.to_le_bytes());
        let mut file = frame("LAP", &m1);
        file.extend(frame("LAP", &m2));

        let mut gatherer = Gatherer::default();
        gatherer.walk(&file, true);
        assert_eq!(
            gatherer.first_origin,
            Some(20_015),
            "origin = first end_time − duration = 30015 − 10000"
        );
    }

    #[test]
    fn test_first_lap_origin_absent_without_markers() {
        let mut gatherer = Gatherer::default();
        gatherer.walk(&frame("RCR", b"BOB\0"), true);
        assert_eq!(gatherer.first_origin, None);
    }

    #[test]
    fn test_first_lap_origin_uses_first_marker_regardless_of_segment() {
        // A leading split (segment 1) marker still sets the origin — matching
        // libxrk, which caches the first LAP message of any segment.
        let mut split = lap_marker(1, 0, 5_000);
        split[16..20].copy_from_slice(&12_000u32.to_le_bytes()); // end_time
        let mut gatherer = Gatherer::default();
        gatherer.walk(&frame("LAP", &split), true);
        assert_eq!(
            gatherer.first_origin,
            Some(7_000),
            "12000 − 5000, from a segment-1 marker"
        );
    }

    #[test]
    fn test_truncated_lap_marker_errors() {
        assert!(matches!(
            decode(&frame("LAP", &[0u8; 4])),
            Err(DecodeError::TruncatedLaps)
        ));
    }

    #[test]
    fn test_markers_reached_after_data_and_group_messages() {
        // A CNF (channel 0 size 4, channel 1 size 2, group 0), then LAP markers
        // separated by every data-message kind — all size-skipped so both laps
        // are reached.
        let mut c0 = vec![0u8; 112];
        c0[0..2].copy_from_slice(&0u16.to_le_bytes());
        c0[72] = 4;
        let mut c1 = vec![0u8; 112];
        c1[0..2].copy_from_slice(&1u16.to_le_bytes());
        c1[72] = 2;
        let mut grp = vec![0u8; 8];
        grp[2..4].copy_from_slice(&2u16.to_le_bytes());
        grp[6..8].copy_from_slice(&1u16.to_le_bytes());
        let mut inner = frame("CHS", &c0);
        inner.extend(frame("CHS", &c1));
        inner.extend(frame("GRP", &grp));
        let mut file = frame("CNF", &inner);

        file.extend(frame("LAP", &lap_marker(0, 1, 60_000)));
        // (S channel 0, (M channel 0, (G group 0, and the three (c variants.
        file.extend_from_slice(&[b'(', b'S', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, b')']);
        let mut m = vec![b'(', b'M', 0, 0, 0, 0, 0, 0, 2, 0];
        m.extend_from_slice(&[0u8; 8]);
        m.push(b')');
        file.extend(m);
        let mut g = vec![b'(', b'G', 0, 0, 0, 0, 0, 0];
        g.extend_from_slice(&[0u8; 6]);
        g.push(b')');
        file.extend(g);
        let mut c_v1 = vec![b'(', b'c', 0x00, 0, 0, 0x84, 0x06];
        c_v1.extend_from_slice(&[0u8; 8]);
        c_v1.push(b')');
        file.extend(c_v1);
        let mut c_v2 = vec![b'(', b'c', 0x00, 0, 0, 0x84, 0x08];
        c_v2.extend_from_slice(&[0u8; 8]);
        c_v2.push(b')');
        file.extend(c_v2);
        file.extend_from_slice(&[b'(', b'c', 0x01, 0, 0, 0x84, 0x02, 0, 0, b')']);
        file.extend(frame("LAP", &lap_marker(0, 2, 55_000)));

        let data = decode(&file).expect("decode");
        assert_eq!(
            data.len(),
            2,
            "both markers reached across the data messages"
        );
        assert_eq!(data.best_lap_index(), Some(1));
    }

    #[test]
    fn test_walk_stops_on_unsizable_and_stray_bytes() {
        // A LAP marker then an (S for an unknown channel stops the walk; the lap
        // gathered so far survives. Likewise a stray non-message byte.
        let mut a = frame("LAP", &lap_marker(0, 1, 60_000));
        a.extend_from_slice(&[b'(', b'S', 0, 0, 0, 0, 9, 0]); // channel 9 undefined
        assert_eq!(decode(&a).expect("decode").len(), 1);

        let mut b = frame("LAP", &lap_marker(0, 1, 60_000));
        b.extend_from_slice(&[0xEE, 0xEE]);
        assert_eq!(decode(&b).expect("decode").len(), 1);
    }

    #[test]
    fn test_malformed_group_and_unknown_kinds_are_tolerated() {
        // A short GRP (< 4 bytes), an unknown (c variant, and an unknown '(x'
        // kind are all handled without panic; the LAP marker still decodes.
        let mut short_grp = frame("CNF", &frame("GRP", &[0u8; 2]));
        short_grp.extend(frame("LAP", &lap_marker(0, 1, 60_000)));
        assert_eq!(decode(&short_grp).expect("decode").len(), 1);

        for tail in [
            &[b'(', b'c', 0x05, 0, 0, 0x84, 0x00, 0, 0][..], // unknown (c variant
            &[b'(', b'x', 0, 0][..],                         // unknown message kind
        ] {
            let mut file = frame("LAP", &lap_marker(0, 1, 60_000));
            file.extend_from_slice(tail);
            assert_eq!(decode(&file).expect("decode").len(), 1);
        }

        // A LAP marker then a truncated header (`<h` with no room) stops the walk.
        let mut trunc = frame("LAP", &lap_marker(0, 1, 60_000));
        trunc.extend_from_slice(&[0x3C, 0x68, b'T']);
        assert_eq!(decode(&trunc).expect("decode").len(), 1);
    }
}
