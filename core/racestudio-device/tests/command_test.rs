//! Issue #179 — the live client's command frames reproduce the captured ones
//! byte for byte (`fixtures/device/client/`, `control/`, `transfer/`), and the
//! device's echoes parse into the documented fields.

use std::path::PathBuf;

use racestudio_device::command::{
    build_ack, build_catalog_request, build_clock_upload, build_close, build_hello,
    build_read_file, build_read_request, build_session_open, is_device_hello, opcode, parse_echo,
    tag, MAX_PATH_LEN,
};
use racestudio_device::{build_session_list_request, parse_frame, DeviceError, SessionDate};

fn fixture(rel: &str) -> Vec<u8> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/device")
        .join(rel);
    std::fs::read(&path).unwrap_or_else(|e| panic!("fixture {rel}: {e}"))
}

fn payload(rel: &str) -> Vec<u8> {
    parse_frame(&fixture(rel))
        .expect("fixture frame")
        .0
        .payload
        .to_vec()
}

#[test]
fn test_hello_matches_captured_client_hello() {
    assert_eq!(build_hello(), fixture("client/hello_request.bin"));
}

#[test]
fn test_device_hello_is_recognised() {
    assert!(is_device_hello(&payload("control/hello.bin")));
}

#[test]
fn test_client_hello_is_not_mistaken_for_the_device_hello() {
    assert!(!is_device_hello(&payload("client/hello_request.bin")));
}

#[test]
fn test_short_payload_is_not_a_device_hello() {
    assert!(!is_device_hello(&[0, 0, 0, 0, 0x06]));
}

#[test]
fn test_session_open_matches_captured_command() {
    assert_eq!(build_session_open(), fixture("control/command_info.bin"));
}

#[test]
fn test_session_list_request_is_the_session_open_command() {
    assert_eq!(build_session_list_request(), build_session_open());
}

#[test]
fn test_clock_upload_matches_captured_upload() {
    let local = SessionDate {
        year: 2026,
        month: 7,
        day: 21,
        hour: 14,
        minute: 16,
        second: 0,
    };
    let utc = SessionDate { hour: 11, ..local };

    assert_eq!(
        build_clock_upload(&local, &utc),
        fixture("client/clock_upload.bin")
    );
}

#[test]
fn test_info_requests_match_captured_commands_in_order() {
    let built: Vec<Vec<u8>> = opcode::INFO
        .iter()
        .map(|&c| build_read_request(c))
        .collect();

    assert_eq!(
        built,
        vec![
            fixture("client/info_0202_request.bin"),
            fixture("client/info_0208_request.bin"),
            fixture("client/info_0203_request.bin"),
        ]
    );
}

#[test]
fn test_catalog_request_matches_captured_command() {
    assert_eq!(
        build_catalog_request(),
        fixture("client/catalog_request.bin")
    );
}

#[test]
fn test_read_file_matches_captured_request() {
    let built = build_read_file("1:/mem/a_0053.xrz").expect("valid path");

    assert_eq!(built, fixture("transfer/open_request.bin"));
}

#[test]
fn test_ack_matches_captured_ack() {
    assert_eq!(build_ack(65472), fixture("transfer/ack.bin"));
}

#[test]
fn test_close_matches_captured_close() {
    assert_eq!(build_close(), fixture("client/close_request.bin"));
}

#[test]
fn test_read_file_rejects_empty_path() {
    assert_eq!(build_read_file(""), Err(DeviceError::InvalidPath));
}

#[test]
fn test_read_file_rejects_path_longer_than_the_field() {
    let long = "x".repeat(MAX_PATH_LEN + 1);

    assert_eq!(build_read_file(&long), Err(DeviceError::InvalidPath));
}

#[test]
fn test_read_file_accepts_path_that_fills_the_field() {
    let longest = "x".repeat(MAX_PATH_LEN);

    assert!(build_read_file(&longest).is_ok());
}

#[test]
fn test_read_file_rejects_nul_byte() {
    assert_eq!(
        build_read_file("1:/mem/a\0b.xrz"),
        Err(DeviceError::InvalidPath)
    );
}

#[test]
fn test_read_file_rejects_non_ascii() {
    assert_eq!(
        build_read_file("1:/mem/á.xrz"),
        Err(DeviceError::InvalidPath)
    );
}

#[test]
fn test_session_open_echo_asks_for_the_upload() {
    let echo = parse_echo(&payload("client/open_echo.bin")).expect("echo");

    assert_eq!(
        (echo.code, echo.tag, echo.stride),
        (opcode::SESSION_OPEN, tag::REQUEST, 0xFFC0)
    );
}

#[test]
fn test_session_open_header_declares_the_identity_length() {
    let echo = parse_echo(&payload("client/open_header.bin")).expect("echo");

    assert_eq!((echo.tag, echo.length), (tag::RESPONSE_HEADER, 4268));
}

#[test]
fn test_catalog_echo_is_accepted() {
    let echo = parse_echo(&payload("client/catalog_echo.bin")).expect("echo");

    assert_eq!((echo.code, echo.tag), (opcode::CATALOG, tag::ACCEPTED));
}

#[test]
fn test_catalog_header_declares_the_csv_length() {
    let csv_len = payload("client/catalog_response.bin").len() - 4;

    let echo = parse_echo(&payload("client/catalog_header.bin")).expect("echo");

    assert_eq!(
        (echo.tag, echo.length as usize),
        (tag::RESPONSE_HEADER, csv_len)
    );
}

#[test]
fn test_read_file_header_declares_the_file_length() {
    let echo = parse_echo(&payload("transfer/length_response.bin")).expect("echo");

    assert_eq!(
        (echo.code, echo.tag, echo.length),
        (opcode::READ_FILE, tag::RESPONSE_HEADER, 210_158)
    );
}

#[test]
fn test_echo_of_wrong_size_is_unexpected() {
    assert_eq!(parse_echo(&[0u8; 4]), Err(DeviceError::UnexpectedResponse));
}
