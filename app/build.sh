#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="OrthoControl"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "Done! App bundle created at: $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "To install: cp -r $APP_BUNDLE /Applications/"
