#!/bin/bash
# Builds and signs the standalone Gaze bundle used for local installs and releases.
# For distribution, select one architecture per invocation: DIST=1 GAZE_ARCHS=arm64
# or DIST=1 GAZE_ARCHS=x86_64. Local builds default to both architectures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=Tools/Scripts/toolchain.sh
. "$ROOT/Tools/Scripts/toolchain.sh"
. "$ROOT/Tools/Scripts/MainAppSources.sh"
. "$ROOT/Tools/Scripts/BundleResources.sh"
. "$ROOT/Tools/Release/Architecture.sh"
. "$ROOT/Tools/Release/Signing.sh"
if [ "${DIST:-}" = "1" ]; then
	gaze_require_release_arch "${GAZE_ARCHS:-}" || exit 2
fi
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)" || {
	echo "Unable to inspect valid signing identities. The existing app was not replaced." >&2
	exit 1
}
IDENTITY="$(gaze_signing_identity "${DIST:-0}" "${GAZE_SIGNING_IDENTITY:-}" "$IDENTITIES")" || exit 1
DEFAULT_OUTPUT="$ROOT/build/Gaze.app"
SIGNING_FLAGS=(--options runtime)
if [ "${DIST:-}" = "1" ]; then
	python3 "$ROOT/Tools/Release/ModelClearance/validate.py" || {
		echo "Release model/asset clearance is incomplete (see NOTICE.md); the existing app was not replaced." >&2
		exit 1
	}
	DEFAULT_OUTPUT="$ROOT/build/release/$GAZE_ARCHS/Gaze.app"
	SIGNING_FLAGS+=(--timestamp)
fi
collect_gaze_main_sources "$ROOT"
require_toolchain
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

# Built aside and swapped in at the end, rather than deleted and rebuilt in place.
#
# In-place rebuilds leave a window where the bundle exists but its executable does not,
# and the Dock draws a prohibitory sign over the icon for as long as that lasts —
# intermittently, depending on when you happen to look.
#
# Staged in the temporary directory, not beside the output, which is where this used to
# put it. Beside the output is inside the checkout, and a checkout under ~/Documents
# sits in a folder iCloud Drive syncs: the file provider stamps every directory it
# watches being created with com.apple.FinderInfo, and codesign reads that as
# "resource fork, Finder information, or similar detritus" and refuses the bundle. It
# re-stamps as quickly as it can be cleared — a clear immediately before signing still
# lost, three attempts running — so signing inside a managed folder does not work at
# all, and no amount of retrying changes that.
#
# TMPDIR is on the same volume as the output, so the swap at the end is still a rename
# and the app is still never on disk half-built. On the unlikely chance TMPDIR is set
# to another volume, the move degrades to a copy: slower, and no longer atomic, but the
# result is the same app.
mkdir -p "$(dirname "$APP")"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/.staging-Gaze.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/Gaze.app"
BIN="$STAGE/Contents/MacOS/Gaze"

echo "→ Cleaning"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

echo "→ Bundle skeleton"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

echo "→ App icon and Core ML resources"
compile_gaze_app_icon "$ROOT" "$STAGE/Contents/Resources" "$MIN_SDK_MAJOR.0" >/dev/null
LOCAL_MODELS=""
if [ "${DIST:-}" != "1" ]; then LOCAL_MODELS="$ROOT/build/local-models"; fi
stage_gaze_models "$ROOT" "$STAGE/Contents/Resources" "$LOCAL_MODELS"
stage_gaze_iris_notices "$ROOT" "$STAGE/Contents/Resources"

# Bundle the artwork used by setup, the toolbar and the lock screen.
if [ -d "$ROOT/Resources/Art" ]; then
	echo "→ Copying setup art"
	mkdir -p "$STAGE/Contents/Resources/Art"
	cp "$ROOT/Resources/Art/"*.png "$STAGE/Contents/Resources/Art/" 2>/dev/null || true
	# The native unlock animation uses video clips alongside its resting frames.
	cp "$ROOT/Resources/Art/"*.mp4 "$STAGE/Contents/Resources/Art/" 2>/dev/null || true
	# Screenshots arrive with Finder metadata attached — a resource fork from a Quick Look
	# edit, a "where from" attribute from a download. codesign refuses to sign a bundle
	# containing any of it ("resource fork, Finder information, or similar detritus not
	# allowed"), and the error names the bundle rather than the file, so it reads as a
	# broken build rather than a stray xattr on one PNG.
	xattr -cr "$STAGE/Contents/Resources/Art" 2>/dev/null || true
	art_count=$(find "$STAGE/Contents/Resources/Art" \( -name '*.png' -o -name '*.mp4' \) | wc -l | tr -d ' ')
	echo "  ✓ $art_count image(s)"
fi

