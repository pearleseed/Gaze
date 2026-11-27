#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/Tools/Release/Signing.sh"
DEV_HASH=1111111111111111111111111111111111111111
RELEASE_HASH=2222222222222222222222222222222222222222
FIXTURE="  1) $DEV_HASH \"Apple Development: Test (TEAM)\"
  2) $RELEASE_HASH \"Developer ID Application: Test (TEAM)\"
     2 valid identities found"
DEV_ONLY="  1) $DEV_HASH \"Apple Development: Test (TEAM)\"
     1 valid identities found"

# Default 1B un-notarized posture (GAZE_REQUIRE_DEVELOPER_ID=0 by default):
# - Local builds (mode 0) keep using Apple Development when present.
# - Distribution builds (mode 1) prefer Developer ID Application, and otherwise
#   default to portable ad-hoc ('-') rather than embedding a personal Apple Development cert.
unset GAZE_REQUIRE_DEVELOPER_ID || true
test "$(gaze_signing_identity 0 '' "$FIXTURE")" = "$DEV_HASH"
test "$(gaze_signing_identity 0 '' "$DEV_ONLY")" = "$DEV_HASH"
test "$(gaze_signing_identity 1 '' "$FIXTURE")" = "$RELEASE_HASH"
test "$(gaze_signing_identity 1 '' "$DEV_ONLY")" = '-'
test "$(gaze_signing_identity 1 "$DEV_HASH" "$DEV_ONLY")" = "$DEV_HASH"
test "$(gaze_signing_identity 1 '' '0 valid identities found')" = '-'
test "$(gaze_signing_identity 1 '-' "$FIXTURE")" = '-'
test "$(gaze_signing_identity 0 '-' "$FIXTURE")" = '-'
if gaze_signing_identity 0 '' '0 valid identities found' >/dev/null 2>&1; then
	echo "FAIL: local missing identity accepted" >&2; exit 1
fi

# Strict Developer ID posture (GAZE_REQUIRE_DEVELOPER_ID=1).
export GAZE_REQUIRE_DEVELOPER_ID=1
test "$(gaze_signing_identity 0 '' "$FIXTURE")" = "$DEV_HASH"
test "$(gaze_signing_identity 1 '' "$FIXTURE")" = "$RELEASE_HASH"
test "$(gaze_signing_identity 1 "$RELEASE_HASH" "$FIXTURE")" = "$RELEASE_HASH"
test "$(gaze_signing_identity 1 'Developer ID Application: Test (TEAM)' "$FIXTURE")" = "$RELEASE_HASH"
test "$(gaze_signing_identity 0 "$RELEASE_HASH" "$FIXTURE")" = "$RELEASE_HASH"
for requested in '-' "$DEV_HASH" 'Apple Development: Test (TEAM)' missing 'Developer ID Application: Test'; do
	if gaze_signing_identity 1 "$requested" "$FIXTURE" >/dev/null 2>&1; then
		echo "FAIL: invalid release identity accepted under strict mode" >&2; exit 1
	fi
done
for mode in 0 1; do
	if gaze_signing_identity "$mode" '' '0 valid identities found' >/dev/null 2>&1; then
		echo "FAIL: missing identity accepted under strict mode" >&2; exit 1
	fi
done
if gaze_signing_identity 1 '-' "$FIXTURE" >/dev/null 2>&1; then
	echo "FAIL: ad-hoc release identity accepted under strict mode" >&2; exit 1
fi
test "$(gaze_signing_identity 0 '-' "$FIXTURE")" = '-'
if gaze_signing_identity 1 '' "$DEV_ONLY" >/dev/null 2>&1; then
	echo "FAIL: development-only machine accepted for strict release" >&2; exit 1
fi
unset GAZE_REQUIRE_DEVELOPER_ID

node - "$ROOT" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = process.argv[2];
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');

const build = read('build.sh');
assert(build.indexOf('gaze_signing_identity ') < build.indexOf('\nrequire_toolchain'));
assert(build.indexOf('gaze_signing_identity ') < build.indexOf('mktemp -d'));
assert(build.includes('DEFAULT_OUTPUT="$ROOT/build/release/$GAZE_ARCHS/Gaze.app"'));
assert(build.includes('SIGNING_FLAGS+=(--timestamp)'));
assert(build.includes('SIGNING_FLAGS=(--options runtime)'));
assert(build.includes('REQUIRE_DEVELOPER_ID="${GAZE_REQUIRE_DEVELOPER_ID:-0}"'));
assert(build.includes('--identifier com.pearleseed.Gaze.Finder'));
assert(build.includes('--identifier com.pearleseed.Gaze'));
assert(build.indexOf("'^Authority=Developer ID Application: '") < build.indexOf('mv "$STAGE" "$APP"'));
assert(build.indexOf("'^Timestamp='") < build.indexOf('mv "$STAGE" "$APP"'));
assert(build.includes('codesign --verify --strict -R "=$REFERENCE_REQUIREMENT"'));

