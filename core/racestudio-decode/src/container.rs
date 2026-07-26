//! `.xrk` container + header-metadata decoder (issue 1.2).
//!
//! An `.xrk` file is a flat stream of framed messages. Two kinds interleave:
//!
//! - **Header messages** — `'<h'` + token(u32 LE) + payload_len(i32 LE) +
//!   version(u8) + `'>'` + payload + `'<'` + token + checksum(u16) + `'>'`.
//!   Session metadata (driver, vehicle, venue, date/time) lives here, as do the
//!   channel definitions (`CHS`, nested inside `CNF`), GPS samples, and lap
//!   markers.
//! - **Data messages** — `'('` + kind (`S`/`M`/`G`/`c`) + timecode + body +
//!   `')'`. 1.2 does not decode their samples; it only skips them (using each
//!   channel's byte size) so the walk reaches the end of the file and observes
//!   the *last* re-transmission of each metadata token — which is the one AiM's
//!   loggers (and libxrk) treat as authoritative.
//!
//! This is the foundation the channel (1.3), GPS (1.4), and lap (1.5) decoders
//! build on: they take the parsed [`Container`] rather than re-reading raw bytes.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;

use crate::error::DecodeError;

/// Header-message magic: ASCII `'<h'`.
pub(crate) const MAGIC: [u8; 2] = [0x3C, 0x68];

/// Session metadata parsed from the `.xrk` container header.
///
/// String fields hold the **last** occurrence of each token in the file
/// (matching libxrk): AiM loggers re-transmit the header periodically and the
/// final copy — e.g. once the GPS clock has synced — is authoritative.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Metadata {
    /// Vehicle name (token `VEH`).
    pub vehicle: String,
    /// Track / venue name (token `TRK`).
    pub track: String,
    /// Driver / racer name (token `RCR`).
    pub driver: String,
    /// Session name (token `VTY`).
    pub session: String,
    /// Championship / series name (token `CMP`).
    pub series: String,
    /// Raw log date as stored (`MM/DD/YYYY`, token `TMD`).
    pub log_date: String,
    /// Raw log time as stored (`HH:MM:SS`, token `TMT`).
    pub log_time: String,
    /// Session start as epoch seconds. The logger stores wall-clock with no
    /// timezone, so it is interpreted as UTC (0 when absent/unparseable).
    pub datetime_utc: i64,
}

/// An opened `.xrk` container: parsed header [`Metadata`] plus the structural
/// counts the later decoders consume without re-reading raw bytes.
#[derive(Debug, Clone)]
pub struct Container {
    metadata: Metadata,
    channel_count: usize,
    has_gps: bool,
    lap_marker_count: usize,
    /// The full file bytes, retained so the channel/GPS/lap decoders can walk
    /// the message stream without re-reading from disk. Shared (`Arc`) so
    /// cloning a `Container` stays cheap.
    bytes: Arc<[u8]>,
}

impl Container {
    /// The parsed session metadata.
    #[must_use]
    pub fn metadata(&self) -> &Metadata {
        &self.metadata
    }

    /// The raw file bytes backing this container, for the layered decoders
    /// (channels 1.3, GPS 1.4, laps 1.5).
    pub(crate) fn raw(&self) -> &[u8] {
        &self.bytes
    }

    /// A cheap clone of the shared raw bytes for the lazy channel index (7.2):
    /// each lazily decoded [`Channel`](crate::Channel) holds one so it can walk the
    /// stream on first access without re-reading from disk.
    pub(crate) fn raw_arc(&self) -> Arc<[u8]> {
        Arc::clone(&self.bytes)
    }

    /// Lazily index the container's channels (issue 7.2): see
    /// [`channel_index`](crate::channel_index). Each returned channel carries its
    /// metadata but decodes (and allocates) its samples only on first access, so
    /// opening a very large session materializes no sample vectors and only the
    /// channels actually plotted pay their decode cost. The channel set/order
    /// matches [`decode_channels`](crate::decode_channels).
    ///
    /// # Errors
    /// Returns the same [`DecodeError`] as
    /// [`decode_channels`](crate::decode_channels) for a truncated or
    /// bad-sample-count data stream, so a corrupt/partial session is reported at
    /// index time rather than silently served as complete.
    pub fn channel_index(&self) -> Result<Vec<crate::channels::Channel>, DecodeError> {
        crate::channels::channel_index(self)
    }

