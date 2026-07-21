## Summary

Implements 6.3 — mDNS discovery of MyChron loggers on the WiFi link.

Closes #NN

## Notes

This PR touches device code and references the reverse-engineering ADR
(docs/adr/0006-device-wifi-reverse-engineering.md), but the author forgot to
record the required `needs-legal-review` sign-off line — so the CI guard must
block it.

## Testing & coverage

```
$ make coverage
PASS: coverage gate green (threshold 95%)
```
