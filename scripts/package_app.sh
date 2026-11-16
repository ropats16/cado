#!/usr/bin/env bash
# Build (release) and assemble a self-contained dist/Cado.app, ad-hoc signed.
#
# Usage: scripts/package_app.sh [--install]
#   --install   also copy the .app to /Applications
#
# The Metal shader is EMBEDDED in the binary (see scripts/embed_metal_shader.sh),
# so there is no app data to bundle — the .app is just the binary + Info.plist +
# the OS-level icon (Contents/Resources/AppIcon.icns, which Finder, System
# Settings and notifications read from the bundle; the app itself never does).
# The mascot art the app draws is compiled in (Brand/MascotArt+SVG.swift).
# SwiftPM's FluidAudio_FluidAudio.bundle is deliberately left out: it holds only
# LuxTts G2P data for FluidAudio's TTS, which the app never calls (Parakeet ASR
# never reads it). The folder-model pins are compiled in (FolderModelPins+Tables),
# as is the Acknowledgements screen's text (Acknowledgements+Text).
#
# Release hooks (used by scripts/release.sh; unset = unchanged dev behaviour):
#   CADO_VERSION / CADO_BUILD   stamp CFBundleShortVersionString / CFBundleVersion
#   CADO_ASSEMBLE_ONLY=1        stop after assembling the unsigned .app (the
#                               release script does its own signing)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

APP_NAME="Cado"
BUNDLE_ID="com.ropats16.Cado"
APP="$ROOT/dist/$APP_NAME.app"
INSTALL=0
if [[ "${1:-}" == "--install" ]]; then
  INSTALL=1
fi

echo "==> Embedding Metal shader"
bash "$ROOT/scripts/embed_metal_shader.sh"

echo "==> Building $APP_NAME (release)"
swift build -c release --package-path "$ROOT"

BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -n "${CADO_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CADO_VERSION" \
    -c "Set :CFBundleVersion ${CADO_BUILD:?CADO_BUILD required with CADO_VERSION}" \
    "$APP/Contents/Info.plist"
fi
if [[ "${CADO_ASSEMBLE_ONLY:-0}" == "1" ]]; then
  echo "✓ Assembled (unsigned): $APP"
  exit 0
fi

echo "==> Ensuring a stable signing identity"
bash "$ROOT/scripts/create_signing_cert.sh" || true

# Prefer the stable self-signed identity (TCC grants survive rebuilds); fall
# back to ad-hoc if it isn't available.
SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Cado Self-Signed"; then
  SIGN_ID="Cado Self-Signed"
  security unlock-keychain -p "cado-local" "$HOME/Library/Keychains/cado-signing.keychain-db" 2>/dev/null || true
  echo "==> Codesigning with '$SIGN_ID' (identifier $BUNDLE_ID) — grants persist across rebuilds"
else
  echo "==> Ad-hoc codesigning (identifier $BUNDLE_ID) — grants will NOT survive rebuilds"
fi
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose "$APP"

if [[ "$INSTALL" -eq 1 ]]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Installing to $DEST"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # Re-register with Launch Services, or Spotlight and System Settings keep
  # showing the icon they cached from the previous install.
  touch "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
  echo "✓ Installed to $DEST"
  if [[ "$SIGN_ID" != "-" ]]; then
    echo "  Signed with a stable certificate, so Microphone/Accessibility grants"
    echo "  persist across rebuilds — grant once and you're done."
  else
    echo "  Ad-hoc signed: a rebuild changes the signature, so macOS may re-prompt"
    echo "  for Accessibility. Run 'make setup' to create the stable signing cert."
  fi
fi

echo ""
echo "✓ Packaged: $APP"
