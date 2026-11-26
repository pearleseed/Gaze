#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/gaze-source-archive.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/Resources" "$FIXTURE/Sources/Recognition" "$FIXTURE/Tools/Scripts"
cp "$ROOT/Tools/Scripts/source-archive.sh" "$FIXTURE/Tools/Scripts/source-archive.sh"
cp "$ROOT/Resources/Info.plist" "$FIXTURE/Resources/Info.plist"
printf 'Synthetic notice\n' > "$FIXTURE/NOTICE.md"
cp "$ROOT/Sources/Recognition/FaceAligner.swift" "$FIXTURE/Sources/Recognition/FaceAligner.swift"
for model in FaceEmbedding.mlpackage Liveness.mlmodelc Liveness.mlpackage; do
    mkdir -p "$FIXTURE/Resources/$model/weights"
    printf 'fixture weights, not a model\n' > "$FIXTURE/Resources/$model/weights/test.bin"
done
mkdir -p "$FIXTURE/Resources/IrisLandmarks.mlpackage"
printf '{}\n' > "$FIXTURE/Resources/IrisLandmarks.mlpackage/Manifest.json"
cat > "$FIXTURE/bin/git" <<'SH'
#!/bin/bash
test "$1" = -C && test "$3" = ls-files || exit 1
printf '%s\n' 'NOTICE.md' 'Resources/Info.plist' 'Sources/Recognition/FaceAligner.swift' \
    'Sources/Recognition/RemovedDetector.swift' \
    'Resources/FaceEmbedding.mlpackage/weights/test.bin' \
    'Resources/Liveness.mlmodelc/weights/test.bin' 'Resources/Liveness.mlpackage/weights/test.bin' \
    'Resources/IrisLandmarks.mlpackage/Manifest.json'
SH
chmod +x "$FIXTURE/bin/git"
PATH="$FIXTURE/bin:$PATH" bash "$FIXTURE/Tools/Scripts/source-archive.sh" > "$FIXTURE/output.log"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FIXTURE/Resources/Info.plist")"
unzip -Z1 "$FIXTURE/build/Gaze-$VERSION-source.zip" > "$FIXTURE/contents.txt"
grep -qx 'Sources/Recognition/FaceAligner.swift' "$FIXTURE/contents.txt"
grep -qx 'Resources/IrisLandmarks.mlpackage/Manifest.json' "$FIXTURE/contents.txt"
if grep -qx 'Sources/Recognition/RemovedDetector.swift' "$FIXTURE/contents.txt"; then
    echo 'FAIL: a deleted source file entered the archive' >&2
    exit 1
fi
if grep -Eq 'Resources/(FaceEmbedding\.mlpackage|Liveness\.mlmodelc|Liveness\.mlpackage)/' "$FIXTURE/contents.txt"; then
    echo 'FAIL: excluded model payload entered the source archive' >&2
    exit 1
fi
echo 'PASS: source archive keeps current Swift source and skips deleted files and excluded model payloads.'
