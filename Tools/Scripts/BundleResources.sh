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

# Prefer a local compiled model over raw model files. Some source checkouts
# contain only the Iris package manifest, so only compile packages with data.
stage_gaze_models() {
	local root="$1" resources="$2" local_models="${3:-}" model compiled source name
	for name in FaceEmbedding IrisLandmarks Spoof; do
		model="$root/Resources/$name"
		compiled="$model.mlmodelc"
		if [ -n "$local_models" ] && [ -d "$local_models/$name.mlmodelc" ]; then
			compiled="$local_models/$name.mlmodelc"
		fi
		source=""
		if [ -d "$compiled" ]; then
			echo "  ✓ $name.mlmodelc (prebuilt)"
			cp -R "$compiled" "$resources/" || return
			continue
		elif [ -f "$model.mlpackage/Manifest.json" ] && [ -d "$model.mlpackage/Data" ]; then
			source="$model.mlpackage"
		elif [ -f "$model.mlmodel" ]; then
			source="$model.mlmodel"
		fi

		if [ -n "$source" ]; then
			xcrun coremlc compile "$source" "$resources" >/dev/null || return
			echo "  ✓ $name.mlmodelc"
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
