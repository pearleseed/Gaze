#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/gaze-source-archive.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/Resources" "$FIXTURE/Sources/GazeRecognition" "$FIXTURE/Tools/Scripts"
cp "$ROOT/Tools/Scripts/source-archive.sh" "$FIXTURE/Tools/Scripts/source-archive.sh"
cp "$ROOT/Package.swift" "$FIXTURE/Package.swift"
cp "$ROOT/Resources/Info.plist" "$FIXTURE/Resources/Info.plist"
printf 'Synthetic notice\n' > "$FIXTURE/NOTICE.md"
cp "$ROOT/Sources/GazeRecognition/FaceAligner.swift" "$FIXTURE/Sources/GazeRecognition/FaceAligner.swift"
for model in FaceEmbedding.mlpackage Liveness.mlmodelc Liveness.mlpackage; do
    mkdir -p "$FIXTURE/Resources/$model/weights"
    printf 'fixture weights, not a model\n' > "$FIXTURE/Resources/$model/weights/test.bin"
done
mkdir -p "$FIXTURE/Resources/IrisLandmarks.mlpackage"
printf '{}\n' > "$FIXTURE/Resources/IrisLandmarks.mlpackage/Manifest.json"
cat > "$FIXTURE/bin/git" <<'SH'
#!/bin/bash
test "$1" = -C && test "$3" = ls-files || exit 1
printf '%s\n' 'NOTICE.md' 'Package.swift' 'Resources/Info.plist' \
    'Sources/GazeRecognition/FaceAligner.swift' \
    'Sources/GazeRecognition/RemovedDetector.swift' \
    'Resources/FaceEmbedding.mlpackage/weights/test.bin' \
    'Resources/Liveness.mlmodelc/weights/test.bin' 'Resources/Liveness.mlpackage/weights/test.bin' \
    'Resources/IrisLandmarks.mlpackage/Manifest.json'
SH
chmod +x "$FIXTURE/bin/git"
PATH="$FIXTURE/bin:$PATH" bash "$FIXTURE/Tools/Scripts/source-archive.sh" > "$FIXTURE/output.log"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FIXTURE/Resources/Info.plist")"
unzip -Z1 "$FIXTURE/build/Gaze-$VERSION-source.zip" > "$FIXTURE/contents.txt"
grep -qx 'Package.swift' "$FIXTURE/contents.txt"
grep -qx 'Sources/GazeRecognition/FaceAligner.swift' "$FIXTURE/contents.txt"
grep -qx 'Resources/IrisLandmarks.mlpackage/Manifest.json' "$FIXTURE/contents.txt"
if grep -qx 'Sources/GazeRecognition/RemovedDetector.swift' "$FIXTURE/contents.txt"; then
    echo 'FAIL: a deleted source file entered the archive' >&2
    exit 1
fi
if grep -Eq 'Resources/(FaceEmbedding\.mlpackage|Liveness\.mlmodelc|Liveness\.mlpackage)/' "$FIXTURE/contents.txt"; then
    echo 'FAIL: excluded model payload entered the source archive' >&2
    exit 1
fi
echo 'PASS: source archive keeps Package.swift and Sources/Gaze* Swift source, skips deleted files and excluded model payloads.'
