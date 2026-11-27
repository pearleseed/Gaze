#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
COMPILE_ONLY=0
if [ "${1:-}" = "--compile-only" ]; then
	COMPILE_ONLY=1
fi

. "$ROOT/Tests/Scripts/Support/swiftpm.sh"
gaze_swiftpm_setup "$ROOT" GazeApp

if [ "$COMPILE_ONLY" = 1 ]; then
	OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/gaze-settings-interaction.XXXXXX")"
	trap 'rm -rf "$OUTPUT"' EXIT
else
	OUTPUT="${1:-$ROOT/build/settings-interaction-regression}"
	mkdir -p "$OUTPUT"
	rm -f "$OUTPUT/results.json"
fi
APP="$OUTPUT/Gaze Settings Fixture.app"
mkdir -p "$APP/Contents/MacOS"
python3 "$ROOT/Tests/Scripts/AppIntegration/SettingsInteraction/generate.py" "$OUTPUT/CaptureFixture.swift"
xcrun swiftc -parse-as-library -swift-version 6 -package-name "$GAZE_PACKAGE_NAME" -sdk "$GAZE_SDK" -target "$(host_target)" \
	-I "$GAZE_SPM_BIN" -L "$GAZE_SPM_BIN" \
	-lGazeCore -lGazeDesign -lGazeTourKit -lGazeCamera \
	-lGazeRecognition -lGazeSecurity -lGazeUpdates \
	"$ROOT/Sources/GazeApp/Settings/SettingsBehaviourSection.swift" \
	"$ROOT/Sources/GazeApp/Settings/SettingsUpdatesSection.swift" \
	"$ROOT/Sources/GazeApp/Settings/SettingsSourceBuildSection.swift" \
	"$ROOT/Sources/GazeApp/Setup/SetupScaffold.swift" \
	"$ROOT/Sources/GazeApp/ReleaseNotesView.swift" \
	"$ROOT/Sources/GazeApp/Setup/SetupAccessibilityDemo.swift" \
	"$ROOT/Sources/GazeApp/Setup/SetupShot.swift" \
	"$ROOT/Sources/GazeApp/Setup/SetupControls.swift" \
	"$ROOT/Sources/GazeApp/Setup/GazeTourSizing.swift" \
	"$ROOT/Sources/GazeApp/Enrollment/EnrollmentRing.swift" \
	"$ROOT/Tests/Scripts/AppIntegration/SettingsInteraction/Stubs.swift" \
	"$ROOT/Tests/Scripts/AppIntegration/SettingsInteraction/ServiceStubs.swift" \
	"$ROOT/Tests/Scripts/AppIntegration/SettingsInteraction/SettingsFixture.swift" \
	"$ROOT/Tests/Scripts/AppIntegration/SettingsInteraction/Tests.swift" \
	"$ROOT/Tests/Scripts/AppIntegration/SettingsInteraction/CaptureTests.swift" \
	"$OUTPUT/CaptureFixture.swift" -o "$APP/Contents/MacOS/SettingsFixture"
if [ "$COMPILE_ONLY" = 1 ]; then
	echo "PASS: SettingsInteraction harness compiled cleanly under Swift 6."
	exit 0
fi

python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'com.pearleseed.SettingsInteractionFixture',
                  'CFBundleExecutable':'SettingsFixture', 'CFBundleName':'Gaze Settings Fixture',
                  'CFBundlePackageType':'APPL', 'LSMinimumSystemVersion':'26.0'}, stream)
PY
codesign --force --sign - "$APP" >/dev/null 2>&1
"$APP/Contents/MacOS/SettingsFixture" "$OUTPUT" "${@:2}"
