//! Clean-room decoder for AiM RaceStudio telemetry (`.xrk`) files.
//!
//! Decoding is validated against XRKConverter's `libxrk` output as the golden
//! oracle (see the decode-strategy ADR, `docs/adr/0002-xrk-decode-strategy.md`).
//! Milestone M1 builds it up in layers: the container + header metadata (1.2,
//! this module's [`open_container`]), then channels (1.3, [`decode_channels`]),
//! GPS (1.4, [`decode_gps`]), laps (1.5).
//!
//! ```no_run
//! let container = racestudio_decode::open_container("session.xrk")?;
//! let meta = container.metadata();
//! println!("{} at {} ({} ch)", meta.driver, meta.track, container.channel_count());
//! for channel in racestudio_decode::decode_channels(&container)? {
//!     println!("{} [{}] {} samples", channel.name(), channel.unit(), channel.samples().len());
//! }
//! if let Some(gps) = racestudio_decode::decode_gps(&container)? {
//!     println!("{} GPS fixes", gps.len());
//! }
//! # Ok::<(), racestudio_decode::DecodeError>(())
//! ```

pub mod channels;
pub mod container;
pub mod error;
pub mod gps;

pub use channels::{decode_channels, Channel, ChannelMeta};
pub use container::{open_container, Container, Metadata};
pub use error::DecodeError;
pub use gps::{decode_gps, GpsChannel, GpsChannelKind, GpsData, GpsFix};
