#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/Tools/Release/Architecture.sh"
if [ -z "${GAZE_ARCHS:-}" ] && [ -n "${1:-}" ] && [ "${DIST:-0}" != "1" ]; then
	GAZE_ARCHS="$(uname -m)"
fi
gaze_require_release_arch "${GAZE_ARCHS:-}" || exit 2
APP="${1:-$ROOT/build/release/$GAZE_ARCHS/Gaze.app}"
BUNDLE_ID=com.pearleseed.Gaze
REQUIRE_DEVELOPER_ID="${GAZE_REQUIRE_DEVELOPER_ID:-0}"
fail() { echo "FAIL: $*" >&2; exit 1; }
test -d "$APP" || fail "Release bundle missing: $APP"
PLIST="$APP/Contents/Info.plist"
test -f "$PLIST" || fail "Bundle Info.plist missing"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "$BUNDLE_ID" || fail "Unexpected bundle identifier"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null)" || fail "Unexpected executable"
test "$EXECUTABLE" = Gaze || fail "Unexpected executable"
test -x "$APP/Contents/MacOS/$EXECUTABLE" || fail "Gaze executable missing"
gaze_verify_bundle_arch "$APP" "$GAZE_ARCHS"
test -f "$APP/Contents/PkgInfo" || fail "Bundle PkgInfo missing"
for key in CFBundleName CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion NSCameraUsageDescription; do
	/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 || fail "Info.plist key $key missing"
done
for model in FaceEmbedding Spoof; do
	test -d "$APP/Contents/Resources/$model.mlmodelc" || fail "Required $model model missing"
done
if [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
	codesign --verify --deep --strict -R="anchor apple generic and identifier \"$BUNDLE_ID\"" "$APP" || fail "Code signature verification failed"
else
	codesign --verify --deep --strict "$APP" || fail "Code signature verification failed"
fi
SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1)" || fail "Signature metadata unavailable"
test "$(printf '%s\n' "$SIGNATURE" | sed -n 's/^Identifier=//p')" = "$BUNDLE_ID" || fail "Signed app identifier mismatch"
TEAM="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p')"
if [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
	printf '%s\n' "$SIGNATURE" | grep -q '^Authority=' || fail "No signing authority (ad-hoc signatures are not supported)"
	printf '%s\n' "$SIGNATURE" | grep -q '^Authority=Developer ID Application: ' || fail "Developer ID Application signature required"
	[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail "No valid signing team"
	printf '%s\n' "$SIGNATURE" | grep -q '^Timestamp=' || fail "Secure timestamp missing"
fi
printf '%s\n' "$SIGNATURE" | grep -q 'flags=.*runtime' || fail "Hardened Runtime missing"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gaze-release-verify.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
codesign -d --entitlements :- "$APP" > "$SCRATCH/entitlements.plist" 2>/dev/null || fail "Entitlements unavailable"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$SCRATCH/entitlements.plist")" = true || fail "Camera entitlement missing"
for entitlement in get-task-allow cs.allow-jit cs.disable-library-validation cs.allow-dyld-environment-variables cs.allow-unsigned-executable-memory cs.disable-executable-page-protection; do
	value="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.$entitlement" "$SCRATCH/entitlements.plist" 2>/dev/null || true)"
	test "$value" != true || fail "Unsafe release entitlement: $entitlement"
done
if [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
	xcrun stapler validate "$APP" || fail "Stapled notarization ticket not validated"
	spctl --assess --type execute --verbose=2 "$APP" || fail "Gatekeeper did not accept the release bundle"
	echo "PASS: bundle, architecture, signed identifier, models, signature, timestamp, entitlements, notarization ticket and Gatekeeper checks"
else
	echo "PASS: un-notarized bundle, architecture, signed identifier, models, signature, runtime and entitlements checks"
fi
echo "Team: ${TEAM:-not set}"
echo "Architecture: $GAZE_ARCHS"
echo "Executable SHA-256: $(shasum -a 256 "$APP/Contents/MacOS/$EXECUTABLE" | awk '{print $1}')"
echo "This is artifact validation, NOT proof of safe recognition, working lock-screen unlock, redistribution rights or clean-install compatibility."
