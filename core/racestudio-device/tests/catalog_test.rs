//! Issue #179 — the device's download-summary CSV parses into typed sessions:
//! the de-identified capture matches its golden, and malformed input degrades
//! row by row instead of failing the whole catalog.

use std::path::PathBuf;

use serde::Deserialize;

use racestudio_device::catalog::{is_valid_file_name, RECORDED_DIR};
use racestudio_device::{parse_catalog, parse_frame, session_path, DeviceError, SessionDate};

const HEADER: &str = "name,size,date,hour,nlap,nbest,best,pilota,track_name,veicolo,campionato,venue_type,mode,trk_type,motivolap,maxvel,device,track_lat,track_lon,test_dur,pname,ptype,ptime,pdist,pmaxv,valid,";
const ROW: &str = "a_0001.xrz,1000,02/03/2025,04:05:06,7,3,61234,Driver,Track,Kart,Cup,,speed,closed,stop,0,,-227767969,-471201413,90000,,,,,,,";

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/device")
}

fn csv(lines: &[&str]) -> Vec<u8> {
    lines
        .iter()
        .map(|l| format!("{l}\r\n"))
        .collect::<String>()
        .into_bytes()
}

#[derive(Deserialize)]
struct Golden {
    skipped_rows: usize,
    sessions: Vec<GoldenSession>,
}

#[derive(Deserialize)]
struct GoldenSession {
    file_name: String,
    size_bytes: u32,
    date: GoldenDate,
    lap_count: u16,
    best_lap_number: Option<u16>,
    best_lap_ms: Option<u32>,
    driver: String,
    track_name: String,
    vehicle: String,
    championship: String,
    duration_ms: Option<u32>,
    track_latitude: f64,
    track_longitude: f64,
}

#[derive(Deserialize)]
struct GoldenDate {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
}

#[test]
fn test_captured_catalog_matches_golden() {
    let raw = std::fs::read(fixtures().join("client/catalog_response.bin")).expect("fixture");
    let csv = &parse_frame(&raw).expect("frame").0.payload[4..];
    let golden: Golden = serde_json::from_slice(
        &std::fs::read(fixtures().join("golden/catalog.json")).expect("golden"),
    )
    .expect("golden parses");

    let catalog = parse_catalog(csv).expect("catalog parses");

    assert_eq!(catalog.skipped_rows, golden.skipped_rows);
    assert_eq!(catalog.sessions.len(), golden.sessions.len());
    for (got, want) in catalog.sessions.iter().zip(&golden.sessions) {
        let d = &want.date;
        assert_eq!(got.file_name, want.file_name);
        assert_eq!(got.size_bytes, want.size_bytes);
        assert_eq!(
            got.date,
            SessionDate {
                year: d.year,
                month: d.month,
                day: d.day,
                hour: d.hour,
                minute: d.minute,
                second: d.second
            }
        );
        assert_eq!(got.lap_count, want.lap_count);
        assert_eq!(got.best_lap_number, want.best_lap_number);
        assert_eq!(got.best_lap_ms, want.best_lap_ms);
        assert_eq!(got.driver, want.driver);
        assert_eq!(got.track_name, want.track_name);
        assert_eq!(got.vehicle, want.vehicle);
        assert_eq!(got.championship, want.championship);
        assert_eq!(got.duration_ms, want.duration_ms);
        assert_eq!(got.track_latitude, Some(want.track_latitude));
        assert_eq!(got.track_longitude, Some(want.track_longitude));
    }
}

#[test]
fn test_row_fields_are_decoded() {
    let catalog = parse_catalog(&csv(&[HEADER, ROW])).expect("parses");

    let entry = &catalog.sessions[0];
    assert_eq!(entry.file_name, "a_0001.xrz");
    assert_eq!(
        entry.date,
        SessionDate {
            year: 2025,
            month: 3,
            day: 2,
            hour: 4,
            minute: 5,
            second: 6
        }
    );
    assert_eq!(
        (entry.lap_count, entry.best_lap_number, entry.best_lap_ms),
        (7, Some(3), Some(61234))
    );
    assert_eq!(
        (
            entry.driver.as_str(),
            entry.track_name.as_str(),
            entry.vehicle.as_str(),
            entry.championship.as_str()
        ),
        ("Driver", "Track", "Kart", "Cup")
    );
    assert_eq!(entry.track_latitude, Some(-22.776_796_9));
    assert_eq!(entry.duration_ms, Some(90000));
}

#[test]
fn test_empty_input_is_an_empty_catalog() {
    let catalog = parse_catalog(b"").expect("parses");

    assert!(catalog.sessions.is_empty());
    assert_eq!(catalog.skipped_rows, 0);
}

#[test]
fn test_header_only_is_an_empty_catalog() {
    let catalog = parse_catalog(&csv(&[HEADER])).expect("parses");

    assert!(catalog.sessions.is_empty());
}

