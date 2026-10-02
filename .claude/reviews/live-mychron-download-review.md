# Review: live MyChron download (#179)

**Reviewed**: 2026-10-02
**Branch**: feature/179-live-mychron-download → main
**Decision**: APPROVE after fixes (all CRITICAL/HIGH resolved)

## Summary
Two independent reviews (Rust client + FFI, Swift panel + live service) of the
read-only live download client. No security or data-loss issue; the frame,
catalog and path handling never panic or allocate unboundedly, and only read
opcodes can be built. Four HIGH findings were connection-lifecycle bugs, all
fixed with tests.

## Findings

### CRITICAL
None.

### HIGH (fixed)
1. **FFI socket outlived a failed call or `close()`** — `Canceller` holds a
   duplicate fd, so dropping the client did not end the TCP connection, holding
   the logger's only client slot. `with_client` and `close()` now shut it.
   Test: `test_failed_exchange_ends_the_tcp_connection`.
2. **A cancel landing between calls poisoned the cached connection** — Retry
   then reported every session "not downloaded". `LiveDeviceService.cancel()`
   now forgets and closes the link; a device `Cancelled` nobody asked for is a
   failure, not a cancel. Test: `test_device_cancellation_nobody_asked_for_is_a_failure`,
   `test_retry_after_cancel_downloads_again`.
3. **Cancel during connect was lost** — the download then ran in full.
4. **Actor reentrancy in `open()`** could leak a connection (window closed
   mid-enumerate) or overwrite one. Both fixed with a generation counter bumped
   by cancel/disconnect; an open finishing under an old generation closes its
   link and throws `Cancelled`.

### MEDIUM
- Fixed: per-kind reply caps (1 MiB handshake/info, 8 MiB catalog) refuse a
  hostile header before allocating (`test_oversized_reply_is_refused_before_allocating`).
- Fixed: `close()` never waits on a running call — it cancels it first
  (`test_close_does_not_wait_for_a_stalled_download`).
- Fixed: an empty file read is `UnexpectedResponse`, not an empty `.xrk`.
- Fixed: cancel semantics documented as final on `Canceller` / `DeviceConnection::cancel`.
- Fixed: progress is monotonic; stale table selection no longer counts; import
  file I/O runs off the main actor; the test wait has a deadline; the fake
  device's cancel flag resets per download.
- **Deferred**: read timeouts are per `read`, not per frame — a device dripping
  one byte every 9 s could hold a frame indefinitely. Cancel still works; worth
  a per-frame deadline if seen in practice.
- **Deferred**: `DeviceNetwork.isJoined` keys on a `10.0.0.x` address, which a
  home router can also hand out. It only chooses whether to show the join hint.

### LOW
- Fixed: `CorruptArchive` keeps the connection open; upload ack must be 4 bytes;
  `probe` no longer spins on immediate socket errors; `InvalidPath` doc;
  impossible dates (31/04, 29/02 off leap years) are skipped; library file
  names are capped and stripped of control characters; cancel-during-import doc.
- Fixed: `test_cancelled_client_sends_nothing_more` now asserts no catalog read
  reached the device.
- Deferred: a missing file surfaces as `UnexpectedResponse` (the not-found reply
  was never captured); retry order is failed-then-skipped.

## Validation Results

| Check | Result |
|---|---|
| cargo fmt / clippy -D warnings (workspace, all targets) | Pass |
| cargo test (workspace) | Pass |
| Rust line coverage (clean measure) | 99.0% |
| Swift tests (RaceStudioCoreTests, CLT toolchain) | Pass — 1361 |
| Swift RaceStudioCore line coverage | 99.4% |
| swiftlint | Pass |
| App shell build (Xcode toolchain) | Pass |
| Handbook doc-lint, fixture manifest + de-identification tests | Pass |
