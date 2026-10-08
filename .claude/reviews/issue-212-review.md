# Review: issue 212, the G-ball's ring labels and G numbers

## Review of 6f3f865

Scope:
- `GForceWidget`: ring labels, and the combined, lateral and longitudinal G under the ball.
- `OverlayFormatter.signed`, which `delta` now uses.
- Two new localised labels, LAT and LON.
- The coaching presets' taller, wider G-ball.
- The re-recorded goldens, the handbook and the preset diagram.

What holds:
- **Ring labels follow the rings actually drawn.** They use the same `g < G max` rule as
  `drawStatic`, outermost first.
  - The outer label always stays. An inner one stays only when it is clear of the horizontal axis
    and of every label kept so far, so inner labels drop first.
  - `test_no_two_texts_overlap` covers five sizes (down to a 34 × 18 content box) and G max 0.5, 2
    and 5.
- **Static and dynamic layers.** Ring labels and the LAT/LON labels are drawn once, in the static
  layer. Only the dot, the trail and the three numbers are drawn per frame. Both are asserted by
  rendering each layer alone.
- **The numbers tell the truth.**
  - They read the real G while the dot is held on the outer ring (`2.63 g` with a 2 g range).
  - They read `—` without both axes, and for an absurd value from a corrupt file.
  - The decimal mark follows the export language.
- **The unit's descender.** The `g` dips below its row's capitals, so the combined row keeps a
  margin above the LAT/LON row. The first render showed it touching a label, which the
  static/dynamic test caught.
- **The two halves keep apart.** A gap separates the lateral and longitudinal halves (pinned by a
  test). The first render read `+0.62LON`.
- **Presets.** The G-ball rect `(0.03, 0.49, 0.14, 0.31)` matches the speed box's width. The
  safe-area and no-overlap invariants hold in all four aspects.
- **Formatter.** `delta` now goes through `signed`, with identical output; its tests are unchanged
  and pass.

Findings:
- **MEDIUM, fixed: a value of 10 g or more overflowed its slot.** The styles were fitted to
  `8.88 g` and `−8.88`. A crash spike in the accelerometer data can read two whole digits, and
  `−23.45` was wider than its slot, spilling into the LON label.
  - Both styles are now fitted to two digits.
  - `test_a_two_digit_g_still_fits_its_slots` failed before the fix and passes now.
- **LOW, kept: ring labels are small at 720p** (capitals about 8 px). They are legible at 1080p
  and above, and with the Large size class. Their size is bounded by the spacing between rings at
  the default 2 g range.
- **LOW, kept: two defensive fallbacks are unreachable** (`?? ""`, `?? .zero`): the outer label
  always exists.
- **Note.** A workspace overlay saved before this change keeps its square G-ball rect. The numbers
  still fit (the strip is at least a quarter of the height), with a smaller ball. Choosing the
  preset again picks up the new rect, as the handbook says since #210.

| Check | Result |
|---|---|
| Tests before the change (RED) | Compile failure on the missing `Layout` API; then the presets' G-ball rect; then the descender, gap and two-digit tests, each before its fix |
| Full suite in parallel | 2417 passed |
| `swift test --no-parallel` | 2417 passed in 38 s |
| RaceStudioCore coverage | 99.38% (`OverlayFormatter` 100%, `GForceWidget` 97.4%: the two fallbacks) |
| SwiftLint | 0 violations |
| Tooling self-tests (CLT selected) | All pass except `swift_gate_test` (2), which fails the same way on clean `origin/main` |

Environment: this session found Xcode's licence unaccepted, which blocks `/usr/bin/git`, `make`
and `lipo` through Xcode. Runs used `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
