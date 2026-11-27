#!/bin/bash
# Shared SwiftPM build/link environment helper for standalone scripts under Tests/Scripts/.

gaze_swiftpm_package_name() {
	local root="$1" identity
	identity="$(swift package --package-path "$root" show-dependencies --format json 2>/dev/null \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"])' 2>/dev/null || true)"
	if [ -z "$identity" ]; then
		identity="$(basename "$root")"
	fi
	printf '%s' "$identity" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g'
}

gaze_swiftpm_setup() {
	local root="$1"
	shift
	. "$root/Tools/Scripts/toolchain.sh"
	require_toolchain
	for product in "$@"; do
		swift build --package-path "$root" --product "$product" >/dev/null
	done
	GAZE_SPM_BIN="$(swift build --package-path "$root" --show-bin-path)"
	GAZE_PACKAGE_NAME="$(gaze_swiftpm_package_name "$root")"
	GAZE_SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
	export GAZE_SPM_BIN GAZE_PACKAGE_NAME GAZE_SDK
}
