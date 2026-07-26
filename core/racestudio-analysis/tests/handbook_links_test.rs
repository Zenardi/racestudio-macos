//! Doc-lint for the user handbook under `docs/handbook/` (issue 7.5).
//!
//! The handbook is a shipped deliverable, so it gets the same treatment as any
//! other output: a test that fails the build when it rots. These checks are the
//! executable half of the handbook's Definition of Done — they keep the prose
//! honest against the code it documents:
//!
//! - every chapter promised by the issue is present and non-empty;
//! - every internal link and image reference resolves to a file that exists
//!   (no broken cross-links, no missing screenshots);
//! - every function documented in the math-channels chapter is a *real* built-in
//!   of `racestudio-analysis`'s `expr` engine, with the documented arity, and —
//!   conversely — every shipped built-in is documented (no drift either way);
//! - every worked example evaluates through the real `eval` to the value the
//!   handbook claims, and appears verbatim in the chapter (examples can't lie);
//! - `scripts/build_docs.sh` (what `make docs` runs) renders the static site and
//!   its own link-check passes.
//!
//! Like `parity_matrix_test.rs`, the Markdown parsing is deliberately
//! dependency-free `std` string handling: the documents are the system under
//! test, not a Markdown engine.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use racestudio_analysis::expr::{eval_scalar, parse_str, Env, Func};

/// The five chapters plus the landing page the issue requires, in reading order.
const CHAPTERS: [&str; 6] = [
    "index.md",
    "01-getting-started-import.md",
    "02-analysis-views.md",
    "03-math-channels.md",
    "04-device-download.md",
    "05-troubleshooting.md",
];

/// Header of the built-in-function reference table in the math-channels chapter.
const FUNCTION_TABLE_HEADER: [&str; 3] = ["Function", "Arity", "Description"];

/// Absolute tolerance for a worked example's evaluated result.
const EVAL_TOLERANCE: f64 = 1e-9;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn handbook_dir() -> PathBuf {
    repo_root().join("docs/handbook")
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|err| panic!("{path:?} not readable: {err}"))
}

fn read_chapter(name: &str) -> String {
    read(&handbook_dir().join(name))
}

// --------------------------------------------------------------------------- //
// Markdown link / image extraction (std-only)
// --------------------------------------------------------------------------- //

/// One `[text](target)` or `![alt](target)` reference found in a document.
struct Ref {
    /// True for an image (`![...]`), false for a plain link.
    is_image: bool,
    /// The raw target (may carry a `#fragment` or a `"title"`).
    target: String,
}

/// Every link/image reference in `md`, in source order. Bracketed spans in our
/// handbook never nest, so a first-`]`/first-`)` scan is sufficient and can't
/// panic (all delimiters are ASCII; the slice is taken from the byte buffer).
fn refs(md: &str) -> Vec<Ref> {
    let bytes = md.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'[' {
            i += 1;
            continue;
        }
        let is_image = i > 0 && bytes[i - 1] == b'!';
        let Some(close) = find(bytes, b']', i + 1) else {
            break;
        };
        if bytes.get(close + 1) != Some(&b'(') {
            i += 1;
            continue;
        }
        let Some(rparen) = find(bytes, b')', close + 2) else {
            break;
        };
        let raw = String::from_utf8_lossy(&bytes[close + 2..rparen]);
        // Drop an optional `"title"` after the URL.
        let target = raw.split_whitespace().next().unwrap_or("").to_string();
        out.push(Ref { is_image, target });
        i = rparen + 1;
    }
    out
}

/// Index of the next `needle` byte at or after `from`.
fn find(haystack: &[u8], needle: u8, from: usize) -> Option<usize> {
    haystack[from..]
        .iter()
        .position(|&b| b == needle)
        .map(|offset| from + offset)
}

