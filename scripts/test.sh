#!/bin/bash
# Runs the parser/OTP tests (no app launch, no phone needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
xcrun swiftc -module-cache-path "$ROOT/build/ModuleCache" -o "$ROOT/build/parser-tests" \
  "$ROOT/Sources/SideText/OTPExtractor.swift" \
  "$ROOT/Sources/SideText/IncomingMessage.swift" \
  "$ROOT/Tests/main.swift"
"$ROOT/build/parser-tests"
