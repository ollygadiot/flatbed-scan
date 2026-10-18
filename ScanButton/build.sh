#!/bin/zsh
# Build ScanButton.app into ~/Applications, register it with LaunchServices, and start it.
set -euo pipefail

here=${0:A:h}
script=${here:h}/scan.sh
app="$HOME/Applications/ScanButton.app"

pkill -x ScanButton 2>/dev/null || true
pkill -f "process == .EPSON Scanner 2. AND eventMessage" 2>/dev/null || true  # its log watcher
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

swiftc -O "$here/main.swift" -o "$app/Contents/MacOS/ScanButton"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.epson.EventManager</string>
  <key>CFBundleName</key><string>ScanButton</string>
  <key>CFBundleExecutable</key><string>ScanButton</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>ScanScript</key><string>$script</string>
</dict>
</plist>
EOF

codesign --force --sign - "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
open "$app"
print "ScanButton running; logs: log stream --predicate 'subsystem == \"local.scanbutton\"'"
