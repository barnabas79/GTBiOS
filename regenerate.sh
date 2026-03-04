#!/bin/bash
# Xcode projekt újragenerálása Xcode 14.2-kompatibilis formátumban.
# Az xcodegen 2.44.1 objectVersion=77-et ír (Xcode 15+),
# ezt kézzel 56-ra javítjuk (Xcode 14.x).

set -e

XCODEGEN=/tmp/xcodegen_bin/xcodegen/bin/xcodegen
XCODEGEN_SHARE=/tmp/xcodegen_bin/xcodegen/share/xcodegen

echo "⚙️  Generálás..."
rm -rf GTBiOS.xcodeproj
XCODEGEN_SHARE_PATH="$XCODEGEN_SHARE" "$XCODEGEN" generate

echo "🔧  objectVersion javítása (77 → 56, Xcode 14.2 kompatibilis)..."
sed -i '' 's/objectVersion = 77/objectVersion = 56/' GTBiOS.xcodeproj/project.pbxproj

echo "✅  Kész: GTBiOS.xcodeproj"
open GTBiOS.xcodeproj
