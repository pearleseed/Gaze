#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Tools/Scripts/toolchain.sh"
source "$ROOT/Tools/Scripts/BundleResources.sh"
require_toolchain
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$ROOT/build"
BUILD="$(mktemp -d "$ROOT/build/onboarding-checks.XXXXXX")"
APP="$BUILD/Gaze Onboarding Review.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -parse-as-library -sdk "$SDK" -target "$(host_target)" \
	"$ROOT/Tests/Onboarding/Stubs.swift" \
	"$ROOT/Tests/Onboarding/OnboardingTests.swift" \
	"$ROOT/Tests/Onboarding/LessonMotionTests.swift" \
	"$ROOT/Tests/Support/PreviewPreferences.swift" \
	"$ROOT/Sources/Design/"*.swift \
	"$ROOT/Sources/App/AppIdentity.swift" \
	"$ROOT/Sources/App/DesktopWallpaper.swift" \
	"$ROOT/Sources/LockScreen/GazeFaceMark.swift" \
	"$ROOT/Sources/LockScreen/NotchCapsule.swift" \
	"$ROOT/Sources/LockScreen/NotchCapsuleModel.swift" \
	"$ROOT/Sources/LockScreen/NotchAppearance.swift" \
	"$ROOT/Sources/LockScreen/WallpaperGlass.swift" \
	"$ROOT/Sources/LockScreen/NativeUnlockAnimation.swift" \
	"$ROOT/Sources/LockScreen/NativeMovementMark.swift" \
	"$ROOT/Sources/LockScreen/LockPanelPreview.swift" \
	"$ROOT/Sources/LockScreen/NotchPanelShape.swift" \
	"$ROOT/Sources/Companion/"*.swift \
	"$ROOT/Sources/Enrollment/EnrollmentRing.swift" \
	"$ROOT/Sources/Setup/SetupPlan.swift" \
	"$ROOT/Sources/Setup/OnboardingHistory.swift" \
	"$ROOT/Sources/Setup/SetupRequest.swift" \
	"$ROOT/Sources/Setup/SetupMeetGazeStep.swift" \
	"$ROOT/Sources/Setup/GazeLessonAnimation.swift" \
	"$ROOT/Sources/Setup/GazePeekingCompanion.swift" \
	"$ROOT/Sources/Setup/SetupBackdrop.swift" \
	"$ROOT/Sources/Setup/SetupScaffold.swift" \
	"$ROOT/Sources/Setup/SetupAccessibilityDemo.swift" \
	"$ROOT/Sources/Setup/SetupShot.swift" \
	"$ROOT/Sources/Setup/SetupControls.swift" \
	"$ROOT/Sources/Setup/SetupWelcomeStep.swift" \
	"$ROOT/Sources/Setup/GazeWelcomeTour.swift" \
	"$ROOT/Sources/Setup/GazeTourSizing.swift" \
	"$ROOT/Sources/Setup/GazeMovementTour.swift" \
	"$ROOT/Sources/Setup/GazeTourMovementPage.swift" \
	"$ROOT/Sources/Setup/GazeTourUnlockDemo.swift" \
	"$ROOT/Sources/Setup/GazeTourPrivacyDemo.swift" \
	"$ROOT/Sources/Setup/GazeTourChoiceDemo.swift" \
	"$ROOT/Sources/Setup/GazeTourAppLockDemo.swift" \
	"$ROOT/Sources/Setup/GazeLookingCompanion.swift" \
	"$ROOT/ThirdParty/TourKit/TourKit.swift" \
	"$ROOT/Sources/Setup/SetupHowStep.swift" \
	"$ROOT/Sources/Setup/SetupCaptureStep.swift" \
	"$ROOT/Sources/Setup/SetupPasswordStep.swift" \
	"$ROOT/Sources/Setup/SetupPermissionStep.swift" \
	"$ROOT/Sources/Security/SpaceKeyMonitor.swift" \
	"$ROOT/Sources/Setup/SetupDoneStep.swift" \
	"$ROOT/Tests/Support/CompanionCapture.swift" \
	-o "$APP/Contents/MacOS/OnboardingReview"
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
