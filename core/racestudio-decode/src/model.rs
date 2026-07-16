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
use crate::laps::{decode_laps, LapData};

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
    let laps = decode_laps(&container)?;
    Ok(Session {
        metadata: container.metadata().clone(),
        channels,
        gps,
        laps,
    })
}
