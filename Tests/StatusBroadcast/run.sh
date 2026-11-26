#!/bin/bash
# Status feed contract: compiles the real Sources/App/StatusBroadcast.swift with the
# checks beside it. Posts go to a capture closure, never the distributed centre.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/Tools/Scripts/toolchain.sh"
require_toolchain
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-status-broadcast-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -parse-as-library \
	"$ROOT/Sources/App/StatusBroadcast.swift" \
	"$ROOT/Tests/StatusBroadcast/StatusBroadcastTests.swift" \
	-o "$BUILD/status-broadcast-tests"
"$BUILD/status-broadcast-tests"
