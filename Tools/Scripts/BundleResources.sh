#!/bin/bash

compile_gaze_app_icon() {
	local root="$1" resources="$2" minimum_version="$3"
	if [ -d "$root/Resources/AppIcon.icon" ]; then
		xcrun actool "$root/Resources/AppIcon.icon" \
			--app-icon AppIcon --include-all-app-icons \
			--compile "$resources" \
			--platform macosx --target-device mac \
			--minimum-deployment-target "$minimum_version" \
			--development-region en --enable-on-demand-resources NO \
			--output-partial-info-plist "$resources/.icon-partial.plist" || return
		rm -f "$resources/.icon-partial.plist"
	elif [ -f "$root/Resources/AppIcon.icns" ]; then
		cp "$root/Resources/AppIcon.icns" "$resources/AppIcon.icns"
	fi
}

# Prints "<kind>\t<path>" ("prebuilt" or "compile") when a model source exists, or nothing.
# Prefer a local compiled model over raw model files. Some source checkouts
# contain only the Iris package manifest, so only compile packages with data.
resolve_gaze_model_source() {
	local root="$1" name="$2" local_models="${3:-}" model compiled
	model="$root/Resources/$name"
	compiled="$model.mlmodelc"
	if [ -n "$local_models" ] && [ -d "$local_models/$name.mlmodelc" ]; then
		compiled="$local_models/$name.mlmodelc"
	fi
	if [ -d "$compiled" ]; then
		printf 'prebuilt\t%s\n' "$compiled"
	elif [ -f "$model.mlpackage/Manifest.json" ] && [ -d "$model.mlpackage/Data" ]; then
		printf 'compile\t%s\n' "$model.mlpackage"
	elif [ -f "$model.mlmodel" ]; then
		printf 'compile\t%s\n' "$model.mlmodel"
	fi
}

stage_gaze_models() {
	local root="$1" resources="$2" local_models="${3:-}" name resolved kind source
	for name in FaceEmbedding IrisLandmarks Spoof; do
		resolved="$(resolve_gaze_model_source "$root" "$name" "$local_models")"
		if [ -n "$resolved" ]; then
			kind="${resolved%%$'\t'*}"
			source="${resolved#*$'\t'}"
			if [ "$kind" = "prebuilt" ]; then
				echo "  ✓ $name.mlmodelc (prebuilt)"
				cp -R "$source" "$resources/" || return
				xattr -cr "$resources/$name.mlmodelc" 2>/dev/null || true
			else
				xcrun coremlc compile "$source" "$resources" >/dev/null || return
				echo "  ✓ $name.mlmodelc"
			fi
		else
			case "$name" in
				FaceEmbedding) echo "  ! No face embedding model. The landmark fallback supports recognition testing only." ;;
				IrisLandmarks) echo "  ! No iris model. Follow the light uses pixel-based pupil detection." ;;
				Spoof) echo "  ! No spoof model. Unlock is refused when photo rejection is required." ;;
			esac
		fi
	done
}

stage_gaze_iris_notices() {
	local root="$1" resources="$2"
	if [ -d "$resources/IrisLandmarks.mlmodelc" ]; then
		cp "$root/ThirdParty/MediaPipeIris/LICENSE" "$resources/MediaPipeIris-LICENSE.txt" || return
		cp "$root/ThirdParty/MediaPipeIris/SOURCE.md" "$resources/MediaPipeIris-NOTICE.txt"
	else
		rm -f "$resources/MediaPipeIris-LICENSE.txt" "$resources/MediaPipeIris-NOTICE.txt"
	fi
}

gaze_model_outputs_ready() {
	local root="$1" resources="$2" local_models="${3:-}" name resolved
	[ -f "$resources/TourKit-LICENSE.txt" ] || return 1
	for name in FaceEmbedding IrisLandmarks Spoof; do
		resolved="$(resolve_gaze_model_source "$root" "$name" "$local_models")"
		if [ -n "$resolved" ]; then
			[ -d "$resources/$name.mlmodelc" ] || return 1
		elif [ -d "$resources/$name.mlmodelc" ]; then
			return 1
		fi
	done
	if [ -d "$resources/IrisLandmarks.mlmodelc" ]; then
		[ -f "$resources/MediaPipeIris-LICENSE.txt" ] && [ -f "$resources/MediaPipeIris-NOTICE.txt" ] || return 1
	elif [ -f "$resources/MediaPipeIris-LICENSE.txt" ] || [ -f "$resources/MediaPipeIris-NOTICE.txt" ]; then
		return 1
	fi
	return 0
}

gaze_models_stamp() {
	local root="$1" local_models="${2:-}"
	local roots=() path
	for path in "$root"/Resources/FaceEmbedding* "$root"/Resources/IrisLandmarks* "$root"/Resources/Spoof*; do
		[ -e "$path" ] || [ -L "$path" ] || continue
		roots+=("$path")
	done
	if [ -n "$local_models" ] && [ -e "$local_models" ]; then
		roots+=("$local_models")
	fi
	for path in \
		"$root/ThirdParty/TourKit/LICENSE" \
		"$root/ThirdParty/MediaPipeIris/LICENSE" \
		"$root/ThirdParty/MediaPipeIris/SOURCE.md" \
		"$root/Tools/Scripts/xcode-bundle-resources.sh" \
		"$root/Tools/Scripts/BundleResources.sh"; do
		if [ -e "$path" ] || [ -L "$path" ]; then
			roots+=("$path")
		fi
	done
	printf 'local_models=%s\n' "$local_models"
	if [ "${#roots[@]}" -gt 0 ]; then
		{ find -L "${roots[@]}" -type f -print0 2>/dev/null || true; } \
			| LC_ALL=C sort -z \
			| xargs -0 stat -L -f '%z %Fm %N'
	fi
}

stamp_gaze_bundle_version() {
	local app_plist="$1" target_plist="$2" key value
	for key in CFBundleShortVersionString CFBundleVersion; do
		value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$app_plist")" || return
		/usr/libexec/PlistBuddy -c "Set :$key $value" "$target_plist" 2>/dev/null ||
			/usr/libexec/PlistBuddy -c "Add :$key string $value" "$target_plist" || return
	done
}

compile_gaze_pam_module() {
	local source="$1" output="$2" sdk="$3" minimum_version="$4"
	shift 4
	xcrun clang -bundle -O2 -Wall -Werror "$@" -isysroot "$sdk" \
		-mmacosx-version-min="$minimum_version" -lpam -framework Security -framework CoreFoundation \
		"$source" -o "$output"
}
