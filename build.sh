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
# 发布用固定的自签名证书签名：macOS 按“同一个证书 + 同一个 Bundle ID”认出是同一个 App，
# 日历、提醒事项、蓝牙、通知的授权在更新后才会保留，自动更新也只接受这个证书签的新版本。
# 证书只在发布者的钥匙串里；没有时（比如 CI 或别人自己编译）退回临时签名。
IDENTITY="${NOTCHDECK_SIGN_IDENTITY:-NotchDeck Self-Signed Code Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad hoc (no \"$IDENTITY\" certificate in the keychain)"
fi
echo "Built $APP"
