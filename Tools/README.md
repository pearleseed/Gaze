# Tools

- `Scripts/`: toolchain discovery, shared bundle resource staging, the local
  build-and-run/install helpers, and the source-archive builder.
- `Release/DMG/`: the disk-image layout, artwork, and `package.py` packager.
- `Release/Homebrew/`: the cask for the `pearleseed/gaze` tap.
- `Release/ModelClearance/`: the model and asset licence inventory that the build checks.
- `Release/Signing.sh`, `preflight.sh`, `verify.sh`: signing and release checks.

## Debug models

Xcode Debug and local `build.sh` builds look for locally provisioned compiled
models in the git-ignored `build/local-models/` directory. Put `FaceEmbedding.mlmodelc`
there for face recognition and `IrisLandmarks.mlmodelc` for iris tracking when the
source package lacks model data. Debug builds also look in `Resources/` when there
is no local override. `Spoof.mlmodel` is compiled from the checked-in source.

Set the Apple Development team for Debug in the git-ignored `Xcode/Local.xcconfig`.
For a local build that signs directly with that certificate, use these settings.

```xcconfig
DEVELOPMENT_TEAM[config=Debug] = YOUR_TEAM_ID
PROVISIONING_PROFILE_REQUIRED[config=Debug] = NO
PROVISIONING_PROFILE_SUPPORTED[config=Debug] = NO
```

## Release builds

The release inventory checks the precompiled models at
`Resources/FaceEmbedding.mlmodelc` and `Resources/IrisLandmarks.mlmodelc`.
These directories are git-ignored and must be provisioned locally with the exact
files recorded in [the inventory](Release/ModelClearance/clearance.json).
See [NOTICE.md](../NOTICE.md) for model sources and redistribution terms.

Run `bash Tools/Release/preflight.sh` to check the release prerequisites.
Build each target separately (`GAZE_REQUIRE_DEVELOPER_ID=1` enforces a Developer ID Application signature; otherwise `Signing.sh` defaults to un-notarized signing).

```sh
DIST=1 GAZE_ARCHS=arm64 bash build.sh
DIST=1 GAZE_ARCHS=x86_64 bash build.sh
```

The app bundles are `build/release/arm64/Gaze.app` for Apple Silicon and
`build/release/x86_64/Gaze.app` for Intel. Xcode's Release configuration defaults
to the host architecture. To cross-build in Xcode, pass `ARCHS=arm64` or
`ARCHS=x86_64` and use a separate `-derivedDataPath` for each build.

Verify each bundle and package its DMG (`GAZE_REQUIRE_DEVELOPER_ID=1` verifies Developer ID, timestamp, stapled notarization ticket, and Gatekeeper):

```sh
GAZE_ARCHS=arm64 bash Tools/Release/verify.sh
GAZE_ARCHS=x86_64 bash Tools/Release/verify.sh
```

Package each verified app with `Release/DMG/package.py` (`--arch arm64` or `--arch x86_64`).
The images are named `Gaze-<version>-<build>-arm64.dmg` and
`Gaze-<version>-<build>-x86_64.dmg` in `build/installers/`. Notarize and staple
the images for distribution when using `--notary-profile`.
