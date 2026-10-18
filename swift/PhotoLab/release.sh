#!/bin/sh
# Makes the update feed for the current VERSION and, with --publish, the GitHub release the app updates from.
#   ./package.sh && ./release.sh            -> dist/appcast.xml (signed) for dist/PhotoLab-<version>-macOS.zip
#   ./release.sh --publish                  -> rebuild from HEAD, create the release (and its tag v<version>)
# The installed app reads .../releases/latest/download/appcast.xml, so the newest release must carry appcast.xml.
# Signing uses the EdDSA private key in the login keychain (account "photo-lab", made by Sparkle's generate_keys);
# without that key no update can be published. --publish refuses unless main is clean and pushed, and rebuilds the
# zip first, so what gets signed is exactly the pushed commit.
set -eu
PUBLISH=0
case "${1:-}" in
  "") ;;
  --publish) PUBLISH=1 ;;
  *) echo "usage: $0 [--publish]" >&2; exit 2 ;;
esac
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
case "$VERSION" in *[!0-9.]*|"") echo "bad VERSION: $VERSION" >&2; exit 1 ;; esac
REPO="liaw-boy/photo-lab"
TAG="v$VERSION"
ZIP="$ROOT/dist/PhotoLab-$VERSION-macOS.zip"         # the clean build only, never the -with-logos one

if [ "$PUBLISH" = 1 ]; then
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }
  [ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" = main ] || { echo "not on main" >&2; exit 1; }
  # Every git step uses origin (its own credentials), so origin must be the repository the release goes to.
  # Host must be exactly github.com (https with optional user, scp-style ssh, or ssh:// with optional port).
  origin_url="$(git -C "$ROOT" remote get-url origin | tr '[:upper:]' '[:lower:]')"   # GitHub ignores case
  origin_url="${origin_url%/}"; origin_url="${origin_url%.git}"
  printf '%s\n' "$origin_url" | grep -Eqx \
    "(https://([^/@#?[:space:]]+@)?github\.com/|git@github\.com:|ssh://git@github\.com(:[0-9]+)?/)$REPO" \
    || { echo "origin is not github.com/$REPO" >&2; exit 1; }
  git -C "$ROOT" fetch -q origin main
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] \
    || { echo "HEAD is not the pushed origin/main" >&2; exit 1; }
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "tag $TAG exists" >&2; exit 1; fi
  # ls-remote --exit-code: 0 = tag on GitHub, 2 = no such tag, anything else = lookup failed (stop, do not guess).
  rc=0; git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || rc=$?
  case "$rc" in
    2) ;;
    0) echo "tag $TAG exists on GitHub" >&2; exit 1 ;;
    *) echo "could not check GitHub for tag $TAG (git ls-remote exit $rc)" >&2; exit 1 ;;
  esac
  # A release (or a draft left by a failed upload) under this tag name: clean it up by hand first. The list
  # includes drafts; if it cannot be read (gh not logged in, network), stop instead of assuming there is none.
  releases="$(gh release list --repo "$REPO" --limit 1000 --json tagName --jq '.[].tagName')" \
    || { echo "could not list GitHub releases (is gh logged in?)" >&2; exit 1; }
  if printf '%s\n' "$releases" | grep -qxF "$TAG"; then
    echo "release $TAG already exists on GitHub (maybe a draft from a failed run): delete it first" >&2; exit 1
  fi
  ./package.sh                                         # clean build of exactly this commit
fi
[ -f "$ZIP" ] || { echo "missing $ZIP (run ./package.sh first)" >&2; exit 1; }
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
[ -x "$TOOLS/generate_appcast" ] || { echo "missing Sparkle tools (run swift package resolve)" >&2; exit 1; }

STAGE=".build/appcast"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$ZIP" "$STAGE/"
# This version's section of CHANGELOG.md: the notes in the update dialog and on the GitHub release.
NOTES_DIR=".build/release-notes"
rm -rf "$NOTES_DIR"; mkdir -p "$NOTES_DIR"
awk -v v="$VERSION" '
  index($0, "## " v " ") == 1 { on = 1; next }
  on && /^## / { exit }
  on { print }
' "$ROOT/CHANGELOG.md" > "$NOTES_DIR/section.md"
[ -s "$NOTES_DIR/section.md" ] || { echo "no CHANGELOG.md section for $VERSION" >&2; exit 1; }
{ echo "<pre style=\"white-space: pre-wrap; font: 13px -apple-system\">"
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$NOTES_DIR/section.md"
  echo "</pre>"; } > "$STAGE/PhotoLab-$VERSION-macOS.html"

"$TOOLS/generate_appcast" --account photo-lab \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes "$STAGE"
cp "$STAGE/appcast.xml" "$ROOT/dist/appcast.xml"
echo "appcast: $ROOT/dist/appcast.xml"

if [ "$PUBLISH" = 1 ]; then
  cp "$NOTES_DIR/section.md" "$NOTES_DIR/release.md"
  cat >> "$NOTES_DIR/release.md" <<'NOTES'

**Install (macOS 14+):** unzip, move `PhotoLab.app` to Applications, first start: right-click → Open (ad-hoc signed, not notarized).
Already on 1.1.0 or later: Photo_Lab → 檢查更新… installs this version.
Brand logos and fonts are not included: see Help → 自備品牌 logo 與字體… in the app, or the README.
NOTES
  # The release creates the tag on GitHub at this commit in the same step (a lightweight tag), so a failed upload
  # leaves no stray tag; gh uploads into a draft first, and a draft left behind is caught by the check above.
  gh release create "$TAG" "$ZIP" "$ROOT/dist/appcast.xml" --repo "$REPO" --title "Photo_Lab $VERSION" \
    --target "$(git -C "$ROOT" rev-parse HEAD)" --notes-file "$NOTES_DIR/release.md" --latest
  echo "published: https://github.com/$REPO/releases/tag/$TAG"
  git -C "$ROOT" fetch -q origin "refs/tags/$TAG:refs/tags/$TAG" \
    || echo "warning: release is published, but fetching tag $TAG failed; run git fetch --tags later" >&2
fi
