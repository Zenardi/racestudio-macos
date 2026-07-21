#!/usr/bin/env bash
#
# check_legal_gate.sh — CI guard for the M6 device-WiFi reverse-engineering work
# (issue 6.1). It enforces two invariants so no protocol/capture/transfer work
# (6.2–6.7) can merge without the legal gate being satisfied:
#
#   1. FORBIDDEN ARTIFACTS (any PR): no AiM firmware (*.fw), RaceStudio DLL
#      (*.dll), or decompiled iOS app binary (*.ipa) may be committed. Only our
#      own clean-room notes/fixtures of on-the-wire bytes may be kept. See the
#      "MUST NOT redistribute" list in docs/device/LEGAL_GATE.md.
#
#   2. DEVICE-AREA SIGN-OFF: a PR that changes device code/docs (or is labelled
#      `area:device`) MUST carry, in its body, a link to
#      docs/adr/0006-device-wifi-reverse-engineering.md AND a recorded
#      `needs-legal-review` sign-off line.
#
# The guard is deliberately I/O-driven so it is testable from committed fixtures
# (tests/legal_gate_test.sh) with no GitHub API calls: the PR body and the
# changed-file list are supplied as files or env vars.
#
# Usage:
#   check_legal_gate.sh --body-file BODY --files-file FILES
#   check_legal_gate.sh --files "a b c" --require-signoff
#   PR_BODY="…" PR_LABELS="area:device" check_legal_gate.sh --ci   # CI mode
#
# Inputs (flags override env):
#   --body-file FILE    PR body text          (else $PR_BODY, else empty)
#   --files-file FILE   changed paths, 1/line
#   --files "a b c"     changed paths, inline (whitespace-separated)
#   --require-signoff   force the device-area sign-off requirement
#   --ci                derive changed files from `git diff` vs $BASE_REF and
#                       read $PR_BODY / $PR_LABELS from the environment
#
# Exit: 0 = gate satisfied; 1 = missing sign-off/ADR link; 2 = forbidden artifact.
set -uo pipefail

# --- The gated ADR + the patterns this guard enforces. ----------------------
ADR_LINK='docs/adr/0006-device-wifi-reverse-engineering.md'
# A path is "device-area" if it lives under a device module/doc tree or names
# the device hardware, or if the PR carries the area:device label.
DEVICE_PATH_RE='(^|/)devices?/|racestudio-device|mychron|docs/device/|adr/0006-device-wifi'

BODY_FILE=''
FILES_FILE=''
FILES_INLINE=''
REQUIRE_SIGNOFF=0
CI_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --body-file)      BODY_FILE="${2:-}"; shift 2 ;;
    --files-file)     FILES_FILE="${2:-}"; shift 2 ;;
    --files)          FILES_INLINE="${2:-}"; shift 2 ;;
    --require-signoff) REQUIRE_SIGNOFF=1; shift ;;
    --ci)             CI_MODE=1; shift ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "check_legal_gate: unknown argument: $1" >&2; exit 64 ;;
  esac
done

TMPDIR_GATE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_GATE"' EXIT
BODY="$TMPDIR_GATE/body"
FILES="$TMPDIR_GATE/files"

# --- Resolve the PR body into $BODY. ----------------------------------------
if [ -n "$BODY_FILE" ]; then
  cat "$BODY_FILE" > "$BODY" 2>/dev/null || : > "$BODY"
else
  printf '%s' "${PR_BODY:-}" > "$BODY"
fi

# --- Resolve the changed-file list into $FILES (one path per line). ---------
if [ -n "$FILES_FILE" ]; then
  cat "$FILES_FILE" > "$FILES" 2>/dev/null || : > "$FILES"
elif [ -n "$FILES_INLINE" ]; then
  printf '%s\n' $FILES_INLINE > "$FILES"
elif [ "$CI_MODE" -eq 1 ]; then
  base="${BASE_REF:-main}"
  git fetch --depth=1 origin "$base" >/dev/null 2>&1 || true
  { git diff --name-only "origin/$base" 2>/dev/null \
    || git diff --name-only HEAD~1 2>/dev/null \
    || git ls-files; } > "$FILES"
else
  : > "$FILES"
fi

# ---------------------------------------------------------------------------
# Check 1 — forbidden artifacts (applies to every PR, before area detection).
# ---------------------------------------------------------------------------
forbidden=''
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.fw|*.dll|*.ipa) forbidden="$forbidden $f" ;;
  esac
done < "$FILES"

if [ -n "$forbidden" ]; then
  echo "FAIL: forbidden AiM artifact(s) staged — MUST NOT commit firmware/DLL/app binary:"
  for f in $forbidden; do echo "  - $f"; done
  echo "Only clean-room notes/fixtures of on-the-wire bytes may be kept."
  echo "See the do-not-redistribute list in docs/device/LEGAL_GATE.md."
  exit 2
fi

# ---------------------------------------------------------------------------
# Check 2 — device-area sign-off. Detect the area, then require the records.
# ---------------------------------------------------------------------------
device=0
if [ "$REQUIRE_SIGNOFF" -eq 1 ]; then
  device=1
fi
case ",${PR_LABELS:-}," in
  *,area:device,*) device=1 ;;
esac
if [ "$device" -eq 0 ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if printf '%s' "$f" | grep -qiE "$DEVICE_PATH_RE"; then device=1; break; fi
  done < "$FILES"
fi

if [ "$device" -eq 0 ]; then
  echo "OK: no device-area changes detected; the M6 legal gate does not apply."
  exit 0
fi

missing=''
grep -qiF "$ADR_LINK" "$BODY" || missing="$missing adr-link"
# A recorded sign-off: a checked box that names needs-legal-review and states it
# was signed off (see the marker format in docs/device/LEGAL_GATE.md).
grep -qiE '\[x\].*needs-legal-review.*sign' "$BODY" || missing="$missing needs-legal-review-signoff"

if [ -n "$missing" ]; then
  echo "FAIL: device-area PR is missing required legal-gate record(s):$missing"
  echo "A device-area PR body MUST contain:"
  echo "  * a link to $ADR_LINK"
  echo "  * a recorded needs-legal-review sign-off, e.g.:"
  echo "      - [x] \`needs-legal-review\` signed off by @<reviewer> — see $ADR_LINK"
  exit 1
fi

echo "OK: device-area PR carries the ADR link and a recorded needs-legal-review sign-off."
exit 0
