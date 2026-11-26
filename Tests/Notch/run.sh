#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/Tools/Scripts/toolchain.sh"
require_toolchain
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-notch-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
xcrun swiftc -parse-as-library -sdk "$SDK" -target "$(uname -m)-apple-macos26.0" \
	"$ROOT/Tests/Support/PreviewPreferences.swift" \
	"$ROOT/Sources/Design/"*.swift \
	"$ROOT/Sources/LockScreen/GazeFaceMark.swift" \
	"$ROOT/Sources/Companion/"*.swift \
	"$ROOT/Sources/LockScreen/NotchCapsule.swift" \
	"$ROOT/Sources/LockScreen/NotchCapsuleModel.swift" \
	"$ROOT/Sources/LockScreen/NotchAppearance.swift" \
	"$ROOT/Sources/LockScreen/WallpaperGlass.swift" \
	"$ROOT/Sources/LockScreen/LockPanelPreview.swift" \
	"$ROOT/Sources/LockScreen/NotchPanelShape.swift" \
	"$ROOT/Sources/LockScreen/NotchMetrics.swift" \
	"$ROOT/Sources/LockScreen/NativeUnlockAnimation.swift" \
	"$ROOT/Sources/LockScreen/NativeMovementMark.swift" \
	"$ROOT/Sources/LockScreen/NotchPreviewCanvas.swift" \
	"$ROOT/Tests/Support/CompanionCapture.swift" \
	"$ROOT/Tests/Notch/NotchTests.swift" \
	-o "$BUILD/notch-tests"
"$BUILD/notch-tests" "${1:-$BUILD/renders}"
