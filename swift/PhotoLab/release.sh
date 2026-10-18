#!/bin/sh
# Makes the update feed for the current VERSION and, with --publish, the GitHub release the app updates from.
#   ./package.sh && ./release.sh            -> dist/appcast.xml (signed) for dist/PhotoLab-<version>-macOS.zip
#   ./release.sh --publish                  -> rebuild from HEAD, then tag v<version>, push it, create the release
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
  git -C "$ROOT" fetch -q origin main
  [ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] \
    || { echo "HEAD is not the pushed origin/main" >&2; exit 1; }
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "tag $TAG exists" >&2; exit 1; fi
  ./package.sh                                         # clean build of exactly this commit
fi
[ -f "$ZIP" ] || { echo "missing $ZIP (run ./package.sh first)" >&2; exit 1; }
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
[ -x "$TOOLS/generate_appcast" ] || { echo "missing Sparkle tools (run swift package resolve)" >&2; exit 1; }

STAGE=".build/appcast"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$ZIP" "$STAGE/"
# Release notes shown in the update dialog: this version's section of CHANGELOG.md.
awk -v v="$VERSION" '
  index($0, "## " v " ") == 1 { on = 1; next }
  on && /^## / { exit }
  on { print }
' "$ROOT/CHANGELOG.md" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' > "$STAGE/notes.txt"
[ -s "$STAGE/notes.txt" ] || { echo "no CHANGELOG.md section for $VERSION" >&2; exit 1; }
{ echo "<pre style=\"white-space: pre-wrap; font: 13px -apple-system\">"; cat "$STAGE/notes.txt"; echo "</pre>"; } \
  > "$STAGE/PhotoLab-$VERSION-macOS.html"
rm "$STAGE/notes.txt"

"$TOOLS/generate_appcast" --account photo-lab \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes "$STAGE"
cp "$STAGE/appcast.xml" "$ROOT/dist/appcast.xml"
echo "appcast: $ROOT/dist/appcast.xml"

if [ "$PUBLISH" = 1 ]; then
  git -C "$ROOT" tag -a "$TAG" -m "Photo_Lab $VERSION"
  git -C "$ROOT" push origin "$TAG"
  awk -v v="$VERSION" '
    index($0, "## " v " ") == 1 { on = 1; next }
    on && /^## / { exit }
    on { print }
  ' "$ROOT/CHANGELOG.md" > "$STAGE/release-notes.md"
  cat >> "$STAGE/release-notes.md" <<'NOTES'

**Install (macOS 14+):** unzip, move `PhotoLab.app` to Applications, first start: right-click → Open (ad-hoc signed, not notarized).
Already on 1.1.0 or later: Photo_Lab → 檢查更新… installs this version.
Brand logos and fonts are not included: see Help → 自備品牌 logo 與字體… in the app, or the README.
NOTES
  gh release create "$TAG" "$ZIP" "$ROOT/dist/appcast.xml" --repo "$REPO" --title "Photo_Lab $VERSION" \
    --notes-file "$STAGE/release-notes.md" --latest
fi
