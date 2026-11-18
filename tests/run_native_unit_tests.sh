#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nxmanager-unit.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/module-cache" \
  "$ROOT/NativeApp/GameLibraryStatus.swift" \
  "$ROOT/NativeApp/NXNativeHIDConfiguration.swift" \
  "$ROOT/NativeApp/ControllerCalibration.swift" \
  "$ROOT/tests/native_unit_tests.swift" \
  -o "$TEST_DIR/NXManagerUnitTests"
"$TEST_DIR/NXManagerUnitTests"
