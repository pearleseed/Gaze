#!/bin/bash
# Fixture tests for Tools/Release/preflight.sh. Synthetic identities and
# resource trees, mocked xcrun, no signing, no network, no app launch,
# nothing written outside the scratch directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gaze-release-preflight.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
BIN="$SCRATCH/bin"
RES="$SCRATCH/Resources"
mkdir -p "$BIN" "$RES/FaceEmbedding.mlmodelc" "$RES/Spoof.mlmodelc"
cp "$ROOT/Resources/Info.plist" "$ROOT/Resources/Gaze.entitlements" "$RES/"
export GAZE_PREFLIGHT_RESOURCES="$RES"
DID_IDENTITIES='  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (TEAMID1234)"
     1 valid identities found'
DEV_IDENTITIES='  1) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Fixture (TEAMID1234)"
     1 valid identities found'
COUNT=0
MODE=--build-tools-only
check() {
	local expected="$1" marker="$2"
	local actual=0
	bash "$ROOT/Tools/Release/preflight.sh" "$MODE" > "$SCRATCH/output" 2>&1 || actual=$?
	if [ "$expected" = pass ]; then
		test "$actual" = 0 || { cat "$SCRATCH/output"; exit 1; }
	else
		test "$actual" != 0 || { echo "FAIL: bad fixture passed ($marker)" >&2; exit 1; }
	fi
	grep -Fq "$marker" "$SCRATCH/output" || { cat "$SCRATCH/output"; exit 1; }
	COUNT=$((COUNT + 1))
}

export GAZE_PREFLIGHT_IDENTITIES="$DID_IDENTITIES"
check pass 'PREFLIGHT PASS'
check pass 'Developer ID Application signing identity'

export GAZE_PREFLIGHT_IDENTITIES="$DEV_IDENTITIES"
check fail 'no Developer ID Application identity'
check fail 'local Apple Development builds are unaffected'

export GAZE_PREFLIGHT_IDENTITIES=''
check fail 'no valid signing identity at all'

export GAZE_PREFLIGHT_IDENTITIES="$DID_IDENTITIES"
PATH="$BIN:/usr/bin:/bin" check fail 'tool spctl'

cat > "$BIN/xcrun" <<'MOCK'
#!/bin/bash
if [ "${1:-}" = "--find" ] && [ "${2:-}" = "notarytool" ]; then exit 1; fi
exec /usr/bin/xcrun "$@"
MOCK
chmod +x "$BIN/xcrun"
PATH="$BIN:/usr/bin:/bin:/usr/sbin" check fail 'notarytool is not available'
rm "$BIN/xcrun"

rmdir "$RES/FaceEmbedding.mlmodelc" "$RES/Spoof.mlmodelc"
PATH="/usr/bin:/bin:/usr/sbin" check fail 'no FaceEmbedding source'
PATH="/usr/bin:/bin:/usr/sbin" check fail 'no Spoof source'
mkdir -p "$RES/FaceEmbedding.mlmodelc" "$RES/Spoof.mlmodelc"
PATH="/usr/bin:/bin:/usr/sbin" check pass 'PREFLIGHT PASS'
/usr/libexec/PlistBuddy -c 'Delete :NSCameraUsageDescription' "$RES/Info.plist"
PATH="/usr/bin:/bin:/usr/sbin" check fail 'key NSCameraUsageDescription is absent'

cp "$ROOT/Resources/Info.plist" "$RES/Info.plist"
cat > "$BIN/python3" <<'MOCK'
#!/bin/bash
case "$1" in
	*/ModelClearance/validate.py) ;;
	*) exit 2 ;;
esac
echo 'Fixture clearance validator invoked'
exit "${GAZE_FIXTURE_CLEARANCE_STATUS:-0}"
MOCK
chmod +x "$BIN/python3"
MODE=''
PATH="$BIN:/usr/bin:/bin:/usr/sbin" check pass 'Fixture clearance validator invoked'
PATH="$BIN:/usr/bin:/bin:/usr/sbin" GAZE_FIXTURE_CLEARANCE_STATUS=1 check fail 'model/asset clearance evidence is incomplete'
python3 "$ROOT/Tools/Release/ModelClearance/test_validate.py"

echo "PASS: $COUNT preflight checks; synthetic identities and resources, mocked xcrun, no signing or network."
