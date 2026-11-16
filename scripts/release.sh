#!/usr/bin/env bash
# One command: Developer ID-signed, Hardened Runtime, notarized, stapled
# dist/Cado-<version>.dmg (Cado.app + /Applications symlink). See docs/RELEASING.md.
#
# Usage: scripts/release.sh <version>        (or: make release VERSION=x.y.z)
#
# Environment:
#   CADO_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)" (or its SHA-1). Required.
#   CADO_NOTARY_PROFILE  notarytool keychain profile name. Required unless SKIP_NOTARIZE=1.
#   SKIP_NOTARIZE=1      rehearsal: run every stage except notarize/staple/Gatekeeper
#                        checks. CADO_SIGN_IDENTITY may then be any identity (or "-" ad-hoc);
#                        the DMG is NOT distributable.
#   CADO_BUILD           override the build number (default: git commit count).
#
# Stages are functions run in order at the bottom. Later tickets add stages after
# stage_verify, using VERSION, BUILD, APP, DMG, DMG_SHA256 (all set by then):
#   #24 Sparkle appcast entry (sign_update on $DMG), #25 Homebrew cask bump ($VERSION, $DMG_SHA256).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_NAME="Cado"
BUNDLE_ID="com.ropats16.Cado"
ENTITLEMENTS="$ROOT/Resources/Cado.entitlements"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

