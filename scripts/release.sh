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
#   CADO_BUILD           override the build number (default: git commit count). Either
#                        way it must be new to the published appcast and greater than
#                        its newest build (checked in preflight, before the build).
#   CADO_APPCAST_BASE    use this file as the published appcast instead of fetching it
#                        (an empty file = a new feed).
#
# A real release refuses a dirty tree (tracked changes, or untracked files where the
# build reads them): the DMG must be HEAD, which the printed 'gh release create
# --target' tags. A rehearsal only warns.
#   CADO_SPARKLE_ACCOUNT login-keychain account of the Sparkle EdDSA key (default: cado).
#                        It signs dist/appcast.xml's entry; its public half must equal
#                        Resources/Info.plist's SUPublicEDKey. Rehearsals sign too.
#
# Stages are functions run in order at the bottom. Later tickets add stages after
# stage_verify, using VERSION, BUILD, APP, DMG, DMG_SHA256 (all set by then):
#   #24 Sparkle appcast entry (stage_appcast: sign_update on $DMG -> dist/appcast.xml),
#   #25 Homebrew cask bump ($VERSION, $DMG_SHA256).
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
# Two releases from one HEAD would share it: preflight refuses that against the
# published appcast (make_appcast.py --check).
BUILD="${CADO_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)}"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "cannot derive build number (shallow clone?); set CADO_BUILD=<integer>"

APP="$ROOT/dist/$APP_NAME.app"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
DMG_SHA256=""

# Temp dirs / mounts to clean on any exit.
STAGE_DIR=""
MNT=""
BASE_APPCAST=""
cleanup() {
  [[ -z "$MNT" ]] || { hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true; }
  [[ -z "$STAGE_DIR" ]] || rm -rf "$STAGE_DIR"
  [[ -z "$BASE_APPCAST" ]] || rm -f "$BASE_APPCAST"
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
  check_clean_tree
  echo "version $VERSION  build $BUILD  identity '$CADO_SIGN_IDENTITY'"
}

# The DMG is built from the working tree but the release tags HEAD: they must match.
check_clean_tree() {
  local changes
  changes="$(git -C "$ROOT" status --porcelain --untracked-files=no
             git -C "$ROOT" ls-files --others --exclude-standard -- \
               Sources Resources Package.swift Package.resolved scripts Makefile | sed 's/^/?? /')"
  [[ -n "$changes" ]] || return 0
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "warning: uncommitted changes (a real release refuses these; this rehearsal builds them):"
    sed 's/^/  /' <<<"$changes"
  else
    echo "error: uncommitted changes; the DMG would not be the HEAD the release tags. Commit or stash:" >&2
    sed 's/^/  /' <<<"$changes" >&2
    exit 1
  fi
}

stage_build() {
  say "Build + assemble unsigned $APP_NAME.app $VERSION ($BUILD)"
  CADO_VERSION="$VERSION" CADO_BUILD="$BUILD" CADO_ASSEMBLE_ONLY=1 bash "$ROOT/scripts/package_app.sh"
}

# Hardened Runtime + secure timestamp. The only nested code is Sparkle.framework
# (#24): signed BEFORE the app, inside-out, never --deep. Anything else nested
# fails the release until it gets signed here too.
stage_sign_app() {
  say "Sign app (Hardened Runtime)"
  local other
  other="$(find "$APP/Contents" -mindepth 2 -maxdepth 2 \( -path "*/Frameworks/*" -o -path "*/XPCServices/*" \
             -o -path "*/Helpers/*" -o -path "*/PlugIns/*" \) ! -path "*/Frameworks/Sparkle.framework")"
  [[ -z "$other" ]] || die "unexpected nested code, sign it in stage_sign_app first: $other"
  bash "$ROOT/scripts/sign_sparkle.sh" "$APP/Contents/Frameworks/Sparkle.framework" \
    --sign "$CADO_SIGN_IDENTITY" "${TS[@]}" --options runtime
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

# --- Sparkle appcast (#24) ----------------------------------------------------
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
SPARKLE_ACCOUNT="${CADO_SPARKLE_ACCOUNT:-cado}"
APPCAST="$ROOT/dist/appcast.xml"
REPO="ropats16/cado"
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/Resources/Info.plist"; }

# Fails before the long build if the update key isn't usable: the keychain key's
# public half must be the one the app ships (else every update is rejected).
stage_preflight_sparkle() {
  say "Preflight: Sparkle update key (keychain account '$SPARKLE_ACCOUNT')"
  # Exactly the committed pins (#27); package_app.sh builds with them too.
  [[ -f "$ROOT/Package.resolved" ]] || die "Package.resolved missing: a release builds only the committed dependency pins"
  swift package --package-path "$ROOT" --force-resolved-versions resolve >/dev/null \
    || die "Package.resolved doesn't satisfy Package.swift; run 'swift package resolve', review and commit it"
  [[ -x "$SPARKLE_BIN/sign_update" ]] || die "Sparkle tools not found in $SPARKLE_BIN (swift package resolve)"
  local shipped keychain
  shipped="$(plist_get SUPublicEDKey)"
  [[ "$shipped" != "SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER" ]] \
    || die "Resources/Info.plist SUPublicEDKey is still the placeholder; see docs/RELEASING.md 'Update signing key'"
  keychain="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)" \
    || die "no Sparkle key for account '$SPARKLE_ACCOUNT' in the login keychain (docs/RELEASING.md 'Update signing key')"
  [[ "$keychain" == "$shipped" ]] \
    || die "keychain public key '$keychain' != Info.plist SUPublicEDKey '$shipped'; updates would be rejected"
  echo "update key OK ($shipped)"
  [[ "$CADO_SIGN_IDENTITY" != "-" ]] || echo "note: ad-hoc + Hardened Runtime fails library validation for" \
    "Sparkle.framework, so this rehearsal app won't launch; use an Apple Development identity for a runnable one"
  fetch_base_appcast
  # Sparkle offers by build number: refuse one the feed already has under another
  # version, or one not newer than its newest, before the long build.
  python3 "$ROOT/scripts/make_appcast.py" --check --base "$BASE_APPCAST" --version "$VERSION" --build "$BUILD"
}

# BASE_APPCAST = the published appcast (or CADO_APPCAST_BASE); empty = new feed.
fetch_base_appcast() {
  local feed code
  feed="$(plist_get SUFeedURL)"
  BASE_APPCAST="$(mktemp)"
  if [[ -n "${CADO_APPCAST_BASE:-}" ]]; then
    cp "$CADO_APPCAST_BASE" "$BASE_APPCAST"
    echo "base appcast: $CADO_APPCAST_BASE"
  else
    code="$(curl -sSL --max-time 30 -o "$BASE_APPCAST" -w '%{http_code}' "$feed" || true)"
    case "$code" in
      200) echo "base appcast: published $feed" ;;
      404) : >"$BASE_APPCAST"; echo "no published appcast yet ($feed): starting a new one" ;;
      *) die "fetching $feed gave HTTP '$code'; retry, or set CADO_APPCAST_BASE=<file> (empty file = new feed)" ;;
    esac
  fi
}

