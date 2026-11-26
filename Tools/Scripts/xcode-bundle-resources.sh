#!/bin/bash
set -euo pipefail

. "$SRCROOT/Tools/Scripts/BundleResources.sh"

case "$1" in
	models)
		resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
		mkdir -p "$DERIVED_FILE_DIR" "$resources"
		stage="$(mktemp -d "$DERIVED_FILE_DIR/models.XXXXXX")"
		trap 'rm -rf "$stage"' EXIT
		local_models=""
		if [ "${CONFIGURATION:-}" = Debug ]; then local_models="$SRCROOT/build/local-models"; fi
		stage_gaze_models "$SRCROOT" "$stage" "$local_models"
		for model in FaceEmbedding IrisLandmarks Spoof; do
			rm -rf "$resources/$model.mlmodelc"
			if [ -d "$stage/$model.mlmodelc" ]; then
				mv "$stage/$model.mlmodelc" "$resources/"
			fi
		done
		stage_gaze_iris_notices "$SRCROOT" "$resources"
		cp "$SRCROOT/ThirdParty/TourKit/LICENSE" "$resources/TourKit-LICENSE.txt"
		;;
	pam)
		output="$SCRIPT_OUTPUT_FILE_0"
		mkdir -p "$(dirname "$output")"
		read -r -a architectures <<<"$ARCHS"
		flags=()
		for arch in "${architectures[@]}"; do flags+=(-arch "$arch"); done
		compile_gaze_pam_module "$SCRIPT_INPUT_FILE_0" "$output" "$SDKROOT" \
			"$MACOSX_DEPLOYMENT_TARGET" "${flags[@]}"
		if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
			codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$output"
		fi
		;;
	finder)
		mkdir -p "$(dirname "$SCRIPT_OUTPUT_FILE_0")"
		cp "$SCRIPT_INPUT_FILE_0" "$SCRIPT_OUTPUT_FILE_0"
		stamp_gaze_bundle_version "$SCRIPT_INPUT_FILE_1" "$SCRIPT_OUTPUT_FILE_0"
		;;
	*) exit 2 ;;
esac
