# RaceStudio — Brand & Style Identity

> Issue [7.3 / #141](https://github.com/Zenardi/racestudio-macos/issues/141). The single
> source of truth for the app's visual identity. Every colour, type size, gap, and corner
> in the UI is a **named token** resolved from `RaceStudioCore`'s `Theme` — views never
> hard-code a hue, size, or spacing value.

## Where the tokens live & how views consume them

| Layer | File | Responsibility |
|---|---|---|
| **Tokens (pure, tested)** | [`app/Sources/RaceStudioCore/Theme/`](../app/Sources/RaceStudioCore/Theme/) | `Theme.raceStudio` — the palette, type scale, spacing and rounding as value types, plus `BrandColor`'s WCAG contrast math. No SwiftUI. |
| **SwiftUI bridge (thin shell)** | [`app/Sources/RaceStudio/Views/Theme+SwiftUI.swift`](../app/Sources/RaceStudio/Views/Theme+SwiftUI.swift) | Maps `BrandColor → Color`, `FontToken → Font`, and threads the active `Theme` through the environment (`\.theme`). |
| **Accessibility proof** | [`app/Tests/RaceStudioCoreTests/ThemeTests.swift`](../app/Tests/RaceStudioCoreTests/ThemeTests.swift) | Asserts every text/surface pair meets WCAG AA in both appearances; runs in CI. |
| **Reference screen** | `LibraryPreviewPane` in [`LibraryBrowserView.swift`](../app/Sources/RaceStudio/Views/LibraryBrowserView.swift) | The worked example: the library preview pane drawn entirely from tokens. |

A view consumes tokens by reading the environment and painting semantic roles:

```swift
@Environment(\.theme) private var theme
@Environment(\.colorScheme) private var scheme

Text(venue)
    .font(.token(theme.typography.title))
    .foregroundStyle(theme.palette.textPrimary.color(scheme))   // resolves light/dark
    .padding(theme.spacing.md)
```

The `Theme` is injected once at the app root (`RaceStudioApp`); because the environment key
also defaults to `.raceStudio`, any view can read tokens even without an explicit injection.

---

## Palette

Semantic **roles**, not raw colours — a view asks for `textPrimary` or `accent`, so the hue
can change in one place. Each role carries a light and a dark value.

| Role | Light | Dark | Used for |
|---|---|---|---|
| `background` | `#F1F3F5` | `#0E1116` | Window canvas |
| `surface` | `#FAFBFC` | `#191E26` | Panels, list rows, cards |
| `surfaceElevated` | `#FFFFFF` | `#222833` | Raised cards, thumbnails, popovers |
| `textPrimary` | `#14171C` | `#F2F4F7` | Titles, primary body text |
| `textSecondary` | `#565C66` | `#A7AFBA` | Captions, metadata, secondary text |
| `accent` | `#C21A2B` | `#DC2A3B` | Brand — primary actions, selection, racing line |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | Text/icons on an accent fill |
| `separator` | `#D8DCE2` | `#333B47` | Hairlines, borders |
| `positive` | `#137A38` | `#3FB964` | Faster/best-lap, improvement |
| `negative` | `#C21A2B` | `#FF6B77` | Slower, warnings, destructive |

**Rationale.** A **motorsport red** accent on a **cool near-neutral** canvas: high-legibility,
data-forward, and deliberately restrained so the coloured telemetry traces (the overlay
palette in `PlotColor`) stay the loudest thing on screen. `positive`/`negative` are reserved
for delta semantics (faster vs slower) and never used decoratively.

### WCAG AA contrast

Every text role clears **4.5:1** against every surface, in both appearances; `onAccent`
clears 4.5:1 on `accent`; `accent` clears the **3:1** non-text (WCAG 1.4.11) bar against
*every* surface (canvas, panel, elevated card). This is enforced by
`ThemeTests.test_every_text_on_surface_pair_meets_wcag_aa` and
`test_accent_meets_non_text_contrast_against_every_surface` — both derive their role sets from
`ColorRole.kind`, so a future palette edit (or a new role) that breaks contrast fails CI.

| Pair | Light | Dark | Requirement |
|---|---|---|---|
| `textPrimary` / `background` | 16.2:1 | 17.2:1 | ≥ 4.5 (AA text) |
| `textSecondary` / `background` | 6.1:1 | 8.5:1 | ≥ 4.5 (AA text) |
| `textSecondary` / `surface` | 6.5:1 | 7.6:1 | ≥ 4.5 (AA text) |
| `positive` / `surface` | 5.2:1 | 6.6:1 | ≥ 4.5 (AA text) |
| `negative` / `surface` | 5.8:1 | 6.1:1 | ≥ 4.5 (AA text) |
| `onAccent` / `accent` | 6.0:1 | 4.7:1 | ≥ 4.5 (AA text) |
| `accent` / `background` | 5.5:1 | 4.0:1 | ≥ 3.0 (AA non-text) |
| `accent` / `surfaceElevated` | 6.0:1 | 3.1:1 | ≥ 3.0 (AA non-text) |

(The lowest text pair overall is `positive`/`background` in light mode at 4.9:1 — still above
AA. Full matrix is in the test.)

---

## Type scale

macOS-native system font, seven named steps. `readout` is the only monospaced-digit step —
telemetry numbers must not jitter their width as digits change.

| Token | Size | Weight | Digits | Used for |
|---|---|---|---|---|
| `largeTitle` | 26 | bold | proportional | Hero / empty-state headings |
| `title` | 20 | semibold | proportional | Screen & panel titles |
| `headline` | 15 | semibold | proportional | Section headers |
| `body` | 13 | regular | proportional | Default text |
| `callout` | 12 | regular | proportional | Supporting labels |
| `caption` | 11 | regular | proportional | Metadata, badges |
| `readout` | 13 | medium | **monospaced** | Lap times, channel values, deltas |

Sizes are strictly decreasing `largeTitle → caption` (the reference size at the default text
setting). Each token also names a **Dynamic Type anchor**, and the shell renders it through
that anchor (`Font.system(_ style:)`) — so type **scales with the system accessibility
text-size setting** rather than being pinned to a fixed size — applying the token weight and
`.monospacedDigit()` when requested.

## Spacing

A strictly-increasing **4-point grid** for padding and stack spacing, so vertical/horizontal
rhythm is uniform across surfaces.

| Token | `xs` | `sm` | `md` | `lg` | `xl` | `xxl` |
|---|---|---|---|---|---|---|
| Points | 4 | 8 | 12 | 16 | 24 | 32 |

## Rounding

| Token | `sm` | `md` | `lg` |
|---|---|---|---|
| Radius | 4 | 8 | 12 |

`sm` for controls/badges, `md` for cards and thumbnails, `lg` for large containers/sheets.

---

## Iconography

- **SF Symbols** only — no bespoke icon set. Native weight/scale matching, free Dynamic Type
  and accessibility support, and visual consistency with macOS.
- **Monoline / regular weight**, matched to adjacent text; tinted with a semantic role
  (`textSecondary` for passive glyphs, `accent` for active/selected, `negative` for
  destructive) rather than a raw colour.
- Prefer **filled** variants for status/emphasis (e.g. `exclamationmark.triangle.fill`) and
  **outline** for neutral affordances (`folder`, `film`, `chart.xyaxis.line`).
- Every icon that conveys meaning pairs with a text label or an accessibility label — an icon
  is never the sole carrier of information.

## Wordmark direction

"**RaceStudio**" set in the system font, `largeTitle`/`title` weight, with the **`accent`**
red reserved for a single emphasized element (e.g. a leading mark or the "Studio" segment) —
not the whole wordmark, keeping it legible in both appearances. A dedicated app-icon
treatment is tracked separately in [#142](https://github.com/Zenardi/racestudio-macos/issues/142).

## Scope & consistency

This issue establishes the token **system** and applies it to one reference screen (the
library preview pane); the tokens are available app-wide via `\.theme`. Rolling the tokens
across the remaining analysis surfaces is the follow-on UI-styling work in
[#143](https://github.com/Zenardi/racestudio-macos/issues/143).