# dist/appcast.xml = the published appcast (if any) + a signed item for this DMG.
# The item's sparkle:version is the stamped CFBundleVersion ($BUILD).
stage_appcast() {
  say "Sparkle appcast entry"
  local sig len url
  # May raise a one-time keychain prompt for sign_update: choose Always Allow.
  sig="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" -p "$DMG")" || die "sign_update failed"
  # Checked against the key the app in this DMG trusts, not the keychain.
  swift "$ROOT/scripts/verify_update_signature.swift" \
    "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" "$sig" "$DMG"
  len="$(stat -f%z "$DMG")"
  url="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
  # The base fetched in preflight (and checked against this build there).
  python3 "$ROOT/scripts/make_appcast.py" --out "$APPCAST" --base "$BASE_APPCAST" \
    --version "$VERSION" --build "$BUILD" --min-os "$(plist_get LSMinimumSystemVersion)" \
    --url "$url" --length "$len" --signature "$sig" \
    --notes-url "https://github.com/$REPO/releases/tag/v$VERSION"
  xmllint --noout "$APPCAST"
  # Sign the whole feed (#46): sign_update embeds a trailing signature comment, so
  # a client that sets SURequireSignedFeed rejects a feed edited after this point.
  # Keychain step like the DMG one. Must be the LAST change to the file.
  "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$APPCAST" >/dev/null || die "sign_update failed on the appcast"
  swift "$ROOT/scripts/verify_update_signature.swift" --feed \
    "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" "$APPCAST"
  xmllint --noout "$APPCAST"
  # The item must match the bundle it describes.
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]] \
    || die "app CFBundleVersion != $BUILD"
}

# Never automatic: print the upload, for the maintainer to run after checking.
stage_publish_hint() {
  echo
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "Rehearsal: do NOT publish. A real release would print:"
  else
    echo "To publish (creates tag v$VERSION at HEAD; the DMG and appcast.xml become"
    echo "this release's assets, and 'latest/download/appcast.xml' then serves this feed):"
  fi
  echo "  gh release create v$VERSION '$DMG' '$APPCAST' --repo $REPO \\"
  echo "    --target $(git -C "$ROOT" rev-parse HEAD) --title 'Cado $VERSION' --generate-notes"
}

stage_homebrew() {
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then echo "Homebrew cask: skipped (rehearsal DMG must not reach the tap)"; return; fi
  if [[ -z "${CADO_TAP_DIR:-}" ]]; then echo "Homebrew cask: skipped (set CADO_TAP_DIR=<tap checkout> to bump it; docs/RELEASING.md)"; return; fi
  say "Homebrew cask bump ($CADO_TAP_DIR)"
  bash "$ROOT/scripts/bump_homebrew_cask.sh" "$VERSION" "$DMG_SHA256" "$CADO_TAP_DIR"
}

stage_summary() {
  echo
  echo "✓ Release $VERSION (build $BUILD)$([[ "$SKIP_NOTARIZE" == "1" ]] && echo ' [REHEARSAL, NOT NOTARIZED]')"
  echo "  DMG:    $DMG"
  echo "  sha256: $DMG_SHA256"
}

stage_preflight
stage_preflight_sparkle
stage_build
stage_sign_app
stage_dmg
stage_notarize
stage_verify
stage_appcast
stage_homebrew
stage_summary
stage_publish_hint
