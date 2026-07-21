# M6 Device Connectivity — Legal Gate

**Every M6 device PR (6.2–6.7) references this document.** It is the operational
companion to [ADR 0006](../adr/0006-device-wifi-reverse-engineering.md): the ADR
records the *decision* (clean-room, interoperability-only reverse-engineering of
the MyChron WiFi protocol) and the legal basis (DMCA §1201(f); EU Software
Directive 2009/24/EC Art. 6); this file records the *first-contact attempt*, the
*clean-room role split*, the *do-not-redistribute list*, and the *sign-off* every
device PR must carry.

> No packet capture, protocol dissection, discovery, or transfer code (6.2–6.7)
> may merge until a `needs-legal-review` sign-off is recorded in the PR (see
> [Sign-off](#pr-sign-off-required-on-every-device-pr) below). This is enforced
> in CI by [`scripts/check_legal_gate.sh`](../../scripts/check_legal_gate.sh).

## AiM first-contact record

Before falling back to reverse-engineering, we ask AiM directly for official
protocol documentation or a partnership/SDK, so the RE path is a **recorded,
justified fallback**.

- **Recipient:** AiM Tech Srl — developer / OEM relations
  (`info@aim-sportline.com`, plus the developer-support web form).
- **Date sent:** 2026-07-21
- **Channel:** email + web contact form (copy archived with the maintainers).
- **Request text (verbatim):**

  > We are building RaceStudio-macOS, an independent, open telemetry tool for
  > owners of AiM MyChron5 / MyChron6 loggers. We would like to let a device
  > owner import their own recorded sessions over WiFi. Do you offer official
  > protocol documentation, an SDK, or a partnership that would let us
  > interoperate with the MyChron WiFi download protocol? We are glad to work
  > within any program you have for third-party developers.

- **Outcome / deadline:** _Awaiting response._ **No response by 2026-08-21**
  (30 days) → the clean-room interoperability RE path in
  [ADR 0006](../adr/0006-device-wifi-reverse-engineering.md) is the recorded
  fallback. Update this line with the actual response if/when received.

## Clean-room role split (observer vs. implementer)

The reverse-engineering runs as a **clean-room** process. The two roles are kept
strictly separate and **the same person must not do both** for a given protocol
element:

| Role | May do | MUST NOT do |
| --- | --- | --- |
| **Observer** | Capture and observe on-the-wire bytes (WiFi packets, framing, timings); write a **neutral, behavioural** specification of what was observed. | Write shipping code. |
| **Implementer** | Write our independent Rust/Swift implementation **only** from the observer's neutral specification of observed bytes. | Read AiM firmware, decompiled binaries, or any AiM source/DLL. |

Only our **own** clean-room notes and fixtures **of the on-the-wire bytes** are
kept in the repo. The neutral spec describes *observed behaviour*, never AiM's
implementation.

## MUST NOT redistribute

We **MUST NOT** commit or redistribute, ever — only our own clean-room
notes/fixtures of observed on-the-wire bytes may be kept:

- AiM **firmware** images (`*.fw`),
- AiM **RaceStudio DLLs** / libraries (`*.dll`),
- the AiM **iOS app binary** or any decompiled form of it (`*.ipa`),
- any other **AiM-copyrighted asset** (source, resources, documentation, images).

These patterns are ignored by [`.gitignore`](../../.gitignore) and **actively
rejected in CI** by [`scripts/check_legal_gate.sh`](../../scripts/check_legal_gate.sh):
a PR that stages any of them fails the build.

## PR sign-off (required on every device PR)

A device-area PR (any change under a device module/doc, or labelled
`area:device`) MUST include, in its body:

1. a link to [`docs/adr/0006-device-wifi-reverse-engineering.md`](../adr/0006-device-wifi-reverse-engineering.md), and
2. a recorded `needs-legal-review` sign-off line in exactly this shape:

   ```
   - [x] `needs-legal-review` signed off by @<reviewer> — see docs/adr/0006-device-wifi-reverse-engineering.md
   ```

[`scripts/check_legal_gate.sh`](../../scripts/check_legal_gate.sh) checks for both
and fails the PR if either is missing. The guard is covered by
`tests/legal_gate_test.sh` and runs in
[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).

## References

- [ADR 0006](../adr/0006-device-wifi-reverse-engineering.md) — the decision and
  legal basis this gate operationalises.
- Blocked consumers: 6.2 (capture), 6.3 (discovery), 6.4 (enumeration), 6.5
  (download), 6.6 (delete), 6.7 (device UI).
