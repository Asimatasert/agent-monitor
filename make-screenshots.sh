#!/bin/sh
# Capture every Agent Bar popover view with live panel data (for checking UI changes).
# Usage: ./make-screenshots.sh [out_dir] [view ...]   views: live quota usage kanban health health-models health-chains
# The popover is built full height so nothing is cut off by the scroll view.
set -e
P="$HOME/agent-monitor"
OUT="${1:-$P/screenshots}"
[ $# -gt 0 ] && shift
B=$(mktemp -d)
A="$B/AgentBarShots.app/Contents"
mkdir -p "$A/MacOS" "$A/Resources" "$OUT"
cp -R "$P/menubar/icons" "$A/Resources/icons"
sed -e 's/^@main$//' -e 's/.frame(height: 540)/.frame(height: 1350)/' "$P/menubar/AgentBar.swift" > "$B/app.swift"
swiftc -swift-version 5 -O "$B/app.swift" "$P/menubar/screenshots/main.swift" -o "$A/MacOS/shots"
cat > "$A/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.agent.bar.shots</string>
<key>CFBundleExecutable</key><string>shots</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PL
codesign --force -s - "$B/AgentBarShots.app" >/dev/null 2>&1 || true
"$A/MacOS/shots" "$OUT" "$@" 2>/dev/null
echo "screenshots: $OUT"
