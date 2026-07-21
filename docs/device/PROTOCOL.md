# MyChron5/6 WiFi download protocol — clean-room notes (issue 6.2)

**Status:** partial, observation-only. These notes describe *observed on-the-wire
behaviour* of the AiM iOS app ↔ MyChron6 (fw `02.46.16`) WiFi exchange, captured
per [`CAPTURE.md`](CAPTURE.md) and dissected against the committed, de-identified
fixtures in [`../../fixtures/device/`](../../fixtures/device). Every claim below
cites a specific fixture + byte offset so the notes are **executable**: the
assertions in `core/racestudio-device/tests/protocol_notes_test.rs` fail if a
documented field is wrong.

> **Clean-room / legal.** This is clean-room, **interoperability-only** reverse
> engineering (**DMCA §1201(f)**; **EU Software Directive 2009/24/EC Art. 6**),
> per [ADR 0006](../adr/0006-device-wifi-reverse-engineering.md) and the
> [legal gate](LEGAL_GATE.md). Only our own recorded observations of the
> on-the-wire bytes are kept — **never** AiM firmware, DLLs, or the app binary
> ([MUST NOT redistribute](LEGAL_GATE.md#must-not-redistribute)). Captured
> identifiers (device **serial** `35002652`, **SSID** `AiM-MYC6-002652`, owner
> name/email, **track names**) are stripped from every committed fixture; see
> [§8](#8-de-identification).

Notation: offsets are 0-based into the named artifact; integers are
**little-endian** unless stated. "payload" = an STCP frame's payload (see §3).

---

## 1. Transport

| Channel | Transport | Endpoint (observed) | Fixture |
| --- | --- | --- | --- |
| Discovery | **UDP 36002** | client → multicast `224.4.161.221:36002`; device (`10.0.0.1`) replies unicast | `discovery/*.bin` |
| Control + transfer | **TCP 2000** | device `10.0.0.1:2000` ↔ client | `control/*.bin`, `sessions/*.bin`, `transfer/*.bin` |

The MyChron6 is its own WiFi AP (`10.0.0.1`); the client (phone) is a DHCP client
(`10.0.0.2`). All control and bulk transfer run over a single TCP/2000 connection.

---

## 2. Discovery (UDP 36002)

**Probe** — the client multicasts the 6-byte ASCII string `aim-ka` to
`224.4.161.221:36002` (fixture `discovery/probe.bin`, verbatim).

**Response** — the device replies with a 236-byte struct
(`discovery/response.bin`, 236 B):

| Offset | Size | Field | Observed | Notes |
| --- | --- | --- | --- | --- |
| `0x00` | u32 | `length` | `236` | total response length (`0xEC`) |
| `0x04` | u32 | `type` | `2` | response/version tag |
| `0x08` | 4 | `device_ip` | `10.0.0.1` | device's own IPv4 |
| `0x0C` | u16 | *port?* | `0x0600` | **uncertain** — likely a service port/flags |
| `0x54` | — | `idn` block | `"idn"…` | device-identity block |
| `0x60` | u32 | **serial** | *(scrubbed)* | on-wire `1c 19 16 02` = `35002652`; **de-identified** in the fixture |

Parsed by `parse_discovery_response` (asserts `length=236`, `type=2`,
`device_ip=[10,0,0,1]`). Fields past `0x0C` other than the `idn`/serial block are
**not yet decoded**.

### Typed discovery (issue 6.3)

`parse_discovery(bytes) -> Result<Vec<Device>, DeviceError>` builds one typed
`Device { name, address, port, model }` per announcement (self-delimited by the
`length` prefix, so a repeated announcement de-duplicates to a single entry):

| `Device` field | Source | Notes |
| --- | --- | --- |
| `address` | response `device_ip` (`0x08`) | the decoded on-wire field (`10.0.0.1`) |
| `port` | `CONTROL_PORT` (`2000`) | the TCP port we connect to next; the response's own port field (`0x0C`) is **uncertain**, so it is not used |
| `model` | response `type` (`0x04`) | `type == 2` → the `MyChron` family; the specific MYC5/MYC6 + serial are in the SSID, **de-identified** out of the committed fixture (and, on the live path, come from the Bonjour service name) |
| `name` | derived | deterministic `"{model} @ {address}"`; the live mDNS path uses the Bonjour service instance name |

A malformed/truncated record (too short, a `length` that overruns the buffer, or
`type != 2`) returns `DeviceError::MalformedRecord` — never a panic. When no
responder is present, `ap_mode_fallback()` returns the well-known gateway
`Device` (`10.0.0.1:2000`). The live **mDNS/Bonjour** browser (Swift `NWBrowser`)
is injected behind the `DeviceBrowser` trait, so discovery is fixture-replayable
with no live device; the golden oracle is
[`../../fixtures/device/golden/discovery.json`](../../fixtures/device/golden/discovery.json).
**No networking client** lands here — enumeration/download/delete are 6.4–6.6.

> **Caveat — Bonjour service type is unverified.** The only discovery mechanism
> proven by the 6.2 capture is the UDP-36002 `aim-ka` exchange above; **no capture
> yet confirms the MyChron advertises an mDNS/Bonjour service**. The Swift
> `BonjourBrowser` browses `_aim-stcp._tcp` as a *placeholder* (issue 6.3 mandates
> the `NWBrowser` primary path), surfacing its terminal state via `os.Logger` and
> falling back to AP mode; the type must be confirmed against a live LAN capture
> (or the live path rewired to the verified UDP-36002 exchange). The
> fixture-tested `parse_discovery`/`ap_mode_fallback` path is the verified one.

---

## 3. STCP frame format (TCP 2000)

Every control/transfer message on TCP 2000 is a framed, checksummed record:

```
 header : "<hSTCP"  length(u32 LE)  flag(u8)  ">"      (12 bytes)
 payload: <length> bytes
 trailer: "<STCP"   checksum(u16 LE) ">"               (8 bytes)
```

- `flag` was `0` in every observed frame (**uncertain** meaning).
- The trailer is present on data-bearing frames; small ACK frames (§6) may omit it.
- Implemented by `parse_frame`; see fixtures `control/hello.bin` (8-B payload),
  `control/command_info.bin` (64-B), `sessions/list_response.bin` (4272-B),
  `transfer/chunk.bin` (65476-B).

### Checksum (the algorithm the issue asks to prove)

`checksum = (sum of all payload bytes) mod 65536`, stored **little-endian** in the
trailer. This is `racestudio_device::stcp_checksum`. It reproduces the observed
trailer on **1484/1484** client→device and **1422/1423** device→client frames in
the capture (the single miss is a naive-reassembly artifact on one retransmitted
TCP segment, not an algorithm error). `test_documented_checksum_reproduces_captured_value`
re-derives the checksum for every STCP-frame fixture and asserts it equals the
recorded trailer — four of them preserve the **verbatim observed** checksum.

Worked example (`control/hello.bin`): payload `00 00 00 00 06 09 00 00` →
`0x06 + 0x09 = 0x0f` → trailer `<STCP 0f 00 >` = `15`. ✓

---

## 4. Handshake

The connection opens with an 8-byte hello each way (`control/hello.bin` is the
device side, payload `00000000 06 09 0000`, checksum 15; the client side is
`… 06 08 …`, checksum 14). The `06 08`/`06 09` pair is **uncertain** (likely a
protocol/version id). The client then sends a time-sync frame (68-B payload
carrying the current date/time as consecutive **u32-LE** fields, e.g.
`ea 07 00 00`=2026 (year), `07`=month, `15`=21 (day)).

---

## 5. Commands & catalog/session-list

Client commands are 64-byte-payload STCP frames; the **command code** sits at
`payload[8..12]` (`control/command_info.bin` = `10 00 01 00`, "get catalog").
The device answers each command with 64-byte echo frames that carry a `c0 ff`
(`0xFFC0`) marker and, at `payload[16..20]`, the **byte length of the data frame
that follows** — e.g. `ac 10 00 00` = `0x10AC` = 4268 ≈ the 4272-byte catalog
frame. Observed command codes: `10 00 01 00`, `02 00 02 00`, `08 00 02 00`,
`03 00 02 00`, `02 00 04 00` (start-download). Their exact semantics beyond the
above are **uncertain**.

**Catalog / session-list response** (`sessions/list_response.bin`, 4272-B frame):
a container of records:

| Offset (payload) | Field | Notes |
| --- | --- | --- |
| `0x04` | `"<hiMST"` | nested record-container header |
| — | `"idn"` records | fixed-stride identity/config records (serial at record `+8`, **scrubbed**) |
| `0xD0`… | `"<iMST…><hiHW …>"` | hardware descriptor: `WiFi=ESP32\|Reg=eu\|LSM6DSV16X…` |

> **Caveat (honest):** at capture time the device held **0 recorded sessions**
> (all had been imported to the app), so this response enumerated the device's
> config/identity records rather than dated session entries. The **record framing**
> (nested `<hiMST>`/`<hiHW>`, `idn` stride) is what 6.4 needs; the per-session
> fields (date/size/name), visible in the app UI, are **not** in this fixture and
> must be re-captured with sessions present.

`test_session_list_offsets_parse_from_fixture` asserts the `<hiMST` header at
payload `0x04` and the presence of `idn` records.

### Typed session enumeration (issue 6.4)

`build_session_list_request()` reproduces the captured catalog request
(`control/command_info.bin`, command `0x0110`) **byte-for-byte** — a 64-byte
payload wrapped in a checksum-valid STCP frame (checksum 94). It is the request
6.5 writes to start enumeration.

`parse_session_list(bytes) -> Result<Vec<SessionInfo>, DeviceError>` verifies the
response frame's trailer checksum **before** parsing (a mismatch is
`DeviceError::BadChecksum`, with no partial list surfaced), then reads a leading
`u32` LE session **count** at `payload[0..4]`:

| `SessionInfo` field | Source (per record) | Notes |
| --- | --- | --- |
| *(count)* | response `payload[0..4]` (u32 LE) | number of session records; **0 in the sole capture** |
| `id` | `+4` (u32 LE) | device-local session id |
| `date` | `+8` (year u16, then month/day/hour/min/sec u8) | a **typed** `SessionDate`, reusing the observed device-time encoding (§4) |
| `lap_count` | `+16` (u16 LE) | recorded laps |
| `size_bytes` | `+18` (u32 LE) | on-device data size |
| `name` | `+24` (32 B, NUL-padded ASCII) | display name |

An empty store (count 0) is `Ok(vec![])`, never an error; a truncated frame or a
count that overruns the payload is `DeviceError::TruncatedList`; a record lacking
the session magic is `DeviceError::MalformedRecord`. The parser never panics.

> **Caveat — the per-session record layout is unverified.** The recorded
> `list_response.bin` was captured with **0 on-board sessions** (see the §5 caveat
> above), so it carries only `idn`/`<hiHW>`/`<iPRL>` identity/config records, and
> `parse_session_list` returns an **empty** list over it — the verified behaviour
> (`session_test.rs::test_session_list_matches_golden`, golden
> `fixtures/device/golden/sessions.json`). The dated-record layout in the table
> (id/date/laps/size/name offsets) is a **hypothesis**, exercised only against a
> synthetic frame in `session_test.rs`; it must be confirmed against a
> session-present capture (**issue #130**) before the download step (6.5) relies
> on it. The **verified** anchors are the byte-exact request and the
> checksum-gated framing.

---

## 6. Transfer (download)

After `start-download`, the device streams the session file as a sequence of STCP
frames with a **65476-byte payload** = `[offset(u32 LE)][65472 data bytes]`
(`transfer/chunk.bin`). The client ACKs each chunk with a 4-byte frame carrying
the **next** offset; offsets advance by the data stride `0xFFC0` (65472):
`0x00000000, 0x0000FFC0, 0x0001FF80, …` (a chunk resets to `0x0` at each new file
within the session bundle). The final chunk is short (observed `23850` B).

- `transfer_chunk_offset` / `transfer_chunk_data` expose the two fields;
  `test_transfer_framing_fields_are_documented` asserts the 65476-B frame length,
  the 65472-B data length, and that the offset is a multiple of `0xFFC0`.
- **Fields 6.5 (download) needs:** frame length, the 4-byte chunk offset, the
  65472 chunk stride, the ACK-with-next-offset flow-control, and the STCP checksum
  to validate each chunk.

### Typed chunked download (issue 6.5)

`racestudio_device::download_session(plan, transport, progress)` reassembles the
chunk stream into the original file. Each chunk frame's checksum is **verified
before use** (a corrupt chunk is retried up to `MAX_CHUNK_RETRIES`; unrecoverable
corruption is `DeviceError::ChecksumMismatch`); chunks are placed by their
declared offset, so out-of-order and duplicate deliveries reassemble correctly
and idempotently; a stream that ends before full coverage is
`DeviceError::MissingChunk`; and the reassembled whole file is checksum-gated
before it is surfaced — **no partial file is ever returned as success**. The byte
source is injected as a [`Transport`], so CI replays fixtures with no live device;
progress is reported via a [`ProgressSink`] for the 6.7 progress bar.

| Field | Source | Verified? |
| --- | --- | --- |
| Chunk frame + trailer checksum | `transfer/chunk.bin` (`checksum_observed`) | ✅ observed |
| Chunk offset `payload[0..4]` u32 LE = 65472 | `transfer/chunk.bin` | ✅ observed |
| Multi-chunk stream shape / end-of-stream | — | ⚠️ hypothesized |
| Whole-file checksum source | — (passed via `DownloadPlan`) | ⚠️ hypothesized |
| Retry / re-request handshake | — | ⚠️ hypothesized |

> **Caveat — the multi-chunk *stream* is unverified.** Only one real chunk was
> captured (the device held 0 on-board sessions), so the reassembly, whole-file
> checksum, and retry handshake are exercised only against synthetic multi-chunk
> streams **and a real M1 `.xrk` streamed as chunks** — the reassembled bytes must
> equal the file byte-for-byte and decode via `racestudio-decode` to the M1
> golden, proving the reassemble→decode pipeline end-to-end. The stream protocol
> itself must be confirmed against a session-present capture (**issue #133**)
> before it is trusted against a live device.

[`Transport`]: the byte-source seam (recorded replay in CI; live TCP in 6.7).
[`ProgressSink`]: the progress callback (bytes done / total).

---

## 7. Delete (NOT yet observed)

The delete operation (issue **6.6**) is **not** in these fixtures: the device held
0 on-board sessions at capture time, so no on-device delete could be issued (see
`manifest.json` → `pending`). Delete is expected to reuse the STCP framing (§3)
with a delete command opcode (§5); its exact opcode + payload must be captured
when a session is present on the device, at which point a `delete/*.bin` fixture
and this section will be completed.

---

## 8. De-identification

Committed fixtures are stripped of identifiers that are **not protocol-relevant**,
replaced by fixed same-length placeholders (offsets preserved) so the framing and
checksums still parse:

| Identifier | On the wire | In fixtures |
| --- | --- | --- |
| Device serial `35002652` | `1c 19 16 02` (u32 LE) / ASCII | zeroed / `00000000` |
| SSID `AiM-MYC6-002652` | ASCII | `AiM-MYC6-XXXXXX` |
| Owner name / email | ASCII | `XXXXXXX` / masked |
| Track names (`Kenting`, `S.MarinoK`, …) | ASCII in telemetry | `FIXTURE…` |

When a payload is scrubbed its STCP checksum is **recomputed** for the scrubbed
bytes (`manifest.json` marks `deidentified: true`, `checksum_observed: false`);
verbatim fixtures keep the **observed** checksum (`checksum_observed: true`).
`test_capture_is_deidentified` asserts none of the identifiers above remain in any
fixture. Raw `.pcap`/`.pcapng` are never committed (git-ignored).

---

## 9. Fields required by downstream issues

| Issue | Needs from this protocol |
| --- | --- |
| **6.3 discovery** | UDP 36002 probe `aim-ka` + 236-B response parsing (device IP) |
| **6.4 enumeration** | ✅ byte-exact request + checksum-gated framing → typed `SessionInfo`; **per-session date/size/name layout hypothesized, to be confirmed with a session-present capture (#130)** |
| **6.5 download** | ✅ checksum-gated chunk reassembly by offset → decodable `.xrk` (validated via M1 decode); **multi-chunk stream / whole-file-checksum source / retry handshake hypothesized, to be confirmed with a session-present capture (#133)** |
| **6.6 delete** | STCP command framing; **delete opcode still to be captured** (§7) |
| **6.7 UI** | device identity (name/serial/firmware) from discovery + catalog |
