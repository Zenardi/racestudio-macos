//! Channel decoding (issue 1.3): the `CHS` table + `(S`/`(M` sample streams of an
//! opened [`Container`] decoded into typed, unit-tagged time series.
//!
//! An `.xrk` container defines its logged channels with `CHS` messages (nested in
//! `CNF`) and carries their samples in data messages. [`decode_channels`] walks
//! the stream, builds the channel table, and decodes each channel's samples into
//! `(timecode_ms, value)` pairs — clean-room, validated against libxrk's
//! `log.channels` as the golden oracle.
//!
//! Faithful reproduction of libxrk hinges on three subtleties:
//!
//! - **Definitions are first-wins.** A `CHS` index is defined once; later
//!   retransmissions (which can carry a *different* name, e.g. `Temperature 1` →
//!   `Exhaust Temp`) are ignored. This is the opposite of header metadata, which
//!   is last-wins (see [`Container`]).
//! - **Samples are de-duplicated by timecode.** A single (`(S`) sample is kept
//!   only if its timecode strictly exceeds the last accepted one; a multi-sample
//!   burst (`(M`) drops the leading samples that overlap already-accepted
//!   timecodes. Without this the sample counts diverge from libxrk.
//! - **Values are raw.** libxrk stores each channel's decoded value as-is; the
//!   display precision (`decimals`) is a rounding hint, not a scale factor. The
//!   sole scaling is calibrated millivolts (`mV` → `V`, ÷1000).
//!
//! GPS channels (milestone 1.4) are *synthesized* from GPS messages, have no
//! `CHS` definition, and are therefore out of scope here — `decode_channels`
//! returns exactly the `CHS`-backed channels. Group (`(G`) and expansion (`(c`)
//! data messages are size-skipped so the walk stays aligned, but their sample
//! extraction (which needs an empirical pairing heuristic) is deferred; the M1
//! fixtures contain neither.

use std::collections::HashMap;

use crate::container::{le_i32, le_u16, le_u32, nullterm, read_header, tokstr, Container, MAGIC};
use crate::error::DecodeError;

/// libxrk drops these virtual channels from its output; we match it.
const FILTERED: [&str; 2] = ["StrtRec", "Master Clk"];

/// Metadata for one decoded [`Channel`].
#[derive(Debug, Clone, PartialEq)]
pub struct ChannelMeta {
    name: String,
    unit: String,
    sample_rate_hz: f64,
    decimals: u8,
}

impl ChannelMeta {
    /// Channel name (the `CHS` long name, e.g. `AccelerometerX`).
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Physical unit (e.g. `g`, `rpm`, `bar`); empty when the unit is unknown or
    /// dimensionless.
    #[must_use]
    pub fn unit(&self) -> &str {
        &self.unit
    }

    /// Native sample rate in Hz, from the channel's `CHS` sample period.
    #[must_use]
    pub fn sample_rate_hz(&self) -> f64 {
        self.sample_rate_hz
    }

    /// Display precision (decimal places) for the unit; a rounding hint, not a
    /// scale factor.
    #[must_use]
    pub fn decimals(&self) -> u8 {
        self.decimals
    }
}

/// A decoded channel: its [`ChannelMeta`] plus `(timecode_ms, value)` samples in
/// chronological order.
#[derive(Debug, Clone)]
pub struct Channel {
    meta: ChannelMeta,
    samples: Vec<(f64, f64)>,
}

impl Channel {
    /// The channel's metadata (name, unit, sample rate, precision).
    #[must_use]
    pub fn meta(&self) -> &ChannelMeta {
        &self.meta
    }

    /// Channel name (see [`ChannelMeta::name`]).
    #[must_use]
    pub fn name(&self) -> &str {
        self.meta.name()
    }

    /// Physical unit (see [`ChannelMeta::unit`]).
    #[must_use]
    pub fn unit(&self) -> &str {
        self.meta.unit()
    }

    /// Native sample rate in Hz (see [`ChannelMeta::sample_rate_hz`]).
    #[must_use]
    pub fn sample_rate_hz(&self) -> f64 {
        self.meta.sample_rate_hz()
    }

    /// Display precision (see [`ChannelMeta::decimals`]).
    #[must_use]
    pub fn decimals(&self) -> u8 {
        self.meta.decimals()
    }

    /// The channel's samples as `(timecode_ms, value)` pairs.
    #[must_use]
    pub fn samples(&self) -> &[(f64, f64)] {
        &self.samples
    }
}

/// Decode all `CHS`-backed channels of an opened container into typed series.
///
/// Returns one [`Channel`] per non-empty, decodable channel definition, in
/// `CHS`-index order. GPS channels (1.4) are excluded (they have no `CHS`).
///
/// # Errors
/// - [`DecodeError::TruncatedChannel`] if a channel data message's samples run
///   past the end of the stream.
/// - [`DecodeError::BadSampleCount`] if a `(M` burst declares a zero or
///   overflowing sample count.
///
/// Malformed input never panics.
pub fn decode_channels(container: &Container) -> Result<Vec<Channel>, DecodeError> {
    let mut builder = Builder::default();
    builder.walk(container.raw(), true)?;
    Ok(builder.into_channels())
}

