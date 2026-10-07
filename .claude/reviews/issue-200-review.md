# Review: issue #200 — SIGSEGV in the Swift test run on GitHub's macOS VMs

**Reviewed**: 2026-10-07
**Branch**: fix/200-ci-sigsegv → main (cut from d5d1b4e)
**Decision**: APPROVE. Two passes, and every finding above LOW is fixed. The LOWs left are
justified below.

## Summary

Since #199 (#190) merged, the Swift test run on CI sometimes died with
`Exited with unexpected signal code 11`. CI now keeps the crash reports, and they name the code.

**The crash is in the test footage writer, not in the export engine.**
`TestMediaFactory.Feed.appendVideo` read `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool`
once per frame. AVFoundation swaps that pool for the encoder's a few frames into a write. A local
probe saw the swap at frames 6–8 with the hardware encoder. It releases the first pool on its own
queue, and the getter returns the pool unretained. So the read raced the release.

The fix: the factory makes its own `CVPixelBufferPool` once per movie. Nothing else touches that
pool.

## Evidence

**Crash reports** come from `scripts/collect_crash_reports.sh` on a scratch hunt workflow. It
runs the old code: one build, then the Swift tests with coverage, as CI does, many times on one
runner. All three reports are SIGSEGV with `KERN_INVALID_ADDRESS`.

| Report | Faulting frame | Test |
|---|---|---|
| swiftpm-testing-helper-2026-10-07-160724 | `objc_retain` ← `TestMediaFactory.Feed.appendVideo(to:)` :161 (`adaptor.pixelBufferPool`) | FootageProbeTests.test_a_30_fps_clip_is_described |
| swiftpm-testing-helper-2026-10-07-161203 | `CVAtomicBunchApply` ← `CVLocklessBunchPair::tryToReuseABacking` ← `CVPixelBufferPoolCreatePixelBuffer` ← `appendVideo` :163 | OverlayVideoExporterFailureTests.test_an_existing_destination_survives_a_failure |
| swiftpm-testing-helper-2026-10-07-161547 | `CF_IS_OBJC` ← `CFDictionaryGetValue` ← `CVPixelBufferPoolCreatePixelBuffer` ← `appendVideo` :163 | OverlayCompositorTests.test_frame_k_carries_the_overlay_for_its_session_time |

**Hit rate before and after.** One iteration is one full `swift test --enable-code-coverage`.

| Code | Hunt runs | Iterations | Crashes (SIGSEGV) | Hangs | Other failures |
|---|---|---|---|---|---|
| before (7239272) | 37649000980, 37649006904, 37649012503, 37653842855, 37653849280, HANG_HUNT_RUN | HANG_HUNT_ITER | HANG_HUNT_CRASH | HANG_HUNT_HANG | 0 |
| after (own pool) | 37654388418, 37654393725 | 24 | 0 | 0 | 0 |

`HANG_NOTE`

**Locally**, on macOS 27 on Apple silicon, the crash never reproduced. That covered:
- 16 full runs;
- 23 runs under `taskpolicy -b`;
- 47 runs of the export suites;
- the export suites under ASan and under TSan.

Two probes still back the mechanism here:
- the adaptor's pool address changes once per write with the hardware encoder;
- frames drawn from a pool of another size are scaled by the writer, not dropped.

## What was ruled out

- **The export engine's VideoToolbox, reader and writer paths.** No crash report points there.
- **`EncoderAvailability.system` and `ExternalVolume`.** No crash report points there either.
- **An AVFoundation per-frame timeout in the custom compositor.** A frame that took 12 s was still
  exported.
- **Compositor instances shared across readers.** AVFoundation makes one compositor per reader.

## Found on the way, kept out of this PR: #203

`OverlayCompositor.cancelAllPendingVideoCompositionRequests` returns at once. AVFoundation's
contract says it must block until every pending request is finished.

- **Evidence.** An instrumented compositor showed 4 requests in flight on every mid-encode
  cancel, finished after the read was torn down.
- **No crash and no ASan report here.**
- **A fix and a RED-first test are attached to #203.** Neither is in this PR: the fix should be
  proven against CI's macOS 15 AVFoundation first, and this PR unblocks the release.

## The `OverlayVideoExporterTests` failures (#191's CI attempt 2, the Release run 37640505537)

Both runs were built from d5d1b4e, before this fix.

- **37640505537.** Every export came out with only part of its frames, e.g. 4 of 45 and 11 of 90.
  The run was starved: trivial tests reported 14 s.
- **#191, attempt 2.** The run reported "5 issues" and printed none of their names.

The fix's runs above show none of this: 24 hunt iterations, plus the PR's CI runs. That does
not prove these failures shared the crash's root cause. A use-after-free that doesn't crash can
corrupt memory silently, but no log ties the two.

So the swift gate now names the failing tests from the whole log. `coverage.sh --swift-build`
tees the run, and on failure prints every recorded issue, failed test or suite, and crash.
`tests/swift_gate_test.sh` prints that block before its 25-line tail. A recurrence will name its
tests.

