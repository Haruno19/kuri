#!/bin/bash
# Builds Kuri in Release and packs it into build/release/Kuri-<version>.dmg:
# the app and a link to Applications on a still frame of the meadow.
#
#   Release/make-dmg.sh
#
# Without a Developer ID the app keeps Xcode's ad-hoc signature: it runs, but
# people who download it have to allow it once (README, Install). With one,
# set both of these and the app and the image are signed and notarized:
#
#   KURI_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   KURI_NOTARY_PROFILE=kuri   # from: xcrun notarytool store-credentials kuri
#
# KURI_DMG_SEED picks another tree for the background.
#
# Finder lays out the window (AppleScript is the only way Apple offers), so
# the first run asks to let the terminal control Finder, and a Finder window
# opens and closes while it works.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
VOLUME="Kuri"
SEED="${KURI_DMG_SEED:-1}"
# The window and icon positions match Layout in Background.swift.
WIDTH=640 HEIGHT=428 ICON_SIZE=112
APP_POSITION="170, 150" APPLICATIONS_POSITION="470, 150"
# Finder's window bounds include its title bar.
TITLE_BAR=32

step() { printf '\n==> %s\n' "$*"; }

if [ -d "/Volumes/$VOLUME" ]; then
    echo "A volume named $VOLUME is mounted; eject it first." >&2
    exit 1
fi
rm -rf "$OUT/stage" "$OUT/work"
mkdir -p "$OUT/stage/.background" "$OUT/work"

step "Building Kuri (Release, Apple silicon)"
# Apple silicon only: the sandbox (Virtualization) and Apple's on-device
# model need it, and an Intel slice would double the download.
xcodebuild -project "$ROOT/Kuri.xcodeproj" -scheme Kuri -configuration Release \
    -destination 'generic/platform=macOS' ARCHS=arm64 \
    -derivedDataPath "$OUT/DerivedData" -quiet build
APP="$OUT/DerivedData/Build/Products/Release/Kuri.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/Kuri-$VERSION.dmg"

if [ -n "${KURI_SIGN_IDENTITY:-}" ]; then
    step "Signing with $KURI_SIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/App/Kuri.entitlements" --sign "$KURI_SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

step "Drawing the background"
sed '/^\/\/ MARK: - The strip/,$d' "$ROOT/App/Views/Meadow.swift" > "$OUT/work/Meadow.swift"
swiftc -O -parse-as-library -swift-version 6 \
    "$OUT/work/Meadow.swift" "$ROOT/Release/Background.swift" -o "$OUT/work/Background"
"$OUT/work/Background" "$SEED" "$OUT/work/background.png" 1
"$OUT/work/Background" "$SEED" "$OUT/work/background@2x.png" 2
# One file with both sizes: Finder picks the one for the display.
tiffutil -cathidpicheck "$OUT/work/background.png" "$OUT/work/background@2x.png" \
    -out "$OUT/stage/.background/background.tiff" 2>/dev/null

step "Laying out the disk image"
ditto "$APP" "$OUT/stage/Kuri.app"
ln -s /Applications "$OUT/stage/Applications"
SIZE_MB=$(( $(du -sm "$OUT/stage" | cut -f1) + 20 ))
hdiutil create -quiet -srcfolder "$OUT/stage" -volname "$VOLUME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" "$OUT/work/rw.dmg"
hdiutil attach -quiet -noverify -noautoopen "$OUT/work/rw.dmg"

osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        -- The path bar and status bar are Finder-wide settings, not the
        -- window's: setting them here would change the user's Finder and
        -- not the image. Someone who shows the path bar sees it over the grass.
        set toolbar visible of container window to false
        set the bounds of container window to {200, 120, 200 + $WIDTH, 120 + $HEIGHT + $TITLE_BAR}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Kuri.app" of container window to {$APP_POSITION}
        set position of item "Applications" of container window to {$APPLICATIONS_POSITION}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# Finder writes .DS_Store when it likes; give it a moment, then let go.
sync
sleep 2
for attempt in 1 2 3 4 5; do
    hdiutil detach -quiet "/Volumes/$VOLUME" && break
    [ "$attempt" = 5 ] && hdiutil detach -force "/Volumes/$VOLUME"
    sleep 2
done

step "Compressing"
rm -f "$DMG"
hdiutil convert -quiet "$OUT/work/rw.dmg" -format ULFO -o "$DMG"

if [ -n "${KURI_SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$KURI_SIGN_IDENTITY" "$DMG"
    if [ -n "${KURI_NOTARY_PROFILE:-}" ]; then
        step "Notarizing (a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$KURI_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

rm -rf "$OUT/stage" "$OUT/work"
step "Done"
echo "$DMG"
shasum -a 256 "$DMG"