    /// Number of distinct channel definitions (`CHS`) in the container. The
    /// channel decoder (1.3) turns these into decoded channels.
    #[must_use]
    pub fn channel_count(&self) -> usize {
        self.channel_count
    }

    /// Whether the container carries any GPS messages (consumed by 1.4).
    #[must_use]
    pub fn has_gps(&self) -> bool {
        self.has_gps
    }

    /// Number of raw lap-marker (`LAP`) messages. The lap decoder (1.5)
    /// deduplicates these into logical laps.
    #[must_use]
    pub fn lap_marker_count(&self) -> usize {
        self.lap_marker_count
    }
}

/// Open and parse the header of an AiM `.xrk` file at `path`.
///
/// # Errors
/// - [`DecodeError::Io`] if the file cannot be read.
/// - [`DecodeError::BadMagic`] if it does not start with the `'<h'` magic.
/// - [`DecodeError::TruncatedHeader`] if the first header message is cut short.
pub fn open_container(path: impl AsRef<Path>) -> Result<Container, DecodeError> {
    let bytes = std::fs::read(path)?;
    parse_container(&bytes)
}

fn parse_container(bytes: &[u8]) -> Result<Container, DecodeError> {
    if bytes.get(..2) != Some(MAGIC.as_slice()) {
        return Err(DecodeError::BadMagic);
    }
    // Magic is present; the first header message must be fully framed.
    if read_header(bytes, 0).is_none() {
        return Err(DecodeError::TruncatedHeader);
    }
    let mut walker = Walker::default();
    walker.walk(bytes, true);
    Ok(walker.into_container(Arc::from(bytes)))
}

/// A framed header message borrowed from the file bytes.
pub(crate) struct Header<'a> {
    pub(crate) token: u32,
    pub(crate) payload: &'a [u8],
    /// Offset just past this message's footer.
    pub(crate) next: usize,
}

/// Read the header message at `off`, or `None` if it is not a fully-framed
/// header (out of bounds, negative length, or payload/footer past EOF).
///
/// Callers guarantee `bytes[off..off + 2] == MAGIC` before calling.
pub(crate) fn read_header(bytes: &[u8], off: usize) -> Option<Header<'_>> {
    let plen = le_i32(bytes, off + 6)?;
    if plen < 0 {
        return None;
    }
    let token = le_u32(bytes, off + 2)?;
    let start = off + 12;
    let end = start.checked_add(plen as usize)?;
    // Footer is 8 bytes: '<' + token(4) + checksum(2) + '>'.
    if end.checked_add(8)? > bytes.len() {
        return None;
    }
    Some(Header {
        token,
        payload: &bytes[start..end],
        next: end + 8,
    })
}

/// Accumulates parse state across the (recursive) message walk.
#[derive(Default)]
struct Walker {
    channel_sizes: HashMap<u16, usize>,
    group_sizes: HashMap<u16, usize>,
    chs_indices: HashSet<u16>,
    gps: usize,
    lap: usize,
    driver: String,
    vehicle: String,
    track: String,
    session: String,
    series: String,
    log_date: String,
    log_time: String,
}

impl Walker {
    /// Walk a message stream. `top` is false inside a `CNF`/`ENF` sub-stream,
    /// which holds only header messages (no data messages).
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

    /// Dispatch a header message by its token, updating parse state.
    fn register(&mut self, token: u32, payload: &[u8]) {
        match tokstr(token).as_str() {
            "CNF" | "ENF" => self.walk(payload, false),
            "CHS" => {
                if payload.len() >= 73 {
                    if let Some(idx) = le_u16(payload, 0) {
                        self.channel_sizes.insert(idx, payload[72] as usize);
                        self.chs_indices.insert(idx);
                    }
                }
            }
            "GRP" => self.register_group(payload),
            // Metadata tokens — last occurrence wins.
            "RCR" => self.driver = nullterm(payload),
            "VEH" => self.vehicle = nullterm(payload),
            "VTY" => self.session = nullterm(payload),
            "CMP" => self.series = nullterm(payload),
            "TMD" => self.log_date = nullterm(payload),
            "TMT" => self.log_time = nullterm(payload),
            "TRK" => self.track = nullterm(payload.get(..32).unwrap_or(payload)),
            "GPS" | "GPS1" => self.gps += 1,
            "LAP" => self.lap += 1,
            _ => {}
        }
    }

