#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/Tools/Scripts/toolchain.sh"
require_toolchain
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-toolbar-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
APP="$BUILD/Toolbar Checks.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Art"
cp "$ROOT/Resources/Art/gaze-toolbar-black.png" "$ROOT/Resources/Art/gaze-toolbar-white.png" \
	"$APP/Contents/Resources/Art/"
xcrun swiftc -parse-as-library -warnings-as-errors -sdk "$SDK" -target "$(uname -m)-apple-macos26.0" \
	"$ROOT/Sources/App/Settings/SettingsPane.swift" \
	"$ROOT/Sources/App/GazeBrand.swift" "$ROOT/Sources/App/Settings/GazeSettingsPicker.swift" \
	"$ROOT/Sources/Design/"*.swift "$ROOT/Tests/Support/PreviewPreferences.swift" \
	"$ROOT/Tests/Toolbar/ToolbarTests.swift" -o "$APP/Contents/MacOS/ToolbarChecks"
"$APP/Contents/MacOS/ToolbarChecks" "${1:-$BUILD/renders}"