/// A parsed channel definition.
struct Def {
    name: String,
    unit: String,
    decimals: u8,
    decoder: Option<Decoder>,
    data_size: usize,
    period_us: u32,
    /// Whether to decode and emit samples (known decoder, not a filtered virtual
    /// channel, consistent item/data size). Non-kept channels are still
    /// size-skipped so the walk stays aligned.
    keep: bool,
}

impl Def {
    /// Decode one sample block into its physical value (`mV`→`V` applied).
    fn value(&self, block: &[u8]) -> Option<f64> {
        let raw = self.decoder?.decode(block)?;
        Some(if self.unit == "V" { raw / 1000.0 } else { raw })
    }
}

/// Accumulates the channel table and per-channel samples across the walk.
#[derive(Default)]
struct Builder {
    defs: HashMap<u16, Def>,
    order: Vec<u16>,
    group_sizes: HashMap<u16, usize>,
    samples: HashMap<u16, Vec<(f64, f64)>>,
    last_tc: HashMap<u16, i32>,
}

impl Builder {
    /// Walk a message stream. `top` is false inside a `CNF`/`ENF` sub-stream
    /// (header messages only — no data messages).
    fn walk(&mut self, bytes: &[u8], top: bool) -> Result<(), DecodeError> {
        let mut off = 0;
        while off + 2 <= bytes.len() {
            if bytes[off..off + 2] == MAGIC {
                let Some(header) = read_header(bytes, off) else {
                    break;
                };
                self.register(header.token, header.payload)?;
                off = header.next;
            } else if top && bytes[off] == b'(' {
                match self.consume_data(bytes, off)? {
                    Some(next) if next > off => off = next,
                    _ => break,
                }
            } else {
                break;
            }
        }
        Ok(())
    }

    fn register(&mut self, token: u32, payload: &[u8]) -> Result<(), DecodeError> {
        match tokstr(token).as_str() {
            "CNF" | "ENF" => self.walk(payload, false)?,
            "CHS" => self.register_chs(payload),
            "GRP" => self.register_group(payload),
            _ => {}
        }
        Ok(())
    }

    /// Register a channel definition. First-wins: a later `CHS` for an index that
    /// is already defined is ignored (matching libxrk, which rejects renamed
    /// retransmissions).
    fn register_chs(&mut self, payload: &[u8]) {
        if payload.len() < 73 {
            return;
        }
        // `payload.len() >= 73` guarantees the index/name/period/size fields.
        let index = u16::from_le_bytes([payload[0], payload[1]]);
        if self.defs.contains_key(&index) {
            return;
        }
        let (unit, decimals) = unit_for(payload[12]);
        let decoder = decoder_for(payload[20]);
        let data_size = payload[72] as usize;
        let period_us = le_u32(payload, 64).unwrap_or(0);
        let name = nullterm(&payload[32..56]);
        let keep = !FILTERED.contains(&name.as_str())
            && data_size > 0
            && decoder.is_some_and(|d| d.itemsize() <= data_size);
        self.order.push(index);
        self.defs.insert(
            index,
            Def {
                name,
                unit,
                decimals,
                decoder,
                data_size,
                period_us,
                keep,
            },
        );
    }

