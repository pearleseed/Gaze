<div align="center">
  <img src="docs/images/icon.png" width="128" alt="Gaze app icon" />
  <h1>Gaze</h1>
  <p>On-device Face ID-style unlock for macOS. Private, local, and open source.</p>
  <p>
    <a href="https://github.com/pearleseed/Gaze"><img src="docs/images/badge-macos.png" width="179" alt="macOS 26 or later" /></a>
    <a href="https://www.swift.org"><img src="docs/images/badge-swift.png" width="112" alt="Swift 6" /></a>
    <a href="LICENSE"><img src="docs/images/badge-license.png" width="143" alt="License: MIT" /></a>
  </p>
</div>

<p align="center">
  <a href="https://github.com/pearleseed/Gaze"><img src="docs/images/hero.png" width="100%" alt="A MacBook lock screen with Gaze's panel open under the notch, recognising its owner" /></a>
</p>

<p align="center">
  <a href="https://github.com/pearleseed/Gaze/releases"><img src="docs/images/download-button.png" width="253" alt="Download for Mac" /></a>
</p>

## Features

<p align="center">
  <img src="docs/images/card-unlock.png" width="49%" alt="Unlocks as you look" />
  <img src="docs/images/card-local.png" width="49%" alt="Stays on your Mac" />
  <img src="docs/images/card-recognition.png" width="49%" alt="Knows it is you" />
  <img src="docs/images/card-choice.png" width="49%" alt="Your choice, always" />
</p>

- **Lock-screen unlock:** Recognizes your face on wake and unlocks macOS automatically with a native notch/Dynamic Island panel.
- **Liveness & anti-spoofing:** Rejects photos and screens with on-device anti-spoof detection and optional head-movement or gaze challenges.
- **Walk-away lock:** Locks your Mac automatically when you step away, using lightweight rectangles-only presence detection.
- **App Lock, `sudo` PAM & admin prompts:** Lock selected apps (with a Finder extension) and approve `sudo` or Apple administrator dialogs with your face.
- **GitHub Releases self-updating:** Checks `pearleseed/Gaze` releases with mandatory HTTPS and SHA-256 verification before installing updates.

## Requirements

- macOS 26 Tahoe or later (Apple Silicon or Intel)
- A built-in or connected camera
- Your macOS login password

## Installation

### Homebrew

Install with Homebrew (automatically clears macOS quarantine on install and upgrade):

```sh
brew install --cask pearleseed/gaze/gaze
```

### GitHub Releases DMG

Download the latest architecture-matched DMG from [GitHub Releases](https://github.com/pearleseed/Gaze/releases) and drag **Gaze** to `/Applications`.

Because release builds are not Apple-notarized, on first launch open **System Settings → Privacy & Security** and click **Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Gaze.app
```

## Privacy & Security

- **100% on-device:** Face recognition, liveness, and anti-spoofing run locally on your Mac—no biometric data or images are uploaded.
- **Encrypted storage:** Enrollment data is encrypted locally, and your password is protected with a key from your Mac's Secure Enclave.
- **Fail-closed design:** Because a standard webcam cannot measure depth like TrueDepth, Gaze rejects photos and screens, enforces strict frame-freshness and continuity bounds, and always lets your login password sign you in.
- **Reporting issues:** Open bug reports or security issues at [github.com/pearleseed/Gaze/issues](https://github.com/pearleseed/Gaze/issues).

## Building & Testing

Requires **Xcode 26+** and **Swift 6** on macOS 26 or later.

```sh
git clone https://github.com/pearleseed/Gaze.git
cd Gaze
./build.sh
open build/Gaze.app
```

- **Xcode development:** Open `Gaze.xcodeproj` and select the **Gaze** scheme.
- **Unit tests (Swift Testing):** Run `swift test` or `./Tests/run.sh --unit`.
- **Full local verification:** Run `./Tests/run.sh` (unit tests + release/product-boundary checks) or `./Tests/run.sh --all` (includes desktop integration harnesses).
- **Local models, signing & DMG releases:** See [Tools/README.md](Tools/README.md) and [Tests/README.md](Tests/README.md). Source archives omit proprietary/research model weights; see [NOTICE.md](NOTICE.md).

## Architecture

Gaze is organized as a Swift 6 multi-module Swift Package (`Package.swift`) linked into `Gaze.xcodeproj`:

| Module / Component | Responsibility |
|---|---|
| `GazeCore` | `AppIdentity`, preferences, Secure Enclave vault/Keychain, App Lock state store |
| `GazeDesign` | Theme, typography, Liquid Glass controls, companion Metal renderer |
| `GazeTourKit` | Vendored onboarding tour UI |
| `GazeCamera` | Camera pinning, frame leases, continuity tracking, bounded backpressure, presence-only mode |
| `GazeRecognition` | Core ML face embeddings, model residency, anti-spoofing, iris/pupil tracking, liveness challenges |
| `GazeLockScreen` | Lock-screen notch/Dynamic Island capsule, SkyLight space placement, unlock animation, App Lock shield |
| `GazeSecurity` | Lock/presence watchers, lockout, password submission guards, attempt log, admin prompt & `sudo` approval |
| `GazeUpdates` | GitHub Releases feed/download trust policy, SHA-256 verification, in-place updater |
| `GazeApp` / `GazeEntry` | App lifecycle, menu bar, Settings UI, enrollment/setup flows, AppIntents, `LiquidGlass.metal` |
| `FinderExtension` & `PAM` | Sandboxed `GazeFinder.appex` (`com.pearleseed.Gaze.Finder`) and `pam_gaze.so` for `sudo` |

## Acknowledgments & License

Gaze builds on open-source software and research including [InsightFace](https://github.com/deepinsight/insightface), [Sapphire](https://sapphire-app.tech), [MediaPipe Iris](https://github.com/google-ai-edge/mediapipe), [TourKit](https://github.com/rampatra/TourKit), [Atoll](https://github.com/Ebullioscopic/Atoll), [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow), [Glance](https://github.com/jonnyoo/glance), and the [Face Spoof Detection](https://universe.roboflow.com/mohammeds-workspace-ft3sn/face-spoof-detection-liika) dataset.

<sub>Available under the [MIT License](LICENSE). Third-party code, models, and dataset terms are documented in [NOTICE.md](NOTICE.md). Gaze is not affiliated with Apple. Face ID, iPhone, and Mac are trademarks of Apple Inc.</sub>
