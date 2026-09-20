# Releasing RaceStudio for macOS

RaceStudio ships as a **universal, unsigned `.dmg`** attached to a
[GitHub Release](https://github.com/Zenardi/racestudio-macos/releases). One download runs on
Apple Silicon and Intel, macOS 13 (Ventura) or later.

## For users: installing a downloaded build

1. Download `RaceStudio-<version>.dmg` from the release page.
2. Open it and drag **RaceStudio** onto **Applications**.
3. **First launch only** — right-click the app and choose **Open**, then **Open** again.

### Why the extra step (Gatekeeper)

The build is *ad-hoc signed* but **not notarized**: this project has no paid Apple signing
certificate, so Apple never sees the binary and cannot vouch for it. macOS therefore attaches a
quarantine flag to anything downloaded from the internet and refuses to launch it on a double
click — typically *"RaceStudio can't be opened because Apple cannot check it for malicious
software."*

Right-click → **Open** records your consent once. If macOS still refuses (Sequoia and later are
stricter), clear the flag directly:

```sh
xattr -dr com.apple.quarantine /Applications/RaceStudio.app
```

This is expected for any independently distributed macOS app without a paid certificate; it is not
a sign that anything is wrong with the build. Verify what you downloaded before you clear the flag:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## For maintainers: cutting a release

Releases are produced entirely by `.github/workflows/release.yml`; nothing is built or uploaded
from a laptop.

```sh
git switch main && git pull
git tag v1.2.0
git push origin v1.2.0
```

The tag push runs two jobs:

| Job | What it does |
| --- | --- |
| `verify` | Re-runs `make ci` — swiftlint + `cargo clippy`/`fmt`, the ≥95% line-coverage gate, and the e2e golden-corpus harness — against the tagged tree. |
| `build` | Only `needs: verify`. Derives `1.2.0` from `v1.2.0`, smoke-tests the packaging, builds the universal `.app`, packages the `.dmg` + `SHA256SUMS.txt`, and publishes the Release with generated notes. |

`workflow_dispatch` runs the same pipeline with an optional `version` input; it uploads the build
artifacts but publishes no Release (that happens only on a tag).

**No secrets are involved.** The workflow reads nothing beyond the automatic
`permissions: contents: write`, so anyone who can push a tag can cut a release.
`tests/release_test.sh` fails if a secret reference or the Apple notarization toolchain is ever
reintroduced — that would silently break tag builds for anyone without the certificate.

### Building the `.dmg` locally

```sh
make dmg                 # version from the newest v* tag
make dmg VERSION=1.2.0   # or state it outright
```

That runs the same two scripts the workflow does, writing into the git-ignored `dist/`:

| Script | Responsibility |
| --- | --- |
| [`scripts/build_app.sh`](../scripts/build_app.sh) | Universal (`arm64` + `x86_64`) release build, bundle layout, `Info.plist` derived from `app/Sources/RaceStudio/Info.plist` with the version rewritten, app icon, ad-hoc signature with the sandbox entitlements. |
| [`scripts/package_dmg.sh`](../scripts/package_dmg.sh) | Stages the app beside an `/Applications` symlink with `ditto` (signature-preserving), builds a compressed read-only HFS+ image, writes `SHA256SUMS.txt`. |
| [`scripts/release_smoke.sh`](../scripts/release_smoke.sh) | `--dry-run`: runs both of the above over a universal stub executable, so the packaging logic is verified in seconds without a Swift build. Exercised by `tests/release_test.sh` on every PR. |

## What is deliberately out of scope

- **Paid-certificate signing and notarization.** Adding them would make every tag build depend on
  secrets that only the certificate holder has.
- **The Mac App Store**, and **Sparkle** in-app auto-update.

If a certificate is ever obtained, the place to add signing is `scripts/build_app.sh` step 5 (which
already applies the entitlements) plus a notarize-and-staple step between packaging and publishing —
and `tests/release_test.sh` would need its no-secrets assertion revisited on purpose.
