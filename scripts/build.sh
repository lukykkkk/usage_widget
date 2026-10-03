#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p "build/Token Usage.app/Contents/MacOS" .build-cache
swiftc -swift-version 5 -O -module-cache-path .build-cache Sources/*.swift -o "build/Token Usage.app/Contents/MacOS/TokenUsage" -framework Cocoa -framework SwiftUI
cp Info.plist "build/Token Usage.app/Contents/Info.plist"
codesign --force --sign - "build/Token Usage.app"
echo "Built: $PWD/build/Token Usage.app"
