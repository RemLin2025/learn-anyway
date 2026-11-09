#!/usr/bin/env bash
# Build a release CramLab.app and install it into /Applications (or ~/Applications if that isn't writable).
# Safe to re-run. User data lives in ~/Library/Application Support and is never touched.
# Usage: scripts/install-macos.sh [--no-launch]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NAME="Learn Anyway"                 # name shown in Finder, Launchpad, Spotlight, Dock and the menu bar
EXE=Braincell                        # executable / module name (unchanged by design)
STAGE=$ROOT/.build-manual/dist/$NAME.app

# 1. Release build
CONFIG=release scripts/build.sh app
BUILT=$ROOT/.build-manual/out-release/Braincell.app/Contents

# 2. Assemble the bundle
ICON=$ROOT/scripts/icon/AppIcon.icns
if [ ! -f "$ICON" ]; then
  echo "» Generating placeholder icon"
  TMP=$(mktemp -d); SET=$TMP/AppIcon.iconset
  OV=(); [ -f .build-manual/overlay.yaml ] && OV=(-vfsoverlay .build-manual/overlay.yaml)  # same toolchain workaround as build.sh
  swiftc "${OV[@]}" scripts/icon/make-icon.swift -o "$TMP/make-icon" && "$TMP/make-icon" "$SET" && iconutil -c icns "$SET" -o "$ICON"
fi
rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILT/MacOS/$EXE" "$STAGE/Contents/MacOS/$EXE"
cp Sources/BraincellApp/Info.plist "$STAGE/Contents/Info.plist"
cp "$ICON" "$STAGE/Contents/Resources/AppIcon.icns"
PB=/usr/libexec/PlistBuddy; PL=$STAGE/Contents/Info.plist
$PB -c "Set :CFBundleName $NAME" "$PL"
$PB -c "Add :CFBundleDisplayName string $NAME" "$PL"
$PB -c "Add :CFBundleIconFile string AppIcon" "$PL"
$PB -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PL"
$PB -c "Add :CFBundleDevelopmentRegion string en" "$PL"
$PB -c "Add :CFBundleVersion_build string 0" "$PL" >/dev/null 2>&1 && $PB -c "Delete :CFBundleVersion_build" "$PL" || true
$PB -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$PL"
chmod 755 "$STAGE/Contents/MacOS/$EXE"
codesign --force --deep --sign - "$STAGE"   # ad-hoc: enough for a local, personal app
plutil -lint "$PL" >/dev/null
codesign --verify --deep --strict "$STAGE"

# 3. Install
DEST_DIR=/Applications
[ -w "$DEST_DIR" ] || { DEST_DIR=$HOME/Applications; mkdir -p "$DEST_DIR"; echo "! /Applications not writable; installing to $DEST_DIR"; }
DEST=$DEST_DIR/$NAME.app
if pgrep -x "$EXE" >/dev/null; then
  echo "» Quitting running $NAME"; osascript -e "tell application id \"app.braincell.Braincell\" to quit" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$EXE" >/dev/null || break; sleep 0.5; done
  pgrep -x "$EXE" >/dev/null && { echo "✗ $NAME is still running; quit it and re-run."; exit 1; }
fi
NEW=$DEST_DIR/.$NAME.new.app; OLD=$DEST_DIR/.$NAME.old.app
rm -rf "$NEW" "$OLD"
ditto "$STAGE" "$NEW"
[ -d "$DEST" ] && mv "$DEST" "$OLD"
mv "$NEW" "$DEST"
rm -rf "$OLD"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
touch "$DEST"

echo "✓ Installed $DEST  (version $($PB -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist"))"
echo "  Data: ~/Library/Application Support/Braincell (untouched)"
[ "${1:-}" = "--no-launch" ] || open "$DEST"
