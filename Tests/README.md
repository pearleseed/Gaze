# Tests

Run the local suites on macOS with Xcode, Python 3, and Node.js.

## Quick start

```sh
Tests/run.sh                          # Default: swift test + Release + ProductBoundary
Tests/run.sh --unit                   # Headless Swift Testing unit suites only (CI-safe)
Tests/run.sh --all                    # swift test + Release + all desktop AppIntegration suites
Tests/run.sh --list                   # Every available target and script
Tests/run.sh Release ProductBoundary  # Named targets or scripts
Tests/run.sh MultiFace                # Downloads two synthetic face images
```

## Layout

- `GazeCameraTests/`, `GazeCoreTests/`, `GazeRecognitionTests/`,
  `GazeSecurityTests/`, `GazeUITests/`, `GazeUpdatesTests/`: Swift Testing targets
  declared in `Package.swift` and run directly by `swift test` or `Tests/run.sh --unit`.
- `Scripts/Release/`: signing, preflight, source archive, artifact verification,
  and disk-space guard checks.
- `Scripts/AppIntegration/`: standalone `.app`-bundle, product-boundary, Metal
  cadence, and PNG-capture verification harnesses (`Notch`, `Onboarding`,
  `ProductBoundary`, `SettingsInteraction`, `SettingsLaunch`, `Toolbar`). AppKit
  and visual fixtures require a logged-in desktop session; run individual scripts
  directly (for example `bash Tests/Scripts/AppIntegration/Onboarding/run.sh --review`,
  or pass `--compile-only` to verify Swift 6 compilation without launching UI).
- `Scripts/MultiFace/`: still-image multi-face matcher (`--compile-only` builds
  without downloading test images).
- `Scripts/Support/`: shared helpers (`swiftpm.sh`, `CompanionCapture.swift`).
