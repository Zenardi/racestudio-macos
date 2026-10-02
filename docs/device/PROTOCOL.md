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
The live client that uses these devices is §10 (issue #179).

> **Caveat — Bonjour service type is unverified.** The only discovery mechanism
> proven by the 6.2 capture is the UDP-36002 `aim-ka` exchange above; **no capture
> yet confirms the MyChron advertises an mDNS/Bonjour service**. The Swift
> `BonjourBrowser` browses `_aim-stcp._tcp` as a *placeholder* (issue 6.3 mandates
> the `NWBrowser` primary path), surfacing its terminal state via `os.Logger` and
> falling back to AP mode; the type must be confirmed against a live LAN capture
> (or the live path rewired to the verified UDP-36002 exchange). The
> fixture-tested `parse_discovery`/`ap_mode_fallback` path is the verified one.

### Live discovery (issue #179)

The Bonjour browser is gone. The app now runs the **verified** exchange:
`racestudio_device::discover_live` (FFI `discover_devices`) sends `aim-ka` to the
multicast group **and** straight to `10.0.0.1:36002`, collects replies for 1.5 s,
parses each with `parse_discovery`, and falls back to `ap_mode_fallback()` when
nothing answers, so the list is never empty.

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
`client/hello_request.bin`, `… 06 08 …`, checksum 14). The `06 08`/`06 09` pair is
**uncertain** (likely a protocol/version id).

The client then runs **session-open**, opcode `0x0110` (`control/command_info.bin`):
its payload announces a 64-byte upload at `payload[16..20]`, the device echoes it
with tag `0x0a01` ("send it", `client/open_echo.bin`), and the client uploads its
clock (`client/clock_upload.bin`): a zero offset, then 8 zero bytes, the **local**
year/month/day/hour/minute/second as u32 LE, 8 zero bytes, and the same instant in
**UTC**. The device acks the upload with a bare u32 (`client/upload_ack.bin`), then
answers like any read (§6) with its identity and path table — the 4268-byte reply
in `sessions/list_response.bin` (`client/open_header.bin` declares the length).

The AiM app follows with three info reads, opcodes `0x0202`, `0x0208`, `0x0203`
(`client/info_*_request.bin`); the live client sends them too and discards the
replies, so its conversation matches the recorded one. The app ends a conversation
with opcode `0x0001`, tag `0x0a00` (`client/close_request.bin`), which gets no
reply.

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

### The catalog is a CSV (issue #179)

The #133 capture answered what the caveat above could not. `0x0110` is the
**session-open** command (§4), and its reply is the device's identity and **path
table** (`dwnsm=1:/mem/dwnsm,…|`, `recorded=1:/mem,…|`). The session catalog is a
separate read, opcode **`0x0224`** (`client/catalog_request.bin`), answered like any
read (§6) with the download-summary **CSV** stored on the device as `1:/mem/dwnsm`
(`client/catalog_response.bin`, de-identified, cut to six rows):

```
name,size,date,hour,nlap,nbest,best,pilota,track_name,veicolo,campionato,venue_type,mode,trk_type,motivolap,maxvel,device,track_lat,track_lon,test_dur,pname,ptype,ptime,pdist,pmaxv,valid,
a_0061.xrz,3866208,11/07/2025,17:45:28,23,2,53951,,FIXTURE TRACK B,,,,speed,closed,stop,1079269785,,123456789,-123456789,1294498,,,,,,,
```

Rows are `\r\n`-separated and end in a comma. `size` is the **stored
(compressed) size** — exactly the length the file's read declares (§6); `date` is
`dd/mm/yyyy`, `hour` `hh:mm:ss` (device-local); `best` is the best lap in ms and
`nbest` its lap number; `test_dur` is the session length in ms; `track_lat` /
`track_lon` are degrees × 10⁷; `pilota`/`veicolo`/`campionato` are the driver,
vehicle and championship set on the logger. `maxvel` looks like an f32 bit pattern
and is not decoded.