#[test]
fn test_missing_required_column_is_malformed() {
    let header = HEADER.replace("hour,", "clock,");

    assert_eq!(
        parse_catalog(&csv(&[&header, ROW])),
        Err(DeviceError::MalformedRecord)
    );
}

#[test]
fn test_reordered_columns_are_read_by_name() {
    let catalog = parse_catalog(&csv(&[
        "size,hour,name,date,",
        "500,10:00:00,b_1.xrz,01/01/2026,",
    ]))
    .expect("parses");

    let entry = &catalog.sessions[0];
    assert_eq!(
        (entry.file_name.as_str(), entry.size_bytes),
        ("b_1.xrz", 500)
    );
    assert_eq!(entry.lap_count, 0);
    assert_eq!(entry.track_latitude, None);
}

#[test]
fn test_row_with_wrong_column_count_is_skipped() {
    let short = "a_0002.xrz,1000,02/03/2025";

    let catalog = parse_catalog(&csv(&[HEADER, short, ROW])).expect("parses");

    assert_eq!((catalog.sessions.len(), catalog.skipped_rows), (1, 1));
}

#[test]
fn test_row_with_unreadable_size_is_skipped() {
    let bad = ROW.replacen(",1000,", ",big,", 1);

    let catalog = parse_catalog(&csv(&[HEADER, &bad])).expect("parses");

    assert_eq!((catalog.sessions.len(), catalog.skipped_rows), (0, 1));
}

#[test]
fn test_row_with_impossible_date_is_skipped() {
    let bad = ROW.replacen("02/03/2025", "32/13/2025", 1);

    let catalog = parse_catalog(&csv(&[HEADER, &bad])).expect("parses");

    assert_eq!(catalog.skipped_rows, 1);
}

#[test]
fn test_row_with_impossible_time_is_skipped() {
    let bad = ROW.replacen("04:05:06", "24:00:00", 1);

    let catalog = parse_catalog(&csv(&[HEADER, &bad])).expect("parses");

    assert_eq!(catalog.skipped_rows, 1);
}

#[test]
fn test_row_with_extra_time_component_is_skipped() {
    let bad = ROW.replacen("04:05:06", "04:05:06:07", 1);

    let catalog = parse_catalog(&csv(&[HEADER, &bad])).expect("parses");

    assert_eq!(catalog.skipped_rows, 1);
}

#[test]
fn test_row_naming_a_path_outside_the_session_store_is_skipped() {
    let bad = ROW.replacen("a_0001.xrz", "../sys/x.xrz", 1);

    let catalog = parse_catalog(&csv(&[HEADER, &bad])).expect("parses");

    assert_eq!(catalog.skipped_rows, 1);
}

#[test]
fn test_unreadable_optional_fields_become_none() {
    let odd = ROW.replacen(",7,3,61234,", ",x,y,z,", 1);

    let entry = &parse_catalog(&csv(&[HEADER, &odd]))
        .expect("parses")
        .sessions[0];

    assert_eq!(
        (entry.lap_count, entry.best_lap_number, entry.best_lap_ms),
        (0, None, None)
    );
}

#[test]
fn test_out_of_range_coordinate_is_none() {
    let odd = ROW.replacen("-227767969", "-950000000", 1);

    let entry = &parse_catalog(&csv(&[HEADER, &odd]))
        .expect("parses")
        .sessions[0];

    assert_eq!(entry.track_latitude, None);
}

#[test]
fn test_invalid_utf8_is_read_lossily() {
    let (before, after) = ROW.split_once("Track").expect("ROW names a track");
    let invalid = [
        &csv(&[HEADER])[..],
        before.as_bytes(),
        b"Tr\xFFck",
        after.as_bytes(),
    ]
    .concat();

    let entry = &parse_catalog(&invalid).expect("parses").sessions[0];

    assert_eq!(entry.track_name, "Tr\u{FFFD}ck");
}

#[test]
fn test_session_path_is_inside_the_recorded_store() {
    assert_eq!(
        session_path("a_0053.xrz"),
        Ok(format!("{RECORDED_DIR}a_0053.xrz"))
    );
}

#[test]
fn test_session_path_rejects_traversal() {
    assert_eq!(session_path("../a.xrz"), Err(DeviceError::InvalidPath));
}

#[test]
fn test_file_name_needs_a_session_extension() {
    assert!(!is_valid_file_name("a_0053.txt"));
}

#[test]
fn test_file_name_needs_a_stem() {
    assert!(!is_valid_file_name(".xrz"));
}

#[test]
fn test_file_name_accepts_upper_case_xrk() {
    assert!(is_valid_file_name("A-1.XRK"));
}

#[test]
fn test_file_name_too_long_for_the_command_is_rejected() {
    let long = format!("{}.xrz", "a".repeat(30));

    assert!(!is_valid_file_name(&long));
}
