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
	local root="${1:-}"
	[ -n "$root" ] || return 1
	shift
	. "$root/Tools/Scripts/toolchain.sh" || return 1
	require_toolchain || return 1
	# Build every library product in Package.swift so callers linking transitive
	# `-lGaze*` static libraries succeed on a clean `.build/` checkout.
	swift build --package-path "$root" >/dev/null || return 1
	GAZE_SPM_BIN="$(swift build --package-path "$root" --show-bin-path)" || return 1
	GAZE_PACKAGE_NAME="$(gaze_swiftpm_package_name "$root")" || return 1
	if [ -n "${SDKROOT:-}" ]; then
		GAZE_SDK="$SDKROOT"
	else
		GAZE_SDK="$(xcrun --sdk macosx --show-sdk-path)" || return 1
	fi
	[ -n "$GAZE_SPM_BIN" ] && [ -n "$GAZE_PACKAGE_NAME" ] && [ -n "$GAZE_SDK" ] || return 1
	GAZE_SPARKLE_FRAMEWORK_DIR=""
	for candidate in \
		"$GAZE_SPM_BIN" \
		"$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64" \
		"$root/build/sparkle-tools"; do
		if [ -d "$candidate/Sparkle.framework" ]; then
			GAZE_SPARKLE_FRAMEWORK_DIR="$candidate"
			break
		fi
	done
	export GAZE_SPM_BIN GAZE_PACKAGE_NAME GAZE_SDK GAZE_SPARKLE_FRAMEWORK_DIR
}
