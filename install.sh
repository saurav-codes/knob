#!/bin/bash
# Builds Knob into ~/Applications, starts it at login, and restarts it.
set -euxo pipefail
cd "$(dirname "$0")"
app="$HOME/Applications/Knob.app"
label=io.github.saurav-codes.knob
agent="$HOME/Library/LaunchAgents/$label.plist"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"

iconset=$(mktemp -d)/Knob.iconset
mkdir "$iconset"
swift Icon.swift "$iconset/icon_512x512@2x.png"
for px in 16 32 128 256 512; do
  sips -z $px $px "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Knob.icns"
swiftc -O Knob.swift -o "$app/Contents/MacOS/Knob"
codesign -s - --force "$app"

cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$app/Contents/MacOS/Knob</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST
# Load the agent fresh, so a changed plist takes effect. KeepAlive restarts Knob after a crash, not after Quit.
if launchctl bootout "gui/$(id -u)/$label" 2>/dev/null; then
  while launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; do sleep 0.1; done
fi
launchctl bootstrap "gui/$(id -u)" "$agent"
