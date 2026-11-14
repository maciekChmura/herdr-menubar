#!/usr/bin/env bash
# Builds the Release version of herdr-menubar, installs it to /Applications and launches it from there.
# Run it again after pulling changes to update the installed copy.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="HerdrMenubar.app"
BUNDLE_ID="io.github.maciekchmura.HerdrMenubar"
BUILT="build/Build/Products/Release/$APP_NAME"
DEST="/Applications/$APP_NAME"
LOG="build/install.log"

# Never replace something that isn't this app.
if [[ -e "$DEST" ]]; then
    existing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$existing" != "$BUNDLE_ID" ]]; then
        echo "$DEST exists but isn't herdr-menubar (bundle ID: ${existing:-unknown}). Leaving it alone." >&2
        exit 1
    fi
fi

echo "Generating the Xcode project…"
xcodegen generate --quiet

echo "Building the Release version…"
mkdir -p build
if ! xcodebuild -scheme HerdrMenubar -configuration Release -derivedDataPath build build > "$LOG" 2>&1; then
    echo "The build failed. Errors from ${LOG}:" >&2
    grep -E "error:" "$LOG" >&2 || tail -20 "$LOG" >&2
    exit 1
fi

echo "Quitting running copies…"
pkill -x HerdrMenubar || true
for _ in {1..20}; do
    pgrep -x HerdrMenubar > /dev/null || break
    sleep 0.25
done

echo "Installing to ${DEST}…"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

# LaunchServices sometimes refuses to open an app right after its previous copy quit (error -600), so retry.
for attempt in 1 2 3; do
    open "$DEST" && break
    if [[ $attempt == 3 ]]; then
        echo "Couldn't launch ${DEST}. Open it from Finder." >&2
        exit 1
    fi
    sleep 1
done

echo "Done: $DEST is installed and running."
echo "To start it at login, open its menu and turn on \"Launch at login\"."