`racestudio_device::parse_catalog` reads it into `SessionEntry` values (golden:
`golden/catalog.json`). Columns are found **by name**; a row with the wrong column
count or an unreadable required field (name, size, date, time) is skipped and
counted, never fatal; a file name outside `[A-Za-z0-9_-]` + `.xrz`/`.xrk` is
rejected, so a hostile catalog cannot steer a read outside `1:/mem/`.

### Typed session enumeration (issue 6.4)

> **Superseded by the CSV catalog above (issue #179).** Kept for the guarded
> delete's `SessionInfo`; the binary record layout below was never observed.

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

**Fully observed** (issue #133): the 6.2 transfer capture turned out to contain a
bulk download of the device's whole recorded store — **44 file downloads**, 21 of
them byte-exact, contiguous and gap-free. `transfer/session_stream.bin` is one of
those 21, committed whole. (The §5 catalog fixture looks empty because the
session-list phase was captured *two minutes after* this download, by which point
the app had already imported and cleared the store.)

A download is **per file**, addressed by path — there is no separate
"start-download" opcode:

```
client  0x0402  + "1:/mem/a_0053.xrz"        read-file request   (transfer/open_request.bin)
device  0x0402  tag 0x0a09, length 0         open ack            (transfer/open_ack.bin)
device  0x0402  tag 0x0a11, length N         transfer header     (transfer/length_response.bin)
client  ACK(0)                               4-byte next-offset  (transfer/ack.bin)
device  CHUNK(offset 0,       65472 B)
client  ACK(65472)
device  CHUNK(offset 65472,   65472 B)
  ...
device  CHUNK(offset k*65472, r B)   r < 65472  -> END OF STREAM
```

- **Transfer header** (`tag 0x0a11`, the second response): `payload[16..20]` is the
  file's **total length** (u32 LE) — the on-wire source of
  `DownloadPlan::total_len`; `payload[20..24]` is the **chunk stride** `0xFFC0`
  (65472); `payload[32..]` echoes the NUL-terminated path. The first response
  (`tag 0x0a09`) is a bare open ack and declares length 0.
- **Chunk frames**: payload = `[offset(u32 LE)][data]`, `65476` bytes for a full
  chunk. Offsets advance by the stride and **reset to 0 for each new file** —
  the reset is per-`0x0402`, not per-session-bundle.
- **ACK flow control**: the client replies to each chunk with a 4-byte frame
  carrying the **next** offset it wants (`0, 0xFFC0, 0x1FF80, …`).
- **End of stream** is the **short final chunk** — a chunk whose data is shorter
  than the stride. There is no terminator frame and no trailing status. The chunk
  data lengths must sum to exactly the declared total.
- `transfer_chunk_offset` / `transfer_chunk_data` expose the two chunk fields;
  `test_transfer_framing_fields_are_documented` asserts the framing against the
  verbatim `transfer/chunk.bin` anchor.

### Sessions are stored compressed (`.xrz`)

A recorded session is served **zlib-compressed** — the reassembled bytes begin
`78 01` and inflate ~2.3x to the `<hCNF>…<hCHS>` `.xrk` container the decoder
reads. Compression is **per file**: the track/config files the same capture
downloaded (e.g. `0:/tkk/al.ria`, which `transfer/chunk.bin` is chunk #2 of) are
served **uncompressed**, so a client must sniff the zlib header rather than
inflate unconditionally. `racestudio_device::inflate_session` does exactly that.

### There is no whole-file checksum on the wire

The transfer header carries **only** the length and the stride — no checksum
field. On-wire integrity is per-chunk (the STCP trailer) plus the declared total
length. `DownloadPlan::whole_file_checksum` is therefore a **caller-supplied**
expectation, not a device-reported value.

### Typed chunked download (issue 6.5)

`racestudio_device::download_session(plan, transport, progress)` reassembles the
chunk stream into the file as the device stores it, then
`racestudio_device::inflate_session` unwraps it into the decodable `.xrk`. Each
chunk frame's checksum is **verified before use** (a corrupt chunk is retried up
to `MAX_CHUNK_RETRIES`; unrecoverable corruption is
`DeviceError::ChecksumMismatch`); chunks are placed by their declared offset, so
out-of-order and duplicate deliveries reassemble correctly and idempotently; a
stream that ends before full coverage is `DeviceError::MissingChunk`; and the
reassembled whole file is checksum-gated before it is surfaced — **no partial
file is ever returned as success**. Inflation is bounded against a decompression
bomb (`DeviceError::CorruptArchive`). The byte source is injected as a
[`Transport`], so CI replays fixtures with no live device; progress is reported
via a [`ProgressSink`] for the 6.7 progress bar.

| Field | Source | Verified? |
| --- | --- | --- |
| Chunk frame + trailer checksum | `transfer/chunk.bin` (`checksum_observed`) | ✅ observed |
| Chunk offset `payload[0..4]` u32 LE | `transfer/chunk.bin` | ✅ observed |
| Multi-chunk stream shape / end-of-stream | `transfer/session_stream.bin` | ✅ observed (#133) |
| Total length + 0xFFC0 stride | `transfer/length_response.bin` | ✅ observed (#133) |
| ACK-with-next-offset flow control | `transfer/ack.bin` | ✅ observed (#133) |
| Sessions are zlib-compressed (`.xrz`) | `transfer/session_stream.bin` → golden | ✅ observed (#133) |
| Whole-file checksum | — **absent from the protocol** | ✅ observed absent (#133) |
| Retry / re-request handshake | — | ⚠️ hypothesized |

> **Remaining caveat — the retry handshake is still unverified.** The captured
> transfer completed with **zero** chunk-checksum failures across 1474 frames, so
> the device never had to re-send a chunk and its recovery behaviour could not be
> observed. Re-requesting is *presumed* to be re-sending the ACK for the offset
> that failed (that is the only flow-control vehicle on the wire), and
> `download_session` is written to tolerate a re-delivery, but this path is
> exercised only against synthetic streams in `tests/transfer_test.rs`. The same
> applies to out-of-order and duplicate delivery, which the device never exhibited.

[`Transport`]: the byte-source seam (recorded replay in CI; live TCP in 6.7).
[`ProgressSink`]: the progress callback (bytes done / total).

---

### Every command is the same transaction (issue #179)

The read-file exchange above is one instance of the transaction every command
runs (`racestudio_device::command`):

```
client  command, 64-byte payload: opcode [8..12], upload length [16..20],
        tag 0x0a01 [24..28], NUL-terminated path [32..64]
device  echo, tag 0x0a01 "send it"         ── only when an upload follows
client  upload: offset(u32) = 0, then the data
device  bare u32 ack
device  echo, tag 0x0a09 "accepted"        ── when there is no upload
device  echo, tag 0x0a11: response length [16..20], stride 0xFFC0 [20..24]
client  ACK(next offset) / device chunk(offset + data) … until the length is covered
```

A response of length 0 ends at the header. Every frame in the capture (1536
client, 1593 device) carries the checksum trailer.

## 7. Delete (guarded write — opcode NOT yet observed)

The real delete opcode is **not** in any capture: the device held 0 on-board
sessions at 6.2 capture time, so no on-device delete could be issued (see
`manifest.json` → `pending`). Delete reuses the STCP framing (§3) with a delete
command opcode (§5); the exact opcode + response must still be captured on the
wire — tracked in **issue #130**.

### Guarded session delete (issue 6.6)

`racestudio_device::delete_session(target, confirm, armed, transport)` is a
**destructive WRITE** behind layered safety guards. It refuses — transmitting
**zero bytes** — unless *both* an `armed` flag is set *and* a `DeleteConfirmation`
matches the target's id **and** display name. Only then is exactly one delete
frame sent; a non-ack response is a typed error that is **never** blindly retried
(no accidental double-delete). The name is a client-side guard and is **never**
sent — only the id crosses the wire. The transport is injected, so CI replays
fixtures with no live device; only the guarded API is exposed over FFI (there is
no un-guarded delete).

| Field | Source | Verified? |
| --- | --- | --- |
| STCP request framing + trailer checksum | shared `framing::encode_frame` (§3) | ✅ verified |
| Guard logic (arm + id/name match ⇒ 0 bytes on refusal) | `delete_session` | ✅ verified |
| Delete **opcode** `payload[8..12]` | — (hypothesized `04 00 02 00`) | ⚠️ hypothesized |
| Target id at `payload[12..16]` (u32 LE) | `build_delete_request` | ⚠️ hypothesized |
| Ack/reject **response** shape (`status(u16 LE) ‖ id`) | — | ⚠️ hypothesized |

> **Caveat — the delete opcode + response are synthetic.** No delete traffic was
> ever captured (0 on-board sessions), so `fixtures/device/delete/{request,ack,
> reject}.bin` are **synthetic**, frozen so `build_delete_request` is pinned
> byte-for-byte and a real capture (**issue #130**) can be diffed against them.
> The **verified** anchors are the STCP framing and the guard logic; the opcode,
> id offset, and response shape must be confirmed against a session-present
> capture before a live delete relies on them. Clean-room, interoperability-only.

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
| **6.6 delete** | ✅ guarded delete: arm + typed confirmation ⇒ 0 bytes on refusal, one frame, no blind retry, over verified STCP framing; **delete opcode + ack/reject response synthetic, to be confirmed with a real capture (#130)** (§7) |
| **#179 live client** | ✅ hello + session-open with clock + info reads (§4), CSV catalog via `0x0224` (§5), per-file `0x0402` reads paced by ACKs (§6), close; every request pinned byte-for-byte to a captured frame, end-to-end against a fake device that replays the fixtures; **read-only** (§10) |
| **6.7 UI** | ✅ device panel: a tested `DevicePanelModel` state machine over an injected `DeviceService` (discovery → session table → 0→100% download progress → guarded, name-confirmed delete); logic in `RaceStudioCore`, SwiftUI shell excluded from coverage; fixture-driven, no live device |

---

## 10. The live download client (issue #179)

`racestudio_device::net::connect` opens TCP 2000 (5 s connect, 10 s per read or
write), runs the handshake (§4) and returns a `DeviceClient`:

| Call | Exchange | Result |
| --- | --- | --- |
| `list_sessions()` | `0x0224` read | `Catalog { sessions, skipped_rows }` (§5) |
| `download(file_name, progress)` | `0x0402` read of `1:/mem/<file_name>` | the inflated `.xrk` (§6) |
| `close()` | `0x0001` | — |

- **Read-only.** The client can send only the commands above. Nothing it sends
  modifies the device; the delete of §7 is not reachable from it or from the app.
- **Integrity.** Each chunk's trailer is verified and the chunks must cover exactly
  the declared length (`download_session`, whose whole-file checksum is optional
  because the device sends none). A corrupt chunk is asked for again by re-sending
  the ACK for the same offset — the presumed retry, still unobserved on the wire.
- **Failures** are typed: `Timeout`, `ConnectionFailed`, `ConnectionClosed`,
  `UnexpectedResponse` (a wrong hello or echo), `InvalidPath`, `Cancelled`. A
  `Canceller` stops a call from another thread by shutting the socket.
- **Verification.** `tests/command_test.rs` pins every request to a captured frame;
  `tests/client_test.rs` runs connect → list → download against an in-process fake
  MyChron that replays the fixtures (`tests/support/fake_mychron.rs`), checks the
  download equals `golden/transfer_reassembled.xrk`, checks the command order and
  that only read opcodes are ever sent, and injects drops, corrupt chunks, silence
  and cancellation.
- **FFI.** `discover_devices(timeout_ms)` and the `DeviceConnection` object
  (`connect`, `list_sessions`, `download`, `cancel`, `close`); the app's device
  window drives them through `LiveDeviceService`.
