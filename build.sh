#!/bin/bash
# Builds and signs the standalone Gaze bundle used for local installs and releases.
# For distribution, select one architecture per invocation: DIST=1 GAZE_ARCHS=arm64
# or DIST=1 GAZE_ARCHS=x86_64. Local builds default to the host architecture.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=Tools/Scripts/toolchain.sh
. "$ROOT/Tools/Scripts/toolchain.sh"
. "$ROOT/Tools/Release/Architecture.sh"
. "$ROOT/Tools/Release/Signing.sh"
if [ "${DIST:-}" = "1" ]; then
	gaze_require_release_arch "${GAZE_ARCHS:-}" || exit 2
fi
REQUIRE_DEVELOPER_ID="${GAZE_REQUIRE_DEVELOPER_ID:-0}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)" || {
	echo "Unable to inspect valid signing identities. The existing app was not replaced." >&2
	exit 1
}
SIGNING_FLAGS=(--options runtime)
if [ "${DIST:-}" = "1" ]; then
	IDENTITY="$(GAZE_REQUIRE_DEVELOPER_ID="$REQUIRE_DEVELOPER_ID" gaze_signing_identity 1 "${GAZE_SIGNING_IDENTITY:-}" "$IDENTITIES")" || exit 1
	if [ "$IDENTITY" != "-" ] && { [[ "$IDENTITY" == "Developer ID Application: "* ]] || printf '%s\n' "$IDENTITIES" | grep -F "$IDENTITY" | grep -q 'Developer ID Application: '; }; then
		SIGNING_FLAGS+=(--timestamp)
	fi
else
	IDENTITY="$(gaze_signing_identity 0 "${GAZE_SIGNING_IDENTITY:-}" "$IDENTITIES")" || exit 1
fi
DEFAULT_OUTPUT="$ROOT/build/Gaze.app"
if [ "${DIST:-}" = "1" ]; then
	python3 "$ROOT/Tools/Release/ModelClearance/validate.py" || {
		echo "Release model/asset clearance is incomplete (see NOTICE.md); the existing app was not replaced." >&2
		exit 1
	}
	DEFAULT_OUTPUT="$ROOT/build/release/$GAZE_ARCHS/Gaze.app"
fi
require_toolchain
read -r -a ARCHITECTURES <<<"${GAZE_ARCHS:-$(uname -m)}"
if [ "${#ARCHITECTURES[@]}" -eq 0 ]; then
	echo "GAZE_ARCHS must contain at least one architecture." >&2
	exit 1
fi
ARCH_STRING="${ARCHITECTURES[*]}"
ARCH_KEY="${ARCH_STRING// /-}"
APP="${GAZE_BUILD_OUTPUT:-$DEFAULT_OUTPUT}"
python3 "$ROOT/Tools/Release/check-build-space.py" --output "$APP" --temporary "${TMPDIR:-/tmp}" || {
	echo "Insufficient disk space for a safe build. The existing app was not replaced." >&2
	exit 1
}
SIGNING_REFERENCE="${GAZE_SIGNING_REFERENCE:-$ROOT/build/Gaze.app}"
REFERENCE_REQUIREMENT=""
if [ "${DIST:-}" != "1" ] && [ -d "$SIGNING_REFERENCE" ]; then
	REFERENCE_TEAM="$(codesign -dv "$SIGNING_REFERENCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
	if [ -n "$REFERENCE_TEAM" ] && [ "$REFERENCE_TEAM" != "not set" ]; then
		REFERENCE_REQUIREMENT="$(codesign -d -r- "$SIGNING_REFERENCE" 2>&1 | sed -n 's/^designated => //p')"
		[ -n "$REFERENCE_REQUIREMENT" ] || { echo "Could not read the existing Gaze signing requirement." >&2; exit 1; }
	fi
fi

# A checkout under ~/Documents (or any folder iCloud Drive syncs) has new directories
# stamped with com.apple.FinderInfo and com.apple.fileprovider.fpfs#P by the file
# provider, asynchronously. codesign reads those as "resource fork, Finder information,
# or similar detritus" and refuses the bundle — and the message names the bundle rather
# than the attribute, so it reads as a broken build instead of a stray xattr.
#
# Clearing once is not enough. The provider is watching this tree, which has just been
# rewritten file by file, and it re-stamps a directory while a recursive clear is still
# walking the rest of it — so a clear early in the script has worn off by the time
# signing happens. Clear immediately before each sign instead, and retry for the case
# where the stamp lands in the gap anyway.
#
# com.apple.provenance survives the clear and is harmless; codesign ignores it.
gaze_codesign() {
	local target="${*: -1}" attempt
	for attempt in 1 2 3; do
		xattr -cr "$target" 2>/dev/null || true
		codesign "$@" && return 0
		sleep 0.25
	done
	return 1
}

