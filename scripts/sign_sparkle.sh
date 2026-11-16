#!/usr/bin/env bash
# Sign an embedded Sparkle.framework inside-out, as Sparkle documents for
# signing outside Xcode (sparkle-project.org/documentation/sandboxing,
# "Code signing"): its XPC services (if any), Autoupdate, Updater.app, then
# the framework itself. Never --deep.
#
# Usage: scripts/sign_sparkle.sh <path/to/Sparkle.framework> <codesign args...>
#   e.g.  sign_sparkle.sh "$APP/Contents/Frameworks/Sparkle.framework" \
#           --sign "$IDENTITY" --timestamp --options runtime
#
# Cado is not sandboxed, so package_app.sh strips the XPC services (Sparkle
# uses them only with SUEnableInstallerLauncherService / SUEnableDownloaderService,
# i.e. sandboxed apps); they're still handled here in case they're ever kept.
set -euo pipefail

FW="${1:?usage: sign_sparkle.sh <Sparkle.framework> <codesign args...>}"
shift
(($#)) || { echo "error: no codesign arguments" >&2; exit 1; }
V="$FW/Versions/B"
[[ -d "$V" ]] || { echo "error: $V not found (Sparkle 2 framework layout expected)" >&2; exit 1; }

sign() { echo "signing nested ${1#"$FW"/}"; codesign --force "${@:2}" "$1"; }

[[ ! -e "$V/XPCServices/Installer.xpc" ]] || sign "$V/XPCServices/Installer.xpc" "$@"
# Sparkle >= 2.6: keep the Downloader's own entitlements.
[[ ! -e "$V/XPCServices/Downloader.xpc" ]] || sign "$V/XPCServices/Downloader.xpc" "$@" --preserve-metadata=entitlements
sign "$V/Autoupdate" "$@"
sign "$V/Updater.app" "$@"
echo "signing Sparkle.framework"
codesign --force "$@" "$FW"
