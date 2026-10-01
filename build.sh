#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Vibemeter.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13.0" Sources/*.swift -o "build/Vibemeter-$arch"
done
lipo -create build/Vibemeter-* -output "$APP/Contents/MacOS/Vibemeter"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Vibemeter || true
    rm -rf /Applications/Vibemeter.app
    cp -R "$APP" /Applications/
    open /Applications/Vibemeter.app
fi

if [[ "${1:-}" == "--dmg" ]]; then
    mkdir build/dmg && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
    hdiutil create -volname Vibemeter -srcfolder build/dmg -format UDZO -ov build/Vibemeter.dmg
fi
