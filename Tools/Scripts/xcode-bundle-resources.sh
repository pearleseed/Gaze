#!/bin/bash
set -euo pipefail

. "$SRCROOT/Tools/Scripts/BundleResources.sh"

case "$1" in
	models)
		resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
		mkdir -p "$DERIVED_FILE_DIR" "$resources"
		local_models=""
		if [ "${DIST:-0}" != 1 ] && { [ "${CONFIGURATION:-}" = Debug ] || [ "${GAZE_USE_LOCAL_MODELS:-0}" = 1 ]; }; then
			local_models="$SRCROOT/build/local-models"
		fi
		stamp_file="$resources/.models.stamp"
		stamp_tmp="$(mktemp "$DERIVED_FILE_DIR/models-stamp.XXXXXX")"
		stage=""
		cleanup() {
			rm -rf "$stamp_tmp" ${stage:+"$stage"}
		}
		trap cleanup EXIT
		gaze_models_stamp "$SRCROOT" "$local_models" > "$stamp_tmp"
		if [ -f "$stamp_file" ] && cmp -s "$stamp_tmp" "$stamp_file" \
			&& gaze_model_outputs_ready "$SRCROOT" "$resources" "$local_models"; then
			echo "  ✓ Core ML models and notices (cached)"
			exit 0
		fi
		stage="$(mktemp -d "$DERIVED_FILE_DIR/models.XXXXXX")"
		stage_gaze_models "$SRCROOT" "$stage" "$local_models"
		for model in FaceEmbedding IrisLandmarks Spoof; do
			rm -rf "$resources/$model.mlmodelc"
			if [ -d "$stage/$model.mlmodelc" ]; then
				mv "$stage/$model.mlmodelc" "$resources/"
			fi
		done
		stage_gaze_iris_notices "$SRCROOT" "$resources"
		cp "$SRCROOT/ThirdParty/TourKit/LICENSE" "$resources/TourKit-LICENSE.txt"
		mv "$stamp_tmp" "$stamp_file"
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
