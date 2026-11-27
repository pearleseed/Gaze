#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
COMPILE_ONLY=0
if [ "${1:-}" = "--compile-only" ]; then
	COMPILE_ONLY=1
fi

. "$ROOT/Tests/Scripts/Support/swiftpm.sh"
. "$ROOT/Tools/Scripts/BundleResources.sh"
gaze_swiftpm_setup "$ROOT" GazeApp

mkdir -p "$ROOT/build"
BUILD="$(mktemp -d "$ROOT/build/onboarding-checks.XXXXXX")"
if [ "$COMPILE_ONLY" = 1 ]; then
	trap 'rm -rf "$BUILD"' EXIT
fi
APP="$BUILD/Gaze Onboarding Review.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -sdk "$GAZE_SDK" -target "$(host_target)" \
	-I "$GAZE_SPM_BIN" -L "$GAZE_SPM_BIN" \
	-F "$GAZE_SPARKLE_FRAMEWORK_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$GAZE_SPARKLE_FRAMEWORK_DIR" \
	-lGazeApp -lGazeCore -lGazeDesign -lGazeTourKit -lGazeCamera \
	-lGazeRecognition -lGazeLockScreen -lGazeSecurity -lGazeUpdates \
	"$ROOT/Tests/Scripts/Support/CompanionCapture.swift" \
	"$ROOT/Tests/Scripts/AppIntegration/Onboarding/OnboardingTests.swift" \
	"$ROOT/Tests/Scripts/AppIntegration/Onboarding/LessonMotionTests.swift" \
	-o "$APP/Contents/MacOS/OnboardingReview"
if [ "$COMPILE_ONLY" = 1 ]; then
	echo "PASS: Onboarding harness compiled cleanly under Swift 6."
	exit 0
fi

compile_gaze_app_icon "$ROOT" "$APP/Contents/Resources" "$MIN_SDK_MAJOR.0" >/dev/null
mkdir -p "$APP/Contents/Resources/Art"
for artwork in tour-backdrop setup-accessibility setup-camera-prompt setup-password; do
	cp "$ROOT/Resources/Art/$artwork.png" "$APP/Contents/Resources/Art/"
done
cp "$ROOT/ThirdParty/TourKit/LICENSE" "$APP/Contents/Resources/TourKit-LICENSE.txt"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.pearleseed.OnboardingReview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string OnboardingReview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Gaze Onboarding Review' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist"
codesign --force --options runtime --sign - "$APP" >/dev/null 2>&1
"$APP/Contents/MacOS/OnboardingReview" "${1:-$BUILD/renders}" "${@:2}"
echo "Review app: $APP"
