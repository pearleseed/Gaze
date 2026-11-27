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
	OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/gaze-scene-probe.XXXXXX")"
	trap 'rm -rf "$OUTPUT"' EXIT
else
	OUTPUT="${1:-$ROOT/build/lesson-scene-probe}"
fi
APP="$OUTPUT/Gaze Lesson Scene Probe.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors -sdk "$GAZE_SDK" -target "$(host_target)" \
	-I "$GAZE_SPM_BIN" -L "$GAZE_SPM_BIN" \
	-lGazeApp -lGazeCore -lGazeDesign -lGazeTourKit -lGazeCamera \
	-lGazeRecognition -lGazeLockScreen -lGazeSecurity -lGazeUpdates \
	"$ROOT/Tests/Scripts/AppIntegration/Onboarding/LessonSceneProbe.swift" \
	"$ROOT/Tests/Scripts/Support/CompanionCapture.swift" \
	-o "$APP/Contents/MacOS/LessonSceneProbe"
if [ "$COMPILE_ONLY" = 1 ]; then
	echo "PASS: LessonSceneProbe compiled cleanly under Swift 6."
	exit 0
fi

python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'com.pearleseed.LessonSceneProbe',
                  'CFBundleExecutable':'LessonSceneProbe', 'CFBundleName':'Gaze Lesson Scene Probe',
                  'CFBundlePackageType':'APPL', 'LSMinimumSystemVersion':'26.0'}, stream)
PY
codesign --force --sign - "$APP" >/dev/null 2>&1
open -n "$APP" --args "$OUTPUT/scene-events.json"
echo "Scene probe: $APP"
echo "Events: $OUTPUT/scene-events.json"
