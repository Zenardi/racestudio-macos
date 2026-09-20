# Analysis views

Once a session is imported, open it into the **analysis workspace** — a set of
tiled views that all share one **linked cursor**: move it in any tile and every
other tile updates to the same point in time/distance (milestones **M3** analysis
engine and **M4** analysis UI, issues 3.1–3.8 and 4.1–4.7).

![Analysis workspace: tiled views sharing one linked cursor.](img/analysis-views.svg)

## Open a session for analysis

1. In the **library**, select a session and open it (double-click, or ⌘O on the
   selection).
2. The **workspace** opens with the default tiles laid out and a lap selected.
3. **Move the cursor** — hover or click in any tile. The delta strip, readouts,
   track-map dot, and tables all follow the same cursor position.
4. **Pick laps to compare** in the lap overlay; the delta-t strip shows where time
   is won or lost between them.

## The views

| View | What it shows |
|---|---|
| **Time / distance plot** | One or more channels against time or distance, the core trace view. |
| **Lap overlay + Δt strip** | Two or more laps overlaid, with a delta-t strip (time gained/lost vs a reference lap). |
| **GPS track map** | The racing line drawn from GPS, colorable by a channel (e.g. speed). |
| **Channel table** | A channels × laps grid of the value **at the cursor**, plus digital readouts. |
| **Histogram** | Distribution of a channel's samples (equal-count or fixed-width bins). |
| **XY scatter** | One channel against another, with a fitted trend line. |
| **Spectrum** | A windowed FFT amplitude-vs-frequency plot (e.g. for suspension/vibration). |
| **Math editor** | Author a derived channel live — see [Math channels](03-math-channels.md). |
| **Video review** | The session's onboard video tied to the cursor, reviewed lap by lap and sector by sector — see below. |

Statistics (min/max/mean/standard deviation, per lap or over a selected range) are
computed with a numerically stable (Welford) method and shown alongside the tables.

## Video review

Attach the onboard video for a session and review it against the data, one
section at a time.

1. **Attach the footage.** Pick **Video** in the left rail, then **Import
   Video…** and choose the file. It is remembered by bookmark, so saving the
   workspace (`.rsproj`) and reopening it later brings the same video back,
   aligned exactly as you left it.
2. **Sync it to the track data.** If the camera stamped a creation time and the
   log carries a date, an opening alignment is proposed automatically from those
   two clocks. Otherwise — or to correct it — select a lap or sector, scrub the
   footage to the frame where that section actually begins, and press **Sync to
   Section**. The offset is exact and unbounded, so a camera started minutes
   before the logger aligns fine; the slider then trims ±60 s around it.
3. **Review section by section.** The grid on the right is one row per lap and
   one cell per split, showing the time spent in each (the same numbers the
   **Splits** report shows — both are summed from one base grid,
   so they cannot disagree). Click a cell to send the cursor **and** the playhead
   to that section; the fastest time in each column is highlighted.
4. **Compare one section across laps.** With a sector selected, **Lap +** /
   **Lap −** hold that section and move through the laps — the same corner, lap
   after lap. **Play Section** plays exactly the selected window, and **Loop
   Section** repeats it.

While the footage plays it drives the shared cursor, so every other panel
follows; while it is paused, scrubbing the plot seeks the video instead. A
section the footage does not cover is dimmed and cannot be played, rather than
seeking to a wrong frame.

## Notes

- Large sessions stay responsive: the engine exposes **windowed** queries and
  min/max decimation, so a tile only fetches the samples it needs to draw.
- The exact mapping of RS3 analysis features to what has shipped here is tracked
  in the [parity matrix](../PARITY_MATRIX.md).
- Video review uses the split layout from the **Splits** report, so changing the
  split count there re-cuts the review grid too.

## Next

- Learn the expression language in [Math channels](03-math-channels.md).
- Back to [importing a session](01-getting-started-import.md).
