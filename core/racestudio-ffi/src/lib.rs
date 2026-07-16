//! UniFFI boundary exposing the RaceStudio Rust core to the SwiftUI frontend.
//!
//! Milestone M0 (issue 0.4) proved the Rust→Swift pipeline end-to-end with a
//! single exported `core_version()`. Milestone M1 (issue 1.7) adds the decode
//! interface: [`open_session`] returns an opaque, `Arc`-backed [`SessionHandle`]
//! over the decoded [`Session`](racestudio_decode::Session) (1.6), and Swift
//! reads channel data through the **windowed** [`SessionHandle::samples`]
//! accessor — a bounded slice per call — rather than copying whole channels
//! across the boundary. Every entry point returns a UniFFI-mapped
//! [`FfiDecodeError`]; malformed input never panics or traps.

use std::sync::Arc;

use racestudio_decode::{decode_session, DecodeError, Session};

uniffi::setup_scaffolding!();

/// The RaceStudio Rust core version, exported across the UniFFI boundary.
///
/// Returns the `racestudio-ffi` crate version (`CARGO_PKG_VERSION`). Swift calls
/// this as `coreVersion()`; a round-trip test asserts the string crosses the
/// boundary unchanged, proving the FFI pipeline works.
#[uniffi::export]
#[must_use]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Session metadata carried across the boundary (mirrors the decode
/// [`Metadata`](racestudio_decode::Metadata)).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionMetadata {
    /// Vehicle name.
    pub vehicle: String,
    /// Track / venue name.
    pub track: String,
    /// Driver / racer name.
    pub driver: String,
    /// Session name.
    pub session: String,
    /// Championship / series name.
    pub series: String,
    /// Raw log date as stored (`MM/DD/YYYY`).
    pub log_date: String,
    /// Raw log time as stored (`HH:MM:SS`).
    pub log_time: String,
    /// Session start as epoch seconds (UTC; 0 when absent/unparseable).
    pub datetime_utc: i64,
}

/// A channel's listing entry: metadata only — **no** bulk samples. Sample data
/// is fetched separately and in windows via [`SessionHandle::samples`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct ChannelInfo {
    /// Channel name (e.g. `RPM`, `AccelerometerX`).
    pub name: String,
    /// Physical unit (e.g. `g`, `V`); empty when dimensionless.
    pub unit: String,
    /// Native sample rate in hertz (0 when unknown).
    pub sample_rate_hz: f64,
    /// Display precision (decimal places) hint.
    pub decimals: u8,
    /// Number of samples in the channel (reported without copying them).
    pub sample_count: u32,
}

/// One decoded lap's timing.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LapInfo {
    /// Zero-based lap index within the session.
    pub index: u32,
    /// Session-relative start time in seconds (cumulative).
    pub start_time_s: f64,
    /// Lap duration in seconds.
    pub duration_s: f64,
    /// Session-relative end time in seconds (`start + duration`).
    pub end_time_s: f64,
}

/// A summary of the session's GPS stream — counts and time span, without the
/// per-fix bulk data.
#[derive(Debug, Clone, uniffi::Record)]
pub struct GpsSummary {
    /// Number of GPS fixes.
    pub fix_count: u32,
    /// Number of GPS channels (raw + computed).
    pub channel_count: u32,
    /// Timecode (ms) of the first fix (0 when there are none).
    pub first_timecode_ms: f64,
    /// Timecode (ms) of the last fix (0 when there are none).
    pub last_timecode_ms: f64,
}

/// One channel sample: a `(timecode, value)` pair.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Sample {
    /// Logger timecode (milliseconds for most channels).
    pub timecode: f64,
    /// The sample's physical value.
    pub value: f64,
}

/// The decode failure surface across the FFI boundary, mapped from the decode
/// crate's [`DecodeError`], plus the FFI-specific out-of-range channel index.
#[derive(Debug, uniffi::Error)]
pub enum FfiDecodeError {
    /// The file could not be read from disk.
    Io { message: String },
    /// The file does not begin with the `.xrk` header magic.
    BadMagic,
    /// The first header message is cut short.
    TruncatedHeader,
    /// A channel data message's samples run past end-of-file.
    TruncatedChannel,
    /// A multi-sample burst declared an invalid sample count.
    BadSampleCount,
    /// The GPS stream is not a whole number of records.
    TruncatedGps,
    /// A lap marker is too short for its timing fields.
    TruncatedLaps,
    /// A `samples(...)` call named a channel index outside `0..channel_count`.
    ChannelOutOfRange {
        /// The requested (invalid) index.
        index: u32,
        /// The number of channels in the session.
        channel_count: u32,
    },
    /// Any decode error the FFI layer does not distinguish — the reserved
    /// `UnknownUnit` (which the tolerant decoder never emits) and any variant
    /// added to the `#[non_exhaustive]` `DecodeError` after this mapping. Carries
    /// the underlying human-readable message so the boundary stays total.
    Other { message: String },
}

