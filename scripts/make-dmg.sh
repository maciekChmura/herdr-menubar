#!/usr/bin/env bash
# Builds the Release version of herdr-menubar and packs it into a disk image for downloading:
# build/HerdrMenubar-<version>.dmg, with the app and a link to /Applications to drag it onto.
#
# The app is always ad-hoc signed here, even if Config/Local.xcconfig names your own certificate,
# so the image doesn't carry your name or team ID. It isn't notarized, so on first launch macOS
# blocks it until the user allows it in System Settings → Privacy & Security.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="HerdrMenubar.app"
BUILT="build/Build/Products/Release/$APP_NAME"
LOG="build/make-dmg.log"

echo "Generating the Xcode project…"
xcodegen generate --quiet

echo "Building the Release version…"
mkdir -p build
if ! xcodebuild -scheme HerdrMenubar -configuration Release -derivedDataPath build \
        CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build > "$LOG" 2>&1; then
    echo "The build failed. Errors from ${LOG}:" >&2
    grep -E "error:" "$LOG" >&2 || tail -20 "$LOG" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
DMG="build/HerdrMenubar-$VERSION.dmg"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
chmod 755 "$STAGING"   # mktemp makes it private, and the image's root folder would inherit that.
ditto "$BUILT" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"

echo "Creating ${DMG}…"
rm -f "$DMG"
# `diskutil image` replaces `hdiutil create` on newer macOS; older versions only have hdiutil.
if diskutil image create from --help > /dev/null 2>&1; then
    create=(diskutil image create from --format ULFO --volumeName "herdr-menubar $VERSION" "$STAGING" "$DMG")
else
    create=(hdiutil create -volname "herdr-menubar $VERSION" -srcfolder "$STAGING" -format ULFO "$DMG")
fi
if ! "${create[@]}" >> "$LOG" 2>&1; then
    echo "Creating the disk image failed. The end of ${LOG}:" >&2
    tail -10 "$LOG" >&2
    exit 1
fi

echo "Done: $DMG"
