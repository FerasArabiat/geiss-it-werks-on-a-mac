#!/bin/zsh
# Builds "Geiss It Werks on a Mac.app" (release, Apple Silicon) into
# build/, signs it, and zips it for a GitHub release.
#
# Usage: scripts/build-app.sh [--notarize]
#   --notarize                    also have Apple notarize the app and staple
#                                 the ticket, so downloads open without
#                                 warnings (needs the one-time setup in
#                                 README.md › Releasing)
#   GEISSMAC_BUNDLE_ID=...        override the bundle identifier
#   GEISSMAC_SIGN_IDENTITY=...    override the signing identity
#   GEISSMAC_NOTARY_PROFILE=...   notarytool keychain profile (geiss-notary)
set -euo pipefail

NOTARIZE=false
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=true

cd "$(dirname "$0")/.."
APP_NAME="Geiss It Werks on a Mac"
BUNDLE_ID="${GEISSMAC_BUNDLE_ID:-com.ferasarabiat.GeissItWerksOnaMac}"
VERSION="1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

SWIFT_FLAGS=(-c release --arch arm64)
swift build "${SWIFT_FLAGS[@]}" --product GeissMac
swift build "${SWIFT_FLAGS[@]}" --product NowPlayingHelper
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GeissMac" "$APP/Contents/MacOS/GeissMac"
# Loaded from the main bundle at runtime (see MetalRenderer.buildPipelines).
cp Sources/GeissMac/Renderer/Shaders.metal "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Run inside /usr/bin/perl by TrackWatcher (see Sources/NowPlayingHelper).
cp "$BIN_DIR/libNowPlayingHelper.dylib" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>GeissMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>${APP_NAME} listens to the audio playing on your Mac to animate its visuals. The sound is analyzed live and never recorded or saved.</string>
</dict>
</plist>
PLIST

# Signing identity: Developer ID Application (the one Apple notarizes), else
# Apple Development, else ad-hoc. macOS ties permissions to the app's code
# identity: an ad-hoc signature changes with every build, so they would have
# to be granted again after each rebuild; a certificate's stays stable.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
find_identity() { print -r -- "$IDENTITIES" | sed -n "s/.*\"\($1: [^\"]*\)\".*/\1/p" | head -1; }
IDENTITY="${GEISSMAC_SIGN_IDENTITY:-$(find_identity "Developer ID Application")}"
[[ -z "$IDENTITY" ]] && IDENTITY="$(find_identity "Apple Development")"

# The hardened runtime (with the entitlements it needs) always, so local
# builds behave like released ones; a secure timestamp for Developer ID,
# as notarization requires.
SIGN=(codesign --force --sign "${IDENTITY:--}" --options runtime)
[[ "$IDENTITY" == "Developer ID Application:"* ]] && SIGN+=(--timestamp)
"${SIGN[@]}" "$APP/Contents/Resources/libNowPlayingHelper.dylib"
"${SIGN[@]}" --entitlements Resources/GeissMac.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc (permissions must be re-granted after each rebuild)}"

# The file to attach to a GitHub release (ditto keeps the bundle intact).
ZIP="build/Geiss-It-Werks-on-a-Mac-${VERSION}.zip"
rm -f "$ZIP"

if $NOTARIZE; then
    if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
        echo "--notarize needs a Developer ID Application certificate (README.md › Releasing)." >&2
        exit 1
    fi
    PROFILE="${GEISSMAC_NOTARY_PROFILE:-geiss-notary}"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Submitting to Apple's notary service (usually a few minutes)..."
    RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1)" || true
    print -r -- "$RESULT"
    if ! print -r -- "$RESULT" | grep -q "status: Accepted"; then
        echo "Notarization failed. Details: xcrun notarytool log <submission id> --keychain-profile $PROFILE" >&2
        exit 1
    fi
    # Attach the ticket to the app so it opens even offline, then zip that.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $(pwd)/$APP"
echo "Release zip: $(pwd)/$ZIP"
if $NOTARIZE; then
    spctl --assess --type execute --verbose "$APP"
fi
