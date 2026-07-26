#!/usr/bin/env bash
#
# Render + internal-link-check the user handbook (issue 7.5). This is what
# `make docs` runs, and what the doc-lint test `test_handbook_builds_and_linkchecks`
# invokes.
#
# Deliberately dependency-free: pure bash + coreutils, no pandoc/mkdocs required,
# so it runs on the same Command-Line-Tools-only runner as the other gates. If
# `pandoc` happens to be installed it is used for nicer per-chapter HTML;
# otherwise a minimal, self-contained HTML wrapper is emitted. Either way it:
#
#   1. checks that every internal link and image reference in docs/handbook/
#      resolves on disk (external URLs and pure #anchors are skipped), failing
#      with a non-zero status listing any broken reference; and
#   2. renders a static site (an index plus one page per chapter) into $DOCS_OUT
#      (default: dist/handbook).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDBOOK="$ROOT/docs/handbook"
OUT="${DOCS_OUT:-$ROOT/dist/handbook}"

if [ ! -d "$HANDBOOK" ]; then
  echo "build_docs: handbook directory not found: $HANDBOOK" >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# 1. Internal link + image check
# --------------------------------------------------------------------------- #
broken=0
while IFS= read -r md; do
  dir="$(dirname "$md")"
  # Pull the target out of every [..](target) / ![..](target); strip a title.
  while IFS= read -r target; do
    case "$target" in
      http://* | https://* | mailto:* | \#* | "") continue ;;
    esac
    path="${target%%#*}"
    [ -z "$path" ] && continue
    if [ ! -e "$dir/$path" ]; then
      echo "build_docs: BROKEN reference: ${md#"$ROOT"/} -> $target" >&2
      broken=$((broken + 1))
    fi
  done < <(grep -oE '\]\([^)]*\)' "$md" | sed -E 's/^\]\(([^) ]*).*$/\1/')
done < <(find "$HANDBOOK" -name '*.md' | sort)

if [ "$broken" -ne 0 ]; then
  echo "build_docs: link-check FAILED — $broken broken reference(s)" >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# 2. Render the static site
# --------------------------------------------------------------------------- #
rm -rf "$OUT"
mkdir -p "$OUT/img"
if [ -d "$HANDBOOK/img" ]; then
  cp "$HANDBOOK"/img/* "$OUT/img/" 2>/dev/null || true
fi

have_pandoc=0
command -v pandoc >/dev/null 2>&1 && have_pandoc=1

emit_page() {
  # $1 = source .md, $2 = output .html basename (without dir)
  local md="$1" base="$2"
  if [ "$have_pandoc" -eq 1 ]; then
    pandoc -s -f gfm -t html --metadata title="$base" "$md" -o "$OUT/$base.html"
  else
    local esc
    esc="$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$md")"
    {
      printf '%s\n' "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
      printf '%s\n' "<title>$base</title></head><body>"
      printf '%s\n' "<p><a href=\"index.html\">&larr; Handbook home</a></p><pre>"
      printf '%s\n' "$esc"
      printf '%s\n' "</pre></body></html>"
    } >"$OUT/$base.html"
  fi
}

# One page per chapter, plus a generated index that links every chapter.
{
  printf '%s\n' "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
  printf '%s\n' "<title>RaceStudio for macOS — User Handbook</title></head><body>"
  printf '%s\n' "<h1>RaceStudio for macOS — User Handbook</h1><ul>"
} >"$OUT/index.html"

while IFS= read -r md; do
  base="$(basename "${md%.md}")"
  emit_page "$md" "$base"
  if [ "$base" != "index" ]; then
    title="$(grep -m1 -E '^# ' "$md" | sed -E 's/^# +//')"
    [ -z "$title" ] && title="$base"
    printf '%s\n' "<li><a href=\"$base.html\">$title</a> <code>($base)</code></li>" >>"$OUT/index.html"
  fi
done < <(find "$HANDBOOK" -maxdepth 1 -name '*.md' | sort)

printf '%s\n' "</ul></body></html>" >>"$OUT/index.html"

pages="$(find "$OUT" -name '*.html' | wc -l | tr -d ' ')"
echo "build_docs: link-check OK; rendered $pages page(s) to ${OUT#"$ROOT"/}"
