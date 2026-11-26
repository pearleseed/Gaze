#!/bin/bash
# Builds the source archive published on gazeunlock.com.
#
# Not a zip of the working directory. It is built from what git tracks, which
# means anything ignored cannot end up in it by accident — and two of the
# ignored things are other people's property that must never be redistributed:
# FaceIDKit, and whatever else lands in Frameworks/.
#
# Then two tracked things are dropped as well, because tracking is not the same
# as being ours to licence. See NOTICE below.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
OUT="$ROOT/build/Gaze-$VERSION-source.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Excluded from the archive, by path prefix.
#
# The recognition model is the important one. It is InsightFace's ArcFace
# (w600k_r50) by deepinsight, first obtained via Sapphire, which bundles the
# same model; its weights are licensed for non-commercial research use — so it
# is not ours to hand out under MIT. Shipping
# it inside an archive that says MIT on the front would be claiming a grant
# nobody gave.
EXCLUDE=(
	"Resources/FaceEmbedding.mlmodel"
	"Resources/FaceEmbedding.mlpackage/"
	"Resources/Liveness.mlmodelc/"
	"Resources/Liveness.mlpackage/"
)

echo "→ Collecting tracked files"
mkdir -p "$STAGE/src"
count=0
while IFS= read -r file; do
	skip=""
	for prefix in "${EXCLUDE[@]}"; do
		case "$file" in "$prefix"*) skip=1 ;; esac
	done
	[ -n "$skip" ] && continue
	# The index can still list files removed from the working tree.
	[ -e "$ROOT/$file" ] || [ -L "$ROOT/$file" ] || continue
	mkdir -p "$STAGE/src/$(dirname "$file")"
	cp "$ROOT/$file" "$STAGE/src/$file"
	count=$((count + 1))
done < <(git -C "$ROOT" ls-files)
echo "  ✓ $count files"

# The repository's own NOTICE.md is the source of truth for credits, so the archive
# carries that rather than a second copy that would drift out of step with it.
cp "$ROOT/NOTICE.md" "$STAGE/src/NOTICE.md"

cat >> "$STAGE/src/NOTICE.md" <<'NOTICE'

# What is not in this archive

The following resources are excluded from the archive. The app builds without them.

## The recognition model

`Resources/FaceEmbedding.mlpackage` — the model faces are matched against. It
is InsightFace's ArcFace (w600k_r50) by deepinsight, first obtained via
Sapphire, which bundles the same model, and is not ours to redistribute. Without it
the app falls back to comparing facial landmarks directly, which is much
weaker: it can tell you from a stranger, and not much more.

## FaceIDKit

Earlier versions used Aviorrok's private FaceIDKit framework for setup animations.
Current setup animations are rendered by the bundled Gaze companion code.

## Legacy texture model

`Resources/Liveness.mlmodelc` and `Resources/Liveness.mlpackage` are excluded.
The current app does not use this model. Photo rejection uses the separate
Spoof detector, and movement challenges do not depend on the legacy weights.

## What that means for building

`./build.sh` builds with the available resources and reports a missing recognition
model. The legacy texture model is excluded from app bundles too.
NOTICE

echo "→ Packing"
mkdir -p "$ROOT/build"
rm -f "$OUT"
(cd "$STAGE/src" && zip -qr "$OUT" .)

# Belt and braces. The exclusion above is a string comparison, and a rename
# upstream would silently defeat it — so the finished archive is inspected for
# the things that must not be in it rather than trusted to be right.
echo "→ Checking"
archive_paths="$(unzip -Z1 "$OUT")"
# The public Iris package contains only its manifest. Any package payload
# still fails the check below.
archive_paths="$(grep -Fvx \
	-e 'Resources/IrisLandmarks.mlpackage/' \
	-e 'Resources/IrisLandmarks.mlpackage/Manifest.json' <<<"$archive_paths")"
if leaked="$(grep -iE 'FaceIDKit|\.mlpackage(/|$)|(^|/)Frameworks/|Resources/(FaceEmbedding|Liveness)\.mlmodel' <<<"$archive_paths")"; then
	echo "  ✗ Unexpected files in the source archive:" >&2
	printf '%s\n' "$leaked" >&2
	exit 1
fi

echo "  ✓ nothing that shouldn't be"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
