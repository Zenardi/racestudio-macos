# RaceStudio for macOS — User Handbook

This handbook is the end-to-end guide for using RaceStudio for macOS: importing
`.xrk` sessions from AiM loggers, navigating the analysis views, authoring your
own math/derived channels, and downloading sessions directly from a connected
device over WiFi.

It documents exactly the surface that has shipped — cross-referenced to the
[RS3 parity matrix](../PARITY_MATRIX.md) — and nothing that has not. Where a
capability is a documented hypothesis pending real hardware capture, the chapter
says so.

## Chapters

1. [Getting started — importing a session](01-getting-started-import.md) — install,
   open the library, and import your first `.xrk` (M2).
2. [Analysis views](02-analysis-views.md) — the plot, lap overlay, delta strip,
   track map, tables, histogram, scatter, spectrum, and the linked cursor (M3/M4).
3. [Math channels & the expression language](03-math-channels.md) — the exact
   grammar, the built-in functions, and worked examples that actually evaluate (M3).
4. [Downloading from a connected device](04-device-download.md) — discover, list,
   and download sessions over WiFi, with the legal/redistribution notes (M6).
5. [Troubleshooting](05-troubleshooting.md) — what to check when import, discovery,
   download, or an expression does not behave.

## Scope & conventions

- **Language.** This handbook ships in **English**. A Brazilian-Portuguese
  (pt-BR) edition is tracked as a follow-up, consistent with the app's
  localization work (issue 7.3 / [ACCESSIBILITY.md](../ACCESSIBILITY.md)).
- **Figures.** The figures under `img/` are **schematic diagrams** of each screen
  and flow, not pixel screenshots; release-captured screenshots are a tracked
  follow-up. They are enough to follow the numbered steps in each chapter.
- **Freshness.** A doc-lint test (`handbook_links_test.rs`) fails the build if a
  link or image breaks, if a documented math function is not a real engine
  built-in, or if a worked example stops matching what the engine computes — so
  this handbook cannot silently drift from the code.

## Building this handbook

From the repository root:

```sh
make docs
```

`make docs` runs `scripts/build_docs.sh`, which link-checks every internal link
and image and renders a static site to `dist/handbook/` (no Xcode or Markdown
toolchain required). Every follow-up gap it references must meet the shared bar
in the [Definition of Done](../DEFINITION_OF_DONE.md).
