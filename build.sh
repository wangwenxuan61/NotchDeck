#!/bin/bash
# 编译并打包成 build/NotchDeck.app，只需要 Xcode Command Line Tools。
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product NotchDeck

APP="build/NotchDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/NotchDeck" "$APP/Contents/MacOS/NotchDeck"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
