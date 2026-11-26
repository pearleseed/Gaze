#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/Tools/Scripts/toolchain.sh"
require_toolchain
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-presence-lifecycle-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -parse-as-library -warnings-as-errors \
	"$ROOT/Sources/Security/UnlockExecutionPolicy.swift" \
	"$ROOT/Sources/Security/UnlockBackend.swift" \
	"$ROOT/Sources/App/Preferences.swift" \
	"$ROOT/Sources/App/StatusBroadcast.swift" \
	"$ROOT/Sources/Security/Keystrokes.swift" \
	"$ROOT/Sources/Security/LockScreenPasswordSubmission.swift" \
	"$ROOT/Tests/PresenceLifecycle/BackendStubs.swift" \
	"$ROOT/Tests/PresenceLifecycle/LifecycleTests.swift" \
	-o "$BUILD/presence-lifecycle-tests"
"$BUILD/presence-lifecycle-tests"
bash "$ROOT/Tests/PresenceLifecycle/test-wiring.sh"