impl std::fmt::Display for FfiDecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FfiDecodeError::Io { message } => write!(f, "failed to read .xrk file: {message}"),
            FfiDecodeError::BadMagic => write!(f, "not an .xrk file: missing '<h' header magic"),
            FfiDecodeError::TruncatedHeader => write!(f, "truncated .xrk header"),
            FfiDecodeError::TruncatedChannel => write!(f, "truncated channel data"),
            FfiDecodeError::BadSampleCount => write!(f, "invalid channel sample count"),
            FfiDecodeError::TruncatedGps => write!(f, "truncated GPS data"),
            FfiDecodeError::TruncatedLaps => write!(f, "truncated lap marker"),
            FfiDecodeError::ChannelOutOfRange {
                index,
                channel_count,
            } => write!(
                f,
                "channel index {index} out of range (session has {channel_count} channels)"
            ),
            FfiDecodeError::Other { message } => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for FfiDecodeError {}

impl From<DecodeError> for FfiDecodeError {
    fn from(err: DecodeError) -> Self {
        match err {
            DecodeError::Io(e) => FfiDecodeError::Io {
                message: e.to_string(),
            },
            DecodeError::BadMagic => FfiDecodeError::BadMagic,
            DecodeError::TruncatedHeader => FfiDecodeError::TruncatedHeader,
            DecodeError::TruncatedChannel => FfiDecodeError::TruncatedChannel,
            DecodeError::BadSampleCount => FfiDecodeError::BadSampleCount,
            DecodeError::TruncatedGps => FfiDecodeError::TruncatedGps,
            DecodeError::TruncatedLaps => FfiDecodeError::TruncatedLaps,
            // `DecodeError` is `#[non_exhaustive]`; the reserved `UnknownUnit`
            // and any future variant map to a message-bearing catch-all so the
            // boundary stays total.
            other => FfiDecodeError::Other {
                message: other.to_string(),
            },
        }
    }
}

/// An opened decode session, exposed to Swift as an opaque, `Arc`-backed handle.
///
/// The whole [`Session`](racestudio_decode::Session) is decoded once when the
/// handle is created ([`open_session`]); the accessors then read from it in
/// place. Channel samples are read in bounded windows via [`Self::samples`], so
/// Swift never has to copy an entire channel to display part of it.
#[derive(Debug, uniffi::Object)]
pub struct SessionHandle {
    session: Session,
}

#[uniffi::export]
impl SessionHandle {
    /// The session metadata (driver, vehicle, venue, date/time).
    #[must_use]
    pub fn metadata(&self) -> SessionMetadata {
        let m = self.session.metadata();
        SessionMetadata {
            vehicle: m.vehicle.clone(),
            track: m.track.clone(),
            driver: m.driver.clone(),
            session: m.session.clone(),
            series: m.series.clone(),
            log_date: m.log_date.clone(),
            log_time: m.log_time.clone(),
            datetime_utc: m.datetime_utc,
        }
    }

    /// The channel listing: one [`ChannelInfo`] per channel, metadata only. Use
    /// [`Self::samples`] to read a channel's sample window.
    #[must_use]
    pub fn channels(&self) -> Vec<ChannelInfo> {
        self.session
            .channels()
            .iter()
            .map(|c| ChannelInfo {
                name: c.name().to_string(),
                unit: c.unit().to_string(),
                sample_rate_hz: c.sample_rate_hz(),
                decimals: c.decimals(),
                sample_count: u32::try_from(c.samples().len()).unwrap_or(u32::MAX),
            })
            .collect()
    }

    /// The lap timing as a listing.
    #[must_use]
    pub fn laps(&self) -> Vec<LapInfo> {
        self.session
            .laps()
            .laps()
            .iter()
            .map(|l| LapInfo {
                index: l.index(),
                start_time_s: l.start_time_s(),
                duration_s: l.duration_s(),
                end_time_s: l.end_time_s(),
            })
            .collect()
    }