    /// A `GRP` defines a group whose `(G` body is the concatenation of its member
    /// channels' bytes; record that total so `(G` can be size-skipped.
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
            total += self.defs.get(&channel).map_or(0, |d| d.data_size);
        }
        self.group_sizes.insert(gidx, total);
    }

    /// Consume the data message at `off`, extracting `(S`/`(M` samples. Returns
    /// the next offset (`Some`), a signal to stop (`None`: unknown channel or
    /// message kind), or an error on truncation / bad sample count.
    fn consume_data(&mut self, bytes: &[u8], off: usize) -> Result<Option<usize>, DecodeError> {
        match bytes.get(off + 1).copied() {
            Some(b'S') => self.consume_single(bytes, off),
            Some(b'M') => self.consume_multi(bytes, off),
            Some(b'G') => {
                // '(G' + timecode(4) + group(2) + data + ')'. Size-skip only.
                let Some(gidx) = le_u16(bytes, off + 6) else {
                    return Ok(None);
                };
                let Some(size) = self.group_sizes.get(&gidx).copied() else {
                    return Ok(None);
                };
                let end = off + 9 + size;
                if end > bytes.len() {
                    return Err(DecodeError::TruncatedChannel);
                }
                Ok(Some(end))
            }
            Some(b'c') => self.skip_expansion(bytes, off),
            _ => Ok(None),
        }
    }

    /// '(S' + timecode(4) + channel(2) + data(size) + ')'.
    fn consume_single(&mut self, bytes: &[u8], off: usize) -> Result<Option<usize>, DecodeError> {
        let Some(index) = le_u16(bytes, off + 6) else {
            return Ok(None);
        };
        let Some(def) = self.defs.get(&index) else {
            return Ok(None);
        };
        let end = off + 9 + def.data_size;
        if end > bytes.len() {
            return Err(DecodeError::TruncatedChannel);
        }
        if def.keep {
            let tc = le_i32(bytes, off + 2).ok_or(DecodeError::TruncatedChannel)?;
            if tc > self.last_tc.get(&index).copied().unwrap_or(i32::MIN) {
                self.last_tc.insert(index, tc);
                if let Some(value) = def.value(&bytes[off + 8..off + 8 + def.data_size]) {
                    self.samples
                        .entry(index)
                        .or_default()
                        .push((f64::from(tc), value));
                }
            }
        }
        Ok(Some(end))
    }

    /// '(M' + timecode(4) + channel(2) + count(2) + data(size*count) + ')'. The
    /// burst's `count` samples are at `tc + j*Mms`; leading samples overlapping
    /// the last accepted timecode are skipped.
    fn consume_multi(&mut self, bytes: &[u8], off: usize) -> Result<Option<usize>, DecodeError> {
        let Some(index) = le_u16(bytes, off + 6) else {
            return Ok(None);
        };
        let Some(def) = self.defs.get(&index) else {
            return Ok(None);
        };
        let size = def.data_size;
        let count = le_u16(bytes, off + 8).ok_or(DecodeError::TruncatedChannel)? as usize;
        if count == 0 {
            return Err(DecodeError::BadSampleCount);
        }
        let body = size.checked_mul(count).ok_or(DecodeError::BadSampleCount)?;
        let base = off + 10;
        let end = base + body + 1; // trailing ')'
        if end > bytes.len() {
            return Err(DecodeError::TruncatedChannel);
        }
        if def.keep {
            let tc = i64::from(le_i32(bytes, off + 2).ok_or(DecodeError::TruncatedChannel)?);
            let mms = i64::from(def.period_us / 1000);
            let prev = i64::from(self.last_tc.get(&index).copied().unwrap_or(i32::MIN));
            let mut m_skip = 0usize;
            if tc <= prev && mms > 0 {
                m_skip = usize::try_from((prev - tc) / mms + 1).unwrap_or(usize::MAX);
            }
            if m_skip < count {
                let last = tc + (count as i64 - 1) * mms;
                self.last_tc.insert(index, last as i32);
                for j in m_skip..count {
                    let start = base + j * size;
                    if let Some(value) = def.value(&bytes[start..start + size]) {
                        let t = tc + (j as i64) * mms;
                        self.samples
                            .entry(index)
                            .or_default()
                            .push((t as f64, value));
                    }
                }
            }
        }
        Ok(Some(end))
    }

    /// Size-skip a `(c` expansion-channel message by its variant discriminators
    /// (`unk1` at byte 2, `unk4` at byte 6). Sample extraction is deferred.
    fn skip_expansion(&self, bytes: &[u8], off: usize) -> Result<Option<usize>, DecodeError> {
        let (Some(&unk1), Some(&unk4)) = (bytes.get(off + 2), bytes.get(off + 6)) else {
            return Ok(None);
        };
        let end = match (unk1, unk4) {
            (0x00, 0x06) => {
                let field = le_u16(bytes, off + 3).ok_or(DecodeError::TruncatedChannel)? >> 3;
                match self.defs.get(&field).map(|d| d.data_size) {
                    Some(size) => off + 12 + size,
                    None => return Ok(None),
                }
            }
            (0x00, 0x08) => off + 16,
            (0x01, 0x02) => off + 10,
            _ => return Ok(None),
        };
        if end > bytes.len() {
            return Err(DecodeError::TruncatedChannel);
        }
        Ok(Some(end))
    }

    fn into_channels(mut self) -> Vec<Channel> {
        let order = std::mem::take(&mut self.order);
        let mut channels = Vec::new();
        for index in order {
            // Every index in `order` was inserted alongside its `Def`.
            let (name, unit, decimals, period_us) = {
                let def = &self.defs[&index];
                if !def.keep {
                    continue;
                }
                (
                    def.name.clone(),
                    def.unit.clone(),
                    def.decimals,
                    def.period_us,
                )
            };
            let samples = self.samples.remove(&index).unwrap_or_default();
            if samples.is_empty() {
                continue;
            }
            let sample_rate_hz = if period_us > 0 {
                1e6 / f64::from(period_us)
            } else {
                0.0
            };
            channels.push(Channel {
                meta: ChannelMeta {
                    name,
                    unit,
                    sample_rate_hz,
                    decimals,
                },
                samples,
            });
        }
        channels
    }
}

/// How a channel's raw sample bytes are interpreted, keyed by `CHS` decoder type.
#[derive(Clone, Copy)]
enum Decoder {
    I32,
    I16,
    U8,
    U16,
    F32,
    /// 16-bit IEEE half, stored as `u16`.
    F16,
    /// `u16` mapped through a gear lookup (`N`,`1`..`6` → `0`..`6`).
    Gear,
}

impl Decoder {
    /// Bytes read per sample (may be less than the channel's `data_size`).
    fn itemsize(self) -> usize {
        match self {
            Decoder::I32 | Decoder::F32 => 4,
            Decoder::I16 | Decoder::U16 | Decoder::F16 | Decoder::Gear => 2,
            Decoder::U8 => 1,
        }
    }

