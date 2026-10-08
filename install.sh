#!/bin/bash
# Builds Knob into ~/Applications, starts it at login, and restarts it.
set -euxo pipefail
cd "$(dirname "$0")"
app="$HOME/Applications/Knob.app"
label=io.github.saurav-codes.knob
agent="$HOME/Library/LaunchAgents/$label.plist"

mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/"
swiftc -O Knob.swift -o "$app/Contents/MacOS/Knob"
codesign -s - --force "$app"

cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$app/Contents/MacOS/Knob</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$agent"