    /// A summary of the GPS stream, or `None` when the session carries no GPS.
    #[must_use]
    pub fn gps_summary(&self) -> Option<GpsSummary> {
        let gps = self.session.gps()?;
        let fixes = gps.fixes();
        Some(GpsSummary {
            fix_count: u32::try_from(fixes.len()).unwrap_or(u32::MAX),
            channel_count: u32::try_from(gps.channels().len()).unwrap_or(u32::MAX),
            first_timecode_ms: fixes.first().map_or(0.0, |fix| fix.timecode_ms),
            last_timecode_ms: fixes.last().map_or(0.0, |fix| fix.timecode_ms),
        })
    }

    /// Read at most `count` samples of channel `channel_index`, starting at
    /// sample `start`.
    ///
    /// The window is **clamped** to the channel: a `start` at or past the end
    /// yields an empty vec, and a `count` that overruns the end returns only the
    /// samples that remain — never an over-read.
    ///
    /// # Errors
    /// [`FfiDecodeError::ChannelOutOfRange`] when `channel_index` is not a valid
    /// channel. Never panics.
    pub fn samples(
        &self,
        channel_index: u32,
        start: u32,
        count: u32,
    ) -> Result<Vec<Sample>, FfiDecodeError> {
        let channels = self.session.channels();
        let channel = channels.get(channel_index as usize).ok_or_else(|| {
            FfiDecodeError::ChannelOutOfRange {
                index: channel_index,
                channel_count: u32::try_from(channels.len()).unwrap_or(u32::MAX),
            }
        })?;
        let samples = channel.samples();
        let start = start as usize;
        if start >= samples.len() {
            return Ok(Vec::new());
        }
        let end = start.saturating_add(count as usize).min(samples.len());
        Ok(samples[start..end]
            .iter()
            .map(|&(timecode, value)| Sample { timecode, value })
            .collect())
    }
}

/// Open and decode the `.xrk` file at `path` into an opaque [`SessionHandle`].
///
/// The whole session (metadata + channels + GPS + laps) is decoded up front via
/// [`decode_session`]; the returned handle is `Arc`-backed and immutable.
///
/// # Errors
/// An [`FfiDecodeError`] mapped from the decode failure — I/O, bad magic, or a
/// truncated/malformed stream. Never panics or traps.
#[uniffi::export]
pub fn open_session(path: String) -> Result<Arc<SessionHandle>, FfiDecodeError> {
    let session = decode_session(path)?;
    Ok(Arc::new(SessionHandle { session }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_core_version_returns_crate_version() {
        assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn test_error_display_and_mapping_is_total() {
        // Every mapped DecodeError renders a message; the Io mapping carries the
        // OS message; the FFI-only variants render too.
        let io = FfiDecodeError::from(DecodeError::from(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "gone",
        )));
        assert!(io.to_string().contains("gone"));

        for err in [
            FfiDecodeError::from(DecodeError::BadMagic),
            FfiDecodeError::from(DecodeError::TruncatedHeader),
            FfiDecodeError::from(DecodeError::TruncatedChannel),
            FfiDecodeError::from(DecodeError::BadSampleCount),
            FfiDecodeError::from(DecodeError::TruncatedGps),
            FfiDecodeError::from(DecodeError::TruncatedLaps),
            FfiDecodeError::ChannelOutOfRange {
                index: 3,
                channel_count: 1,
            },
        ] {
            assert!(!err.to_string().is_empty(), "{err:?} has a message");
        }
        assert!(FfiDecodeError::BadMagic.to_string().contains("magic"));
        assert!(FfiDecodeError::ChannelOutOfRange {
            index: 3,
            channel_count: 1
        }
        .to_string()
        .contains("out of range"));

        // The reserved `UnknownUnit` flows through the message-bearing catch-all,
        // preserving the underlying decode message across the boundary (Display
        // renders that message verbatim).
        let mapped = FfiDecodeError::from(DecodeError::UnknownUnit);
        assert!(
            matches!(&mapped, FfiDecodeError::Other { message } if message.contains("unit")),
            "UnknownUnit maps to Other, got {mapped:?}"
        );
        assert!(
            mapped.to_string().contains("unit"),
            "Other renders its message"
        );
    }
}
