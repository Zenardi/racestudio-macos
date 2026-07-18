//! 5.1 ⇄ 5.2 round-trip (issue 5.2): a Session written to an AiM CSV and read
//! back preserves channel names, units, sample counts, the 20 Hz timebase, and
//! (within the text precision) every sample value.

mod support;

use racestudio_io::{read_csv, write_aim_csv, ExportOptions};
use support::gps_session;

#[test]
fn test_roundtrip_preserves_channels_and_samples() {
    let original = gps_session();
    let mut buf = Vec::new();
    write_aim_csv(&original, &mut buf, &ExportOptions::default()).expect("write");
    let imported = read_csv(&buf[..]).expect("read");

    // Every written column is a channel: 11 GPS columns (incl. heading) + RPM.
    assert_eq!(imported.channels().len(), 12);

    let by = |name: &str| {
        imported
            .channels()
            .iter()
            .find(|c| c.name() == name)
            .unwrap_or_else(|| panic!("no channel {name:?}"))
    };

    // GPS Speed round-trips m/s → km/h (×3.6) → m/s (÷3.6) ≈ 10.0.
    let speed = by("GPS Speed");
    assert_eq!(speed.unit(), "m/s");
    for &(_, v) in speed.samples() {
        assert!((v - 10.0).abs() < 1e-6, "GPS Speed {v} != 10 m/s");
    }

    // RPM is an i32 channel → sample-held by the writer: at 20 Hz over samples
    // spaced 100 ms, each pair of grid rows holds the earlier value
    // (3000, 3000, 3100, 3100, …, 3500). Those written values survive the text
    // round-trip exactly (0 decimals).
    let rpm = by("RPM");
    assert_eq!(rpm.samples().len(), 11, "grid 0..=500 ms at 20 Hz");
    for (i, &(t, v)) in rpm.samples().iter().enumerate() {
        assert_eq!(t, i as f64 * 50.0, "uniform 50 ms timebase");
        let expected = 3000.0 + (i / 2) as f64 * 100.0;
        assert!(
            (v - expected).abs() < 1e-6,
            "RPM[{i}] = {v}, expected {expected}"
        );
    }

    // Laps reconstructed from the Beacon Markers (60 s, 150 s).
    assert_eq!(imported.laps().len(), 2);
    assert!((imported.laps().laps()[1].end_time_s() - 150.0).abs() < 1e-9);
}
