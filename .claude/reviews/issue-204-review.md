# Review: issue 204, an export that read fewer frames than its plan

## Review of 73a765a

Scope: the frame-count check in `ExportPipeline`; `OverlayCompositor` reports a missing source
frame as `sourceUnreadable`; `ExportShortReadTests` and `OverlayExportShortFootageTests` (added);
ADR 0008.

- The check runs inside `pumpAll`'s `do`, so a short read cancels the reader and the writer like
  any failure. The exporter then keeps an existing destination and removes the scratch directory.
  Both are tested.
- A user's cancel throws `.cancelled` at the top of the pump loop, before the check, so the two
  never collide. A plan with no frames is refused earlier (`rangeOutsideFootage`), so
  `plannedFrames` is never 0.
- Typed errors pass through `OverlayExportError(mapping:)`, so the export UI shows the existing
  `sourceUnreadable` message ("The video can't be read"). No new strings were needed.
- Nothing else referred to the old message, "A video frame could not be read for the overlay".
- **LOW — the compositor made its output pixel buffer before checking for the source frame, and
  threw it away when there was none.** **Fixed**: it checks the instruction, then the source, then
  makes the output, with a message for each failure.
- **LOW, kept — the remaining `writerFailed` branches of `compose` are untested.** One is an
  instruction that is not an overlay's, the other a render context that cannot make a pixel
  buffer. Neither can be provoked from a test without faking AVFoundation, and both are as before.

| Check | Result |
|---|---|
| New tests, before the fix | RED. 10 of 90 frames, and 88 of 90, exported "successfully". Shortened footage failed as `writerFailed`. |
| New tests, after the fix | 5 passed |
| Full suite on a Mac | 2395 passed |
| Full suite with `RACESTUDIO_VIDEO_TESTS=0` (as on CI) | 2395 passed |
| RaceStudioCore coverage on a Mac, nothing left out | 98.18% |
| Real footage, local only: session and best lap | Exports of 10082 and 1220 frames. The check did not trip, and the estimates are within 1.6%. |
| swiftlint | 0 violations |
