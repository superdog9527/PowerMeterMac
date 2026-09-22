#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
cd "$project_dir"
swift build -c release --product PowerMeterMac
app="$project_dir/dist/Power Meter.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
chmod u+w "$app/Contents/Frameworks/libusb-1.0.0.dylib" 2>/dev/null || true
cp "$project_dir/.build/release/PowerMeterMac" "$app/Contents/MacOS/PowerMeterMac"
cp "$project_dir/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib "$app/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -change /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib @executable_path/../Frameworks/libusb-1.0.0.dylib "$app/Contents/MacOS/PowerMeterMac"
codesign --force --deep --sign - "$app"
echo "$app"
