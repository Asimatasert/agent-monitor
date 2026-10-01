#!/bin/sh
# (Re)build ~/Desktop/Agent Monitor.app from the files in ~/agent-monitor.
P="$HOME/agent-monitor"
APP="$HOME/Desktop/Agent Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$P/AgentMonitor.icns" "$APP/Contents/Resources/AgentMonitor.icns"
cat > "$APP/Contents/MacOS/AgentMonitor" <<'SH'
#!/bin/sh
exec "$HOME/agent-monitor/launch.sh"
SH
chmod +x "$APP/Contents/MacOS/AgentMonitor"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Agent Monitor</string>
  <key>CFBundleDisplayName</key><string>Agent Monitor</string>
  <key>CFBundleIdentifier</key><string>local.agent.monitor</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>AgentMonitor</string>
  <key>CFBundleIconFile</key><string>AgentMonitor</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
touch "$APP"
echo "built: $APP"
