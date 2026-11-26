#!/bin/bash

collect_gaze_main_sources() {
	local root="$1"
	local source
	GAZE_MAIN_SOURCES=()
	while IFS= read -r -d '' source; do
		case "$source" in
			*/AutofillSettings.swift|*/FaceCheck.swift) continue ;;
		esac
		GAZE_MAIN_SOURCES+=("$source")
	done < <(find "$root/Sources" \
		\( -path "$root/Sources/FinderExtension" -o -path "$root/Sources/PAM" -o -path "$root/Sources/Autofill" \) -prune -o \
		-type f -name '*.swift' -print0 | LC_ALL=C sort -z)
	# Vendored TourKit onboarding source (see ThirdParty/TourKit/SOURCE.json).
	# Compiled into the Gaze module directly; there is no separate TourKit module.
	GAZE_MAIN_SOURCES+=("$root/ThirdParty/TourKit/TourKit.swift")
}
