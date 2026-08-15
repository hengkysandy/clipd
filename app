#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"          # resolve own location, so it runs from anywhere

APP_NAME="ClipdMac"
INSTALLED="/Applications/Clipd.app"
DERIVED="$PWD/.build/xcode"
BUNDLE_ID="com.hengkysandy.clipd.mac"

# The signing identity is machine specific, so it lives in a gitignored file.
#
# This is NOT the usual "fall back to ad-hoc so anyone can build it" pattern,
# and the difference matters. Measured on this project: under ad-hoc signing
# the CDHash changes on every build, macOS drops the Accessibility permission
# with it, and the app then looks healthy while pasting nothing. So the
# fallback is loud rather than silent.
SIGNING=()
if [ -f .app-signing ]; then
  IDENTITY="$(cat .app-signing)"
  SIGNING=("CODE_SIGN_IDENTITY=$IDENTITY" CODE_SIGN_STYLE=Manual)
else
  echo "############################################################"
  echo "WARNING: no .app-signing file, falling back to ad-hoc."
  echo "The app WILL build and WILL launch, and pasting will be"
  echo "silently broken after the next rebuild, because macOS ties"
  echo "the Accessibility permission to the code signature."
  echo ""
  echo "Fix, once:"
  echo "  security find-identity -v -p codesigning"
  echo "  echo 'Apple Development: you@example.com (TEAMID)' > .app-signing"
  echo "############################################################"
fi

case "${1:-}" in
  up)
    xcodegen generate
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
               -configuration Debug -derivedDataPath "$DERIVED" \
               "${SIGNING[@]}" build
    # Install to /Applications and launch from there. The build folder sits
    # inside a dot-folder Finder will not show in the Accessibility picker,
    # and a clean build deletes it, which silently invalidates the grant.
    # Renaming to Clipd.app is safe: the permission follows the bundle
    # identifier and certificate, not the path or the file name.
    pkill -f "$APP_NAME" 2>/dev/null || true
    rm -rf "$INSTALLED"
    cp -R "$DERIVED/Build/Products/Debug/$APP_NAME.app" "$INSTALLED"
    open "$INSTALLED"
    echo "installed and launched $INSTALLED"
    ;;
  test)
    echo "=== Core tests (fast, no app, no permissions) ==="
    swift test
    echo "=== Shell tests ==="
    xcodegen generate
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
               -derivedDataPath "$DERIVED" "${SIGNING[@]}" test
    ;;
  dmg)
    # Builds a Release .app and wraps it in a DMG with a drag-to-Applications
    # target. Rejected: shipping the Debug build, which carries assertions and
    # is slower for no benefit to the person installing it.
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
              "$DERIVED/Build/Products/Release/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "0.1.0")
    xcodegen generate
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
               -configuration Release -derivedDataPath "$DERIVED" \
               "${SIGNING[@]}" build
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
              "$DERIVED/Build/Products/Release/$APP_NAME.app/Contents/Info.plist")

    rm -rf dist && mkdir -p dist/stage
    cp -R "$DERIVED/Build/Products/Release/$APP_NAME.app" "dist/stage/Clipd.app"
    # The symlink is what makes the window a drag-and-drop installer.
    ln -s /Applications "dist/stage/Applications"

    hdiutil create -volname "Clipd $VERSION" -srcfolder dist/stage \
                   -ov -format UDZO "dist/Clipd-$VERSION.dmg" >/dev/null
    echo "built dist/Clipd-$VERSION.dmg"
    echo ""
    echo "NOTE: signed with an Apple Development certificate, which cannot be"
    echo "notarised on a free account. On another Mac, Gatekeeper will refuse to"
    echo "open it until quarantine is cleared:"
    echo "  xattr -dr com.apple.quarantine /Applications/Clipd.app"
    codesign -dv --verbose=2 "dist/stage/Clipd.app" 2>&1 | grep -E '^(Identifier|Signature)'
    ;;
  sig)
    # The A9 check. The designated requirement must contain identifier and
    # certificate, and must NOT contain a cdhash. If it does, rebuilds will
    # silently break pasting.
    codesign -dv --verbose=4 "$INSTALLED" 2>&1 | grep -E '^(Identifier|CDHash|Signature)'
    codesign -d --requirements - "$INSTALLED" 2>&1 | grep designated
    ;;
  trust)
    # Clears a stale Accessibility entry. Needed when the signing identity
    # changes, because the old row stays in System Settings, still switched
    # on, and no longer matches the new signature.
    tccutil reset Accessibility "$BUNDLE_ID"
    echo "Accessibility reset. Relaunch and grant again."
    ;;
  *)
    echo "usage: ./app {up|test|dmg|sig|trust}"
    exit 1
    ;;
esac