    /// A `GRP` defines a group whose data-message body is the concatenation of
    /// its member channels' bytes; record that total so `(G` can be skipped.
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

    /// Return the offset just past the data message at `off`, or `None` if it
    /// cannot be sized (unknown kind/variant, missing channel, or truncation) —
    /// which stops the walk rather than panicking.
    fn skip_data(&self, bytes: &[u8], off: usize) -> Option<usize> {
        match *bytes.get(off + 1)? {
            b'S' => {
                // '(S' + timecode(4) + channel(2) + data + ')'
                let size = self.channel_size(le_u16(bytes, off + 6)?)?;
                Some(off + 9 + size)
            }
            b'M' => {
                // '(M' + timecode(4) + channel(2) + count(2) + data*count + ')'
                let size = self.channel_size(le_u16(bytes, off + 6)?)?;
                let count = le_u16(bytes, off + 8)? as usize;
                Some(off + 11 + size * count)
            }
            b'G' => {
                // '(G' + timecode(4) + group(2) + data + ')'
                let size = self.group_sizes.get(&le_u16(bytes, off + 6)?).copied()?;
                Some(off + 9 + size)
            }
            b'c' => self.skip_expansion(bytes, off),
            _ => None,
        }
    }

    /// Size a `(c` expansion-channel message by its variant discriminators:
    /// `unk1` at byte 2 and `unk4` at byte 6.
    fn skip_expansion(&self, bytes: &[u8], off: usize) -> Option<usize> {
        match (*bytes.get(off + 2)?, *bytes.get(off + 6)?) {
            // V1: 12-byte header + one CHS-sized sample.
            (0x00, 0x06) => {
                let size = self.channel_size(le_u16(bytes, off + 3)? >> 3)?;
                Some(off + 12 + size)
            }
            (0x00, 0x08) => Some(off + 16), // V2: fixed 16 bytes.
            (0x01, 0x02) => Some(off + 10), // V3: fixed 10 bytes.
            _ => None,
        }
    }

    fn channel_size(&self, index: u16) -> Option<usize> {
        self.channel_sizes.get(&index).copied()
    }

    fn into_container(self, bytes: Arc<[u8]>) -> Container {
        let datetime_utc = parse_datetime_utc(&self.log_date, &self.log_time);
        Container {
            channel_count: self.chs_indices.len(),
            has_gps: self.gps > 0,
            lap_marker_count: self.lap,
            bytes,
            metadata: Metadata {
                vehicle: self.vehicle,
                track: self.track,
                driver: self.driver,
                session: self.session,
                series: self.series,
                log_date: self.log_date,
                log_time: self.log_time,
                datetime_utc,
            },
        }
    }
}

/// Decode a token integer into its ASCII string, dropping the trailing space
/// AiM uses to pad 3-character tokens to 4 bytes.
pub(crate) fn tokstr(token: u32) -> String {
    let mut out = String::new();
    let mut value = token;
    while value != 0 {
        out.push(char::from((value & 0xFF) as u8));
        value >>= 8;
    }
    out.trim_end().to_string()
}