# The credits avatars — each person's own picture, or their app's icon.
#
# Bundled rather than fetched. The site pulls these from GitHub *on the server* precisely
# so that reading the credits page does not hand GitHub the IP of everyone who reads it;
# an app that fetched them at runtime would do exactly what the site went out of its way
# to avoid, once per launch, from every user's Mac. These are snapshots, resized to 128pt
# — ample for a 26pt row at 2x, and the difference between 148KB and 3.7MB in the bundle.
if [ -d "$ROOT/Resources/Credits" ]; then
	echo "→ Copying credit portraits"
	mkdir -p "$STAGE/Contents/Resources/Credits"
	cp "$ROOT/Resources/Credits/"*.png "$STAGE/Contents/Resources/Credits/" 2>/dev/null || true
	# Same Finder-metadata problem as the setup art; same fix.
	xattr -cr "$STAGE/Contents/Resources/Credits" 2>/dev/null || true
	credit_count=$(find "$STAGE/Contents/Resources/Credits" -name '*.png' | wc -l | tr -d ' ')
	echo "  ✓ $credit_count portrait(s)"
fi

# Metal shaders (the lock screen's Liquid Glass) become default.metallib, which SwiftUI's
# ShaderLibrary.default loads from the main bundle's Resources.
metal_sources=("$ROOT"/Sources/*/*.metal)
if [ -e "${metal_sources[0]}" ]; then
	echo "→ Compiling Metal shaders"
	metal_air=()
	for source in "${metal_sources[@]}"; do
		air="$STAGE_ROOT/$(basename "$source" .metal).air"
		xcrun -sdk macosx metal -c -O3 -mmacosx-version-min="${MIN_SDK_MAJOR}.0" "$source" -o "$air"
		metal_air+=("$air")
	done
	xcrun -sdk macosx metallib "${metal_air[@]}" -o "$STAGE/Contents/Resources/default.metallib"
	echo "  ✓ default.metallib (${#metal_air[@]} file(s))"
fi

# TourKit's MIT licence ships in the bundle because its source is compiled in.
cp "$ROOT/ThirdParty/TourKit/LICENSE" "$STAGE/Contents/Resources/TourKit-LICENSE.txt"
echo "  ✓ TourKit-LICENSE.txt"

# A distribution build links against the oldest SDK installed that still compiles this,
# so the binary cannot reference a symbol an older Mac lacks. The linker also has to be
# told the SDK version explicitly: left alone it stamps the toolchain's newest regardless
# of -sdk, and that stamp is part of how the loader decides what to allow.
SDK_FLAGS=()
if [ "${DIST:-}" = "1" ] && read -r dist_sdk dist_version <<<"$(oldest_usable_sdk)" && [ -n "${dist_sdk:-}" ]; then
	SDK="$dist_sdk"
	SDK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_SDK_MAJOR.0" -Xlinker "$dist_version")
else
	SDK="${SDKROOT:-$(xcrun --show-sdk-path --sdk macosx)}"
fi

# The Shortcuts action (Sources/App/ConfirmIdentityIntent.swift) imports AppIntents.
# Linked only when the file is present, so checkouts without it still build.
APP_INTENTS_FLAGS=()
if [ -f "$ROOT/Sources/App/ConfirmIdentityIntent.swift" ]; then
	# The compiler also writes the intent's constant values, which the metadata
	# step below turns into Metadata.appintents: without that file Shortcuts never
	# lists the action.
	APP_INTENTS_FLAGS=(-framework AppIntents
		-emit-const-values-path "$STAGE_ROOT/Gaze.swiftconstvalues"
		-Xfrontend -const-gather-protocols-file
		-Xfrontend "$ROOT/Tools/Scripts/app-intents-protocols.json")
fi

read -r -a ARCHITECTURES <<<"${GAZE_ARCHS:-arm64 x86_64}"
if [ "${#ARCHITECTURES[@]}" -eq 0 ]; then
	echo "GAZE_ARCHS must contain at least one architecture." >&2
	exit 1
fi

# Local universal builds merge slices. A release compiles straight to the final binary.
compile_swift_binary() {
	local output="$1" module="$2"
	shift 2
	local slices=() arch slice
	for arch in "${ARCHITECTURES[@]}"; do
		slice="$output"
		if [ "${#ARCHITECTURES[@]}" -gt 1 ]; then
			slice="$STAGE_ROOT/$module-$arch"
		fi
		echo "→ Compiling $module ($arch, SDK: $(basename "$SDK"))"
		xcrun swiftc -parse-as-library -module-name "$module" -O -wmo \
			-target "$arch-apple-macos${MIN_SDK_MAJOR}.0" -sdk "$SDK" \
			${SDK_FLAGS[@]+"${SDK_FLAGS[@]}"} "$@" -o "$slice" || return
		slices+=("$slice")
	done
	if [ "${#slices[@]}" -gt 1 ]; then
		lipo -create -output "$output" "${slices[@]}"
	fi
}

compile_swift_binary "$BIN" Gaze \
	-framework SwiftUI -framework AppKit -framework AVFoundation -framework Vision \
	-framework CoreML -framework CryptoKit -framework LocalAuthentication \
	-framework OpenDirectory -framework FinderSync \
	${APP_INTENTS_FLAGS[@]+"${APP_INTENTS_FLAGS[@]}"} "${GAZE_MAIN_SOURCES[@]}"

APPEX="$STAGE/Contents/PlugIns/GazeFinder.appex"
mkdir -p "$APPEX/Contents/MacOS"
compile_swift_binary "$APPEX/Contents/MacOS/GazeFinder" GazeFinder \
	-application-extension -framework Cocoa -framework FinderSync \
	-Xlinker -e -Xlinker _NSExtensionMain \
	"$ROOT"/Sources/FinderExtension/*.swift "$ROOT/Sources/Security/AppLockStore.swift"
cp "$ROOT/Sources/FinderExtension/Info.plist" "$APPEX/Contents/Info.plist"
stamp_gaze_bundle_version "$STAGE/Contents/Info.plist" "$APPEX/Contents/Info.plist"
echo "  ✓ GazeFinder.appex"

# The sudo PAM module. Loaded by /usr/bin/sudo once the user turns on "Approve sudo
# with your face"; SudoApproval copies it to /Library/Security/Gaze. Signed with the app.
PAM_ARCH_FLAGS=()
for arch in "${ARCHITECTURES[@]}"; do PAM_ARCH_FLAGS+=(-arch "$arch"); done
compile_gaze_pam_module "$ROOT/Sources/PAM/pam_gaze.c" "$STAGE/Contents/Resources/pam_gaze.so" \
	"$SDK" "$MIN_SDK_MAJOR.0" "${PAM_ARCH_FLAGS[@]}"
gaze_codesign --force --sign "$IDENTITY" "$STAGE/Contents/Resources/pam_gaze.so"
echo "  ✓ pam_gaze.so"

# Shortcuts metadata, normally made by Xcode. Optional: a failure here only costs
# the Shortcuts action, never the build.
if [ -f "$STAGE_ROOT/Gaze.swiftconstvalues" ] && xcrun -f appintentsmetadataprocessor >/dev/null 2>&1; then
	echo "$STAGE_ROOT/Gaze.swiftconstvalues" > "$STAGE_ROOT/constvals.txt"
	printf '%s\n' "${GAZE_MAIN_SOURCES[@]}" > "$STAGE_ROOT/sources.txt"
	first_arch="${ARCHITECTURES[0]}"
	if xcrun appintentsmetadataprocessor \
		--output "$STAGE/Contents/Resources" \
		--toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun -f swift)")")")" \
		--module-name Gaze \
		--sdk-root "$SDK" \
		--xcode-version "$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')" \
		--platform-family macOS \
		--deployment-target "${MIN_SDK_MAJOR}.0" \
		--target-triple "$first_arch-apple-macos${MIN_SDK_MAJOR}.0" \
		--source-file-list "$STAGE_ROOT/sources.txt" \
		--swift-const-vals-list "$STAGE_ROOT/constvals.txt" \
		--binary-file "$BIN" \
		--dependency-file "$STAGE_ROOT/intents.d" \
		--stringsdata-file "$STAGE_ROOT/intents.stringsdata" \
		--force >/dev/null 2>&1; then
		echo "  ✓ Shortcuts metadata"
	else
		echo "  ! Shortcuts metadata failed; the Confirm It's You action won't appear in Shortcuts."
	fi
fi

if [ "${DIST:-}" = "1" ]; then
	echo "→ Signing release with Developer ID"
else
	echo "→ Signing with a stable local identity"
fi

gaze_codesign --force "${SIGNING_FLAGS[@]}" --sign "$IDENTITY" \
	--entitlements "$ROOT/Sources/FinderExtension/GazeFinder.entitlements" \
	--identifier com.gazeunlock.Gaze.Finder "$APPEX"

codesign --verify --strict "$APPEX"

gaze_codesign --force "${SIGNING_FLAGS[@]}" --sign "$IDENTITY" \
	--entitlements "$ROOT/Resources/Gaze.entitlements" \
	--identifier com.gazeunlock.Gaze "$STAGE"

codesign --verify --strict "$STAGE"
if [ "${DIST:-}" = "1" ]; then
	gaze_verify_bundle_arch "$STAGE" "$GAZE_ARCHS"
	SIGNATURE="$(codesign -dv --verbose=4 "$STAGE" 2>&1)"
	printf '%s\n' "$SIGNATURE" | grep -q '^Authority=Developer ID Application: ' || {
		echo "Release signature is not Developer ID Application. Output was not replaced." >&2; exit 1;
	}
	printf '%s\n' "$SIGNATURE" | grep -q '^Timestamp=' || {
		echo "Release signature has no secure timestamp. Output was not replaced." >&2; exit 1;
	}
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
