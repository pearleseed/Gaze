#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
GAZE_MAIN_SOURCES=()
while IFS= read -r -d '' source; do
	case "$source" in
		*/AutofillSettings.swift|*/FaceCheck.swift)
			echo "FAIL: retired autofill source included in Gaze" >&2; exit 1 ;;
	esac
	GAZE_MAIN_SOURCES+=("$source")
done < <(find "$ROOT/Sources" \
	\( -path "$ROOT/Sources/FinderExtension" -o -path "$ROOT/Sources/PAM" \) -prune -o \
	-type f -name '*.swift' -print0 | LC_ALL=C sort -z)
if [ -d "$ROOT/Sources/Autofill" ] || grep -qE 'AutofillSettings|FaceCheck|Sources/Autofill' "$ROOT/Package.swift" "$ROOT/Gaze.xcodeproj/project.pbxproj"; then
	echo "FAIL: retired autofill source included in Gaze" >&2; exit 1
fi
echo "PASS Gaze build excludes retired autofill implementations"
if grep -qE 'AutofillService|AutofillWatcher|SavedAppStore|GlobalHotKey|AutofillSection|startAutofill' "${GAZE_MAIN_SOURCES[@]}"; then
	echo "FAIL: autofill runtime wiring remains in Gaze" >&2; exit 1
fi
echo "PASS Gaze has no autofill runtime wiring or saved-app store initialization"
if grep -qE 'case .*autofill|\.autofill|autofillOnActivation' "$ROOT/Sources/GazeApp/Settings/"*.swift "$ROOT/Sources/GazeCore/Preferences.swift"; then
	echo "FAIL: autofill pane or preference remains" >&2; exit 1
fi
echo "PASS Gaze exposes no autofill pane or activation preference"
for required in LockWatcher.swift PasswordVault.swift BiometricGate.swift LockScreenPasswordSubmission.swift; do
	found=false
	for source in "${GAZE_MAIN_SOURCES[@]}"; do
		if [ "$(basename "$source")" = "$required" ]; then found=true; break; fi
	done
	if [ "$found" != true ]; then echo "FAIL: missing Mac-unlock protection $required" >&2; exit 1; fi
done
echo "PASS Mac-unlock and owner-authentication protections remain included"
grep -qE -- '--options runtime' "$ROOT/build.sh"
echo "PASS the build enables Hardened Runtime"
echo "5 product-boundary checks passed; no credential access or app launch"
