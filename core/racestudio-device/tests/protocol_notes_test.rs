//! Executable protocol notes for issue 6.2 — the documented MyChron WiFi protocol
//! is asserted against the committed, de-identified fixtures in `fixtures/device/`
//! (carved from a real AiM-app <-> MyChron6 capture; see `docs/device/PROTOCOL.md`).
//!
//! These are the named behaviours from the issue. They make the notes *executable*:
//! if the documented framing/checksum/offsets are wrong, a test fails.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};

use racestudio_device as dev;

// ---- fixture access --------------------------------------------------------

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/device")
}

fn read(rel: &str) -> Vec<u8> {
    std::fs::read(fixtures_dir().join(rel))
        .unwrap_or_else(|e| panic!("fixture {rel} must exist: {e}"))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

#[derive(Deserialize)]
struct Manifest {
    checksum: ChecksumDoc,
    fixtures: Vec<Fixture>,
    pending: Vec<Pending>,
}

#[derive(Deserialize)]
struct ChecksumDoc {
    name: String,
}

#[derive(Deserialize)]
struct Fixture {
    file: String,
    phase: String,
    kind: String,
    bytes: usize,
    sha256: String,
    #[serde(default)]
    deidentified: bool,
    #[serde(default)]
    checksum: Option<u16>,
    #[serde(default)]
    checksum_observed: bool,
    #[serde(default)]
    chunk_data_len: Option<usize>,
    #[serde(default)]
    record_magic: Option<String>,
}

#[derive(Deserialize)]
struct Pending {
    phase: String,
    reason: String,
}

fn manifest() -> Manifest {
    serde_json::from_slice(&read("manifest.json")).expect("manifest.json parses")
}

// ---- the named behaviours --------------------------------------------------

/// Given the checksum bytes in a captured frame, when the documented algorithm is
/// applied, then it reproduces the observed checksum — proving the notes correct.
#[test]
fn test_documented_checksum_reproduces_captured_value() {
    let m = manifest();
    assert_eq!(m.checksum.name, "stcp_u16_le_sum");
    let mut checked = 0;
    for fx in m.fixtures.iter().filter(|f| f.kind == "stcp_frame") {
        let bytes = read(&fx.file);
        let (frame, consumed) = dev::parse_frame(&bytes).expect("frame parses");
        assert_eq!(
            consumed,
            bytes.len(),
            "frame spans whole fixture {}",
            fx.file
        );
        let recorded = frame.checksum.expect("frame carries a trailer checksum");
        // the documented algorithm, applied fresh, reproduces the recorded checksum
        assert_eq!(
            dev::stcp_checksum(frame.payload),
            recorded,
            "documented checksum must reproduce the wire value in {}",
            fx.file
        );
        assert!(frame.checksum_valid());
        assert_eq!(
            Some(recorded),
            fx.checksum,
            "manifest checksum matches {}",
            fx.file
        );
        checked += 1;
    }
    assert!(checked >= 3, "expected the 3+ STCP-frame fixtures");
    // at least one fixture preserves the *observed* on-the-wire checksum verbatim
    assert!(
        m.fixtures.iter().any(|f| f.checksum_observed),
        "at least one verbatim, observed-checksum fixture must exist"
    );
}

/// The manifest describes exactly the recorded fixture files (size + sha256), with
/// no undocumented fixture and no missing one.
#[test]
fn test_fixture_manifest_matches_recorded_files() {
    let m = manifest();
    let mut documented = BTreeSet::new();
    for fx in &m.fixtures {
        let bytes = read(&fx.file);
        assert_eq!(
            bytes.len(),
            fx.bytes,
            "size matches manifest for {}",
            fx.file
        );
        assert_eq!(
            sha256_hex(&bytes),
            fx.sha256,
            "sha256 matches manifest for {}",
            fx.file
        );
        documented.insert(fx.file.clone());
    }
    // every *.bin on disk is documented (no stray/undocumented fixture)
    let mut on_disk = BTreeSet::new();
    collect_bins(&fixtures_dir(), &fixtures_dir(), &mut on_disk);
    assert_eq!(
        on_disk, documented,
        "manifest lists exactly the .bin files on disk"
    );
    // delete is honestly recorded as pending (device had 0 on-board sessions)
    assert!(m
        .pending
        .iter()
        .any(|p| p.phase == "delete" && !p.reason.is_empty()));
}

/// The session-list/catalog response parses into records at the documented offsets.
#[test]
fn test_session_list_offsets_parse_from_fixture() {
    let m = manifest();
    let fx = m
        .fixtures
        .iter()
        .find(|f| f.phase == "session-list")
        .expect("a session-list fixture exists");
    let bytes = read(&fx.file);
    let (frame, _) = dev::parse_frame(&bytes).expect("frame parses");
    assert_eq!(frame.length, 4272);
    // nested record container header at the documented payload offset 4
    assert_eq!(
        &frame.payload[4..10],
        b"<hiMST",
        "nested <hiMST header at offset 4"
    );
    // the record magic documented in the manifest is present in the payload
    let magic = fx.record_magic.as_deref().unwrap_or("idn");
    assert!(
        frame
            .payload
            .windows(magic.len())
            .any(|w| w == magic.as_bytes()),
        "record magic {magic:?} appears in the catalog payload"
    );
    assert!(frame.checksum_valid());
}

/// The transfer chunk framing fields (offset + fixed chunk size) are as documented.
#[test]
fn test_transfer_framing_fields_are_documented() {
    let m = manifest();
    let fx = m
        .fixtures
        .iter()
        .find(|f| f.phase == "transfer")
        .expect("a transfer fixture exists");
    let bytes = read(&fx.file);
    let (frame, _) = dev::parse_frame(&bytes).expect("frame parses");
    assert_eq!(frame.length, 65476, "documented STCP frame length");
    let offset = dev::transfer_chunk_offset(frame.payload).expect("chunk carries an offset");
    let data = dev::transfer_chunk_data(frame.payload).expect("chunk carries data");
    assert_eq!(data.len(), 65472, "documented chunk data length (0xFFC0)");
    assert_eq!(
        Some(data.len()),
        fx.chunk_data_len,
        "manifest documents the chunk data length"
    );
    // the observed offset is a multiple of the chunk stride 0xFFC0
    assert_eq!(
        offset % 0xFFC0,
        0,
        "chunk offset is a multiple of the data stride"
    );
    assert!(frame.checksum_valid());
}

/// Legal gate: only our own recorded bytes are kept — no AiM firmware/DLL/app binary.
#[test]
fn test_fixtures_contain_no_firmware_or_binaries() {
    let mut files = BTreeSet::new();
    collect_all(&fixtures_dir(), &mut files);
    assert!(!files.is_empty(), "fixtures exist");
    for f in &files {
        let name = f.to_string_lossy().to_lowercase();
        assert!(
            !(name.ends_with(".fw") || name.ends_with(".dll") || name.ends_with(".ipa")),
            "forbidden AiM artifact present: {name}"
        );
        assert!(
            name.ends_with(".bin") || name.ends_with(".json"),
            "only .bin fixtures + manifest.json are kept, found {name}"
        );
        // reject executable container magics (PE/ELF/Mach-O) — we keep protocol bytes only
        let head = std::fs::read(f).unwrap();
        let magic4 = head.get(0..4).unwrap_or(&[]);
        for bad in [
            &b"MZ"[..],
            &b"\x7fELF"[..],
            &b"\xfe\xed\xfa\xce"[..],
            &b"\xce\xfa\xed\xfe"[..],
            &b"\xca\xfe\xba\xbe"[..],
        ] {
            assert!(
                !magic4.starts_with(bad),
                "fixture {name} looks like an executable image"
            );
        }
    }
}

/// The captures are stripped of MAC/SSID/serial and other identifiers.
#[test]
fn test_capture_is_deidentified() {
    // identifiers that appeared on the wire and MUST NOT remain in any fixture
    let serial_le: &[u8] = &[0x1c, 0x19, 0x16, 0x02]; // device serial 35002652, u32 LE
    let forbidden: &[&[u8]] = &[
        serial_le,
        b"35002652",
        b"002652",
        b"Zenardi",
        b"Kenting",
        b"MarinoK",
    ];
    let mut bins = BTreeSet::new();
    collect_bins(&fixtures_dir(), &fixtures_dir(), &mut bins);
    assert!(!bins.is_empty());
    for rel in &bins {
        let bytes = read(rel);
        for pat in forbidden {
            assert!(
                !bytes.windows(pat.len()).any(|w| w == *pat),
                "identifier {:?} leaked into fixture {rel}",
                String::from_utf8_lossy(pat)
            );
        }
    }
    // and the de-identified fixtures are flagged as such in the manifest
    assert!(manifest().fixtures.iter().any(|f| f.deidentified));
}

/// Discovery probe/response parse as documented (covers the discovery helpers).
#[test]
fn test_discovery_probe_and_response_parse() {
    assert_eq!(dev::DISCOVERY_PROBE, b"aim-ka");
    assert_eq!(dev::DISCOVERY_PORT, 36002);
    assert_eq!(dev::CONTROL_PORT, 2000);
    assert_eq!(read("discovery/probe.bin"), dev::DISCOVERY_PROBE);

    let resp = read("discovery/response.bin");
    let parsed = dev::parse_discovery_response(&resp).expect("discovery response parses");
    assert_eq!(parsed.length, 236);
    assert_eq!(parsed.kind, 2);
    assert_eq!(parsed.device_ip, [10, 0, 0, 1]);

    // negative paths (cover the None branches)
    assert!(dev::parse_discovery_response(b"short").is_none());
    assert!(dev::parse_frame(b"not-a-frame").is_none());
    assert!(dev::transfer_chunk_offset(b"\x00\x00").is_none());
    assert!(dev::transfer_chunk_data(b"\x00\x00").is_none());
    assert!(!dev::Frame {
        length: 0,
        flag: 0,
        payload: &[1],
        checksum: Some(999)
    }
    .checksum_valid());
}

/// parse_frame rejects malformed headers and tolerates a missing/short trailer
/// (covers the error + no-trailer branches of the parser).
#[test]
fn test_parse_frame_edge_cases() {
    // header magic present but the header is not closed by '>' -> rejected
    assert!(dev::parse_frame(b"<hSTCP\x00\x00\x00\x00\x00X").is_none());
    // declared length exceeds the available bytes -> rejected
    assert!(dev::parse_frame(b"<hSTCP\x05\x00\x00\x00\x00>ab").is_none());
    // a valid frame with NO trailer: parses, checksum is absent
    let (f, consumed) = dev::parse_frame(b"<hSTCP\x02\x00\x00\x00\x00>hi").expect("parses");
    assert_eq!(f.length, 2);
    assert_eq!(f.payload, b"hi");
    assert_eq!(f.checksum, None);
    assert_eq!(consumed, 14);
    assert!(!f.checksum_valid());
    // trailer magic present but not closed by '>': treated as no trailer
    let (f2, _) = dev::parse_frame(b"<hSTCP\x02\x00\x00\x00\x00>hi<STCP\x00\x00X").expect("parses");
    assert_eq!(f2.checksum, None);
    // a hand-built valid frame round-trips through the documented checksum + trailer
    let ck = dev::stcp_checksum(b"hi");
    let mut buf = b"<hSTCP\x02\x00\x00\x00\x00>hi<STCP".to_vec();
    buf.extend_from_slice(&ck.to_le_bytes());
    buf.push(b'>');
    let (f3, c3) = dev::parse_frame(&buf).expect("parses");
    assert_eq!(f3.checksum, Some(ck));
    assert!(f3.checksum_valid());
    assert_eq!(c3, buf.len());
}

// ---- small fs helpers ------------------------------------------------------

fn collect_all(dir: &Path, out: &mut BTreeSet<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let p = entry.unwrap().path();
        if p.is_dir() {
            collect_all(&p, out);
        } else {
            out.insert(p);
        }
    }
}

fn collect_bins(root: &Path, dir: &Path, out: &mut BTreeSet<String>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let p = entry.unwrap().path();
        if p.is_dir() {
            collect_bins(root, &p, out);
        } else if p.extension().is_some_and(|e| e == "bin") {
            out.insert(
                p.strip_prefix(root)
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/"),
            );
        }
    }
}
