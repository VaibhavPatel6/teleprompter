#!/bin/bash
# Builds and runs the Pacer tests. No Xcode/XCTest needed: plain swiftc.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/Pacer.swift Sources/VoiceFollower.swift Tests/main.swift -o build/pacer-tests
./build/pacer-tests
