#!/bin/sh
# (Re)build and install /Applications/Agent Bar.app (menu bar / notch app + desktop widget).
#
# With an Apple Development certificate in the keychain and XcodeGen (brew install xcodegen), the app and its
# widget are built with Xcode from menubar/project.yml — macOS only lists widgets that are Xcode-built and signed
# with a real identity. Without them, the app alone is built with swiftc and ad-hoc signed (no widget).
set -e
P="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Agent Bar.app"
IDENT=$(security find-identity -v -p codesigning 2>/dev/null | grep -v REVOKED | grep -m1 -oE '[0-9A-F]{40}' || true)

install_app() {
  WAS_RUNNING=$(pgrep -x AgentBar || true)
  pkill -x AgentBar 2>/dev/null || true
  rm -rf "$APP"
  ditto "$1" "$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$APP"
  # the running copy was stopped for the update: start the new one so the menu bar / notch don't just vanish
  [ -n "$WAS_RUNNING" ] && open "$APP" || true
}

if [ -n "$IDENT" ] && command -v xcodegen >/dev/null && command -v xcodebuild >/dev/null; then
  NAME=$(security find-identity -v -p codesigning | grep "$IDENT" | sed -E 's/.*"(.*)"/\1/')
  TEAM=$(security find-certificate -c "$NAME" -p | openssl x509 -noout -subject | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p')
  B="$P/menubar/build"
  (cd "$P/menubar" && xcodegen generate --quiet --spec project.yml)
  xcodebuild -quiet -project "$P/menubar/AgentBar.xcodeproj" -scheme AgentBar -configuration Release \
    -derivedDataPath "$B/dd" CODE_SIGN_IDENTITY="$IDENT" DEVELOPMENT_TEAM="$TEAM" build
  install_app "$B/dd/Build/Products/Release/Agent Bar.app"
  echo "built with Xcode (app + widget), signed as: $NAME"
else
  T=$(mktemp -d)
  A="$T/Agent Bar.app"
  mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
  swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
    "$P/menubar/AgentBar.swift" -o "$A/Contents/MacOS/AgentBar"
  cp "$P/AgentMonitor.icns" "$A/Contents/Resources/AgentMonitor.icns"
  cp -R "$P/menubar/icons" "$A/Contents/Resources/icons"
  cat > "$A/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Agent Bar</string>
  <key>CFBundleDisplayName</key><string>Agent Bar</string>
  <key>CFBundleIdentifier</key><string>local.agent.bar</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>AgentBar</string>
  <key>CFBundleIconFile</key><string>AgentMonitor</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PL
  codesign --force --sign - "$A" >/dev/null 2>&1 || true
  install_app "$A"
  rm -rf "$T"
  echo "built with swiftc (app only; the widget needs an Apple Development certificate and XcodeGen)"
fi
echo "installed: $APP"