/// Decode a null-terminated ASCII string from a payload slice.
pub(crate) fn nullterm(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

/// `MM/DD/YYYY` + `HH:MM:SS` (logger wall-clock, treated as UTC) -> epoch
/// seconds. Returns 0 when either field is missing or unparseable.
///
/// Public so a consumer reconstructing [`Metadata`] from another source (e.g. the
/// CSV importer, 5.2) can populate `datetime_utc` the same way the decoder does.
#[must_use]
pub fn parse_datetime_utc(date: &str, time: &str) -> i64 {
    let date: Vec<&str> = date.split('/').collect();
    let time: Vec<&str> = time.split(':').collect();
    if date.len() != 3 || time.len() != 3 {
        return 0;
    }
    let (Ok(month), Ok(day), Ok(year)) = (
        date[0].parse::<i64>(),
        date[1].parse::<i64>(),
        date[2].parse::<i64>(),
    ) else {
        return 0;
    };
    let (Ok(hour), Ok(minute), Ok(second)) = (
        time[0].parse::<i64>(),
        time[1].parse::<i64>(),
        time[2].parse::<i64>(),
    ) else {
        return 0;
    };
    days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second
}

/// Days from 1970-01-01 to the given civil date (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = (if year >= 0 { year } else { year - 399 }) / 400;
    let year_of_era = year - era * 400;
    let month_term = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * month_term + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

pub(crate) fn le_u16(bytes: &[u8], off: usize) -> Option<u16> {
    Some(u16::from_le_bytes(
        bytes.get(off..off + 2)?.try_into().ok()?,
    ))
}

pub(crate) fn le_u32(bytes: &[u8], off: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        bytes.get(off..off + 4)?.try_into().ok()?,
    ))
}

