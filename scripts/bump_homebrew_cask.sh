#!/usr/bin/env bash
# Bump the Cado cask in a Homebrew tap checkout to a released version, then commit
# there. Never pushes. See docs/RELEASING.md ("Homebrew tap").
#
# Usage: scripts/bump_homebrew_cask.sh <version> <sha256> <tap-dir>
#   <tap-dir>  local clone of the tap (e.g. ~/src/homebrew-tap). If it has no
#              Casks/cado.rb yet, packaging/homebrew/Casks/cado.rb is copied in.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 3 ]] || die "usage: $0 <version> <sha256> <tap-dir>"
VERSION="$1"
SHA="$2"
TAP="$3"

ver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
sha_re='^[0-9a-f]{64}$'
[[ "$VERSION" =~ $ver_re ]] || die "version must look like 1.2.3 (got '$VERSION')"
[[ "$SHA" =~ $sha_re ]] || die "sha256 must be 64 lowercase hex chars"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../packaging/homebrew/Casks/cado.rb"
[[ -f "$SRC" ]] || die "missing template $SRC"

[[ -d "$TAP" ]] || die "tap dir not found: $TAP"
TAP="$(cd "$TAP" && pwd -P)"
top="$(git -C "$TAP" rev-parse --show-toplevel 2>/dev/null)" \
  || die "not a git repo: $TAP (clone the tap first: see docs/RELEASING.md)"
[[ "$top" == "$TAP" ]] || die "$TAP is inside another repo ($top); pass the tap's own checkout"

CASK="$TAP/Casks/cado.rb"
if [[ ! -f "$CASK" ]]; then
  mkdir -p "$TAP/Casks"
  cp "$SRC" "$CASK"
  echo "copied cask template into $CASK"
fi

# BSD sed: no -i, write to a temp file and move it over.
tmp="$CASK.tmp.$$"
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 .*/  sha256 \"$SHA\"/" "$CASK" > "$tmp"
mv "$tmp" "$CASK"

grep -qx "  version \"$VERSION\"" "$CASK" || die "version line not rewritten in $CASK (unexpected layout?)"
grep -qx "  sha256 \"$SHA\"" "$CASK" || die "sha256 line not rewritten in $CASK (unexpected layout?)"

git -C "$TAP" add -- Casks/cado.rb
if git -C "$TAP" diff --cached --quiet -- Casks/cado.rb; then
  die "cask already at $VERSION with this sha256; nothing to commit"
fi
git -C "$TAP" commit -q -m "cado $VERSION" -- Casks/cado.rb
echo "committed in $TAP:"
git -C "$TAP" --no-pager log -1 --oneline

echo
echo "not pushed. to publish the bump:"
echo "  git -C \"$TAP\" push"
