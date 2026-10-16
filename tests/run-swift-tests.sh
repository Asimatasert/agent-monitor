#!/bin/sh
# Swift-side unit tests (click decision, command allowlist). Builds in a temp dir; installs nothing.
# AgentBar.swift is compiled without its @main, together with tests/swift/OpenPlanTests.swift (top-level code = main).
set -e
P="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
sed 's/^@main$//' "$P/menubar/AgentBar.swift" > "$T/AgentBar.swift"
cp "$P/tests/swift/OpenPlanTests.swift" "$T/main.swift"
swiftc -O -swift-version 5 -target arm64-apple-macos14 "$T/AgentBar.swift" "$T/main.swift" -o "$T/open-plan-tests"
"$T/open-plan-tests"
