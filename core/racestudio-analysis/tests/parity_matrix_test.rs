//! Structural validator for `docs/PARITY_MATRIX.md` (issue 7.1).
//!
//! The RaceStudio 3 parity audit ends in a checked-in Markdown matrix; these
//! tests parse that document and assert the invariants that keep it auditable,
//! so the matrix cannot rot silently:
//!
//! - every feature row carries a status from the fixed set
//!   `Done | Partial | Missing | Won't-do | Unknown`
//!   (`Unknown` is sanctioned by the issue for features that could not be
//!   verified inside the time-box);
//! - every non-`Done` row links a gap/tracking issue id, so no gap is
//!   recorded without a follow-up (`Won't-do` rows link the issue where the
//!   exclusion was decided);
//! - every `Done`/`Partial` row cites the implementing issue, so the mapping
//!   from RS3 feature to shipped milestone work stays verifiable;
//! - the gap-backlog appendix is present, complete (proposed id, `area:*`
//!   label, impact, effort, scope) and sorted by priority;
//! - the exact RS3 version examined, the evidence source, and a link to the
//!   Definition of Done are recorded in the header.
//!
//! The validator is deliberately dependency-free (plain `std` string parsing):
//! the document is the system under test, not a Markdown engine.

use std::fs;
use std::path::{Path, PathBuf};

/// Statuses the matrix is allowed to use (issue 7.1 Goal).
const ALLOWED_STATUSES: [&str; 5] = ["Done", "Partial", "Missing", "Won't-do", "Unknown"];

/// Header of the parity-matrix table, in column order (issue 7.1 plan).
const MATRIX_HEADER: [&str; 6] = [
    "Feature",
    "RS3 behaviour",
    "This app status",
    "Implementing issue",
    "Gap issue",
    "Priority",
];

/// Header of the gap-backlog appendix table, in column order.
const BACKLOG_HEADER: [&str; 6] = [
    "Priority",
    "Proposed issue",
    "Area label",
    "Impact",
    "Effort",
    "Scope",
];

fn matrix_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/PARITY_MATRIX.md")
}

fn read_matrix() -> String {
    let path = matrix_path();
    fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("docs/PARITY_MATRIX.md not readable at {path:?}: {err}"))
}

/// Split a `| a | b |` Markdown table line into trimmed cell strings.
fn split_row(line: &str) -> Vec<String> {
    let trimmed = line.trim();
    let inner = trimmed
        .strip_prefix('|')
        .and_then(|rest| rest.strip_suffix('|'))
        .unwrap_or(trimmed);
    inner
        .split('|')
        .map(|cell| cell.trim().to_string())
        .collect()
}

/// True for `| --- | :-- |` style separator rows.
fn is_separator_row(cells: &[String]) -> bool {
    cells
        .iter()
        .all(|cell| !cell.is_empty() && cell.chars().all(|c| matches!(c, '-' | ':')))
}

