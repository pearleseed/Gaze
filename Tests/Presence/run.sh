#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/Tools/Scripts/toolchain.sh"
require_toolchain
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-presence-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -parse-as-library \
	"$ROOT/Sources/Security/PresenceAbsenceGate.swift" \
	"$ROOT/Sources/Security/PresenceCheckSchedule.swift" \
	"$ROOT/Tests/Presence/Tests.swift" \
	-o "$BUILD/presence-tests"
"$BUILD/presence-tests"
