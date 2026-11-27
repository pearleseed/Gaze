#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
COMPILE_ONLY=0
if [ "${1:-}" = "--compile-only" ]; then
	COMPILE_ONLY=1
elif [ "$#" -gt 0 ]; then
	echo "Usage: $0 [--compile-only]" >&2
	exit 2
fi

. "$ROOT/Tests/Scripts/Support/swiftpm.sh"
gaze_swiftpm_setup "$ROOT" GazeRecognition

OUT="$ROOT/build/multiface-check"
APP="$OUT/MultiFaceCheck.app"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -swift-version 6 -warnings-as-errors -sdk "$GAZE_SDK" -target "$(host_target)" \
	-I "$GAZE_SPM_BIN" -L "$GAZE_SPM_BIN" \
	-lGazeRecognition -lGazeCamera -lGazeCore \
	"$ROOT/Tests/Scripts/MultiFace/main.swift" \
	-o "$APP/Contents/MacOS/MultiFaceCheck"

if [ "$COMPILE_ONLY" = 1 ]; then
	echo "PASS: MultiFace harness compiled cleanly under Swift 6."
	exit 0
fi

fetch_face() {
	curl -sL -A 'Mozilla/5.0' "https://thispersondoesnotexist.com/random-person.jpeg?t=$RANDOM" -o "$1"
}
[ -s "$OUT/A.jpg" ] || fetch_face "$OUT/A.jpg"
[ -s "$OUT/B.jpg" ] || { sleep 2; fetch_face "$OUT/B.jpg"; }
tries=0
while cmp -s "$OUT/A.jpg" "$OUT/B.jpg" && [ "$tries" -lt 3 ]; do
	sleep 2
	fetch_face "$OUT/B.jpg"
	tries=$((tries + 1))
done

# Bundle.main lookup needs the model beside the binary, so stage it into the
# tool bundle: prefer the app build, fall back to a prebuilt compiled model.
if [ -d "$ROOT/build/Gaze.app/Contents/Resources/FaceEmbedding.mlmodelc" ]; then
	rm -rf "$APP/Contents/Resources/FaceEmbedding.mlmodelc"
	cp -R "$ROOT/build/Gaze.app/Contents/Resources/FaceEmbedding.mlmodelc" "$APP/Contents/Resources/"
elif [ -d "$ROOT/Resources/FaceEmbedding.mlmodelc" ]; then
	rm -rf "$APP/Contents/Resources/FaceEmbedding.mlmodelc"
	cp -R "$ROOT/Resources/FaceEmbedding.mlmodelc" "$APP/Contents/Resources/"
else
	echo "  ! no FaceEmbedding.mlmodelc staged — check runs on the landmark fallback" >&2
fi

"$APP/Contents/MacOS/MultiFaceCheck" "$OUT"
