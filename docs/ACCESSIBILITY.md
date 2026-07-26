# Accessibility & Localization Audit (issue 7.3)

RaceStudio for macOS must be usable with VoiceOver, respect Dynamic Type, and
ship fully localized in English and Brazilian Portuguese (pt-BR). This document
is the completed audit checklist plus the reference for how the localization and
accessibility surface is built and gated.

Scope: **en** + **pt-BR** only. All testable localization/accessibility logic
lives in the `RaceStudioCore` library target (the 95%-coverage gate); the thin
`RaceStudio` @main shell only *applies* the strings that logic produces and is
excluded from the coverage metric.

## How it works

- **String Catalog** — `app/Sources/RaceStudioCore/Localization/Localizable.xcstrings`
  is the single source of truth for every user-facing string, with an `en` and a
  `pt-BR` translation per key. It is shipped **verbatim** into `Bundle.module`
  (a `.copy` resource rule, not `.process`), so `LocalizationCatalog` parses the
  raw `.xcstrings` JSON at runtime. This means the completeness gate runs in CI
  on a Command-Line-Tools-only runner — no dependency on Xcode's `xcstringstool`.
- **Typed keys** — `L10n.Key` enumerates every catalog key; `L10n.string(_:locale:)`
  resolves the closest available language (region-specific → language → source),
  and an unknown key resolves to a **flagged sentinel** (`⚠️MISSING:<key>`) that a
  developer notices immediately rather than a silent empty string.
- **Localized numbers** — `L10n.formattedNumber(_:fractionDigits:locale:)` follows
  the locale's decimal/grouping separators (pt-BR `1.234,5`; en `1,234.5`) and is
  non-finite-safe (a sensor gap renders the em-dash placeholder, never `NaN`).
- **Chart summaries** — `AccessibilitySummary.channel(…)` builds the VoiceOver
  `accessibilityValue` for a plotted channel: its name, unit, and min → max range,
  localized. `ChannelViewModel.accessibilityLabel(locale:)` /
  `.accessibilityValue(unit:locale:)` surface it to the plot layer.
- **Control labels** — `ControlLabel` enumerates every interactive control; each
  exposes a localized, non-empty `label(locale:)` used as its `accessibilityLabel`.

## Automated gates

These run under `swift test` / `make coverage` and fail the build on regression:

| Test | Guarantees |
|---|---|
| `test_all_en_keys_have_ptbr_translation` | Every `en` key has a `pt-BR` translation |
| `test_no_untranslated_or_stale_strings` | No `new`/`needs_review`/`stale` unit; `en` and `pt-BR` key sets are identical (no orphans) |
| `test_every_typed_key_resolves_in_both_languages` | `L10n.Key` and the catalog stay in lock-step; no typed key is unresolved |
| `test_channel_accessibility_summary_includes_name_unit_range` | Chart summary speaks name, unit, and min/max |
| `test_every_control_has_nonempty_label` | Every control has a non-empty, un-flagged label in both languages |
| `test_ptbr_locale_formats_numbers_localized` | Numbers follow the locale (pt-BR comma decimal) |
| `test_l10n_lookup_missing_key_is_flagged` | A missing key is flagged, never silently empty |

## Manual VoiceOver audit checklist

Run with VoiceOver on (`⌘F5`) at the largest accessibility Dynamic Type size.

- [x] **VoiceOver labels** — every interactive control exposes a non-empty,
  localized `accessibilityLabel` (charts, buttons, pickers, lists). Chart views
  route their labels through `L10n` (`AnalysisWindowView`, `WorkspaceView`,
  `TrackMapView`, `HistogramView`, `ScatterView`, `SpectrumView`,
  `DeltaStripView`, `MathChannelEditorView`).
- [x] **Chart values** — each chart exposes an `accessibilityValue` summarizing the
  plotted channel (name, unit, min/max) via `AccessibilitySummary`, so a VoiceOver
  user gets the data without sight.
- [x] **Rotor** — headings, form controls, and links are reachable via the
  VoiceOver rotor; no interactive element is rotor-invisible.
- [x] **Focus order** — focus moves in a logical reading order (toolbar → sidebar →
  content → inspector); no focus traps.
- [x] **Dynamic Type** — at the largest accessibility text size, key screens do not
  truncate labels or clip controls; layouts reflow rather than overlap.
- [x] **Contrast** — text and essential UI meet WCAG AA contrast (4.5:1 body,
  3:1 large text / UI affordances) in both light and dark appearance.
- [x] **Localization** — with the system set to pt-BR the menus, labels, units, and
  number/date formatting render in Portuguese; no string falls back to a raw key
  (flagged sentinel) or an untranslated English literal.
- [x] **Reduced motion** — no essential information is conveyed by motion alone.

## Adding or changing a string

1. Add the key + `en`/`pt-BR` translations to `Localizable.xcstrings`
   (`state: "translated"`).
2. Add the matching case to `L10n.Key` (raw value = the catalog key). If it names
   an interactive control, add a `ControlLabel` case too.
3. Run `swift test` — the completeness and lock-step gates fail if a translation
   or typed key is missing or stale.
