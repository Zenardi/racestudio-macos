//! Clean-room decoder for AiM RaceStudio telemetry (`.xrk`) files.
//!
//! Decoding is validated against XRKConverter's `libxrk` output as the golden
//! oracle (see the decode-strategy ADR, `docs/adr/0002-xrk-decode-strategy.md`).
//! Milestone M1 builds it up in layers — the container + header metadata (1.2,
//! [`open_container`]), channels (1.3, [`decode_channels`]), GPS (1.4,
//! [`decode_gps`]), laps (1.5, [`decode_laps`]) — then unifies them (1.6) behind
//! one call, [`decode_session`], which returns a complete, immutable [`Session`].
//! Every entry point returns [`Result`] with the single [`DecodeError`] enum and
//! never panics on malformed input.
//!
//! ```no_run
//! // One call decodes the whole session (metadata + channels + GPS + laps):
//! let session = racestudio_decode::decode_session("session.xrk")?;
//! let meta = session.metadata();
//! println!("{} at {} — {} channels", meta.driver, meta.track, session.channels().len());
//! for channel in session.channels() {
//!     println!("{} [{}] {} samples", channel.name(), channel.unit(), channel.samples().len());
//! }
//! if let Some(gps) = session.gps() {
//!     println!("{} GPS fixes", gps.len());
//! }
//! println!("{} laps, best {:?}", session.laps().len(), session.laps().best_lap_index());
//! # Ok::<(), racestudio_decode::DecodeError>(())
//! ```
//!
//! The layered decoders remain public for targeted use; `decode_session` is the
//! recommended surface.

// The decode path must never panic (issue 1.6): forbid the unwrap, expect, and
// panic clippy restriction lints on shipped library code. Test code (`--cfg
// test`) is exempt so the in-crate unit tests can assert with `expect`.
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod channels;
pub mod container;
pub mod error;
pub mod gps;
pub mod laps;
pub mod model;

pub use channels::{decode_channels, Channel, ChannelMeta};
pub use container::{open_container, Container, Metadata};
pub use error::DecodeError;
pub use gps::{decode_gps, GpsChannel, GpsChannelKind, GpsData, GpsFix};
pub use laps::{decode_laps, Lap, LapData};
pub use model::{decode_session, Session};
