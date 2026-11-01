#!/bin/bash
# Runs parser/OTP and DOM regression tests (no app launch or phone needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
xcrun swiftc -module-cache-path "$ROOT/build/ModuleCache" -o "$ROOT/build/parser-tests" \
  "$ROOT/Sources/SideText/OTPExtractor.swift" \
  "$ROOT/Sources/SideText/IncomingMessage.swift" \
  "$ROOT/Sources/SideText/WebScripts.swift" \
  "$ROOT/Tests/main.swift"
"$ROOT/build/parser-tests"
node "$ROOT/Tests/mark-read.test.js" "$ROOT/build/parser-tests"
