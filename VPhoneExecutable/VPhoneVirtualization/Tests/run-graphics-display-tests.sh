#!/bin/zsh
# vphone-tier: build
set -euo pipefail

tests="${0:a:h}"
repo="${tests:h:h:h}"
out="$repo/.build/graphics-display-tests"
mkdir -p "$out"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -target arm64-apple-macos15.0 -module-cache-path "$out/module-cache" \
    "$tests:h/UI/VirtualMachine/VPhoneGraphicsDisplaySupport.swift" \
    "$tests/GraphicsDisplaySupportTests.swift" -o "$out/GraphicsDisplaySupportTests"
"$out/GraphicsDisplaySupportTests"
