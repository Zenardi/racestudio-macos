//! The unified session model (issue 1.6).
//!
//! [`decode_session`] is the crate's primary entry point: one call opens the
//! `.xrk` container and runs every layered decoder (channels 1.3, GPS 1.4, laps
//! 1.5) over it, returning a complete, immutable [`Session`]. Everything is
//! decoded once, up front — no field decodes lazily on access — so the returned
//! value is a plain, cloneable data bundle with typed accessors.
//!
//! Every failure funnels through the single [`DecodeError`] enum, and no input
//! (missing, malformed, or truncated) ever panics.

use std::path::Path;

use crate::channels::{decode_channels, Channel};
use crate::container::{open_container, Metadata};
use crate::error::DecodeError;
use crate::gps::{decode_gps, GpsData};
use crate::laps::{decode_laps_and_origin, LapData};

/// A fully decoded `.xrk` session: the container [`Metadata`] plus every decoded
/// layer — [`Channel`]s (1.3), [`GpsData`] (1.4), and [`LapData`] (1.5).
///
/// A `Session` is immutable (accessors hand out shared references only) and
/// cloneable. It is decoded eagerly by [`decode_session`]; holding one performs
/// no further decoding. This is the stable surface the UniFFI layer (1.7) and
/// the golden-validation harness (1.8) build on.
#[derive(Debug, Clone)]
pub struct Session {
    metadata: Metadata,
    channels: Vec<Channel>,
    gps: Option<GpsData>,
    laps: LapData,
    first_lap_origin_ms: Option<i64>,
}

impl Session {
    /// The parsed session metadata (driver, vehicle, venue, date/time).
    #[must_use]
    pub fn metadata(&self) -> &Metadata {
        &self.metadata
    }

    /// The decoded channel series, in container order.
    #[must_use]
    pub fn channels(&self) -> &[Channel] {
        &self.channels
    }

    /// The decoded GPS data, or `None` when the session carries no GPS stream.
    #[must_use]
    pub fn gps(&self) -> Option<&GpsData> {
        self.gps.as_ref()
    }

    /// The decoded lap timing (empty when the session has no lap markers).
    #[must_use]
    pub fn laps(&self) -> &LapData {
        &self.laps
    }

    /// The raw logger timecode (ms) at which lap timing began — the first LAP
    /// marker's `end_time − duration` — or `None` when the session has no laps.
    ///
    /// Channel/GPS sample timecodes are stored **raw**. A consumer that needs a
    /// session-relative axis (e.g. the AiM CSV export, 5.1) derives the recording
    /// origin as `min(first_lap_origin, earliest sample timecode)` — matching
    /// libxrk's `time_offset` — and subtracts it. Exposing the raw lap origin
    /// (rather than a pre-combined offset) keeps this a decoded fact and leaves
    /// the axis policy to the consumer.
    #[must_use]
    pub fn first_lap_origin_ms(&self) -> Option<i64> {
        self.first_lap_origin_ms
    }
}

/// Decode an AiM `.xrk` file at `path` into a complete [`Session`].
///
/// This orchestrates the layered decoders in one call: [`open_container`] parses
/// the header, then [`decode_channels`], [`decode_gps`], and [`decode_laps`] run
/// over the opened container. All four parts are decoded up front and bundled
/// into an immutable [`Session`]; the result is exactly the sum of the individual
/// decoders (1.2–1.5).
///
/// # Errors
/// Returns a [`DecodeError`] for any failure: [`Io`](DecodeError::Io) when the
/// file cannot be read, [`BadMagic`](DecodeError::BadMagic) /
/// [`TruncatedHeader`](DecodeError::TruncatedHeader) for a malformed container,
/// or a per-layer truncation error. Never panics on any input.
///
/// # Examples
/// ```no_run
/// let session = racestudio_decode::decode_session("session.xrk")?;
/// println!(
///     "{} — {} channels, {} laps",
///     session.metadata().driver,
///     session.channels().len(),
///     session.laps().len(),
/// );
/// # Ok::<(), racestudio_decode::DecodeError>(())
/// ```
pub fn decode_session(path: impl AsRef<Path>) -> Result<Session, DecodeError> {
    let container = open_container(path)?;
    let channels = decode_channels(&container)?;
    let gps = decode_gps(&container)?;
    // One walk yields both the laps and the raw first-lap origin.
    let (laps, first_lap_origin_ms) = decode_laps_and_origin(&container)?;
    Ok(Session {
        metadata: container.metadata().clone(),
        channels,
        gps,
        laps,
        first_lap_origin_ms,
    })
}
