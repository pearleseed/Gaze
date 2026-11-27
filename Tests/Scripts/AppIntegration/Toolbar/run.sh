#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
. "$ROOT/Tests/Scripts/Support/swiftpm.sh"
gaze_swiftpm_setup "$ROOT" GazeApp

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-toolbar-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/Toolbar Checks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Art"
cp "$ROOT/Resources/Art/gaze-toolbar-black.png" "$ROOT/Resources/Art/gaze-toolbar-white.png" \
	"$APP/Contents/Resources/Art/"
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -sdk "$GAZE_SDK" -target "$(host_target)" \
	-I "$GAZE_SPM_BIN" -L "$GAZE_SPM_BIN" \
	-lGazeApp -lGazeCore -lGazeDesign -lGazeTourKit -lGazeCamera \
	-lGazeRecognition -lGazeLockScreen -lGazeSecurity -lGazeUpdates \
	"$ROOT/Tests/Scripts/AppIntegration/Toolbar/ToolbarTests.swift" \
	-o "$APP/Contents/MacOS/ToolbarChecks"
if [ "${1:-}" = "--compile-only" ]; then
	echo "PASS: Toolbar harness compiled cleanly under Swift 6."
	exit 0
fi
"$APP/Contents/MacOS/ToolbarChecks" "${1:-$BUILD/renders}"
