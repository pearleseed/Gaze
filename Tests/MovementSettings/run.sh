#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/Tools/Scripts/toolchain.sh"
require_toolchain
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-movement-settings-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -parse-as-library \
	"$ROOT/Tests/MovementSettings/UnlockBackendStub.swift" \
	"$ROOT/Sources/App/Preferences.swift" \
	"$ROOT/Sources/App/StatusBroadcast.swift" \
	"$ROOT/Sources/Camera/CameraFrameLease.swift" \
	"$ROOT/Sources/Security/UnlockChallengeGate.swift" \
	"$ROOT/Tests/MovementSettings/MovementSettingsTests.swift" \
	-o "$BUILD/movement-settings-tests"
"$BUILD/movement-settings-tests"