die() { echo "error: $*" >&2; exit 1; }
say() { echo; echo "==> $*"; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3 (usage: make release VERSION=x.y.z)"

# CFBundleVersion = number of commits on HEAD: monotonically increasing along main,
# needs no state file, and is a plain integer. Override with CADO_BUILD if needed.
BUILD="${CADO_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)}"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "cannot derive build number (shallow clone?); set CADO_BUILD=<integer>"

APP="$ROOT/dist/$APP_NAME.app"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
DMG_SHA256=""

# Temp dirs / mounts to clean on any exit.
STAGE_DIR=""
MNT=""
cleanup() {
  [[ -z "$MNT" ]] || { hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; }
  [[ -z "$STAGE_DIR" ]] || rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

# "-" (ad-hoc) cannot take a secure timestamp.
TS=(--timestamp)

stage_preflight() {
  say "Preflight"
  local missing=()
  [[ -n "${CADO_SIGN_IDENTITY:-}" ]] || missing+=("CADO_SIGN_IDENTITY (e.g. 'Developer ID Application: Your Name (TEAMID)'; see docs/RELEASING.md)")
  if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    [[ -n "${CADO_NOTARY_PROFILE:-}" ]] || missing+=("CADO_NOTARY_PROFILE (name given to 'xcrun notarytool store-credentials')")
  fi
  if ((${#missing[@]})); then
    echo "error: missing environment:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
  fi
  [[ "$CADO_SIGN_IDENTITY" != "Cado Self-Signed" ]] || die "the dev self-signed identity must not be used for a release"
  if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    [[ "$CADO_SIGN_IDENTITY" == "Developer ID Application:"* || "$CADO_SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] \
      || die "CADO_SIGN_IDENTITY must be a 'Developer ID Application: ...' identity (or its SHA-1) to notarize"
  fi
  if [[ "$CADO_SIGN_IDENTITY" == "-" ]]; then
    TS=(--timestamp=none)
  else
    security find-identity -v -p codesigning | grep -qF "$CADO_SIGN_IDENTITY" \
      || die "signing identity '$CADO_SIGN_IDENTITY' not found in keychain (security find-identity -v -p codesigning)"
  fi
  if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    xcrun notarytool history --keychain-profile "$CADO_NOTARY_PROFILE" >/dev/null 2>&1 \
      || die "notarytool profile '$CADO_NOTARY_PROFILE' not usable (create it with 'xcrun notarytool store-credentials'; see docs/RELEASING.md)"
  else
    echo "SKIP_NOTARIZE=1: rehearsal, result is NOT distributable"
  fi
  command -v hdiutil >/dev/null || die "hdiutil not found"
  echo "version $VERSION  build $BUILD  identity '$CADO_SIGN_IDENTITY'"
}

stage_build() {
  say "Build + assemble unsigned $APP_NAME.app $VERSION ($BUILD)"
  CADO_VERSION="$VERSION" CADO_BUILD="$BUILD" CADO_ASSEMBLE_ONLY=1 bash "$ROOT/scripts/package_app.sh"
}

# Hardened Runtime + secure timestamp. The bundle has no nested code today (one
# executable; every dylib is a system one). If any is added (Sparkle.framework,
# helpers), sign it here BEFORE the app, inside-out, never --deep.
stage_sign_app() {
  say "Sign app (Hardened Runtime)"
  # Nested code, deepest paths first. Empty today.
  local f
  while IFS= read -r -d '' f; do
    echo "signing nested $f"
    codesign --force --sign "$CADO_SIGN_IDENTITY" "${TS[@]}" --options runtime "$f"
  done < <(find "$APP/Contents/Frameworks" "$APP/Contents/XPCServices" "$APP/Contents/Helpers" \
             \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) \
             -print0 2>/dev/null | sort -rz)
  codesign --force --sign "$CADO_SIGN_IDENTITY" "${TS[@]}" --options runtime \
    --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
}

stage_dmg() {
  say "Create $DMG"
  STAGE_DIR="$(mktemp -d)"
  ditto "$APP" "$STAGE_DIR/$APP_NAME.app"
  ln -s /Applications "$STAGE_DIR/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  say "Sign DMG"
  codesign --force --sign "$CADO_SIGN_IDENTITY" "${TS[@]}" "$DMG"
}

stage_notarize() {
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then say "Notarize: skipped (SKIP_NOTARIZE=1)"; return; fi
  say "Notarize (waits for Apple, usually a few minutes)"
  local out="$ROOT/dist/notarytool-$VERSION.json" status id
  xcrun notarytool submit "$DMG" --keychain-profile "$CADO_NOTARY_PROFILE" --wait --output-format json | tee "$out"
  status="$(/usr/bin/plutil -extract status raw -o - "$out" 2>/dev/null || true)"
  id="$(/usr/bin/plutil -extract id raw -o - "$out" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    [[ -z "$id" ]] || xcrun notarytool log "$id" --keychain-profile "$CADO_NOTARY_PROFILE" >&2 || true
    die "notarization status '$status' (log above)"
  fi
  say "Staple"
  xcrun stapler staple "$DMG"
}

stage_verify() {
  say "Verify"
  codesign --verify --strict --verbose=2 "$DMG"
  MNT="$(mktemp -d)"
  hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MNT" >/dev/null
  codesign --verify --strict --verbose=2 "$MNT/$APP_NAME.app"
  [[ -L "$MNT/Applications" ]] || die "DMG lacks /Applications symlink"
  local info; info="$(codesign -d --verbose=4 "$MNT/$APP_NAME.app" 2>&1)"
  grep -qE "flags=.*runtime" <<<"$info" || die "Hardened Runtime flag missing on app"
  grep -q "^Timestamp=" <<<"$info" || [[ "$CADO_SIGN_IDENTITY" == "-" ]] || die "secure timestamp missing on app"
  if [[ "$SKIP_NOTARIZE" != "1" ]]; then
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
    spctl -a -t exec -vv "$MNT/$APP_NAME.app"
  else
    echo "(rehearsal: stapler/spctl checks skipped; they need notarization)"
  fi
  hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true
  rmdir "$MNT" 2>/dev/null || true
  MNT=""
  DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
}

stage_summary() {
  echo
  echo "✓ Release $VERSION (build $BUILD)$([[ "$SKIP_NOTARIZE" == "1" ]] && echo ' [REHEARSAL, NOT NOTARIZED]')"
  echo "  DMG:    $DMG"
  echo "  sha256: $DMG_SHA256"
}

stage_preflight
stage_build
stage_sign_app
stage_dmg
stage_notarize
stage_verify
# Hook points: #24 (Sparkle appcast) and #25 (Homebrew cask) go here.
stage_summary
