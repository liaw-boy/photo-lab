#!/bin/sh
# Builds the release app and packs it as dist/PhotoLab.app + a zip.
#   ./package.sh              clean build  -> dist/PhotoLab-<version>-macOS.zip  (the one to publish)
#   ./package.sh --with-logos personal build with your own logos/ and fonts/ packed in
#                             -> dist/PhotoLab-<version>-macOS-with-logos.zip  (do not hand it to others)
# The app is signed ad hoc (no developer account needed); on another Mac the first start needs right-click > Open.
# A clean build reads logos / fonts from ~/Library/Application Support/Photo_Lab/{logos,fonts}.
set -eu
WITH_LOGOS=0
case "${1:-}" in
  "") ;;
  --with-logos) WITH_LOGOS=1 ;;
  *) echo "usage: $0 [--with-logos]" >&2; exit 2 ;;
esac
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
case "$VERSION" in *[!0-9.]*|"") echo "bad VERSION: $VERSION" >&2; exit 1 ;; esac

# Updates: the feed is the appcast.xml attached to the latest GitHub release (see release.sh). The public key is
# not secret; the private one stays in the login keychain (account "photo-lab") and signs every release.
FEED_URL="https://github.com/liaw-boy/photo-lab/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="/fpsoD6DsSueBfw+aI9mEOZZQp4CTSRmRV4II7urvvY="

swift build -c release
BIN=".build/release/PhotoLab"
[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }

DIST="$ROOT/dist"
APP="$DIST/PhotoLab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoLab"
# Sparkle (updates): the framework goes to Contents/Frameworks, found through an rpath added to the executable.
mkdir -p "$APP/Contents/Frameworks"
ditto ".build/release/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PhotoLab"
# Drop the build machine's rpaths (Xcode toolchain, cryptex mounts): folders outside the bundle that another
# program could fill with a fake Sparkle.framework. Only the system Swift runtime and the bundle remain.
otool -l "$APP/Contents/MacOS/PhotoLab" | awk '$1 == "cmd" { rp = ($2 == "LC_RPATH") } rp && $1 == "path" { print $2 }' |
  while IFS= read -r p; do
    case "$p" in @*|/usr/lib/swift) ;; *) install_name_tool -delete_rpath "$p" "$APP/Contents/MacOS/PhotoLab" ;; esac
  done
cp "$ROOT/assets/PhotoLab.icns" "$APP/Contents/Resources/PhotoLab.icns"
cp "$ROOT/assets/icon_1024.png" "$APP/Contents/Resources/icon_1024.png"
cp "$ROOT/VERSION" "$APP/Contents/Resources/VERSION"

if [ "$WITH_LOGOS" = 1 ]; then
  # Your own brand logos / fonts (they are not in git). Trademarks and font licences: keep such a zip to yourself.
  mkdir -p "$APP/Contents/Resources/logos" "$APP/Contents/Resources/fonts"
  for f in "$ROOT"/logos/*.png; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/logos/"; done
  for f in "$ROOT"/fonts/*.ttf "$ROOT"/fonts/*.otf "$ROOT"/fonts/*.ttc; do
    [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/fonts/"
  done
fi
xattr -cr "$APP"      # no download origin / quarantine / other extended attributes of the source files
echo "logos packed: $(ls "$APP/Contents/Resources/logos" 2>/dev/null | wc -l | tr -d ' ')"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Photo_Lab</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>CFBundleDisplayName</key><string>Photo_Lab</string>
  <key>CFBundleIdentifier</key><string>app.photolab.PhotoLab</string>
  <key>CFBundleExecutable</key><string>PhotoLab</string>
  <key>CFBundleIconFile</key><string>PhotoLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SURequireSignedFeed</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict>
</plist>
PLIST

# Hardened runtime: DYLD_* environment variables are ignored, so nothing can be injected at launch.
# Sparkle (with its helper apps) is signed first, then the app with its entitlements (not passed down).
codesign --force --deep --options runtime --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --entitlements PhotoLab.entitlements --sign - "$APP"
codesign --verify --deep --strict "$APP"

SUFFIX=""; [ "$WITH_LOGOS" = 1 ] && SUFFIX="-with-logos"
ZIP="$DIST/PhotoLab-$VERSION-macOS$SUFFIX.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "built: $APP"
echo "zip:   $ZIP"
