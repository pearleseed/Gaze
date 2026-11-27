#!/bin/bash

gaze_signing_identity() {
	local mode="$1" requested="$2" identities="$3" selected
	local require_developer_id="${GAZE_REQUIRE_DEVELOPER_ID:-0}"
	local strict="0"
	if [ "$mode" = "1" ] && [ "$require_developer_id" = "1" ]; then
		strict="1"
	fi
	if [ "$strict" != "1" ] && [ "$requested" = "-" ]; then
		printf '%s\n' "-"
		return 0
	fi
	selected="$(printf '%s\n' "$identities" | awk -v mode="$mode" -v strict="$strict" -v requested="$requested" '
		$1 ~ /^[0-9]+\)$/ && length($2) == 40 && $2 !~ /[^[:xdigit:]]/ {
			name = $0
			sub(/^[^"]*"/, "", name)
			sub(/".*$/, "", name)
			is_dev_id = (name ~ /^Developer ID Application: /)
			is_apple_dev = (name ~ /^Apple Development: /)
			eligible = is_dev_id || (strict != "1" && is_apple_dev)
			if (eligible && (requested == "" || requested == $2 || requested == name)) {
				if (requested != "" || mode != "1") {
					print $2
					exit
				}
				if (is_dev_id && dev_id == "") {
					dev_id = $2
				}
			}
		}
		END {
			if (requested == "" && mode == "1") {
				if (dev_id != "") print dev_id
			}
		}')"
	if [ -z "$selected" ]; then
		if [ "$strict" != "1" ] && [ "$mode" = "1" ] && [ -z "$requested" ]; then
			printf '%s\n' "-"
			return 0
		fi
		if [ "$strict" = "1" ]; then
			echo "Release signing requires a valid Developer ID Application identity. Ad-hoc and Apple Development signatures are not accepted." >&2
			echo "Set GAZE_REQUIRE_DEVELOPER_ID=0 for portable ad-hoc (-) release signing, or install a Developer ID Application certificate." >&2
		else
			echo "Local builds require a valid Apple Development or Developer ID Application identity (or pass '-' for ad-hoc); the existing app was not replaced." >&2
		fi
		return 1
	fi
	printf '%s\n' "$selected"
}
