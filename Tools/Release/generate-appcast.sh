#!/bin/bash
# Generates and verifies Sparkle 2 EdDSA-signed appcast feeds (appcast-arm64.xml and
# appcast-x86_64.xml) from packaged Gaze DMGs in build/installers/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLERS_DIR="$ROOT/build/installers"
ACCOUNT="com.pearleseed.Gaze"
TAG=""
NOTES_FILE=""
SPARKLE_BIN="${SPARKLE_BIN:-}"

usage() {
	cat <<'EOF'
Usage: Tools/Release/generate-appcast.sh [--tag vX.Y.Z] [--installers-dir DIR] [--notes-file FILE] [--account NAME]
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--tag) TAG="${2:-}"; shift 2 ;;
		--installers-dir) INSTALLERS_DIR="${2:-}"; shift 2 ;;
		--notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
		--account) ACCOUNT="${2:-}"; shift 2 ;;
		--help|-h) usage; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")"
TAG="${TAG:-v$VERSION}"

find_sparkle_tool() {
	local tool="$1" candidate
	for candidate in \
		"${SPARKLE_BIN:+$SPARKLE_BIN/$tool}" \
		"$ROOT/build/sparkle-tools/bin/$tool" \
		"$ROOT/.build/artifacts/sparkle/Sparkle/bin/$tool" \
		"$ROOT/build/DerivedData/release-arm64/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool"; do
		if [ -n "$candidate" ] && [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

GENERATE_APPCAST="$(find_sparkle_tool generate_appcast)" || {
	echo "Missing Sparkle generate_appcast binary. Set SPARKLE_BIN or unpack Sparkle tools in build/sparkle-tools/." >&2
	exit 1
}
SIGN_UPDATE="$(find_sparkle_tool sign_update)" || {
	echo "Missing Sparkle sign_update binary." >&2
	exit 1
}

DOWNLOAD_PREFIX="https://github.com/pearleseed/Gaze/releases/download/$TAG/"
RELEASE_LINK="https://github.com/pearleseed/Gaze/releases/tag/$TAG"
FULL_NOTES_URL="https://github.com/pearleseed/Gaze/releases"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gaze-appcast.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

for arch in arm64 x86_64; do
	DMG="$INSTALLERS_DIR/Gaze-$VERSION-$BUILD-$arch.dmg"
	if [ ! -f "$DMG" ]; then
		echo "Missing DMG for $arch: $DMG" >&2
		exit 1
	fi

	ARCH_DIR="$SCRATCH/$arch"
	mkdir -p "$ARCH_DIR"
	ln -s "$DMG" "$ARCH_DIR/$(basename "$DMG")"

	if [ -n "$NOTES_FILE" ]; then
		NOTES_EXT="${NOTES_FILE##*.}"
		BASE_NAME="$(basename "$DMG" .dmg)"
		cp "$NOTES_FILE" "$ARCH_DIR/$BASE_NAME.$NOTES_EXT"
	fi

	OUT_XML="$INSTALLERS_DIR/appcast-$arch.xml"
	"$GENERATE_APPCAST" \
		--account "$ACCOUNT" \
		--download-url-prefix "$DOWNLOAD_PREFIX" \
		--link "$RELEASE_LINK" \
		--full-release-notes-url "$FULL_NOTES_URL" \
		--embed-release-notes \
		-o "$OUT_XML" \
		"$ARCH_DIR"

	# Verify the generated EdDSA signature directly against the DMG artifact.
	ED_SIG="$(python3 - "$OUT_XML" <<'PY'
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
enc = tree.find(".//item/enclosure")
if enc is None:
    sys.exit("Missing <enclosure> in generated appcast")
sig = enc.attrib.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", "")
if not sig:
    sys.exit("Missing sparkle:edSignature in generated appcast")
print(sig)
PY
)"
	"$SIGN_UPDATE" --account "$ACCOUNT" --verify "$DMG" "$ED_SIG"
	echo "✓ Generated & verified $OUT_XML"
done