## Findings

### Pass 1 — `/ecc:code-review` (local, branch diff)

- **MEDIUM — the collector's wait ended at once on CI.** The runner image ships `.ips` files of
  its own (coreaudiod and lsd, 2026-08-30). "Any report present" ended the wait before ReportCrash
  had written the new one, and hunt run 37653842855 lost its report to this. **Fixed** in
  33005a4: the collector keeps only reports from the last `CRASH_REPORT_MAX_AGE_MIN` minutes, and
  waits while ReportCrash runs. A RED-first test covers it.
- **MEDIUM — one unreadable report ended the whole collection.** A system report that can't be
  copied ended the collector under `set -e`. **Fixed** in 5d5e0ba with a RED-first test.
- **LOW — a re-run could collide on the artifact name.** **Fixed** in 7015a85: the name now
  carries `github.run_attempt`.
- **LOW — the unreadable-file test proves nothing as root.** **Fixed** in 7015a85: it skips there.

### Pass 2 — `ecc:swift-reviewer`, independent and read-only

- **No CRITICAL or HIGH.** Pool lifetime, concurrency, IOSurface/Metal for `paintNoise`, keeping
  the adaptor's attributes, and appending buffers from our own pool were all confirmed correct. No
  other helper reads the pool getter: `MediaFixtures` and `SessionTimeBar` use
  `CVPixelBufferCreate`.
- **MEDIUM — ReportCrash can start more than 5 s after the crash on a loaded runner.** **Fixed**
  in 5ff5c83: the collector also waits, within `CRASH_REPORT_WAIT`, while no report has appeared.
- **LOW — collect and upload ran only on `failure()`.** **Fixed** in 5ff5c83: they now run on
  `failure() || cancelled()`, so a hung, cancelled job still collects its reports.
- **LOW — the frame pool's doc comment named the wrong owner.** **Fixed** in 5ff5c83.
- **LOW, kept — `framePool` throws `.featureUnsupported` without the CVReturn.** It matches the
  file's other failure paths, and this is test support.
- **LOW, kept — no minimum buffer count on the pool.** A few seconds of footage, with buffers
  recycled by the encoder.

## Validation

| Check | Result |
|---|---|
| `make lint` (clippy, fmt, swiftlint) | Pass, 0 violations |
| Swift tests (CLT route, full suite) | Pass, 2250 tests |
| `tests/crash_reports_test.sh` | 6 passed |
| `tests/swift_gate_test.sh` (new test, locally) | Pass. The real swift build is CI-only here: the Xcode/CLT skew. |
| gate, make, release, branch-protection and security self-tests | Pass |
| CI coverage | RaceStudioCore Swift 99.39%; Rust 97.85% (run 37656853552) |

## Files

- `app/Tests/RaceStudioCoreTests/Support/TestMediaFactory.swift` (modified): the fix.
- `scripts/collect_crash_reports.sh` (added) and `tests/crash_reports_test.sh` (added).
- `.github/workflows/ci.yml` and `.github/workflows/release.yml` (modified): collect and upload
  crash reports on failure or cancel.
- `scripts/coverage.sh` and `tests/swift_gate_test.sh` (modified): name the failing tests.
- `docs/adr/0008-overlay-video-export.md` (modified): the pool note.

## Review of ce67702: watchdog and job ceilings

Scope: `scripts/watchdog.sh` and `tests/watchdog_test.sh` (added); `scripts/coverage.sh`,
`tests/swift_gate_test.sh`, both workflows, `TestMediaFactory.swift` and ADR 0008 (modified).

- **HIGH — a stopped run could still hang the job.** `ExternalVolume.hdiutil` ran `hdiutil` with
  the test process's stdout and stderr. An `attach` leaves a `diskimages-helper` running, parented
  to launchd and not a descendant the watchdog stops, and it inherited those streams: the pipe
  `coverage.sh` tees. A run stopped with a volume attached would leave `tee` waiting for an end of
  file that never came. The hung hunt run of 37655954892 showed such a helper, and its `wait`
  blocked for 40 minutes after its own kill. **Fixed**: hdiutil's output goes to `/dev/null`.
- **LOW — the watchdog's trap was set after the command started, and every signal exited 143.**
  **Fixed**: the trap comes first, and HUP, INT and TERM exit 129, 130 and 143.
- No secrets, no unquoted paths, and bash 3.2 compatible (the tests pass under `/bin/bash`).
  `sample` is called as `/usr/bin/sample`: on this Mac a pyenv shim named `sample` comes first on
  PATH.

| Check | Result |
|---|---|
| `tests/watchdog_test.sh` | 6 passed (bash 5 and 3.2) |
| `tests/swift_gate_test.sh`, the two failure-summary tests | 2 passed |
| make, branch-protection, crash-reports, legal, security and release self-tests | Pass |
| Export, footage and volume suites (CLT route) | 75 passed, none skipped, no volume left mounted |
| swiftlint | 0 violations |
| The watchdog with the real `/usr/bin/sample` on a hung process | Sampled, stopped, exit 124 |