    fn decode(self, block: &[u8]) -> Option<f64> {
        Some(match self {
            Decoder::I32 => f64::from(i32::from_le_bytes(block.get(..4)?.try_into().ok()?)),
            Decoder::I16 => f64::from(i16::from_le_bytes(block.get(..2)?.try_into().ok()?)),
            Decoder::U8 => f64::from(*block.first()?),
            Decoder::U16 => f64::from(u16::from_le_bytes(block.get(..2)?.try_into().ok()?)),
            Decoder::F32 => f64::from(f32::from_le_bytes(block.get(..4)?.try_into().ok()?)),
            Decoder::F16 => f16_to_f64(u16::from_le_bytes(block.get(..2)?.try_into().ok()?)),
            Decoder::Gear => f64::from(gear_lookup(u16::from_le_bytes(
                block.get(..2)?.try_into().ok()?,
            ))),
        })
    }
}

/// Map a `CHS` decoder-type byte to a [`Decoder`], or `None` if libxrk has no
/// decoder for it (the channel is then skipped).
fn decoder_for(decoder_type: u8) -> Option<Decoder> {
    Some(match decoder_type {
        0 | 3 | 8 | 12 | 22 | 24 | 26 | 27 | 31 | 32 | 33 | 37 | 38 | 39 => Decoder::I32,
        4 | 11 => Decoder::I16,
        13 => Decoder::U8,
        1 => Decoder::U16,
        15 => Decoder::Gear,
        20 => Decoder::F16,
        6 => Decoder::F32,
        _ => return None,
    })
}

/// Resolve a `CHS` unit-type byte to `(unit, decimals)`. The high bit marks a
/// calibrated channel; calibrated millivolts read as volts.
fn unit_for(unit_type_byte: u8) -> (String, u8) {
    let (unit, decimals) = unit_map(unit_type_byte & 0x7F).unwrap_or(("", 0));
    if unit_type_byte & 0x80 != 0 && unit == "mV" {
        ("V".to_string(), decimals)
    } else {
        (unit.to_string(), decimals)
    }
}

/// The `unit_type` → `(unit, decimals)` table (libxrk `_unit_map`).
fn unit_map(code: u8) -> Option<(&'static str, u8)> {
    Some(match code {
        1 => ("%", 2),
        3 => ("g", 2),
        4 => ("deg", 1),
        5 => ("deg/s", 1),
        6 => ("", 0),
        9 => ("Hz", 0),
        11 => ("", 0),
        12 => ("mm", 0),
        14 => ("bar", 2),
        15 => ("rpm", 0),
        16 => ("km/h", 0),
        17 => ("C", 1),
        18 => ("ms", 0),
        19 => ("Nm", 0),
        20 => ("km/h", 0),
        21 => ("mV", 1),
        22 => ("l", 1),
        24 => ("l/s", 0),
        26 => ("time?", 0),
        27 => ("A", 0),
        30 => ("lambda", 2),
        31 => ("gear", 0),
        33 => ("%", 2),
        43 => ("kg", 3),
        _ => return None,
    })
}

/// Convert IEEE 754 binary16 bits to `f64` (no external crate). Infinities and
/// NaNs are preserved.
fn f16_to_f64(bits: u16) -> f64 {
    let sign = if bits & 0x8000 != 0 { -1.0 } else { 1.0 };
    let exponent = (bits >> 10) & 0x1F;
    let fraction = f64::from(bits & 0x3FF);
    let magnitude = match exponent {
        0 => fraction * 2f64.powi(-24),           // subnormal (and zero)
        0x1F if fraction == 0.0 => f64::INFINITY, // ±inf
        0x1F => f64::NAN,                         // NaN
        e => (1.0 + fraction / 1024.0) * 2f64.powi(i32::from(e) - 15),
    };
    sign * magnitude
}

