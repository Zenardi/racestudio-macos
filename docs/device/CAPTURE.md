# M6 6.2 — MyChron WiFi capture procedure (macOS, clean-room)

**This is the observer-role runbook for issue 6.2.** It documents *how* the
on-the-wire bytes of the MyChron WiFi download protocol are captured on macOS,
de-identified, and turned into the replay fixtures that 6.3–6.6 consume in CI.

It is the operational companion to
[ADR 0006](../adr/0006-device-wifi-reverse-engineering.md) and
[`LEGAL_GATE.md`](LEGAL_GATE.md): the capture is **clean-room,
interoperability-only** reverse engineering (**DMCA §1201(f)**; **EU Software
Directive 2009/24/EC Art. 6**). We record **only our own observations of the
on-the-wire bytes** — never AiM firmware, DLLs, or the app binary (see
[MUST NOT redistribute](LEGAL_GATE.md#must-not-redistribute)).

> **Clean-room role — this document is for the *observer*.** The observer
> captures bytes and writes a neutral, behavioural description of what was seen
> (here and in [`PROTOCOL.md`](PROTOCOL.md)). The observer does **not** write the
> shipping client; the implementer (6.3–6.6) works **only** from the neutral
> notes + de-identified fixtures, never from AiM binaries. See the
> [role split](LEGAL_GATE.md#clean-room-role-split-observer-vs-implementer).

---

## 0. Why macOS-only works (no Windows needed)

The MyChron5/6 does **not** mount as USB mass storage; its only download path is
a proprietary protocol over WiFi. There is **no macOS desktop RaceStudio**, but
**AiM's iOS app speaks the same protocol** — which both proves a non-Windows
client is viable and gives us a client we can drive entirely from a Mac. So the
capture topology is:

```
  iPhone/iPad (AiM app)  ──WiFi──►  MyChron6   (the exchange we want)
        │ USB
        ▼
      Mac  ── pymobiledevice3 (pcapd) ──►  captures/*.pcapng   (the capture)
```

We capture the **iPhone ↔ MyChron** traffic by streaming the iPhone's packets to
the Mac over USB from its on-device `pcapd` service (via `pymobiledevice3`). It
presents the device's traffic at the **IP layer already decrypted**, so we read
TCP/UDP/mDNS payloads directly — no WPA2 key handling.

---

## 1. One-time setup

**Primary tool — `pymobiledevice3`.** Apple's `rvictl` is broken on recent macOS
(it fails with `bootstrap_look_up(): 1102` because its backing daemon is no longer
registered — see §5.1). `pymobiledevice3` captures the same IP-layer traffic
straight from the iPhone's on-device `pcapd` service over USB and needs **no
Xcode** — verified working on iOS 26 / macOS 26 here.

1. **Wireshark** (for `tshark`, used to extract fixtures from the captures):

   ```sh
   brew install --cask wireshark
   ```

2. **pymobiledevice3**:

   ```sh
   python3 -m pip install --user -U pymobiledevice3
   export PATH="$(python3 -m site --user-base)/bin:$PATH"   # its console script lives here
   pymobiledevice3 usbmux list                              # must list the iPhone (USB)
   ```

3. **The AiM iOS app** on the iPhone/iPad, paired with the MyChron6 (confirm you
   can already connect + list sessions in the app before capturing).

4. Connect the iPhone by USB, **unlock it, and tap "Trust"**. A `captures/`
   scratch dir at the repo root holds the raw `.pcapng` — it is **git-ignored**
   (raw captures are never committed; see §4):

   ```sh
   mkdir -p captures
   ```

> **iOS 17+ tunnel note.** Some device services sit behind a root "tunnel"
> (`sudo pymobiledevice3 remote tunneld`), but `pcap` was verified to work
> **without** a tunnel on iOS 26 here. If a capture ever errors that it needs an
> RSD/tunnel, run `sudo pymobiledevice3 remote tunneld` in another terminal and
> retry.

---

## 2. Capture, one phase per file

With the iPhone unlocked, trusted, joined to the **MyChron's WiFi**, and
USB-connected, capture each phase to its own file and stop with `Ctrl-C` after
performing **only** that action in the AiM app. Each file isolates one fixture:

```sh
export PATH="$(python3 -m site --user-base)/bin:$PATH"
pymobiledevice3 pcap --out captures/discovery.pcapng   # app finds the MyChron6 → Ctrl-C
pymobiledevice3 pcap --out captures/sessions.pcapng    # open the session list → Ctrl-C
pymobiledevice3 pcap --out captures/transfer.pcapng    # download ONE small session → Ctrl-C
pymobiledevice3 pcap --out captures/delete.pcapng      # delete ONE disposable session → Ctrl-C
```

| File | Action to perform in the AiM app while capturing |
| --- | --- |
| `captures/discovery.pcapng` | Open the app so it finds/announces the MyChron6 (Bonjour/mDNS). |
| `captures/sessions.pcapng` | Open the device's **session list** (do not download yet). |
| `captures/transfer.pcapng` | **Download one** (ideally small) session start-to-finish — yields the chunk framing + checksums. |
| `captures/delete.pcapng` | **Delete one** disposable test session. |

Optional flags: `--process <name>` filters to just the AiM app's traffic;
`-c <n>` stops automatically after N packets (omit to sniff until `Ctrl-C`).
`pymobiledevice3 pcap` writes Ethernet-framed IPv4/IPv6 packets that Wireshark and
`tshark` read directly.

**What this sees.** `pcapd` mirrors at L3 (IP), so you get the TCP/UDP payloads and
mDNS — the protocol itself. It does **not** carry raw 802.11 management frames, so
the AP-mode *association* handshake is out of scope here; if `PROTOCOL.md` needs
those link-layer details, add a short monitor-mode capture (§5.2) as a supplement.
For discovery via Bonjour/mDNS (UDP), `pcapd` is sufficient.

---

## 3. Note-taking during capture (observer log)

For each capture, jot a plain-language observer log (kept with the maintainers,
distilled into [`PROTOCOL.md`](PROTOCOL.md)):

- device model/firmware shown **in the app** (not extracted from any binary),
- wall-clock start of each phase (to line phases up against packets),
- the exact app action taken and what the app displayed as the result,
- anything surprising (retries, timeouts, error dialogs).

Describe **observed behaviour only** ("after the client sends 4 bytes `…`, the
device replies with N records of 32 bytes"), never AiM's implementation.

---

## 4. De-identification (before anything is committed)

Raw `.pcapng` files carry identifying data and **stay local** (git-ignored). We
commit only **extracted, de-identified protocol bytes** as `fixtures/device/**.bin`.

For each phase, extract just the **application-layer payload** of the protocol
messages (this alone drops IPs and, since RVI has no L2, there are no MACs):

```sh
# Example: dump the TCP payloads of the session-list exchange as hex+offsets,
# then carve the request/response byte ranges into .bin fixtures.
tshark -r captures/sessions.pcapng -Y '<display-filter for the device port>' \
       -T fields -e data.data
```

Then scrub any **identifying value that is not protocol-relevant** that still
appears *inside* a payload — device **serial number**, **SSID**, account/user
strings — by replacing it with a fixed, documented placeholder (e.g. serial →
`0x00…00`, SSID → `"FIXTURE-SSID"`) and recording the offset + original length in
[`PROTOCOL.md`](PROTOCOL.md) and the fixture `manifest.json`. A field that **is**
protocol-relevant (lengths, sequence numbers, checksums, opcodes) is kept
verbatim — those are what 6.3–6.6 replay.

**De-identification checklist (every fixture):**

- [ ] No `*.fw` / `*.dll` / `*.ipa` and no AiM binary/asset (enforced by
      [`scripts/check_legal_gate.sh`](../../scripts/check_legal_gate.sh)).
- [ ] No raw `.pcap`/`.pcapng` committed — only carved `.bin` payloads.
- [ ] Device **serial** removed/placeholdered wherever not protocol-relevant.
- [ ] **SSID** / network names and any **MAC** removed/placeholdered.
- [ ] Personal/account identifiers removed.
- [ ] Each `.bin` is described in `fixtures/device/manifest.json` with its phase,
      source-capture note, byte length, and expected decode.

The negative tests `test_fixtures_contain_no_firmware_or_binaries` and
`test_capture_is_deidentified` in `core/racestudio-device/tests/` assert these
mechanically.

---

## 5. Fallbacks

### 5.1 `rvictl` (legacy — usually broken on recent macOS)

Apple's Remote Virtual Interface tool (`rvictl`, bundled with full Xcode) also
mirrors an iOS device's traffic to an `rvi0` interface. On recent macOS it fails
with `bootstrap_look_up(): 1102` (its `rpmuxd` service is no longer registered),
so prefer `pymobiledevice3` (§1–§2). If it does work on your machine: install
Xcode, `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then
`rvictl -s <UDID>` and capture interface `rvi0` — same IP-layer result.

### 5.2 WiFi monitor-mode capture (no Xcode, no USB)

If the on-device capture is unavailable, sniff the MyChron's AP channel over the
air. This needs no Xcode/tether but is fiddlier and must still use the iOS app as
the client:

1. Put the Mac WiFi into monitor mode on the MyChron's channel (Wireshark →
   *Capture Options* → enable monitor mode on the Wi-Fi interface, or the bundled
   **Wireless Diagnostics ▸ Sniffer**). Capture into `captures/*.pcapng`.
2. If the MyChron AP is **open**, data frames are already cleartext. If **WPA2**,
   also capture the iPhone's join so Wireshark has the 4-way handshake, and add
   the PSK under *Preferences ▸ Protocols ▸ IEEE 802.11 ▸ Decryption keys*.
3. De-identify exactly as in §4 — monitor-mode frames **do** contain MACs/SSIDs in
   the 802.11 headers, so carving only the application payload is important.

---

## 6. Output of this procedure

- `fixtures/device/discovery/*.bin`, `.../sessions/*.bin`, `.../transfer/*.bin`,
  `.../delete/*.bin` — de-identified protocol bytes.
- `fixtures/device/manifest.json` — one entry per fixture (phase, byte length,
  expected decode, and for transfers the recorded checksum).
- [`PROTOCOL.md`](PROTOCOL.md) — the dissected protocol, every field offset tied
  to a specific fixture, with unknown/uncertain fields flagged and the fields
  6.4/6.5/6.6 depend on marked.

No production networking client lands in 6.2 — that is 6.3 (discovery), 6.4
(enumeration), 6.5 (download), 6.6 (delete).
