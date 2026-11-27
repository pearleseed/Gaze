#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
. "$ROOT/Tests/Scripts/Support/swiftpm.sh"
gaze_swiftpm_setup "$ROOT" GazeDesign

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-toolbar-assets.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -sdk "$GAZE_SDK" -target "$(host_target)" \
	-I "$GAZE_SPM_BIN" -L "$GAZE_SPM_BIN" \
	-lGazeDesign -lGazeCore \
	"$ROOT/Tests/Scripts/AppIntegration/Toolbar/ExportBodies.swift" \
	-o "$BUILD/export"
if [ "${1:-}" = "--compile-only" ]; then
	echo "PASS: Toolbar ExportBodies compiled cleanly under Swift 6."
	exit 0
fi
"$BUILD/export" "${1:-$ROOT/Resources/Art}"