const signingSection = build.slice(
	build.indexOf('SIGNING_FLAGS=(--options runtime)'),
	build.indexOf('DEFAULT_OUTPUT="$ROOT/build/Gaze.app"')
);
const distSigningBranch = signingSection.slice(
	signingSection.indexOf('if [ "${DIST:-}" = "1" ]'),
	signingSection.indexOf('\nelse\n')
);
assert(distSigningBranch.includes('gaze_signing_identity 1 '), 'DIST=1 must use gaze_signing_identity 1');
assert(!distSigningBranch.includes('gaze_signing_identity 0'), 'DIST=1 must not bypass mode 1 with gaze_signing_identity 0');
assert(distSigningBranch.includes('GAZE_REQUIRE_DEVELOPER_ID="$REQUIRE_DEVELOPER_ID"'), 'DIST=1 must pass REQUIRE_DEVELOPER_ID to gaze_signing_identity');

// Package.swift + Sources/Gaze* modular layout.
const pkg = read('Package.swift');
for (const mod of [
	'GazeCore', 'GazeTourKit', 'GazeDesign', 'GazeCamera',
	'GazeRecognition', 'GazeLockScreen', 'GazeSecurity', 'GazeUpdates', 'GazeApp'
]) {
	assert(pkg.includes(`.target(\n\t\t\tname: "${mod}"`) || pkg.includes(`name: "${mod}"`), `Package.swift missing ${mod}`);
	assert(fs.statSync(path.join(root, 'Sources', mod)).isDirectory(), `Sources/${mod} missing`);
}
assert(fs.statSync(path.join(root, 'Sources', 'GazeEntry')).isDirectory(), 'Sources/GazeEntry missing');

// Identity: com.pearleseed.Gaze & pearleseed/Gaze.
assert(read('Resources/Info.plist').includes('<string>com.pearleseed.Gaze</string>'));
assert(read('Xcode/Gaze.xcconfig').includes('PRODUCT_BUNDLE_IDENTIFIER = com.pearleseed.Gaze'));
assert(read('Xcode/GazeFinder.xcconfig').includes('PRODUCT_BUNDLE_IDENTIFIER = com.pearleseed.Gaze.Finder'));
assert(read('Tools/Release/verify.sh').includes('BUNDLE_ID=com.pearleseed.Gaze'));
assert(read('Tools/Release/verify.sh').includes('REQUIRE_DEVELOPER_ID="${GAZE_REQUIRE_DEVELOPER_ID:-0}"'));
assert(read('Tools/Release/preflight.sh').includes('BUNDLE_ID=com.pearleseed.Gaze'));
assert(read('Sources/GazeCore/AppIdentity.swift').includes('pearleseed/Gaze'));
assert(read('Tools/Release/Homebrew/gaze.rb').includes('github.com/pearleseed/Gaze'));

// package.py un-notarized posture (1B).
const packager = read('Tools/Release/DMG/package.py');
assert(packager.includes('EXPECTED_BUNDLE_IDENTIFIER = "com.pearleseed.Gaze"'));
assert(packager.includes('--notary-profile'));
assert(packager.includes('UN-NOTARIZED RELEASE DMG'));
assert(packager.includes('if not args.local_preview and authority:'));

// Zero references to deleted MainAppSources.sh, BuildDMG.sh, or legacy Plugin/ directory.
assert(!fs.existsSync(path.join(root, 'Tools/Scripts/MainAppSources.sh')));
assert(!fs.existsSync(path.join(root, 'Tools/Release/BuildDMG.sh')));
assert(!fs.existsSync(path.join(root, 'Plugin')));
for (const rel of ['build.sh', 'Package.swift', 'Tools/README.md', 'Tools/Release/verify.sh',
		'Tools/Release/preflight.sh', 'Tools/Release/DMG/package.py', 'Tools/Scripts/source-archive.sh',
		'Gaze.xcodeproj/project.pbxproj']) {
	const text = read(rel);
	for (const stale of ['MainAppSources.sh', 'BuildDMG.sh', 'Sources/Plugin', 'Plugin/build']) {
		assert(!text.includes(stale), `${rel} contains stale reference to ${stale}`);
	}
}

console.log('PASS: release identity (1B + strict), Package.swift/Sources/Gaze* layout, com.pearleseed.Gaze & pearleseed/Gaze wiring, and zero stale build refs.');
NODE

for architecture in '' 'arm64 x86_64' 'i386'; do
	for script in build.sh Tools/Release/verify.sh; do
		status=0
		output="$(DIST=1 GAZE_ARCHS="$architecture" bash "$ROOT/$script" 2>&1)" || status=$?
		test "$status" = 2 && [[ "$output" == *'exactly one release architecture'* ]] || {
			printf 'FAIL: %s accepted release architecture %q\n%s\n' "$script" "$architecture" "$output" >&2
			exit 1
		}
	done
done
status=0
output="$(python3 "$ROOT/Tools/Release/DMG/package.py" 2>&1)" || status=$?
test "$status" = 2 && [[ "$output" == *'Select --arch arm64'* ]] || { echo "$output"; exit 1; }
status=0
output="$(python3 "$ROOT/Tools/Release/DMG/package.py" --local-preview --notary-profile notary 2>&1)" || status=$?
test "$status" = 2 && [[ "$output" == *'--notary-profile cannot be combined with --local-preview'* ]] || { echo "$output"; exit 1; }

bash "$ROOT/Tests/Scripts/Release/verify-artifact.sh"
bash "$ROOT/Tests/Scripts/Release/preflight-checks.sh"
bash "$ROOT/Tests/Scripts/Release/source-archive.sh"
python3 "$ROOT/Tests/Scripts/Release/test-build-space.py"
