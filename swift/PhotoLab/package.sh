#!/bin/sh
# Builds the release app and packs it as dist/PhotoLab.app + dist/PhotoLab-<version>-macOS.zip.
# The app is signed ad hoc (no developer account needed); on another Mac the first start needs right-click > Open.
# Brand logos and fonts are never bundled (trademarks / licences): the app reads them from
# ~/Library/Application Support/Photo_Lab/{logos,fonts}.
set -eu
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
case "$VERSION" in *[!0-9.]*|"") echo "bad VERSION: $VERSION" >&2; exit 1 ;; esac

swift build -c release
BIN=".build/release/PhotoLab"
[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 1; }

DIST="$ROOT/dist"
APP="$DIST/PhotoLab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoLab"
cp "$ROOT/assets/PhotoLab.icns" "$APP/Contents/Resources/PhotoLab.icns"
cp "$ROOT/assets/icon_1024.png" "$APP/Contents/Resources/icon_1024.png"
cp "$ROOT/VERSION" "$APP/Contents/Resources/VERSION"

# Your own brand logos / fonts (they are not in git) are packed into this local build so the logos show up.
# Do not hand such a zip to other people: the logos are trademarks and the fonts have their own licences.
mkdir -p "$APP/Contents/Resources/logos" "$APP/Contents/Resources/fonts"
for f in "$ROOT"/logos/*.png; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/logos/"; done
for f in "$ROOT"/fonts/*.ttf "$ROOT"/fonts/*.otf "$ROOT"/fonts/*.ttc; do
  [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/fonts/"
done
echo "logos packed: $(ls "$APP/Contents/Resources/logos" | wc -l | tr -d ' ')"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Photo_Lab</string>
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
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

ZIP="$DIST/PhotoLab-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "built: $APP"
echo "zip:   $ZIP"
