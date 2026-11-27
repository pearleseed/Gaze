#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gaze-release-fixture.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
APP="$SCRATCH/Gaze.app"
BIN="$SCRATCH/bin"
FINDER="$APP/Contents/PlugIns/GazeFinder.appex/Contents/MacOS/GazeFinder"
PAM="$APP/Contents/Resources/pam_gaze.so"
mkdir -p "$BIN" "$APP/Contents/MacOS" "$APP/Contents/Resources/FaceEmbedding.mlmodelc" \
	"$APP/Contents/Resources/Spoof.mlmodelc" "$(dirname "$FINDER")" \
	"$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
touch "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
set_architecture() {
	for binary in "$APP/Contents/MacOS/Gaze" "$FINDER" "$PAM"; do
		printf '%s\n' "$1" > "$binary"
	done
}
set_architecture arm64
chmod +x "$APP/Contents/MacOS/Gaze"
cp "$ROOT/Resources/Gaze.entitlements" "$SCRATCH/entitlements.plist"
export GAZE_TEST_ENTITLEMENTS="$SCRATCH/entitlements.plist"
cat > "$BIN/codesign" <<'MOCK'
#!/bin/bash
case "$1" in
	--verify)
		if [ "${GAZE_REQUIRE_DEVELOPER_ID:-0}" = "1" ]; then
			case "$*" in *'anchor apple generic'*) ;; *) exit 91 ;; esac
		fi
		test "${GAZE_TEST_FAILURE:-}" != signature ;;
	-dv)
		if [ "${GAZE_TEST_FAILURE:-}" = app-id ]; then
			echo 'Identifier=wrong.fixture' >&2
		else
			echo 'Identifier=com.pearleseed.Gaze' >&2
		fi
		if [ "${GAZE_TEST_FAILURE:-}" = adhoc ]; then
			echo 'Signature=adhoc' >&2
		else
			if [ "${GAZE_TEST_FAILURE:-}" = authority ]; then
				echo 'Authority=Apple Development: Fixture' >&2
			else
				echo 'Authority=Developer ID Application: Fixture' >&2
			fi
			if [ "${GAZE_TEST_FAILURE:-}" = team ]; then
				echo 'TeamIdentifier=WRONG' >&2
			else
				echo 'TeamIdentifier=CAAVJCSL92' >&2
			fi
		fi
		[ "${GAZE_TEST_FAILURE:-}" = timestamp ] || [ "${GAZE_TEST_FAILURE:-}" = adhoc ] || echo 'Timestamp=Fixture' >&2
		[ "${GAZE_TEST_FAILURE:-}" = runtime ] || echo 'CodeDirectory flags=0x10000(runtime)' >&2
		exit 0 ;;
	-d) cat "$GAZE_TEST_ENTITLEMENTS" ;;
	*) exit 90 ;;
esac
MOCK
cat > "$BIN/xcrun" <<'MOCK'
#!/bin/bash
test "$1" = stapler && test "$2" = validate && test "${GAZE_TEST_FAILURE:-}" != stapler
MOCK
cat > "$BIN/spctl" <<'MOCK'
#!/bin/bash
test "$1" = --assess && test "${GAZE_TEST_FAILURE:-}" != gatekeeper
MOCK
cat > "$BIN/lipo" <<'MOCK'
#!/bin/bash
test "$1" = -archs || exit 1
cat "$2"
MOCK
chmod +x "$BIN/"*
export PATH="$BIN:$PATH"
export GAZE_ARCHS=arm64
COUNT=0
check() {
	local expected="$1" marker="$2" actual=0
	bash "$ROOT/Tools/Release/verify.sh" "$APP" > "$SCRATCH/output" 2>&1 || actual=$?
	if [ "$expected" = pass ]; then
		test "$actual" = 0 || { cat "$SCRATCH/output"; exit 1; }
	else
		test "$actual" != 0 || { echo "FAIL: unsafe fixture passed" >&2; exit 1; }
	fi
	grep -Fq "$marker" "$SCRATCH/output" || { cat "$SCRATCH/output"; exit 1; }
	COUNT=$((COUNT + 1))
}

# Default posture (1B): un-notarized bundle verification (GAZE_REQUIRE_DEVELOPER_ID=0 by default).
unset GAZE_REQUIRE_DEVELOPER_ID || true
check pass 'PASS: un-notarized bundle'
check pass 'artifact validation, NOT proof'
GAZE_TEST_FAILURE=authority check pass 'PASS: un-notarized bundle'
GAZE_TEST_FAILURE=adhoc check pass 'PASS: un-notarized bundle'
# Ad-hoc Hardened Runtime builds allow disable-library-validation solely to load Sparkle.framework.
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$GAZE_TEST_ENTITLEMENTS"
GAZE_TEST_FAILURE=adhoc check pass 'PASS: un-notarized bundle'
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.cs.disable-library-validation' "$GAZE_TEST_ENTITLEMENTS"
GAZE_TEST_FAILURE=stapler check pass 'PASS: un-notarized bundle'
GAZE_TEST_FAILURE=gatekeeper check pass 'PASS: un-notarized bundle'
GAZE_TEST_FAILURE=timestamp check pass 'PASS: un-notarized bundle'
for failure in signature runtime; do
	export GAZE_TEST_FAILURE="$failure"
	check fail 'FAIL:'
