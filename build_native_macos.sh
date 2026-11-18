#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# NativeApp/AppIcon.png is the 1024x1024 master icon, including its transparent
# rounded corners. Keep its alpha channel when producing the App Store sizes.
for dimension in 16 32 64 128 256 512 1024; do
  sips -z "$dimension" "$dimension" "$ROOT/NativeApp/AppIcon.png" \
    --out "$ROOT/NativeApp/Assets.xcassets/AppIcon.appiconset/icon_${dimension}.png" >/dev/null
done
xcodebuild -project "$ROOT/NativeApp/NXManager.xcodeproj" \
  -scheme NXManager -configuration Release -sdk macosx \
  -derivedDataPath "$ROOT/build/native" CODE_SIGNING_ALLOWED=NO build
mkdir -p "$ROOT/dist"
ditto "$ROOT/build/native/Build/Products/Release/NXManager.app" "$ROOT/dist/NXManager.app"
mkdir -p "$ROOT/dist/NXManager.app/Contents/Resources"
xcrun actool --compile "$ROOT/dist/NXManager.app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --target-device mac --output-format human-readable-text \
  --output-partial-info-plist "$ROOT/build/native/AppIconInfo.plist" \
  "$ROOT/NativeApp/Assets.xcassets"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' \
  -c 'Add :CFBundleIconName string AppIcon' \
  "$ROOT/dist/NXManager.app/Contents/Info.plist"
codesign --force --deep --sign - "$ROOT/dist/NXManager.app"
echo "Application created: $ROOT/dist/NXManager.app"
