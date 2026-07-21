# ADR 0006 — Device WiFi protocol: clean-room, interoperability-only reverse-engineering

- **Status:** Accepted
- **Date:** 2026-07-21
- **Milestone:** M6 (issue 6.1). **Gates** 6.2 (capture), 6.3 (discovery), 6.4
  (enumeration), 6.5 (download), 6.6 (delete), 6.7 (device UI).
- **Legal review:** Required — this ADR and every M6 device PR carry the
  `needs-legal-review` label and may not merge without a recorded sign-off (see
  [Consequences](#consequences) and [`docs/device/LEGAL_GATE.md`](../device/LEGAL_GATE.md)).

> **This is a legally sensitive milestone.** Nothing in M6 — no packet capture,
> protocol dissection, discovery, or transfer code — may land until this decision
> and the legal gate it defines are recorded. This issue (6.1) is that gate; it
> deliberately contains **no** networking or capture code.

## Context

The MyChron5 / MyChron6 loggers do **not** mount as USB mass storage. Their only
download path is a **proprietary protocol over WiFi**: the device acts as its own
access point (or joins a network), and AiM's RaceStudio talks to it over that
link. To import sessions natively (the whole point of RaceStudio-macOS — a
clean-room Rust core, no AiM binaries; see
[ADR 0002](0002-xrk-decode-strategy.md)) we must interoperate with that protocol.

Because there is **no public specification**, achieving interoperability requires
one of three paths. Choosing among them, and pinning down the legal basis and the
process, is a prerequisite for any protocol work — hence this ADR before 6.2.

## Options considered

| Option | Pros | Cons |
| --- | --- | --- |
| **Official protocol docs (ask AiM)** | Authoritative; no RE risk; fastest if granted | AiM has no public SDK; likely no/slow response; may require an NDA that would taint a clean-room effort |
| **Partnership / SDK with AiM** | Sanctioned; ongoing support; lowest legal risk | Commercial/time cost; NDA taint risk; out of our control; may never materialise |
| **Clean-room interoperability RE (chosen)** | Independent; no AiM code or NDA; well-established legal footing for interoperability | Slower; requires disciplined observer/implementer separation and a documented legal basis |

A **first-contact attempt with AiM** for official docs / a partnership is made
regardless (recorded in [`docs/device/LEGAL_GATE.md`](../device/LEGAL_GATE.md)),
so the RE path is a **recorded, justified fallback** rather than a first resort.

## Decision

We pursue **clean-room, interoperability-only reverse-engineering** of the
MyChron WiFi download protocol, and we first send AiM a documented request for
official docs / a partnership so RE is the recorded fallback.

### Legal basis (cited in writing)

Our purpose is strictly **interoperability** — enabling RaceStudio-macOS to
exchange a user's own telemetry with a device the user owns — not cloning
RaceStudio or redistributing anything of AiM's. On that purpose we rely on:

- **DMCA §1201(f)** — *Reverse engineering* for interoperability: the exemption
  permitting circumvention/analysis to identify and analyse the elements
  necessary to achieve interoperability of an independently created program.
- **EU Software Directive 2009/24/EC, Art. 6** — *Decompilation* permitted, where
  indispensable, to obtain the information necessary to achieve the
  interoperability of an independently created program.

Both are **interoperability** exemptions and both are **narrow**: they justify
*observing and analysing* the on-the-wire behaviour only to the extent needed to
build our own independent implementation, and they do **not** license
redistributing AiM's copyrighted material (see the do-not-redistribute list
below).

### Clean-room separation (observation vs. implementation)

The RE is run as a **clean-room** process with a strict role split, defined in
[`docs/device/LEGAL_GATE.md`](../device/LEGAL_GATE.md):

- **Observer** — may capture and observe the on-the-wire bytes (WiFi packets,
  timings, framing) and write a *neutral, behavioural* specification of what was
  observed. The observer does **not** write shipping code.
- **Implementer** — writes our independent Rust/Swift implementation **only** from
  that neutral specification of observed bytes. The implementer does **not** read
  AiM firmware, decompiled binaries, or any AiM source/DLL.

Only our **own** clean-room notes and fixtures **of the on-the-wire bytes** are
kept in the repo; nothing of AiM's is.

### MUST NOT redistribute

We MUST NOT commit or redistribute, ever:

- AiM **firmware** images (`*.fw`),
- AiM **RaceStudio DLLs** / libraries (`*.dll`),
- the AiM **iOS app binary** or any decompiled form of it (`*.ipa`),
- any other **AiM-copyrighted asset** (source, resources, documentation).

Only our own clean-room notes/fixtures of observed on-the-wire bytes are kept.
This list is mirrored, with rationale, in
[`docs/device/LEGAL_GATE.md`](../device/LEGAL_GATE.md), enforced by `.gitignore`,
and actively rejected in CI by
[`scripts/check_legal_gate.sh`](../../scripts/check_legal_gate.sh).

## Consequences

- **Gate on 6.2–6.7.** None of 6.2 (capture), 6.3 (discovery), 6.4 (enumeration),
  6.5 (download), 6.6 (delete), or 6.7 (device UI) may merge until **both** this
  ADR is in place **and** the PR records a `needs-legal-review` sign-off with a
  link to this ADR. Every M6 device PR references
  [`docs/device/LEGAL_GATE.md`](../device/LEGAL_GATE.md).
- **CI guard.** [`scripts/check_legal_gate.sh`](../../scripts/check_legal_gate.sh)
  (wired into [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) and
  covered by `tests/legal_gate_test.sh`) fails a device-area PR whose body lacks
  the recorded sign-off / ADR link, and rejects any committed forbidden artifact
  (`*.fw`, `*.dll`, `*.ipa`).
- **Scope discipline.** The observer/implementer split is a process requirement,
  not a suggestion; a PR that mixes the roles, or that ships code derived from AiM
  binaries rather than from observed bytes, is out of compliance with this ADR.
- **Fallback is recorded.** If AiM grants official docs or a partnership, we
  revisit this decision; until then the first-contact record in
  [`docs/device/LEGAL_GATE.md`](../device/LEGAL_GATE.md) justifies the RE path.

## References

- Issue 6.1 (this gate); blocked consumers 6.2–6.7.
- [`docs/device/LEGAL_GATE.md`](../device/LEGAL_GATE.md) — first-contact record,
  clean-room role split, do-not-redistribute list.
- [ADR 0002](0002-xrk-decode-strategy.md) — the clean-room, no-AiM-binaries
  principle this ADR extends from decode to device connectivity.
- DMCA §1201(f); EU Software Directive 2009/24/EC, Art. 6.