done
export GAZE_TEST_FAILURE=app-id
check fail 'Signed app identifier mismatch'
unset GAZE_TEST_FAILURE

# Strict Developer ID + notarization posture (GAZE_REQUIRE_DEVELOPER_ID=1).
export GAZE_REQUIRE_DEVELOPER_ID=1
check pass 'notarization ticket and Gatekeeper checks'
check pass 'Team: CAAVJCSL92'
for failure in signature authority timestamp runtime stapler gatekeeper; do
	export GAZE_TEST_FAILURE="$failure"
	check fail 'FAIL:'
done
export GAZE_TEST_FAILURE=app-id
check fail 'Signed app identifier mismatch'
export GAZE_TEST_FAILURE=team
check fail 'No valid signing team'
export GAZE_TEST_FAILURE=adhoc
check fail 'No signing authority'
export GAZE_TEST_FAILURE=authority
check fail 'Developer ID Application signature required'
unset GAZE_TEST_FAILURE

check pass 'Architecture: arm64'
set_architecture 'arm64 x86_64'
check fail 'expected only arm64'
set_architecture x86_64
check fail 'expected only arm64'
GAZE_ARCHS=x86_64 check pass 'Architecture: x86_64'
printf 'arm64 x86_64\n' > "$FINDER"
GAZE_ARCHS=x86_64 check fail 'GazeFinder: expected only x86_64'
set_architecture x86_64
printf 'arm64\n' > "$PAM"
GAZE_ARCHS=x86_64 check fail 'pam_gaze.so: expected only x86_64'
set_architecture arm64
mv "$PAM" "$SCRATCH/module"
check fail 'Missing release binary: Contents/Resources/pam_gaze.so'
mv "$SCRATCH/module" "$PAM"
for entitlement in get-task-allow cs.allow-jit cs.disable-library-validation cs.allow-dyld-environment-variables cs.allow-unsigned-executable-memory cs.disable-executable-page-protection; do
	/usr/libexec/PlistBuddy -c "Add :com.apple.security.$entitlement bool true" "$GAZE_TEST_ENTITLEMENTS"
	check fail 'Unsafe release entitlement'
	/usr/libexec/PlistBuddy -c "Delete :com.apple.security.$entitlement" "$GAZE_TEST_ENTITLEMENTS"
done
/usr/libexec/PlistBuddy -c 'Set :com.apple.security.device.camera false' "$GAZE_TEST_ENTITLEMENTS"
check fail 'Camera entitlement missing'
/usr/libexec/PlistBuddy -c 'Set :com.apple.security.device.camera true' "$GAZE_TEST_ENTITLEMENTS"
printf 'invalid plist' > "$GAZE_TEST_ENTITLEMENTS"
check fail 'Camera entitlement missing'
cp "$ROOT/Resources/Gaze.entitlements" "$GAZE_TEST_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier example.invalid.fixture' "$APP/Contents/Info.plist"
check fail 'Unexpected bundle identifier'
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable GazeHelper' "$APP/Contents/Info.plist"
check fail 'Unexpected executable'
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mv "$APP/Contents/PkgInfo" "$SCRATCH/PkgInfo"
check fail 'Bundle PkgInfo missing'
mv "$SCRATCH/PkgInfo" "$APP/Contents/PkgInfo"
mv "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" "$SCRATCH/Sparkle"
check fail 'Required Sparkle.framework missing'
mv "$SCRATCH/Sparkle" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
for key in NSCameraUsageDescription SUFeedURL SUPublicEDKey; do
	/usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist"
	check fail "Info.plist key $key missing"
	cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
done
for model in FaceEmbedding Spoof; do
	mv "$APP/Contents/Resources/$model.mlmodelc" "$SCRATCH/$model.mlmodelc"
	check fail "Required $model model missing"
	mv "$SCRATCH/$model.mlmodelc" "$APP/Contents/Resources/$model.mlmodelc"
done
chmod -x "$APP/Contents/MacOS/Gaze"
check fail 'Gaze executable missing'
chmod +x "$APP/Contents/MacOS/Gaze"
mv "$APP/Contents/Info.plist" "$SCRATCH/Info.plist"
check fail 'Bundle Info.plist missing'
mv "$SCRATCH/Info.plist" "$APP/Contents/Info.plist"
check pass 'Architecture: arm64'
echo "PASS: $COUNT artifact-verifier checks (1B un-notarized default + strict Developer ID); synthetic bundle, mocked signing/notarization tools, no network or app launch."
