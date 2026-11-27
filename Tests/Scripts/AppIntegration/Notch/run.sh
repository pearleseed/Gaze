#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
. "$ROOT/Tests/Scripts/Support/swiftpm.sh"
gaze_swiftpm_setup "$ROOT" GazeLockScreen

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-notch-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -sdk "$GAZE_SDK" -target "$(host_target)" \
	-I "$GAZE_SPM_BIN" -L "$GAZE_SPM_BIN" \
	-lGazeLockScreen -lGazeDesign -lGazeCore \
	"$ROOT/Tests/Scripts/Support/CompanionCapture.swift" \
	"$ROOT/Tests/Scripts/AppIntegration/Notch/NotchTests.swift" \
	-o "$BUILD/notch-tests"
if [ "${1:-}" = "--compile-only" ]; then
	echo "PASS: Notch harness compiled cleanly under Swift 6."
	exit 0
fi
"$BUILD/notch-tests" "${1:-$BUILD/renders}"
