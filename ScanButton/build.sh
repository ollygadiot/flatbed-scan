#!/bin/zsh
# Build ScanButton.app into ~/Applications, register it with LaunchServices, and
# run it as a LaunchAgent (starts at login, restarts if it crashes).
set -euo pipefail

here=${0:A:h}
script=${here:h}/scan.sh
app="$HOME/Applications/ScanButton.app"
label="local.scanbutton"
agent="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

# Stop any running copy: the agent (launchd also kills its log watcher), then strays.
launchctl bootout "$domain/$label" 2>/dev/null || true
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

mkdir -p "${agent:h}"
cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/ScanButton</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap "$domain" "$agent"

print "ScanButton running as LaunchAgent $label"
print "logs:      log stream --predicate 'subsystem == \"$label\"'"
print "uninstall: launchctl bootout $domain/$label && rm $agent"
