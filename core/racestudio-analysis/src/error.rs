//! The single error type for the analysis engine (issues 3.1, 3.2, 3.4).

use std::fmt;

/// A recoverable analysis failure. Analysis never panics on caller input; every
/// failure funnels through this enum, mirroring the decode crate's
/// [`DecodeError`](racestudio_decode::DecodeError) convention.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AnalysisError {
    /// A requested channel is not present in a lap (by name).
    MissingChannel {
        /// The channel name that was requested.
        name: String,
    },
    /// A lap carries no samples for the requested channel, so no common axis can
    /// be formed for alignment.
    EmptyLap,
    /// A lap's distance axis is not monotonically non-decreasing, so time cannot
    /// be inverted as a function of distance (delta-t, issue 3.2).
    DistanceNotMonotonic,
    /// A statistics range contains no finite samples — an empty slice, a window
    /// `[t0, t1)` that selects nothing, or an all-`NaN` slice (statistics, 3.4).
    EmptyRange,
}

impl fmt::Display for AnalysisError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingChannel { name } => write!(f, "channel not found in lap: {name}"),
            Self::EmptyLap => write!(f, "lap has no samples to align"),
            Self::DistanceNotMonotonic => write!(f, "lap distance axis is not monotonic"),
            Self::EmptyRange => write!(f, "range has no finite samples for statistics"),
        }
    }
}

impl std::error::Error for AnalysisError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_display_missing_channel_names_the_channel() {
        let err = AnalysisError::MissingChannel {
            name: "RPM".to_string(),
        };
        assert_eq!(err.to_string(), "channel not found in lap: RPM");
    }

    #[test]
    fn test_display_empty_lap() {
        assert_eq!(
            AnalysisError::EmptyLap.to_string(),
            "lap has no samples to align"
        );
    }

    #[test]
    fn test_display_distance_not_monotonic() {
        assert_eq!(
            AnalysisError::DistanceNotMonotonic.to_string(),
            "lap distance axis is not monotonic"
        );
    }

    #[test]
    fn test_display_empty_range() {
        assert_eq!(
            AnalysisError::EmptyRange.to_string(),
            "range has no finite samples for statistics"
        );
    }
}