/// Gear lookup: ASCII `N` and `1`..`6` map to `0`..`6`; anything else passes
/// through unchanged.
fn gear_lookup(value: u16) -> u16 {
    match u8::try_from(value) {
        Ok(b'N') => 0,
        Ok(digit @ b'1'..=b'6') => u16::from(digit - b'0'),
        _ => value,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAGIC_BYTES: [u8; 2] = MAGIC;

    /// Build a framed header message (`<h … >`) with a correct checksum.
    fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
        let tok = token_to_u32(token);
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

    fn token_to_u32(token: &str) -> u32 {
        let mut bytes = token.as_bytes().to_vec();
        while bytes.len() < 4 {
            bytes.push(0);
        }
        u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
    }

    /// A 112-byte CHS payload.
    fn chs(
        index: u16,
        name: &str,
        unit_type: u8,
        decoder: u8,
        data_size: u8,
        period_us: u32,
    ) -> Vec<u8> {
        let mut p = vec![0u8; 112];
        p[0..2].copy_from_slice(&index.to_le_bytes());
        p[12] = unit_type;
        p[20] = decoder;
        let nb = name.as_bytes();
        p[32..32 + nb.len()].copy_from_slice(nb);
        p[64..68].copy_from_slice(&period_us.to_le_bytes());
        p[72] = data_size;
        p
    }

    /// A `(S` message: timecode + channel + `data`.
    fn data_s(channel: u16, tc: i32, data: &[u8]) -> Vec<u8> {
        let mut m = vec![b'(', b'S'];
        m.extend_from_slice(&tc.to_le_bytes());
        m.extend_from_slice(&channel.to_le_bytes());
        m.extend_from_slice(data);
        m.push(b')');
        m
    }

    /// A `(M` burst: timecode + channel + count + `count` samples of `data`.
    fn data_m(channel: u16, tc: i32, count: u16, samples: &[u8]) -> Vec<u8> {
        let mut m = vec![b'(', b'M'];
        m.extend_from_slice(&tc.to_le_bytes());
        m.extend_from_slice(&channel.to_le_bytes());
        m.extend_from_slice(&count.to_le_bytes());
        m.extend_from_slice(samples);
        m.push(b')');
        m
    }

    fn decode(bytes: &[u8]) -> Result<Vec<Channel>, DecodeError> {
        let mut b = Builder::default();
        b.walk(bytes, true)?;
        Ok(b.into_channels())
    }

    #[test]
    fn test_single_channel_int_samples() {
        // A CNF defining one i32 channel (unit rpm, 100 Hz) + three (S samples.
        let mut cnf = frame("CHS", &chs(0, "RPM", 15, 0, 4, 10_000));
        let _ = &mut cnf;
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 100, &1000i32.to_le_bytes()));
        file.extend(data_s(0, 200, &2000i32.to_le_bytes()));
        file.extend(data_s(0, 300, &3000i32.to_le_bytes()));

        let channels = decode(&file).expect("decode");
        assert_eq!(channels.len(), 1);
        let ch = &channels[0];
        assert_eq!(ch.name(), "RPM");
        assert_eq!(ch.unit(), "rpm");
        assert!((ch.sample_rate_hz() - 100.0).abs() < 1e-9);
        assert_eq!(ch.decimals(), 0);
        assert_eq!(
            ch.samples(),
            &[(100.0, 1000.0), (200.0, 2000.0), (300.0, 3000.0)]
        );
        assert_eq!(ch.meta().name(), "RPM");
    }

    #[test]
    fn test_single_channel_deduplicates_non_increasing_timecodes() {
        // The middle (S repeats the first timecode and must be dropped.
        let cnf = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 100, &1i32.to_le_bytes()));
        file.extend(data_s(0, 100, &2i32.to_le_bytes())); // duplicate tc → dropped
        file.extend(data_s(0, 150, &3i32.to_le_bytes()));

        let channels = decode(&file).expect("decode");
        assert_eq!(channels[0].samples(), &[(100.0, 1.0), (150.0, 3.0)]);
    }

    #[test]
    fn test_multi_sample_burst_skips_overlap() {
        // One (S at tc=100, then an (M burst at tc=100 (period 50 ms, 3 samples
        // → tc 100/150/200). The first burst sample overlaps and is skipped.
        let cnf = frame("CHS", &chs(0, "Acc", 3, 4, 2, 50_000));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 100, &10i16.to_le_bytes()));
        let mut samples = Vec::new();
        samples.extend_from_slice(&20i16.to_le_bytes());
        samples.extend_from_slice(&30i16.to_le_bytes());
        samples.extend_from_slice(&40i16.to_le_bytes());
        file.extend(data_m(0, 100, 3, &samples));

        let channels = decode(&file).expect("decode");
        // 100 kept from (S; burst 100 skipped (overlap), 150 & 200 kept.
        assert_eq!(
            channels[0].samples(),
            &[(100.0, 10.0), (150.0, 30.0), (200.0, 40.0)]
        );
        assert!((channels[0].sample_rate_hz() - 20.0).abs() < 1e-9);
    }

    #[test]
    fn test_definitions_are_first_wins() {
        // The same index is re-defined with a different name; the first wins.
        let mut cnf = frame("CHS", &chs(0, "Temperature 1", 17, 0, 4, 1_000_000));
        cnf.extend(frame("CHS", &chs(0, "Exhaust Temp", 17, 0, 4, 1_000_000)));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 10, &250i32.to_le_bytes()));

        let channels = decode(&file).expect("decode");
        assert_eq!(channels[0].name(), "Temperature 1");
        assert_eq!(channels[0].unit(), "C");
    }

    #[test]
    fn test_millivolt_calibrated_reads_as_volts() {
        // unit_type 21 (mV) with the calibrated high bit → unit V, value ÷1000.
        let cnf = frame("CHS", &chs(0, "Batt", 21 | 0x80, 0, 4, 1_000_000));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 10, &4200i32.to_le_bytes()));

        let channels = decode(&file).expect("decode");
        assert_eq!(channels[0].unit(), "V");
        assert_eq!(channels[0].samples(), &[(10.0, 4.2)]);
    }

    #[test]
    fn test_float16_and_float32_and_gear_decoders() {
        // float16 (decoder 20), float32 (decoder 6), gear (decoder 15).
        let mut cnf = frame("CHS", &chs(0, "F16", 3, 20, 2, 10_000));
        cnf.extend(frame("CHS", &chs(1, "F32", 5, 6, 4, 10_000)));
        cnf.extend(frame("CHS", &chs(2, "Gear", 31, 15, 2, 10_000)));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 10, &f16_bits(1.5).to_le_bytes()));
        file.extend(data_s(1, 10, &2.5f32.to_le_bytes()));
        file.extend(data_s(2, 10, &u16::from(b'3').to_le_bytes()));

        let channels = decode(&file).expect("decode");
        let by = |n: &str| channels.iter().find(|c| c.name() == n).unwrap();
        assert_eq!(by("F16").samples()[0].1, 1.5);
        assert_eq!(by("F32").samples()[0].1, 2.5);
        assert_eq!(by("Gear").samples()[0].1, 3.0);
    }

    #[test]
    fn test_unknown_decoder_and_filtered_channels_are_dropped() {
        // Channel 0 has an unknown decoder (99) → skipped; channel 1 is a
        // filtered virtual channel ('Master Clk') → skipped; channel 2 survives.
        let mut cnf = frame("CHS", &chs(0, "Weird", 6, 99, 4, 10_000));
        cnf.extend(frame("CHS", &chs(1, "Master Clk", 18, 0, 4, 10_000)));
        cnf.extend(frame("CHS", &chs(2, "Good", 6, 0, 4, 10_000)));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 10, &1i32.to_le_bytes())); // unknown decoder, size-skipped
        file.extend(data_s(1, 10, &2i32.to_le_bytes())); // filtered, size-skipped
        file.extend(data_s(2, 10, &3i32.to_le_bytes()));

        let channels = decode(&file).expect("decode");
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name(), "Good");
    }

    #[test]
    fn test_empty_and_channelless_streams() {
        // No channels defined at all → empty result.
        assert!(decode(&frame("RCR", b"BOB\0")).expect("decode").is_empty());
        // A defined channel with no samples is dropped (libxrk filters empties).
        let file = frame("CNF", &frame("CHS", &chs(0, "Empty", 6, 0, 4, 10_000)));
        assert!(decode(&file).expect("decode").is_empty());
    }

    #[test]
    fn test_truncated_single_and_multi_error() {
        // (S whose data runs past EOF.
        let cnf = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
        let mut file = frame("CNF", &cnf);
        file.extend_from_slice(&[b'(', b'S', 0, 0, 0, 0, 0, 0, 0x11]); // 1 of 4 data bytes
        assert!(matches!(decode(&file), Err(DecodeError::TruncatedChannel)));

        // (M whose declared burst runs past EOF.
        let cnf = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
        let mut file = frame("CNF", &cnf);
        file.extend_from_slice(&[b'(', b'M', 0, 0, 0, 0, 0, 0, 9, 0]); // count 9, no data
        assert!(matches!(decode(&file), Err(DecodeError::TruncatedChannel)));
    }

    #[test]
    fn test_zero_sample_count_is_bad() {
        let cnf = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
        let mut file = frame("CNF", &cnf);
        file.extend(data_m(0, 10, 0, &[])); // count 0
        assert!(matches!(decode(&file), Err(DecodeError::BadSampleCount)));
    }

    #[test]
    fn test_group_and_expansion_messages_are_size_skipped() {
        // A GRP over channels 0 (size 2) and 1 (size 4), a (G message, then the
        // three (c variants — all size-skipped so the trailing (S is reached.
        let mut cnf = frame("CHS", &chs(0, "A", 6, 4, 2, 10_000));
        cnf.extend(frame("CHS", &chs(1, "B", 6, 0, 4, 10_000)));
        cnf.extend(frame("CHS", &chs(2, "C", 6, 0, 4, 10_000)));
        let mut grp = vec![0u8; 8];
        grp[0..2].copy_from_slice(&0u16.to_le_bytes());
        grp[2..4].copy_from_slice(&2u16.to_le_bytes());
        grp[4..6].copy_from_slice(&0u16.to_le_bytes());
        grp[6..8].copy_from_slice(&1u16.to_le_bytes());
        cnf.extend(frame("GRP", &grp));
        let mut file = frame("CNF", &cnf);

        // (G group 0 (6 bytes body).
        let mut g = vec![b'(', b'G', 0, 0, 0, 0, 0, 0];
        g.extend_from_slice(&[0u8; 6]);
        g.push(b')');
        file.extend(g);
        // (c V1 (channel 0, size 2): '(c' 0x00 field(2) 0x84 0x06 tc(4) data(2) ')'
        let mut c1 = vec![b'(', b'c', 0x00];
        c1.extend_from_slice(&(0u16 << 3).to_le_bytes());
        c1.extend_from_slice(&[0x84, 0x06, 0, 0, 0, 0, 0, 0]);
        c1.push(b')');
        file.extend(c1);
        // (c V2 (fixed 16) and V3 (fixed 10).
        let mut c2 = vec![b'(', b'c', 0x00, 0, 0, 0x84, 0x08, 0, 0, 0, 0];
        c2.extend_from_slice(&[0u8; 4]);
        c2.push(b')');
        file.extend(c2);
        file.extend_from_slice(&[b'(', b'c', 0x01, 0, 0, 0x84, 0x02, 0, 0, b')']);
        // A real (S for channel 2 after all the skips.
        file.extend(data_s(2, 42, &7i32.to_le_bytes()));

        let channels = decode(&file).expect("decode");
        let c = channels
            .iter()
            .find(|c| c.name() == "C")
            .expect("channel C reached");
        assert_eq!(c.samples(), &[(42.0, 7.0)]);
    }

    #[test]
    fn test_walk_stops_on_unknown_message() {
        // An unknown '(x' data message and a stray non-message byte both stop the
        // walk cleanly, keeping what was decoded before.
        let cnf = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 10, &5i32.to_le_bytes()));
        file.extend_from_slice(&[b'(', b'x', 0, 0]);
        let channels = decode(&file).expect("decode");
        assert_eq!(channels[0].samples(), &[(10.0, 5.0)]);
    }

    #[test]
    fn test_f16_special_values() {
        assert_eq!(f16_to_f64(0x0000), 0.0);
        assert_eq!(f16_to_f64(0x3C00), 1.0);
        assert_eq!(f16_to_f64(0xC000), -2.0);
        assert!(f16_to_f64(0x7C00).is_infinite() && f16_to_f64(0x7C00) > 0.0);
        assert!(f16_to_f64(0xFC00).is_infinite() && f16_to_f64(0xFC00) < 0.0);
        assert!(f16_to_f64(0x7E00).is_nan());
        assert!(f16_to_f64(0x0001) > 0.0 && f16_to_f64(0x0001) < 1e-6); // subnormal
    }

    #[test]
    fn test_gear_and_unit_edge_cases() {
        assert_eq!(gear_lookup(u16::from(b'N')), 0);
        assert_eq!(gear_lookup(u16::from(b'6')), 6);
        assert_eq!(gear_lookup(1234), 1234);
        assert_eq!(unit_for(0x00), (String::new(), 0)); // unknown unit → empty
        assert_eq!(unit_for(3), ("g".to_string(), 2));
        assert_eq!(unit_for(21), ("mV".to_string(), 1)); // uncalibrated mV stays mV
    }

    #[test]
    fn test_unit_map_covers_every_known_code() {
        // Exercise every arm of the unit table and confirm an unknown code and
        // the calibrated-mV→V rule.
        let known = [
            (1, "%", 2),
            (3, "g", 2),
            (4, "deg", 1),
            (5, "deg/s", 1),
            (6, "", 0),
            (9, "Hz", 0),
            (11, "", 0),
            (12, "mm", 0),
            (14, "bar", 2),
            (15, "rpm", 0),
            (16, "km/h", 0),
            (17, "C", 1),
            (18, "ms", 0),
            (19, "Nm", 0),
            (20, "km/h", 0),
            (21, "mV", 1),
            (22, "l", 1),
            (24, "l/s", 0),
            (26, "time?", 0),
            (27, "A", 0),
            (30, "lambda", 2),
            (31, "gear", 0),
            (33, "%", 2),
            (43, "kg", 3),
        ];
        for (code, unit, dec) in known {
            assert_eq!(unit_map(code), Some((unit, dec)), "unit_map({code})");
        }
        assert_eq!(unit_map(200), None, "unknown code");
        assert_eq!(
            unit_for(21 | 0x80),
            ("V".to_string(), 1),
            "calibrated mV → V"
        );
    }

    #[test]
    fn test_decoder_table_covers_every_type() {
        // Every decoder type resolves; each `Decoder` variant round-trips a
        // sample (covering itemsize + decode for all arms, incl. U8).
        for t in [0u8, 3, 8, 12, 22, 24, 26, 27, 31, 32, 33, 37, 38, 39] {
            assert!(matches!(decoder_for(t), Some(Decoder::I32)));
        }
        assert!(matches!(decoder_for(4), Some(Decoder::I16)));
        assert!(matches!(decoder_for(11), Some(Decoder::I16)));
        assert!(matches!(decoder_for(13), Some(Decoder::U8)));
        assert!(matches!(decoder_for(1), Some(Decoder::U16)));
        assert!(matches!(decoder_for(15), Some(Decoder::Gear)));
        assert!(matches!(decoder_for(20), Some(Decoder::F16)));
        assert!(matches!(decoder_for(6), Some(Decoder::F32)));
        assert!(decoder_for(200).is_none());

        assert_eq!(Decoder::I32.itemsize(), 4);
        assert_eq!(Decoder::I16.itemsize(), 2);
        assert_eq!(Decoder::U8.itemsize(), 1);
        assert_eq!(Decoder::I32.decode(&(-5i32).to_le_bytes()), Some(-5.0));
        assert_eq!(Decoder::I16.decode(&(-7i16).to_le_bytes()), Some(-7.0));
        assert_eq!(Decoder::U8.decode(&[200]), Some(200.0));
        assert_eq!(Decoder::U16.decode(&300u16.to_le_bytes()), Some(300.0));
        assert_eq!(Decoder::F32.decode(&1.5f32.to_le_bytes()), Some(1.5));
        assert_eq!(
            Decoder::Gear.decode(&u16::from(b'4').to_le_bytes()),
            Some(4.0)
        );
        assert_eq!(Decoder::I32.decode(&[0, 0]), None); // too few bytes
    }

    #[test]
    fn test_u8_channel_decodes() {
        // A status channel (decoder 13 → u8, size 1) — exercises the U8 path
        // end-to-end.
        let cnf = frame("CHS", &chs(0, "Status", 6, 13, 1, 100_000));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 10, &[7]));
        file.extend(data_s(0, 20, &[9]));
        let channels = decode(&file).expect("decode");
        assert_eq!(channels[0].samples(), &[(10.0, 7.0), (20.0, 9.0)]);
    }

    #[test]
    fn test_multi_burst_fully_behind_last_tc_is_dropped() {
        // An (S advances last_tc past a following (M burst entirely (m_skip >=
        // count), so the whole burst is dropped.
        let cnf = frame("CHS", &chs(0, "X", 6, 4, 2, 10_000));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 1000, &1i16.to_le_bytes())); // last_tc = 1000
        let mut samples = Vec::new();
        samples.extend_from_slice(&2i16.to_le_bytes());
        samples.extend_from_slice(&3i16.to_le_bytes());
        file.extend(data_m(0, 100, 2, &samples)); // tc 100/110, both <= 1000
        let channels = decode(&file).expect("decode");
        assert_eq!(channels[0].samples(), &[(1000.0, 1.0)], "burst dropped");
    }

    #[test]
    fn test_malformed_definition_blocks_are_ignored() {
        // A short CHS (< 73 bytes) and a short GRP (< 4 bytes) are skipped
        // without panicking; only the valid channel survives.
        let mut cnf = frame("CHS", &[0u8; 10]); // too short
        cnf.extend(frame("GRP", &[0u8; 2])); // too short for index + count
        cnf.extend(frame("CHS", &chs(7, "Good", 6, 0, 4, 10_000)));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(7, 10, &1i32.to_le_bytes()));
        let channels = decode(&file).expect("decode");
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name(), "Good");
    }

    #[test]
    fn test_data_for_unknown_channel_stops_walk() {
        // A data message for an index with no CHS cannot be sized, so the walk
        // stops cleanly, keeping earlier samples.
        let cnf = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
        let mut file = frame("CNF", &cnf);
        file.extend(data_s(0, 10, &1i32.to_le_bytes()));
        file.extend(data_s(99, 20, &2i32.to_le_bytes())); // channel 99 undefined
        let channels = decode(&file).expect("decode");
        assert_eq!(channels[0].samples(), &[(10.0, 1.0)]);
    }

    #[test]
    fn test_truncated_message_headers_stop_walk() {
        // A bare '(S' / '(M' at EOF (no channel field) stops the walk; likewise a
        // truncated header mid-stream and a stray non-message byte.
        for tail in [
            &b"(S"[..],              // (S with no channel index
            &b"(M"[..],              // (M with no channel index
            &[0x3C, 0x68, b'T'][..], // '<h' then a cut-short header
            &[0xEE, 0xEE][..],       // stray non-message bytes
        ] {
            let cnf = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
            let mut file = frame("CNF", &cnf);
            file.extend(data_s(0, 10, &1i32.to_le_bytes()));
            file.extend_from_slice(tail);
            let channels = decode(&file).expect("decode never panics");
            assert_eq!(channels[0].samples(), &[(10.0, 1.0)]);
        }
    }

    #[test]
    fn test_group_and_expansion_edge_cases() {
        let base = || {
            let cnf = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
            let mut f = frame("CNF", &cnf);
            f.extend(data_s(0, 10, &1i32.to_le_bytes()));
            f
        };
        let decoded_keeps_first = |tail: &[u8]| {
            let mut f = base();
            f.extend_from_slice(tail);
            let ch = decode(&f).expect("decode");
            assert_eq!(ch[0].samples(), &[(10.0, 1.0)]);
        };
        // (G for an unknown group index → walk stops.
        decoded_keeps_first(&[b'(', b'G', 0, 0, 0, 0, 5, 0]);
        // (G whose declared body runs past EOF → error.
        let mut grp = vec![0u8; 8];
        grp[0..2].copy_from_slice(&0u16.to_le_bytes());
        grp[2..4].copy_from_slice(&1u16.to_le_bytes());
        grp[4..6].copy_from_slice(&0u16.to_le_bytes()); // channel 0, size 4
        let mut f = frame("CNF", &{
            let mut c = frame("CHS", &chs(0, "X", 6, 0, 4, 10_000));
            c.extend(frame("GRP", &grp));
            c
        });
        f.extend_from_slice(&[b'(', b'G', 0, 0, 0, 0, 0, 0]); // group 0, no body → truncated
        assert!(matches!(decode(&f), Err(DecodeError::TruncatedChannel)));
        // (c short (no unk4 byte), unknown variant, unknown V1 channel, and a
        // truncated V2 — all handled without panic.
        decoded_keeps_first(&[b'(', b'c', 0x00]); // too short for unk4
        decoded_keeps_first(&[b'(', b'c', 0x05, 0, 0, 0x84, 0x00, 0, 0]); // unknown variant
        decoded_keeps_first(&[b'(', b'c', 0x00, 0xFF, 0xFF, 0x84, 0x06, 0, 0, 0, 0]); // V1 unknown channel
        let mut f = base();
        f.extend_from_slice(&[b'(', b'c', 0x00, 0, 0, 0x84, 0x08]); // V2 header, body past EOF
        assert!(matches!(decode(&f), Err(DecodeError::TruncatedChannel)));
    }

    /// Encode a finite `f32` value into IEEE binary16 bits (round-to-nearest is
    /// not needed for the exact test values used here).
    fn f16_bits(value: f32) -> u16 {
        let bits = value.to_bits();
        let sign = ((bits >> 16) & 0x8000) as u16;
        let exp = ((bits >> 23) & 0xFF) as i32 - 127 + 15;
        let frac = ((bits >> 13) & 0x3FF) as u16;
        sign | ((exp as u16) << 10) | frac
    }
}