/// Group consecutive `|`-prefixed lines into tables (separator rows dropped).
fn tables(doc: &str) -> Vec<Vec<Vec<String>>> {
    let mut all = Vec::new();
    let mut current: Vec<Vec<String>> = Vec::new();
    for line in doc.lines() {
        if line.trim_start().starts_with('|') {
            let cells = split_row(line);
            if !is_separator_row(&cells) {
                current.push(cells);
            }
        } else if !current.is_empty() {
            all.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        all.push(current);
    }
    all
}

/// Find the one table whose header row matches `header`, and return its data rows.
fn table_rows(doc: &str, header: &[&str]) -> Vec<Vec<String>> {
    let matching: Vec<Vec<Vec<String>>> = tables(doc)
        .into_iter()
        .filter(|table| {
            table.first().is_some_and(|cells| {
                cells.len() == header.len()
                    && cells.iter().zip(header).all(|(cell, want)| cell == want)
            })
        })
        .collect();
    assert!(
        matching.len() == 1,
        "expected exactly one table with header {header:?}, found {}",
        matching.len()
    );
    let mut found = matching.into_iter().next().unwrap_or_default();
    found.remove(0); // drop the header row
    assert!(!found.is_empty(), "table {header:?} has no data rows");
    for (index, row) in found.iter().enumerate() {
        assert!(
            row.len() == header.len(),
            "table {header:?} row {index} has {} cells (want {}): {row:?}",
            row.len(),
            header.len()
        );
    }
    found
}

/// A parsed feature row of the parity matrix.
struct FeatureRow {
    feature: String,
    status: String,
    implementing: String,
    gap: String,
}

fn feature_rows() -> Vec<FeatureRow> {
    table_rows(&read_matrix(), &MATRIX_HEADER)
        .into_iter()
        .map(|cells| FeatureRow {
            feature: cells[0].clone(),
            status: cells[2].clone(),
            implementing: cells[3].clone(),
            gap: cells[4].clone(),
        })
        .collect()
}

/// True when `cell` cites at least one issue id — either a milestone-dotted id
/// (`3.2`, `9.1`) or a GitHub number (`#109`).
fn contains_issue_id(cell: &str) -> bool {
    let bytes = cell.as_bytes();
    let dotted = bytes.windows(3).any(|window| {
        window[0].is_ascii_digit() && window[1] == b'.' && window[2].is_ascii_digit()
    });
    let hashed = bytes
        .windows(2)
        .any(|window| window[0] == b'#' && window[1].is_ascii_digit());
    dotted || hashed
}

/// Parse a `P1`/`P2`/`P3` priority cell into its rank.
fn priority_rank(cell: &str) -> u32 {
    cell.trim()
        .strip_prefix('P')
        .and_then(|rest| rest.parse::<u32>().ok())
        .unwrap_or_else(|| panic!("priority cell {cell:?} is not of the form P<n>"))
}

#[test]
fn test_matrix_file_exists() {
    // Given the audit is complete, the matrix document is checked in non-empty.
    let doc = read_matrix();
    assert!(
        !doc.trim().is_empty(),
        "docs/PARITY_MATRIX.md exists but is empty"
    );
}

#[test]
fn test_every_row_has_valid_status() {
    // Given any feature row, its status comes from the fixed allowed set.
    let offending: Vec<String> = feature_rows()
        .into_iter()
        .filter(|row| !ALLOWED_STATUSES.contains(&row.status.as_str()))
        .map(|row| format!("{} -> {:?}", row.feature, row.status))
        .collect();
    assert!(
        offending.is_empty(),
        "rows with a status outside {ALLOWED_STATUSES:?}: {offending:?}"
    );
}

#[test]
fn test_non_done_rows_link_a_gap_issue() {
    // Given any non-Done row, it links a gap/tracking issue id so the gap is
    // never recorded without a follow-up.
    let rows = feature_rows();
    assert!(
        rows.iter().any(|row| row.status != "Done"),
        "no non-Done rows found — the check below would pass vacuously"
    );
    let offending: Vec<String> = rows
        .into_iter()
        .filter(|row| row.status != "Done" && !contains_issue_id(&row.gap))
        .map(|row| format!("{} ({}) -> gap cell {:?}", row.feature, row.status, row.gap))
        .collect();
    assert!(
        offending.is_empty(),
        "non-Done rows without a linked gap issue id: {offending:?}"
    );
}

#[test]
fn test_done_rows_cite_implementing_issue() {
    // Given any Done or Partial row, it cites the concrete milestone issue that
    // provides the behaviour, so the mapping is auditable (issue 7.1 Goal).
    let rows = feature_rows();
    assert!(
        rows.iter()
            .any(|row| matches!(row.status.as_str(), "Done" | "Partial")),
        "no Done/Partial rows found — the check below would pass vacuously"
    );
    let offending: Vec<String> = rows
        .into_iter()
        .filter(|row| matches!(row.status.as_str(), "Done" | "Partial"))
        .filter(|row| !contains_issue_id(&row.implementing))
        .map(|row| format!("{} ({}) -> {:?}", row.feature, row.status, row.implementing))
        .collect();
    assert!(
        offending.is_empty(),
        "Done/Partial rows without an implementing issue citation: {offending:?}"
    );
}

#[test]
fn test_backlog_table_is_prioritized() {
    // Given the gap-backlog appendix, every entry is complete (proposed id,
    // area:* label, scope) and the table is sorted by ascending priority rank.
    let rows = table_rows(&read_matrix(), &BACKLOG_HEADER);
    let mut previous_rank = 0;
    for cells in &rows {
        let (priority, proposed, area, scope) = (&cells[0], &cells[1], &cells[2], &cells[5]);
        assert!(
            contains_issue_id(proposed),
            "backlog row {cells:?} has no proposed issue id"
        );
        assert!(
            area.contains("area:"),
            "backlog row {cells:?} has no area:* label"
        );
        assert!(
            !scope.is_empty(),
            "backlog row {cells:?} has an empty scope"
        );
        let rank = priority_rank(priority);
        assert!(
            rank >= previous_rank,
            "backlog is not sorted by priority: {priority} appears after P{previous_rank}"
        );
        previous_rank = rank;
    }
}

#[test]
fn test_rs3_version_and_source_recorded() {
    // Given the audit header, the exact RS3 version examined and the evidence
    // source are recorded so the conclusion is reproducible.
    let doc = read_matrix();
    let version_line = doc
        .lines()
        .find_map(|line| line.split("RS3 version examined:").nth(1))
        .expect("no 'RS3 version examined:' line in the header");
    assert!(
        contains_issue_id(version_line), // reuses the dotted-number scan: e.g. 3.83.26
        "'RS3 version examined:' does not carry a dotted version number: {version_line:?}"
    );
    let source_line = doc
        .lines()
        .find_map(|line| line.split("Evidence source:").nth(1))
        .expect("no 'Evidence source:' line in the header");
    assert!(
        !source_line.trim().is_empty(),
        "'Evidence source:' line is empty"
    );
}

#[test]
fn test_header_links_definition_of_done() {
    // Given the audit header, it links the Definition of Done as the bar every
    // follow-up gap issue must meet (issue 7.1 plan).
    let doc = read_matrix();
    assert!(
        doc.contains("DEFINITION_OF_DONE.md"),
        "header does not link docs/DEFINITION_OF_DONE.md"
    );
}
