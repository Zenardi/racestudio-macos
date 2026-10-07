# Review: issue 203, the compositor's cancel contract

## Review of b9a623d

Scope: `OverlayCompositor` (a FIFO of waiting requests and a blocking cancel);
`OverlayCompositorCancelTests` (added); ADR 0008.

- A cancel copies and clears the waiting list under the lock, and finishes each request as
  cancelled outside it, so it never calls into AVFoundation while holding the lock. It then
  waits on the compositor's queue for the frame being composed (`queue.sync {}`). A cancel made
  on that queue skips the wait instead of deadlocking.
- A request started after the cancel took the list is a new request, and is composed. A
  `composeNext` that finds the list empty does nothing.
- The test is deterministic for the fixed code: the cancel cannot return before the held draw is
  released. The broken code returned within the 0.3 s window, RED 3 times out of 3.
- **MEDIUM — the blocking cancel could deadlock in an AVFoundation that calls it while holding a
  lock that finishing a request needs.** The contract requires the cancel to block, so this
  should not happen; issue 203 asked for it to be checked on CI's macOS 15. Locally (macOS 27),
  10 rounds of the cancel-heavy suites passed with no hang. **Verified on macOS 15:** run 37693537847 on GitHub's macOS 15.7.9 VM, video tests forced on. Eight rounds of the 29 cancel-heavy tests: 8 out of 8 passed, no hang.
- **LOW, kept — the on-queue path and `compose`'s two `writerFailed` branches are not covered by
  tests** (`OverlayCompositor` 92.65%). They cannot be reached without faking AVFoundation.
  RaceStudioCore is at 98.17%.

| Check | Result |
|---|---|
| New test, before the fix | RED 3 out of 3: the cancel returned before the draw was released |
| New test, after the fix | 3 out of 3 passed |
| Cancel-heavy suites, 10 rounds on this Mac (macOS 27) | 10 out of 10 passed, no hang |
| Cancel-heavy suites, 8 rounds on CI's macOS 15.7.9 VM (37693537847) | 8 out of 8 passed, no hang |
| Full suite on a Mac | 2396 passed |
| Full suite with `RACESTUDIO_VIDEO_TESTS=0` (as on CI) | 2396 passed |
| RaceStudioCore coverage on a Mac | 98.17% |
| Real footage, local only: session and best lap | Exports of 10082 and 1220 frames; the lap-start frames are continuous |
| swiftlint | 0 violations |
