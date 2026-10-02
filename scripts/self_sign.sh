#!/usr/bin/env bash
#
# Sign an app bundle with a freshly generated self-signed certificate.
#
# Why not ad-hoc: macOS 26 never offers an ad-hoc-signed app the Local Network
# permission prompt -- it silently refuses its connections to local devices
# ("No route to host"), so RaceStudio could not reach a MyChron at 10.0.0.1.
# The same bundle signed by a certificate gets the prompt and connects.
#
# No secrets: the key is generated here, used once and deleted with the
# throwaway keychain that held it. Each build therefore has its own identity,
# which means macOS asks for Local Network access again after an update. A
# stable identity would need a stored private key (a CI secret) or an Apple
# Developer ID -- see docs/RELEASE.md.
#
# codesign only finds identities in keychains on the user's search list, so the
# throwaway keychain is added to it for the signing step. On exit -- including
# failure and interruption -- that one entry is removed from the list as it is
# *then*, so a concurrent change to the list is never undone.
#
# Usage: scripts/self_sign.sh APP ENTITLEMENTS [COMMON_NAME]
#   ENTITLEMENTS may be "" to sign without entitlements (the `make run` dev
#   bundle, which is not sandboxed).
set -euo pipefail

APP="${1:?usage: self_sign.sh APP ENTITLEMENTS [COMMON_NAME]}"
ENTITLEMENTS="${2-}"
# Keep only characters that are safe in an openssl DN value (no , / + = # ...).
COMMON_NAME="${3:-RaceStudio Self-Signed}"
COMMON_NAME="${COMMON_NAME//[^A-Za-z0-9 ._()-]/_}"

# LibreSSL ships with macOS and writes PKCS#12 in the format `security import`
# reads; a Homebrew OpenSSL 3 earlier on PATH would not.
OPENSSL=/usr/bin/openssl
[ -x "$OPENSSL" ] || { echo "FAIL: $OPENSSL not found (self_sign.sh needs macOS)" >&2; exit 1; }

# Physical path, so it matches what `security list-keychains` prints.
WORK="$(cd "$(mktemp -d)" && pwd -P)"
KEYCHAIN="$WORK/signing.keychain-db"
PASSWORD="$(uuidgen)"

# The user's keychain search list, one path per line (blank lines skipped).
user_keychains() {
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"
    line="${line#\"}"
    if [ -n "$line" ]; then printf '%s\n' "$line"; fi
  done < <(security list-keychains -d user)
}

cleanup() {
  # Remove only our keychain from the list as it stands now.
  local kept=() path
  while IFS= read -r path; do
    [ "$path" = "$KEYCHAIN" ] || kept+=("$path")
  done < <(user_keychains)
  if [ ${#kept[@]} -gt 0 ]; then
    security list-keychains -d user -s "${kept[@]}" || true
  fi
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $COMMON_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"
HASH="$("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock mid-build
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
# The key now lives only in the throwaway keychain.
rm -f "$WORK/key.pem" "$WORK/identity.p12"
CURRENT_KEYCHAINS=()
while IFS= read -r path; do CURRENT_KEYCHAINS+=("$path"); done < <(user_keychains)
security list-keychains -d user -s ${CURRENT_KEYCHAINS[@]+"${CURRENT_KEYCHAINS[@]}"} "$KEYCHAIN"

ENTITLEMENT_ARGS=()
[ -n "$ENTITLEMENTS" ] && ENTITLEMENT_ARGS=(--entitlements "$ENTITLEMENTS")
codesign --force --sign "$HASH" ${ENTITLEMENT_ARGS[@]+"${ENTITLEMENT_ARGS[@]}"} --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "signed $APP with self-signed certificate \"$COMMON_NAME\" ($HASH)"