pub(crate) fn le_i32(bytes: &[u8], off: usize) -> Option<i32> {
    Some(i32::from_le_bytes(
        bytes.get(off..off + 4)?.try_into().ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a framed header message (`<h … >`) with a correct checksum.
    fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
        let tok = token_to_u32(token);
        let mut out = Vec::new();
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&tok.to_le_bytes());
        out.extend_from_slice(&(payload.len() as i32).to_le_bytes());
        out.push(0); // version
        out.push(b'>');
        out.extend_from_slice(payload);
        out.push(b'<');
        out.extend_from_slice(&tok.to_le_bytes());
        let checksum = (payload.iter().map(|&b| u32::from(b)).sum::<u32>() & 0xFFFF) as u16;
        out.extend_from_slice(&checksum.to_le_bytes());
        out.push(b'>');
        out
    }

    fn token_to_u32(token: &str) -> u32 {
        let mut bytes = token.as_bytes().to_vec();
        while bytes.len() < 4 {
            bytes.push(b' '); // pad 3-char tokens with a trailing space
        }
        u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
    }

    /// A 112-byte CHS payload with the given index and per-sample data size.
    fn chs(index: u16, data_size: u8) -> Vec<u8> {
        let mut p = vec![0u8; 112];
        p[0..2].copy_from_slice(&index.to_le_bytes());
        p[72] = data_size;
        p
    }

    /// A 32-byte-name TRK payload (name null-terminated within [0:32]).
    fn trk(name: &str) -> Vec<u8> {
        let mut p = vec![0u8; 44];
        let n = name.as_bytes();
        p[..n.len()].copy_from_slice(n);
        p
    }

    #[test]
    fn test_parse_full_synthetic_container() {
        // A CNF holding two channel definitions + a group, then top-level
        // metadata, GPS, laps, every data-message kind, and a *late* metadata
        // re-transmission that must win.
        let mut cnf = Vec::new();
        cnf.extend(frame("CHS", &chs(0, 2)));
        cnf.extend(frame("CHS", &chs(1, 4)));
        let mut grp = vec![0u8; 8];
        grp[0..2].copy_from_slice(&0u16.to_le_bytes()); // group index 0
        grp[2..4].copy_from_slice(&2u16.to_le_bytes()); // 2 members
        grp[4..6].copy_from_slice(&0u16.to_le_bytes()); // channel 0 (size 2)
        grp[6..8].copy_from_slice(&1u16.to_le_bytes()); // channel 1 (size 4)
        cnf.extend(frame("GRP", &grp));

        let mut file = Vec::new();
        file.extend(frame("CNF", &cnf));
        file.extend(frame("RCR", b"FIRST\0"));
        file.extend(frame("VEH", b"CAR-9\0"));
        file.extend(frame("VTY", b"Qualifying\0"));
        file.extend(frame("CMP", b"Series X\0"));
        file.extend(frame("TRK", &trk("Silverstone")));
        file.extend(frame("TMD", b"01/23/2016\0"));
        file.extend(frame("TMT", b"12:08:51\0"));
        file.extend(frame("GPS", &[0u8; 56]));
        file.extend(frame("LAP", &[0u8; 20]));
        // Data messages — one of each kind/variant, all sized from CHS/GRP.
        file.extend(data_s(0)); // channel 0, 2 bytes
        file.extend(data_m(1, 3)); // channel 1, 3 samples * 4 bytes
        file.extend(data_g(0)); // group 0, 6 bytes
        file.extend(data_c_v1(0)); // expansion V1, channel 0
        file.extend(data_c_v2()); // expansion V2, fixed
        file.extend(data_c_v3()); // expansion V3, fixed
        file.extend(frame("LAP", &[0u8; 20])); // a second lap marker after data
        file.extend(frame("TMT", b"12:09:04\0")); // LATE time — must win

        let container = parse_container(&file).expect("parse synthetic container");
        let meta = container.metadata();
        assert_eq!(meta.driver, "FIRST");
        assert_eq!(meta.vehicle, "CAR-9");
        assert_eq!(meta.session, "Qualifying");
        assert_eq!(meta.series, "Series X");
        assert_eq!(meta.track, "Silverstone");
        assert_eq!(meta.log_date, "01/23/2016");
        assert_eq!(meta.log_time, "12:09:04", "last TMT must win");
        assert_eq!(meta.datetime_utc, 1_453_550_944);
        assert_eq!(container.channel_count(), 2);
        assert!(container.has_gps());
        assert_eq!(container.lap_marker_count(), 2);
    }

    fn data_s(channel: u16) -> Vec<u8> {
        let mut m = vec![b'(', b'S', 0, 0, 0, 0];
        m.extend_from_slice(&channel.to_le_bytes());
        m.extend_from_slice(&[0u8; 2]); // channel 0 size = 2
        m.push(b')');
        m
    }

    fn data_m(channel: u16, count: u16) -> Vec<u8> {
        let mut m = vec![b'(', b'M', 0, 0, 0, 0];
        m.extend_from_slice(&channel.to_le_bytes());
        m.extend_from_slice(&count.to_le_bytes());
        m.extend(vec![0u8; 4 * count as usize]); // channel 1 size = 4
        m.push(b')');
        m
    }

    fn data_g(group: u16) -> Vec<u8> {
        let mut m = vec![b'(', b'G', 0, 0, 0, 0];
        m.extend_from_slice(&group.to_le_bytes());
        m.extend(vec![0u8; 6]); // group 0 size = 2 + 4
        m.push(b')');
        m
    }

    fn data_c_v1(channel_field: u16) -> Vec<u8> {
        // '(c' unk1=0x00 field(2) unk3=0x84 unk4=0x06 tc(4) data[size] ')'
        let mut m = vec![b'(', b'c', 0x00];
        m.extend_from_slice(&(channel_field << 3).to_le_bytes());
        m.extend_from_slice(&[0x84, 0x06, 0, 0, 0, 0]);
        m.extend_from_slice(&[0u8; 2]); // channel 0 size = 2
        m.push(b')');
        m
    }

    fn data_c_v2() -> Vec<u8> {
        let mut m = vec![b'(', b'c', 0x00, 0, 0, 0x84, 0x08, 0, 0, 0, 0];
        m.extend_from_slice(&[0u8; 4]);
        m.push(b')');
        m // total 16
    }

    fn data_c_v3() -> Vec<u8> {
        // '(c' unk1=0x01 field(2) unk3=0x84 unk4=0x02 data(2) ')'  = 10 bytes.
        let mut m = vec![b'(', b'c', 0x01, 0, 0, 0x84, 0x02, 0, 0];
        m.push(b')');
        m
    }

    #[test]
    fn test_minimal_container_defaults() {
        // A file with just a valid (empty) header: no metadata, no channels,
        // no GPS/laps — everything defaults, datetime is 0, nothing panics.
        let file = frame("RCR", b"\0");
        let container = parse_container(&file).expect("parse minimal");
        assert_eq!(container.channel_count(), 0);
        assert!(!container.has_gps());
        assert_eq!(container.lap_marker_count(), 0);
        assert_eq!(container.metadata().datetime_utc, 0);
        assert_eq!(container.metadata().driver, "");
    }

    #[test]
    fn test_bad_magic_and_short_file() {
        assert!(matches!(
            parse_container(b"XX not xrk"),
            Err(DecodeError::BadMagic)
        ));
        assert!(matches!(parse_container(b""), Err(DecodeError::BadMagic)));
        assert!(matches!(parse_container(b"<"), Err(DecodeError::BadMagic)));
    }

    #[test]
    fn test_truncated_header() {
        // Valid magic but the payload length runs past EOF.
        let bytes = [0x3C, 0x68, b'T', b'M', b'T', 0x20, 0xFF, 0xFF, 0x00, 0x00];
        assert!(matches!(
            parse_container(&bytes),
            Err(DecodeError::TruncatedHeader)
        ));
    }

    #[test]
    fn test_walk_stops_on_unknown_data_variant() {
        // A valid header followed by an unrecognisable '(x' message: the walk
        // stops cleanly (no panic) and returns what it parsed so far.
        let mut file = frame("RCR", b"BOB\0");
        file.extend_from_slice(&[b'(', b'x', 0, 0]);
        let container = parse_container(&file).expect("parse then stop");
        assert_eq!(container.metadata().driver, "BOB");
    }

    #[test]
    fn test_tokstr_strips_three_char_padding() {
        assert_eq!(tokstr(token_to_u32("RCR")), "RCR");
        assert_eq!(tokstr(token_to_u32("GPS1")), "GPS1");
        assert_eq!(tokstr(0), "");
    }

    #[test]
    fn test_parse_datetime_utc_edge_cases() {
        assert_eq!(parse_datetime_utc("11/04/2025", "15:50:07"), 1_762_271_407);
        assert_eq!(parse_datetime_utc("", ""), 0);
        assert_eq!(parse_datetime_utc("2016-01-23", "12:00:00"), 0);
        assert_eq!(parse_datetime_utc("01/23/2016", "aa:bb:cc"), 0);
        assert_eq!(parse_datetime_utc("xx/23/2016", "12:00:00"), 0);
    }

    #[test]
    fn test_epoch_matches_unix_reference() {
        // 1970-01-01T00:00:00Z and a known post-epoch instant.
        assert_eq!(parse_datetime_utc("01/01/1970", "00:00:00"), 0);
        assert_eq!(parse_datetime_utc("01/01/2000", "00:00:00"), 946_684_800);
    }

    #[test]
    fn test_malformed_submessages_are_ignored() {
        // A CNF with an undersized CHS (< 73 bytes) and an undersized GRP
        // (< 4 bytes) skips them without panicking; only the valid CHS counts.
        let mut cnf = Vec::new();
        cnf.extend(frame("CHS", &[0u8; 10])); // too short to be a channel def
        cnf.extend(frame("GRP", &[0u8; 2])); // too short for index + count
        cnf.extend(frame("CHS", &chs(7, 2))); // valid
        let container = parse_container(&frame("CNF", &cnf)).expect("parse");
        assert_eq!(container.channel_count(), 1);
    }

    #[test]
    fn test_walk_breaks_on_negative_length_header() {
        // A later header claiming a negative payload length stops the walk
        // cleanly; what was parsed before it survives.
        let mut file = frame("RCR", b"X\0");
        file.extend_from_slice(&MAGIC);
        file.extend_from_slice(&token_to_u32("TMT").to_le_bytes());
        file.extend_from_slice(&(-1i32).to_le_bytes());
        file.extend_from_slice(&[0x00, b'>']);
        let container = parse_container(&file).expect("parse");
        assert_eq!(container.metadata().driver, "X");
    }

    #[test]
    fn test_walk_stops_on_non_message_byte() {
        // A top-level byte that is neither a header nor a data opcode stops the
        // walk.
        let mut file = frame("RCR", b"Y\0");
        file.extend_from_slice(&[0xEE, 0xEE]);
        let container = parse_container(&file).expect("parse");
        assert_eq!(container.metadata().driver, "Y");
    }

    #[test]
    fn test_unknown_expansion_variant_stops_walk() {
        // An unrecognised (c variant cannot be sized, so the walk stops.
        let mut file = frame("RCR", b"Z\0");
        file.extend_from_slice(&[b'(', b'c', 0x05, 0, 0, 0x84, 0x00, 0, 0]);
        let container = parse_container(&file).expect("parse");
        assert_eq!(container.metadata().driver, "Z");
    }
}