# Built via xcodebuild into DerivedData, then staged in TMPDIR and swapped in at the end.
#
# In-place rebuilds leave a window where the bundle exists but its executable does not,
# and the Dock draws a prohibitory sign over the icon for as long as that lasts —
# intermittently, depending on when you happen to look.
#
# Signing happens in TMPDIR rather than inside the checkout, because a checkout under
# ~/Documents sits in a folder iCloud Drive syncs: the file provider stamps every
# directory it watches being created with com.apple.FinderInfo, and codesign reads that
# as "resource fork, Finder information, or similar detritus" and refuses the bundle.
#
# TMPDIR is on the same volume as the output, so the swap at the end is still a rename
# and the app is still never on disk half-built. On the unlikely chance TMPDIR is set
# to another volume, the move degrades to a copy: slower, and no longer atomic, but the
# result is the same app.
mkdir -p "$(dirname "$APP")"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/.staging-Gaze.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/Gaze.app"

SDK="${SDKROOT:-$(xcrun --show-sdk-path --sdk macosx)}"
if [ "${DIST:-}" = "1" ] && [ -z "${SDKROOT:-}" ] && read -r dist_sdk _ <<<"$(oldest_usable_sdk)" && [ -n "${dist_sdk:-}" ]; then
	case "$dist_sdk" in
		"$DEVELOPER_DIR"/*) SDK="$dist_sdk" ;;
	esac
fi

BUILD_MODE="local"
USE_LOCAL_MODELS=1
if [ "${DIST:-}" = "1" ]; then
	BUILD_MODE="release"
	USE_LOCAL_MODELS=0
fi
DERIVED_DATA="${GAZE_DERIVED_DATA:-$ROOT/build/DerivedData/$BUILD_MODE-$ARCH_KEY}"

echo "→ Building Gaze ($ARCH_STRING, SDK: $(basename "$SDK"))"
DIST="${DIST:-0}" GAZE_USE_LOCAL_MODELS="$USE_LOCAL_MODELS" \
xcodebuild \
	-project "$ROOT/Gaze.xcodeproj" \
	-scheme Gaze \
	-configuration Release \
	-destination 'generic/platform=macOS' \
	-derivedDataPath "$DERIVED_DATA" \
	ARCHS="$ARCH_STRING" \
	ONLY_ACTIVE_ARCH=NO \
	SDKROOT="$SDK" \
	CODE_SIGNING_ALLOWED=NO \
	build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/Gaze.app"
[ -d "$BUILT_APP" ] || { echo "xcodebuild did not produce $BUILT_APP" >&2; exit 1; }

echo "→ Staging bundle"
ditto --noextattr "$BUILT_APP" "$STAGE"
rm -f "$STAGE/Contents/Resources/.models.stamp"
xattr -cr "$STAGE" 2>/dev/null || true

APPEX="$STAGE/Contents/PlugIns/GazeFinder.appex"
PAM="$STAGE/Contents/Resources/pam_gaze.so"

if [ "${DIST:-}" = "1" ] && [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
	echo "→ Signing release with Developer ID"
elif [ "${DIST:-}" = "1" ]; then
	echo "→ Signing release ($IDENTITY)"
else
	echo "→ Signing with a stable local identity"
fi

gaze_codesign --force --sign "$IDENTITY" "$PAM"

gaze_codesign --force "${SIGNING_FLAGS[@]}" --sign "$IDENTITY" \
	--entitlements "$ROOT/Sources/FinderExtension/GazeFinder.entitlements" \
	--identifier com.pearleseed.Gaze.Finder "$APPEX"

codesign --verify --strict "$APPEX"

gaze_codesign --force "${SIGNING_FLAGS[@]}" --sign "$IDENTITY" \
	--entitlements "$ROOT/Resources/Gaze.entitlements" \
	--identifier com.pearleseed.Gaze "$STAGE"

codesign --verify --deep --strict "$STAGE"
if [ "${DIST:-}" = "1" ]; then
	gaze_verify_bundle_arch "$STAGE" "$GAZE_ARCHS"
	if [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
		SIGNATURE="$(codesign -dv --verbose=4 "$STAGE" 2>&1)"
		printf '%s\n' "$SIGNATURE" | grep -q '^Authority=Developer ID Application: ' || {
			echo "Release signature is not Developer ID Application. Output was not replaced." >&2; exit 1;
		}
		printf '%s\n' "$SIGNATURE" | grep -q '^Timestamp=' || {
			echo "Release signature has no secure timestamp. Output was not replaced." >&2; exit 1;
		}
	fi
fi
if [ -n "$REFERENCE_REQUIREMENT" ]; then
	codesign --verify --strict -R "=$REFERENCE_REQUIREMENT" "$STAGE" || {
		echo "Signing identity differs from the existing Gaze app. The existing bundle was not replaced." >&2
		exit 1
	}
	echo "  ✓ Matches the existing Gaze signing requirement"
fi

echo "→ Swapping in"
# Atomic-ish: the finished bundle replaces the old one in a single rename, so the app is
# never on disk in a half-built state.
rm -rf "$APP.old"
[ -d "$APP" ] && mv "$APP" "$APP.old"
mv "$STAGE" "$APP"
rm -rf "$APP.old"

echo "✓ Built $APP"
