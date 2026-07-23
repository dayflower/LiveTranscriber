#!/bin/bash
# Build the SwiftPM executable and wrap it into LiveTranscriber.app.
#
# TCC permissions (Microphone, Screen & System Audio Recording, Calendars) are
# attributed to a bundle identifier, so the binary must run from an .app
# bundle — never launch via `swift run` when testing permission-gated features.
#
# Signing: defaults to ad-hoc (`-`). Ad-hoc signatures change the CDHash on
# every rebuild, which can make macOS drop TCC grants (Screen Recording in
# particular needs a manual re-toggle). To keep grants stable across rebuilds,
# create a self-signed code-signing certificate in Keychain Access and pass it
# via SIGN_ID:
#
#   SIGN_ID="My Dev Cert" ./scripts/make-app.sh
#
# Usage:
#   ./scripts/make-app.sh [--debug] [--run]
#     --debug  build the debug configuration (default: release)
#     --run    open the app after building

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="LiveTranscriber"
BUNDLE_ID="io.github.dayflower.live-transcriber"
# Executable product name (Package.swift); also the app-menu title under
# `swift run`, hence distinct from the LiveTranscriberApp target name.
EXECUTABLE_PRODUCT="LiveTranscriber"
VERSION="0.1.0"
SIGN_ID="${SIGN_ID:--}"

CONFIGURATION="release"
OPEN_AFTER_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIGURATION="debug" ;;
        --run) OPEN_AFTER_BUILD=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Build with the Swift Build system: it compiles Assets.xcassets into a proper
# resource bundle (Assets.car + Info.plist), which the native build system does
# not — see notes/DEVELOP.md.
BUILD_SYSTEM=(--build-system swiftbuild)

swift build "${BUILD_SYSTEM[@]}" -c "$CONFIGURATION"

BIN_DIR="$(swift build "${BUILD_SYSTEM[@]}" -c "$CONFIGURATION" --show-bin-path)"
BIN_PATH="$BIN_DIR/$EXECUTABLE_PRODUCT"
APP_DIR="build/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundle (tray icon, etc.). The Swift Build system already
# compiled it into Contents/Resources/Assets.car with a generated Info.plist;
# Bundle.module resolves it via Bundle.main.resourceURL, so it must live in
# Contents/Resources.
RESOURCE_BUNDLE="live-transcriber_LiveTranscriberApp.bundle"
if [[ -d "$BIN_DIR/$RESOURCE_BUNDLE" ]]; then
    cp -R "$BIN_DIR/$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE"
fi

if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Note: Screen Recording has no Info.plist usage-description key; the Screen &
# System Audio Recording prompt is triggered at first ScreenCaptureKit access.
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>LiveTranscriber captures your microphone to transcribe speech in real time. Audio is never saved.</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>LiveTranscriber reads your calendar events to suggest session names and durations.</string>
	<key>NSCalendarsUsageDescription</key>
	<string>LiveTranscriber reads your calendar events to suggest session names and durations.</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>LiveTranscriber transcribes captured audio on-device.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_ID" \
    --entitlements scripts/entitlements.plist \
    "$APP_DIR"

echo "built: $APP_DIR (configuration: $CONFIGURATION, signing: $SIGN_ID)"

if [[ "$OPEN_AFTER_BUILD" -eq 1 ]]; then
    open "$APP_DIR"
fi
