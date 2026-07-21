## Summary

Implements 6.3 — mDNS discovery of MyChron loggers on the WiFi link.

Closes #NN

## Legal gate (M6 device work)

This device-area PR is bound by the legal gate in
docs/adr/0006-device-wifi-reverse-engineering.md and docs/device/LEGAL_GATE.md.

- [x] `needs-legal-review` signed off by @legal-reviewer — clean-room
      interoperability RE only; see docs/adr/0006-device-wifi-reverse-engineering.md
- [x] No AiM firmware, DLL, or app binary is committed by this PR.

## Testing & coverage

```
$ make coverage
PASS: coverage gate green (threshold 95%)
```
