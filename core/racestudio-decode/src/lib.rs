//! Clean-room decoder for AiM RaceStudio telemetry (`.xrk`) files.
//!
//! Decoding is validated against XRKConverter's `libxrk` output as the golden
//! oracle (see the decode-strategy ADR, `docs/adr/0002-xrk-decode-strategy.md`).
//! Milestone M1 builds it up in layers: the container + header metadata (1.2,
//! this module's [`open_container`]), then channels (1.3), GPS (1.4), laps (1.5).
//!
//! ```no_run
//! let container = racestudio_decode::open_container("session.xrk")?;
//! let meta = container.metadata();
//! println!("{} at {} ({} ch)", meta.driver, meta.track, container.channel_count());
//! # Ok::<(), racestudio_decode::DecodeError>(())
//! ```

pub mod container;
pub mod error;

pub use container::{open_container, Container, Metadata};
pub use error::DecodeError;