/// True for a target the doc-lint does not resolve on disk: an external URL or a
/// pure in-page anchor.
fn is_external_or_anchor(target: &str) -> bool {
    target.is_empty()
        || target.starts_with('#')
        || target.starts_with("http://")
        || target.starts_with("https://")
        || target.starts_with("mailto:")
}

/// Strip a trailing `#fragment` from a link target, leaving the path portion.
fn path_of(target: &str) -> &str {
    target.split('#').next().unwrap_or(target)
}

// --------------------------------------------------------------------------- //
// Markdown table extraction (std-only; mirrors parity_matrix_test.rs)
// --------------------------------------------------------------------------- //

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

/// The data rows (header dropped) of the one table in `doc` whose header matches.
fn table_rows(doc: &str, header: &[&str]) -> Vec<Vec<String>> {
    let mut tables: Vec<Vec<Vec<String>>> = Vec::new();
    let mut current: Vec<Vec<String>> = Vec::new();
    for line in doc.lines() {
        if line.trim_start().starts_with('|') {
            let cells = split_row(line);
            if !is_separator_row(&cells) {
                current.push(cells);
            }
        } else if !current.is_empty() {
            tables.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        tables.push(current);
    }

    let matching: Vec<Vec<Vec<String>>> = tables
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
    found.remove(0);
    assert!(!found.is_empty(), "table {header:?} has no data rows");
    found
}

// --------------------------------------------------------------------------- //
// Tests
// --------------------------------------------------------------------------- //

#[test]
fn test_handbook_has_all_chapters() {
    // Given the handbook is complete, every promised chapter exists non-empty.
    for chapter in CHAPTERS {
        let path = handbook_dir().join(chapter);
        assert!(path.is_file(), "missing handbook chapter: {path:?}");
        assert!(
            !read(&path).trim().is_empty(),
            "handbook chapter is empty: {path:?}"
        );
    }
}

#[test]
fn test_internal_links_resolve() {
    // Given any internal link in any chapter, its target file exists — no broken
    // cross-links. External URLs and pure anchors are out of scope for the lint.
    let mut broken = Vec::new();
    for chapter in CHAPTERS {
        let dir = handbook_dir();
        for reference in refs(&read_chapter(chapter)) {
            if reference.is_image || is_external_or_anchor(&reference.target) {
                continue;
            }
            let rel = path_of(&reference.target);
            if rel.is_empty() {
                continue;
            }
            if !dir.join(rel).exists() {
                broken.push(format!("{chapter} -> {}", reference.target));
            }
        }
    }
    assert!(broken.is_empty(), "unresolved internal links: {broken:?}");
}

#[test]
fn test_images_exist() {
    // Given any image reference, the image file exists (no missing screenshots),
    // and every chapter carries at least one figure as the issue requires.
    let dir = handbook_dir();
    let mut missing = Vec::new();
    for chapter in CHAPTERS {
        if chapter == "index.md" {
            continue; // the landing page is a table of contents, not a screen.
        }
        let images: Vec<Ref> = refs(&read_chapter(chapter))
            .into_iter()
            .filter(|reference| reference.is_image && !is_external_or_anchor(&reference.target))
            .collect();
        assert!(
            !images.is_empty(),
            "chapter {chapter} has no figure/screenshot"
        );
        for image in images {
            let rel = path_of(&image.target);
            if !dir.join(rel).exists() {
                missing.push(format!("{chapter} -> {}", image.target));
            }
        }
    }
    assert!(missing.is_empty(), "missing image files: {missing:?}");
}

#[test]
fn test_documented_functions_exist_in_expr_eval() {
    // Given the built-in-function table in the math chapter, every documented
    // function is a real `expr` built-in with the documented arity — AND every
    // shipped built-in is documented, so the reference cannot drift either way.
    let chapter = read_chapter("03-math-channels.md");
    let mut documented = Vec::new();
    for row in table_rows(&chapter, &FUNCTION_TABLE_HEADER) {
        let signature = row[0].trim_matches('`');
        let name = signature.split('(').next().unwrap_or("").trim().to_string();
        let func = Func::from_name(&name)
            .unwrap_or_else(|| panic!("documented function `{name}` is not an expr built-in"));
        let documented_arity: usize = row[1]
            .parse()
            .unwrap_or_else(|_| panic!("arity cell {:?} for `{name}` is not a number", row[1]));
        assert_eq!(
            func.arity(),
            documented_arity,
            "documented arity for `{name}` disagrees with the engine"
        );
        assert!(
            !documented.contains(&name),
            "function `{name}` is documented twice"
        );
        documented.push(name);
    }

    for func in Func::ALL {
        assert!(
            documented.iter().any(|name| name == func.name()),
            "built-in `{}` is shipped but not documented in the handbook",
            func.name()
        );
    }
    assert_eq!(
        documented.len(),
        Func::ALL.len(),
        "the documented function set must exactly match the shipped built-ins"
    );
}

#[test]
fn test_worked_examples_evaluate() {
    // Given each checked-in worked example, it evaluates through the real engine
    // to the documented value AND appears verbatim in the math chapter, so an
    // example can never silently disagree with what `eval` computes.
    let fixture = read(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/handbook_math_examples.txt"),
    );
    let chapter = read_chapter("03-math-channels.md");

    let mut count = 0;
    for line in fixture.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split("||").collect();
        assert_eq!(
            parts.len(),
            3,
            "fixture line is not `expr || bindings || expected`: {line:?}"
        );
        let expr = parts[0].trim();
        let bindings = parts[1].trim();
        let expected: f64 = parts[2]
            .trim()
            .parse()
            .unwrap_or_else(|_| panic!("expected value {:?} is not a number", parts[2]));

        let ast = parse_str(expr).unwrap_or_else(|err| panic!("parse `{expr}`: {err}"));
        let mut env = Env::new();
        if !bindings.is_empty() {
            for pair in bindings.split(',') {
                let (name, value) = pair
                    .trim()
                    .split_once('=')
                    .unwrap_or_else(|| panic!("binding {pair:?} is not `name=value`"));
                let value: f64 = value
                    .trim()
                    .parse()
                    .unwrap_or_else(|_| panic!("binding value {value:?} is not a number"));
                env.bind(name.trim(), value);
            }
        }
        let got = eval_scalar(&ast, &env).unwrap_or_else(|err| panic!("eval `{expr}`: {err}"));
        assert!(
            (got - expected).abs() < EVAL_TOLERANCE,
            "`{expr}` evaluated to {got}, handbook claims {expected}"
        );
        assert!(
            chapter.contains(expr),
            "worked example `{expr}` is not shown in the math-channels chapter"
        );
        count += 1;
    }
    assert!(
        count >= 6,
        "expected several worked examples, found {count}"
    );
}

#[test]
fn test_handbook_builds_and_linkchecks() {
    // Given `make docs` (via scripts/build_docs.sh), the handbook renders to a
    // static site and the build's own link-check passes; the generated index
    // references every chapter.
    let root = repo_root();
    let script = root.join("scripts/build_docs.sh");
    assert!(script.is_file(), "missing {script:?}");

    let out_dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("handbook-site");
    let status = Command::new("bash")
        .arg(&script)
        .current_dir(&root)
        .env("DOCS_OUT", &out_dir)
        .status()
        .unwrap_or_else(|err| panic!("failed to run {script:?}: {err}"));
    assert!(status.success(), "build_docs.sh failed: {status}");

    let index = out_dir.join("index.html");
    assert!(index.is_file(), "build_docs.sh did not produce {index:?}");
    let rendered = read(&index);
    for chapter in CHAPTERS.iter().filter(|name| **name != "index.md") {
        let stem = chapter.trim_end_matches(".md");
        assert!(
            rendered.contains(stem),
            "rendered index does not link chapter {stem}"
        );
    }
}
