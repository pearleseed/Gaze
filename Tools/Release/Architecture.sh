#!/bin/bash

gaze_require_release_arch() {
	case "${1:-}" in
		arm64|x86_64) return 0 ;;
		*) echo 'Set GAZE_ARCHS to exactly one release architecture: arm64 or x86_64.' >&2; return 1 ;;
	esac
}

gaze_verify_bundle_arch() {
	local app="$1" expected="$2" binary actual
	for binary in Contents/MacOS/Gaze \
		Contents/PlugIns/GazeFinder.appex/Contents/MacOS/GazeFinder \
		Contents/Resources/pam_gaze.so; do
		if [ ! -f "$app/$binary" ]; then
			echo "FAIL: Missing release binary: $binary" >&2
			return 1
		fi
		actual="$(lipo -archs "$app/$binary")" || return 1
		if [ "$actual" != "$expected" ]; then
			echo "FAIL: ${binary##*/}: expected only $expected, found $actual" >&2
			return 1
		fi
	done
}
