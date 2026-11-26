# Design Spec: Pearleseed Gaze — Full Modernization, Multi-Module Swift Architecture & Performance Overhaul

**Date:** 2026-11-26
**Status:** Ready for User Approval (builder-reviewed)
**Repository:** `https://github.com/pearleseed/Gaze`
**Bundle Identifier:** `com.pearleseed.Gaze`

---

## 1. Intent & Why

Gaze has been forked into an independent repository (`https://github.com/pearleseed/Gaze`) that will no longer track upstream `OwenCope/Gaze` or rely on `gazeunlock.com` infrastructure. The goal of this overhaul is to transform the fork into a standalone, release-ready, idiomatic Swift 6 macOS project with:

1. **Complete ownership & identity independence** under `pearleseed` (`com.pearleseed.Gaze`, GitHub Releases self-updating, clean About/README/Homebrew/DynamicLake metadata, zero upstream links or dead legacy/companion baggage).
2. **Measurable performance and operational efficiency gains** across startup, camera/Vision/Core ML latency, idle CPU/timer wakeups, GPU rendering, memory residency, disk I/O, and build times — without weakening any security, anti-spoof, liveness, or fail-closed guarantees.
3. **Clean, modern, modular Swift project structure** using a root `Package.swift` multi-module workspace, Swift 6 strict concurrency (`SWIFT_VERSION = 6`), focused single-responsibility files (breaking up the remaining large monoliths), and Swift Testing (`swift test`) replacing the ad-hoc shell/swiftc test harnesses.
4. **Upgraded tooling and dependencies** to the latest stable versions (`Swift 6`, `dmgbuild==2.0.0`, `Pillow==13.0.0`, audited `GazeTourKit`).

---

## 2. Goals, Non-Goals & Anti-Goals

### Goals
- **Independent Identity (`com.pearleseed.Gaze`):** Every bundle identifier, App Group, Keychain service, logging subsystem, URL scheme metadata, distributed notification prefix, Finder extension, DynamicLake plugin, Homebrew cask, git remote, and updater trust policy belongs exclusively to `pearleseed/Gaze`.
- **Clean Removal of Dead/Unused Subsystems:** Remove the permanently disabled legacy `Plugin/` directory, dead `UnlockService` Mach listener, and `Sources/Browser/` (`GazeBrowser` + `.browserOnly` mode), eliminating unused startup socket/Mach listeners and upstream peer coupling (`com.gazeunlock.Passwords`).
- **GitHub Releases Self-Updating & Canonical Un-Notarized Packaging:** `ReleaseUpdateChecker` and `UpdateInstaller` fetch releases directly from `https://api.github.com/repos/pearleseed/Gaze/releases/latest`, select the architecture-appropriate DMG (`arm64` / `x86_64` / universal), verify SHA-256 checksums, and safely install in-place. Standardize DMG packaging on `Tools/Release/DMG/package.py` (supporting un-notarized local/ad-hoc signed releases with mandatory `.sha256` sidecars, while preserving optional `--notary-profile` support) and retire the duplicate `Tools/Release/BuildDMG.sh`.
- **High-Impact Performance & Efficiency:** Deliver every P1/P2/P3 optimization across Walk-away Lock, model warm-up/residency, shared spoof context crops, Accelerate-vectorized similarity & direct `MLMultiArray` access, bounded camera backpressure, zero-wakeup idle timers, coalesced readiness checks, serialized `UnlockAttemptLog` I/O, and pause-clean Metal/Core Image rendering.
- **Idiomatic Multi-Module Swift 6 Project:** Root `Package.swift` with 9 strictly acyclic local library targets, Swift 6 language mode across all targets, `@Observable` everywhere (migrating `MenuBarVisibility`, the last remaining `ObservableObject`), `Synchronization.Mutex` / actors replacing ad-hoc locks where appropriate, and monolith splits for `LockWatcher`, `NotchCapsule`, and `LivenessChallenge`.
- **Standardized Swift Testing:** Migrate all headless unit, security, recognition, math, hardening, presence, unlock-flow, status-broadcast, sudo-install, settings-search, UI-logic, and update-lifecycle suites from bash/`swiftc` harnesses into `swift test` targets using Apple's `Testing` framework (`@Test`, `#expect`). Keep desktop-session/bundle-dependent visual captures, Metal cadence tests, multi-process launch tests, external fixture downloads (`MultiFace`), and DMG/release verification as thin scripts under `Tests/Scripts/`.
- **Upgraded Dependencies & Fast Builds:** Upgrade Python DMG tooling (`dmgbuild==2.0.0`, `Pillow==13.0.0`), make local dev builds native-arch by default (`$(uname -m)`), and eliminate redundant Core ML model copying in incremental Xcode builds.

### Non-Goals
- Changing biometric matching thresholds, embedding model weights (`FaceEmbedding.mlmodelc`), liveness movement rules, anti-spoof rejection rules, camera pinning policy, or password submission security guards.
- Migrating existing `com.gazeunlock.Gaze` Keychain items or TCC permissions automatically. Switching to `com.pearleseed.Gaze` is an intentional clean break; users enroll fresh under `com.pearleseed.Gaze`.
- Adding external third-party Swift Package dependencies over the network. The app remains zero external SPM dependencies (with `TourKit` vendored locally as `GazeTourKit` to preserve Gaze's custom Liquid Glass controls and offline build determinism).
- Maintaining a companion Passwords/browser-autofill app (`GazeBrowser` is removed per user decision `2A`).
- Adding new end-user features unrelated to ownership, performance, modularity, or dependency upgrades.

### Anti-Goals (Failure Conditions Even If Code Compiles)
- Weakening any fail-closed security property (accepting stale frames > 500 ms, skipping continuity gaps > 240 ms, approving without anti-spoof, allowing untrusted update URLs or unverified SHA-256 downloads, breaking `pam_gaze.so` peer signature checks, or allowing `AdminPromptApproval` to auto-fill non-Apple prompts).
- Regressing lock-screen wake rendering (e.g., blank companion face after lid open/wake, broken SkyLight space adoption, or Liquid Glass shader missing from `default.metallib`).
- Losing test coverage when migrating bash/`swiftc` harnesses to Swift Testing — every behavioral assertion from the existing headless suites must be preserved in `swift test`, and desktop-session/visual/release suites must remain runnable under `Tests/Scripts/`.
- Destroying or discarding the 108 uncommitted refactoring improvements already present in the working tree (`Gaze.xcodeproj`, `Sources/App/Settings/`, `Sources/Design/`, updated `build.sh`, etc.).

---

## 3. Constraints

- **Platform & Toolchain:** macOS 26.0 minimum deployment target (`MACOSX_DEPLOYMENT_TARGET = 26.0`, `LSMinimumSystemVersion = 26.0`), built with Xcode 26+/27+ and Swift 6 (`SWIFT_VERSION = 6`, `.swiftLanguageMode(.v6)`). Release builds support both `arm64` and `x86_64` per-arch (`DIST=1 GAZE_ARCHS=arm64` or `x86_64`); local builds default to native host architecture (`$(uname -m)`).
- **Working Tree Preservation:** The repository currently has 108 uncommitted changes from an earlier refactor (`Sources/App/Settings/`, `Sources/Design/`, `Gaze.xcodeproj`, `docs/superpowers/plans/2026-11-25-gaze-performance.md`, etc.). Execution must preserve this state as the starting baseline on an isolated branch/worktree (never `git reset --hard` or discard local changes) and never touch `main` directly without user consent.
- **Models & Assets:** Local Core ML models (`Resources/FaceEmbedding.mlmodelc`, `Resources/IrisLandmarks.mlmodelc`, `Resources/Spoof.mlmodel`) remain app-bundle resources in `Gaze.app/Contents/Resources/` (excluded from source archives per `NOTICE.md` / `Tools/Scripts/source-archive.sh`). `LiquidGlass.metal` remains compiled into the main app bundle's `default.metallib` so `ShaderLibrary.default` works identically at runtime.
- **No Sandbox on Main App / Sandbox on Finder Extension:** Main `Gaze.app` remains unsandboxed (Hardened Runtime + camera entitlement) because Accessibility/CGEvent password submission cannot run sandboxed. `GazeFinder.appex` remains sandboxed with App Group `group.com.pearleseed.Gaze`.
- **TourKit Customizations:** `GazeTourKit` must preserve the explicit resting Liquid Glass navigation buttons (`.glassEffect(.regular.interactive(), in: .circle)` inside `GlassEffectContainer`) and `pageMedia` hook documented in `ThirdParty/TourKit/LOCAL-CHANGES.md`, while shipping `TourKit-LICENSE.txt` in `Contents/Resources/`.

---

## 4. Approaches Considered

### Approach A — Phased Upgrade on Existing Single-Target Layout
Keep the single-module `build.sh` + `Gaze.xcodeproj` + 27 bash/`swiftc` test scripts, and execute the rebrand, performance optimizations, monolith splits, Swift 6 upgrade, and Python dependency upgrades incrementally.
- **Trade-offs:** Lowest structural churn and zero build/test harness migration risk, but leaves all 34k lines in a single Swift module without compiler-enforced boundaries and preserves 27 ad-hoc bash/`swiftc` test harnesses instead of standard `swift test`.

### Approach B — Full Modernization + Multi-Module Swift Package Workspace & Swift Testing *(Selected by User)*
Execute everything in Approach A **plus**:
- Organize the codebase into an idiomatic root `Package.swift` with 9 strictly acyclic local library targets linked by the macOS app bundle (`Gaze.xcodeproj` + `build.sh`) and `GazeFinder.appex`.
- Migrate all headless suites into Swift Testing targets (`swift test`) while keeping desktop-session/visual/release verification in thin scripts under `Tests/Scripts/`.
- Remove the disabled legacy `Plugin/` directory, dead `UnlockService` Mach stub, and unused `Sources/Browser/` (`GazeBrowser`) subsystem.
- Full clean-break rebrand to `com.pearleseed.Gaze` and `https://github.com/pearleseed/Gaze`, with un-notarized GitHub Releases packaging standardized on `Tools/Release/DMG/package.py`.
- **Why selected:** The user explicitly selected Approach B, `com.pearleseed.Gaze`, un-notarized GitHub Releases (`1B`), and full removal of `GazeBrowser` (`2A`) for the cleanest modern Swift project layout and leanest runtime footprint.

---

## 5. Detailed Design

### 5.1 Ownership, Complete Rebrand (`com.pearleseed.Gaze`) & Legacy Removal

Define a single source of truth `AppIdentity` enum in `GazeCore`:

| Constant | Value |
|---|---|
| `bundleIdentifier` | `"com.pearleseed.Gaze"` |
| `finderExtensionIdentifier` | `"com.pearleseed.Gaze.Finder"` |
| `appGroupIdentifier` | `"group.com.pearleseed.Gaze"` |
| `keychainService` | `"com.pearleseed.Gaze"` |
| `loggerSubsystem` | `"com.pearleseed.Gaze"` |
| `statusNotificationPrefix` | `"com.pearleseed.Gaze.status."` |
| `stateNotificationName` | `"com.pearleseed.Gaze.state"` |
| `pendingSettingsPaneKey` | `"com.pearleseed.Gaze.pendingSettingsPane"` |
| `urlScheme` | `"gaze"` (URL name `"com.pearleseed.Gaze.app-lock"`) |
| `repositorySlug` | `"pearleseed/Gaze"` |
| `repositoryURL` | `https://github.com/pearleseed/Gaze` |
| `releasesURL` | `https://github.com/pearleseed/Gaze/releases` |
| `issuesURL` | `https://github.com/pearleseed/Gaze/issues` |

All existing hardcoded `"com.gazeunlock.Gaze"` strings across `Sources/`, `Resources/Info.plist`, `Sources/FinderExtension/{Info.plist,GazeFinder.entitlements}`, `Xcode/{Gaze,GazeFinder}.xcconfig`, `build.sh`, `Tools/Release/{preflight.sh,verify.sh,DMG/package.py,Homebrew/gaze.rb}`, `Tools/Scripts/install-local.sh`, and `Integrations/DynamicLake/` are replaced cleanly with `com.pearleseed.Gaze` (referencing `AppIdentity` in Swift code).

- **Git Remote:** Update local git `origin` remote URL from `https://github.com/OwenCope/Gaze.git` to `https://github.com/pearleseed/Gaze.git` (never `git push` automatically without explicit user request).
- **About Pane & README:**
  - `SettingsAboutPane`: Website → `https://github.com/pearleseed/Gaze` (`github.com/pearleseed/Gaze`), Release notes → `https://github.com/pearleseed/Gaze/releases`, Report a problem → `https://github.com/pearleseed/Gaze/issues`. Remove the upstream Discord link and upstream Buy-Me-a-Coffee donation section.
  - `README.md`: Update clone URL, Homebrew cask instructions (`pearleseed/gaze`), GitHub Releases download links, Gatekeeper first-launch note for un-notarized builds ("Open Anyway" / Homebrew quarantine clearing), and Swift 6 / SPM build & test instructions. Keep MIT license and third-party attributions in `NOTICE.md`.
- **DynamicLake Integration:** Update `Integrations/DynamicLake/Resources/plugin.json` (`identifier: "com.pearleseed.Gaze.dynamiclake"`, `developerName: "pearleseed"`, `url: "https://github.com/pearleseed/Gaze"`), `Integrations/DynamicLake/Sources/main.swift`, and `Integrations/DynamicLake/Tests/simulate-gaze.swift` to use `"com.pearleseed.Gaze.status."`.
- **Removed Subsystems (`Plugin/`, `UnlockService`, `GazeBrowser`):**
  - Delete `Plugin/` completely.
  - Delete `Sources/Security/UnlockService.swift` and stop launching the disabled Mach listener in `AppServices`. Remove `.authPlugin` from live UI/services (any legacy persisted raw value `"authPlugin"` in `UserDefaults` falls back safely to `.none`).
  - Delete `Sources/Browser/` (`BrowserPeerTrust.swift`, `BrowserProtocol.swift`, `BrowserSocket.swift`, `GazeBrowserApproval.swift`) completely.
  - Remove `browserApprovals` from `AppServices`, remove `.browserOnly` from `UnlockExecutionPolicy` and `MenuBarContent`, and rename `permitsBrowserApproval(passwordReplayEnabled:)` → `permitsAdminPromptApproval(passwordReplayEnabled:)` for `AdminPromptApproval`.
  - Retain the active sudo PAM module (`Sources/PAM/pam_gaze.c` + `SudoApproval` + `SudoInstallScript`).

---

### 5.2 Multi-Module Swift Package Architecture (`Package.swift`)

Adopt a root `Package.swift` (`swift-tools-version: 6.0`, `platforms: [.macOS("26.0")]`, `.swiftLanguageMode(.v6)` on every target) defining a strictly acyclic 9-target dependency graph:

| Target | Dependencies | Responsibility |
|---|---|---|
| `GazeCore` | *(Apple frameworks only)* | `AppIdentity`, `Preferences`, `UnlockExecutionPolicy`, `PasswordReplaySafety`, `AutofillSessionLease`, `Keychain`, `SecureVault`, `PasswordVault`, `BiometricGate`, `AppLockStore`, `AppLockStateMachine`, `AppLockRelockPolicy`, `StatusBroadcast`, `StateBroadcast`, `StartupTiming`, `GazeDiagnostics`, `ProductCaptureDemo` |
| `GazeDesign` | `GazeCore` | `Theme`, `Typography`, `GazeGlassPanel`, `SettingsControls`, `SettingsSection`, `WindowAppearance`, `GazeFaceMark`, `GazeCompanion*` (Metal renderer, shader, motion, view, render diagnostics) |
| `GazeTourKit` | *(Apple frameworks only)* | Vendored `TourKit.swift` (MIT) with Gaze's resting Liquid Glass controls & `pageMedia` hook, Swift 6 clean |
| `GazeCamera` | `GazeCore` | `CameraDevice`, `FacePose`, `CameraFrameLease`, `CameraEvidenceContinuity`, `CameraSessionGate`, `ForegroundCameraClaim`, `FrameQuality`, `FrameBrightness` (`SceneBrightness`), `CameraPreview`, `CameraController` |
| `GazeRecognition` | `GazeCore`, `GazeCamera` | `ModelResidency`, `FaceAligner`, `FaceEmbedder`, `AdjustedThresholdEmbedder`, `FaceTemplateMatcher`, `FaceEnrollment`, `SpoofDetector`, `AntiSpoofGate`, `DeviceBezelGate`, `GlareCue`, `IrisLocator`, `PupilLocator`, `LivenessChallenge` (modularized), `RecognitionFrameGate`, `RecognitionScanPacing`, `UnlockFrameEvaluator`, `EnrollmentModel`, `DatasetCapture` |
| `GazeLockScreen` | `GazeCore`, `GazeDesign`, `GazeRecognition` | `NotchMetrics`, `NotchPanelShape`, `NotchAppearance`, `NotchCapsuleModel`, `NotchCapsule` (modularized), `NotchCapsuleController`, `NotchPreviewCanvas`, `LockScreenSpace`, `LockScreenLight`, `LookTargetOverlay`, `NativeMovementMark`, `NativeUnlockAnimation`, `WallpaperBrightness`, `WallpaperGlass`, `AppLockShield` (callback-decoupled), `LockPanelPreview`, `LockScreenShoot` |
| `GazeSecurity` | `GazeCore`, `GazeCamera`, `GazeRecognition`, `GazeLockScreen` | `LockWatcher` (modularized), `PresenceWatcher`, `PresenceAbsenceGate`, `PresenceCheckSchedule`, `LockoutManager`, `LockScanDiagnostics`, `LockScreenInputGuard`, `LockScreenPasswordSubmission`, `UnlockChallengeGate`, `UnlockAttemptLog`, `UnlockBackend`, `Keystrokes`, `ScreenLock`, `SpaceKeyMonitor`, `TamperGuard`, `IntruderNotice`, `StalePasswordNotice`, `LoginItem`, `FaceApprovalCheck`, `AdminPromptApproval`, `AdminPromptRules`, `SudoApproval`, `SudoInstallScript`, `AppLockWatcher`, `AppLockRecognizer`, `AppLockURLAction` |
| `GazeUpdates` | `GazeCore` | `ReleaseURLPolicy`, `ReleaseUpdateChecker`, `UpdateInstaller`, `RepoRevealHelper` |
| `GazeApp` *(library linked by app entrypoint)* | All library targets above + `GazeTourKit` | `GazeApp`, `AppDelegate`, `AppServices`, `AppActivation`, `MenuBarContent`, `DesktopWallpaper`, `GazeBrand`, `GazeTips`, `ConfirmIdentityIntent`, `ReleaseNotesView`, `Settings/*`, `Enrollment/*` views, `Setup/*` views |

**Cross-module access control:** Use Swift 6's `package` access level for cross-target internal APIs within the workspace so modules have compiler-enforced boundaries without leaking internals as public SDK API.

**App Bundle, Extension, Metal & Build Unification:**
- `Gaze.xcodeproj` references the root local Swift package (`XCLocalSwiftPackageReference`) and links its library products into the `Gaze` macOS `.app` target and `GazeCore` into `GazeFinder.appex`.
- The `Gaze` app target compiles `LiquidGlass.metal` → `Contents/Resources/default.metallib`, compiles `AppIcon.icon`, stages Core ML models (`FaceEmbedding`, `IrisLandmarks`, `Spoof`), compiles `Sources/PAM/pam_gaze.c` → `Contents/Resources/pam_gaze.so`, generates `AppIntents` metadata for `ConfirmIdentityIntent`, embeds `GazeFinder.appex`, and signs with Hardened Runtime.
- `build.sh` builds from the unified project/package (retiring fragile manual file globs in `MainAppSources.sh`) while preserving atomic staging in `$TMPDIR`, iCloud `xattr` retry signing, `DIST=1 GAZE_ARCHS=arm64|x86_64` per-arch release builds, and signing-identity consistency checks. Local dev builds default to `$(uname -m)`.

---

### 5.3 GitHub Releases Updater & Un-Notarized Distribution (`GazeUpdates` + `Tools/Release/`)

#### Updater (`GazeUpdates`)
- **Endpoints & Trust Policy (`ReleaseURLPolicy`):**
  - `feed`: `https://api.github.com/repos/pearleseed/Gaze/releases/latest`
  - `releases`: `https://github.com/pearleseed/Gaze/releases`
  - `isTrustedFeed(_ url:)` allows ONLY `https://api.github.com/repos/pearleseed/Gaze/releases/latest` (and release asset endpoints under `api.github.com/repos/pearleseed/Gaze/releases/assets/...`), HTTPS port 443, no userinfo/fragment.
  - `isTrustedDownload(_ url:)` / `isTrustedDownloadHop(_ url:)` allows ONLY:
    - `https://github.com/pearleseed/Gaze/releases/download/...`
    - `https://release-assets.githubusercontent.com/...`
    - `https://objects.githubusercontent.com/...`
    - (Rejects `gazeunlock.com`, `/OwenCope/Gaze/`, non-download GitHub paths like `/blob/`, non-HTTPS, credentials, custom ports, fragments.)
  - HTTP headers: `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: Gaze/<version>`.
- **Release Decoding & Asset Selection (`ReleaseUpdateChecker`):**
  - Decode standard GitHub Release JSON (`tag_name`, `name`, `body`, `prerelease`, `draft`, `assets: [{ name, browser_download_url, digest }]`).
  - Ignore `draft == true` and `prerelease == true` (treat as `.upToDate`, advancing `lastCheck`). Treat HTTP 404 (fresh fork with zero published releases) as `.upToDate` instead of an error banner.
  - Select the DMG matching current host architecture (`Gaze-*-arm64.dmg` on Apple Silicon, `Gaze-*-x86_64.dmg` on Intel, falling back to universal `Gaze-*.dmg` / `Gaze.dmg`).
  - Extract SHA-256 from GitHub's native asset `digest` (`"sha256:<64-hex>"`), falling back to fetching the matching `<dmg-name>.sha256` sidecar asset on the same release (via trusted download policy, max 4 KiB). Without a verified 64-hex SHA-256, offer browser download only (never unverified in-app install).
- **In-Place Verification (`UpdateInstaller`):**
  - Mandatory HTTPS trusted origin + mandatory SHA-256 match + exact `CFBundleIdentifier == com.pearleseed.Gaze` + version match + strict nested signature check (`kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode`).
  - **Team-aware vs. ad-hoc release handling (for `1B`):** If the running app carries a real Apple Team ID (`kSecCodeInfoTeamIdentifier` present), enforce `SecCodeCopyDesignatedRequirement` matching (same team + bundle ID). If the running app is ad-hoc signed (where designated requirement pins the old binary's `cdhash`), validate strict nested signature integrity (`requirement: nil`) alongside the mandatory GitHub Releases HTTPS trust + SHA-256 + bundle ID + version checks.
  - Swap script cleans up `com.pearleseed.Gaze.agent` (instead of `com.gazeunlock.Gaze.agent`).
- **UI Copy:** Replace all `"gazeunlock.com"` strings in `SettingsUpdatesSection` and `ReleaseUpdateChecker` with `"GitHub"` / `"pearleseed/Gaze"`.

#### Canonical DMG Packaging & Homebrew Cask (`1B`)
- **Single Canonical Packager:** Standardize on `Tools/Release/DMG/package.py` and retire the duplicate `Tools/Release/BuildDMG.sh`.
- **Canonical Artifact Format:** Per-architecture `Gaze-<version>-<build>-<arch>.dmg` plus companion `Gaze-<version>-<build>-<arch>.dmg.sha256` and `.json` receipt.
- **Un-Notarized Release Mode (`1B`):**
  - `Tools/Release/Signing.sh`, `Tools/Release/verify.sh`, `build.sh` (`DIST=1`), and `package.py` support un-notarized releases signed with local Apple Development or ad-hoc identity by default for this fork, while retaining strict Developer ID + `--notary-profile` + `stapler` + `spctl` verification whenever `--notary-profile` or `GAZE_REQUIRE_DEVELOPER_ID=1` is supplied.
  - `package.py` validates `CFBundleIdentifier == "com.pearleseed.Gaze"`.
- **Homebrew Cask (`Tools/Release/Homebrew/gaze.rb`):**
  - Uses `on_arm` / `on_intel` pointing to `https://github.com/pearleseed/Gaze/releases/download/v#{version}/Gaze-#{version}-#{build}-arm64.dmg` (and `x86_64.dmg`), `homepage "https://github.com/pearleseed/Gaze"`.
  - Retains `postflight_steps` clearing `com.apple.quarantine` (matching un-notarized posture `1B`).
  - `uninstall quit: "com.pearleseed.Gaze"` and `zap trash:` for `com.pearleseed.Gaze`.

---

### 5.4 Performance & Operational Efficiency Enhancements

All optimizations preserve existing thresholds, fail-closed security gates, continuity bounds (500 ms frame age, 240 ms continuity gap), and liveness rules:

1. **Walk-Away Lock `rectanglesOnly` Mode (`GazeCamera` + `GazeSecurity`):**
   - Add an analysis mode (`.full` vs `.presenceOnly`) to `CameraController` and `SampleProxy`.
   - In `.presenceOnly`, `SampleProxy` runs ONLY `VNDetectFaceRectanglesRequest` (zero `VNDetectFaceLandmarksRequest`, zero `VNDetectFaceCaptureQualityRequest`, zero `FaceSample`/`CVPixelBuffer` dispatch to `MainActor`) and delivers a lightweight `PresenceObservation` (`verdict: .facePresent | .noFace | .indeterminate`, `frameID`, `capturedAt`).
   - `PresenceWatcher` switches to `.presenceOnly` and closes the camera immediately on `.facePresent`, while keeping the 4 s sustained absence proof, 500 ms age limit, and 1 s gap check.
2. **Deduplicated Model Warm-Up & Residency (`GazeRecognition`):**
   - Track warm-up completion per load generation inside `ModelSlot` so concurrent or repeated `warmUp()` calls (startup, lock, attempt start, pre-loop) execute at most **one** throwaway prediction per residency cycle, resetting automatically when `ModelResidency` unloads after 30 min idle. Failed warm-ups remain retryable.
   - Offload blocking Core ML model validation / initial load off the synchronous `MainActor` launch path while guaranteeing `UnlockGuard` / scans await readiness deterministically (never silently falling back to `LandmarkEmbedder` while Core ML is loading).
3. **Zero-Copy Tensor Extraction & Accelerate Cosine Similarity (`GazeRecognition`):**
   - Vectorize `Faceprint.similarity(to:)` with `Accelerate` (`vDSP_dotpr`, `vDSP_svesq`) instead of scalar Swift loops.
   - In `CoreMLEmbedder.predict(_:)`, read contiguous `.float32` / `.float16` output `MLMultiArray.dataPointer` directly (checking contiguous strides, falling back to subscript only for non-contiguous arrays) instead of 512 `NSNumber` boxings per frame.
4. **Shared Spoof Context Crop & Single Classifier Pass (`GazeRecognition` + `Enrollment`):**
   - Render the 224×224 `FaceAligner.contextCrop` once per matched frame in `UnlockFrameEvaluator.denyChecked(_:)` and pass that pre-rendered `CVPixelBuffer` to `SpoofDetector`, `DeviceBezelGate`, and `GlareCue` (eliminating duplicate Core Image GPU renders per frame).
   - Expose classifier confidence/availability in `UnlockFrameEvaluator.Result` so `RecognitionTestView` displays the evaluator's already-computed spoof verdict instead of invoking `SpoofDetector` a second time on the same frame.
5. **Bounded Camera Backpressure (`GazeCamera`):**
   - Replace unbounded per-frame `Task { @MainActor in ... }` fan-out in `CameraController` with a single-slot latest-pending mailbox (at most 1 pending buffer in flight between `frameQueue` and `MainActor`). When a newer frame overwrites an unconsumed pending slot, record a dropped-frame continuity break flag so `CameraEvidenceContinuity` accurately sees the discontinuity and buffer pool memory stays strictly bounded under MainActor stalls.
6. **Zero Idle Polling Wakeups (`GazeSecurity` + `GazeApp`):**
   - `AdminPromptApproval`: start/stop its 0.5 s `Timer` strictly in sync with `Preferences.shared.approveAdminPrompts`, pause state, and execution policy — **0 timer wakeups/min** when disabled. Re-arm immediately when toggled on in Settings.
   - `DesktopWallpaper`: run its 2 s fallback poll only while a visible window/preview is observing wallpaper (active-observer count > 0), relying on `FSEventStream` + Space/activation notifications otherwise and refreshing immediately when a preview reappears.
7. **Coalesced UI Readiness (`GazeApp`):**
   - Compute `MenuBarContent`'s readiness status once per body pass (returning a single struct carrying both `label` and `opensSettings`) instead of calling `backend.readiness()` (which hits Keychain + AX) twice.
   - Coalesce duplicate `SettingsView` refresh triggers (`onAppear` + `didBecomeActive`).
8. **Serialized `UnlockAttemptLog` I/O & Shared `CIContext` (`GazeSecurity` + `GazeLockScreen`):**
   - Route all `UnlockAttemptLog` disk writes, JPEG encodes, prunes, and `deleteAll()` calls through a single serial actor with a monotonically increasing generation counter so `deleteAll()` strictly ignores/cancels any older in-flight photo encode or JSON snapshot write.
   - Never retain `CVPixelBuffer` when `photoPolicy == .off` (or when `photoPolicy == .whenNotGaze` and `result == .unlocked`).
   - Reuse a single static `CIContext` in `UnlockAttemptLog` and `LockScreenLight`, cache `LockScreenLight`'s rendered glow `CGImage` keyed by `(size, scale, notchRect)`, and decode attempt thumbnails off `MainActor` instead of synchronously inside SwiftUI `body`.
9. **Companion Metal Renderer Efficiency (`GazeDesign`):**
   - Avoid redundant synchronous `view.draw()` calls in `GazeCompanionRenderer.updateNSView` when paused and visual inputs (`revision`, `angle`, `material`, `opacity`) have not changed.
   - Pause continuous `MTKView` ticks when the host window is hidden/minimized while preserving the existing wake/screen-change/occlusion re-arming path required by lock-screen wake.
10. **Build Efficiency:**
    - `build.sh` defaults local builds to `$(uname -m)` (`arm64` on Apple Silicon); `DIST=1` retains explicit `GAZE_ARCHS=arm64|x86_64`.
    - `xcode-bundle-resources.sh` skips re-copying/recompiling Core ML models when outputs are already up-to-date relative to inputs (input/output fingerprint stamp check).

---

### 5.5 Structural Refactoring & Swift 6 Strict Concurrency

1. **Monolith Decomposition:**
   - `LockWatcher.swift` (1,753 lines) → split into cohesive files under `Sources/GazeSecurity/LockWatcher/`:
     - `LockWatcher.swift` (lifecycle, system lock/sleep/wake/screensaver notifications, coordination)
     - `LockUnlockAttemptRunner.swift` (single unlock attempt loop, frame evaluation, movement guidance, password submission)
     - `LockWatcherRetryMonitor.swift` (Space key & pointer retry handling, watchdog)
     - `LockWatcherTelemetry.swift` (attempt timing, `UnlockAttempt.Steps`, logging & ended-without-Gaze recording)
   - `NotchCapsule.swift` (1,087 lines) → split under `Sources/GazeLockScreen/Notch/`:
     - `NotchCapsule.swift` (root routing view)
     - `NotchIslandView.swift` (attached & floating island layout)
     - `NotchEarFlankView.swift` (beside-the-camera ear layout & metrics)
     - `NotchDynamicIslandView.swift` (Dynamic Island morph, metrics & body)
   - `LivenessChallenge.swift` (913 lines) → split under `Sources/GazeRecognition/Liveness/`:
     - `LivenessChallenge.swift` (core state machine, `Action`, `Movement`, `ConsumeResult`)
     - `LivenessPoseEvaluator.swift` (head yaw/pitch/blink/mouth evaluation)
     - `LivenessLookEvaluator.swift` (Follow-the-light gaze tracking & pass scoring)
     - `LivenessLandmarkMath.swift` (geometric landmark ratios & helpers)
   - Clean up legacy aliases (`typealias UpdateChecker = RepoRevealHelper` removed once all call sites use `RepoRevealHelper`).
2. **Swift 6 Language Mode (`SWIFT_VERSION = 6`):**
   - Enable Swift 6 strict concurrency checking in `Package.swift`, `Xcode/Shared.xcconfig`, and `build.sh` with zero warnings (`-warnings-as-errors` on tests).
   - Migrate `MenuBarVisibility` (the sole remaining `ObservableObject` after removing `GazeBrowser`) to `@Observable`.
   - Replace `NSLock` + `@unchecked Sendable` with `Synchronization.Mutex` (macOS 15+, well below our macOS 26 floor) or actors wherever non-recursive locking is used (`ModelSlot`, `IrisLocator`, `CameraController` mailbox, `CoreMLEmbedder` prediction lock).

---

### 5.6 Dependencies, Tooling & Swift Testing Migration

- **Python DMG Tooling (`Tools/Release/DMG/requirements.txt`):**
  - Upgrade `dmgbuild==1.6.5` → `dmgbuild==2.0.0`
  - Upgrade `Pillow==11.3.0` → `Pillow==13.0.0`
  - Verify `Tools/Release/DMG/artwork.py` and `package.py` run cleanly under Python 3.15 + Pillow 13 + dmgbuild 2.0.
- **Vendored `GazeTourKit` (`Sources/GazeTourKit/`):**
  - Place vendored `TourKit.swift` into the `GazeTourKit` SPM target (preserving `ThirdParty/TourKit/LICENSE`, `SOURCE.json`, `LOCAL-CHANGES.md` and `Contents/Resources/TourKit-LICENSE.txt`).
  - Audit for Swift 6 strict concurrency cleanliness while strictly preserving all custom Liquid Glass controls documented in `LOCAL-CHANGES.md`.
- **Test Architecture (`Tests/`):**
  - **Fast, parallel, headless-safe `swift test` targets (6 SPM test targets):**
    - `GazeCoreTests` (`StatusBroadcast`, `AppReadiness`, `EnrollmentStorage`, `AppIdentity`, `SettingsSearch`, `MovementSettings`)
    - `GazeCameraTests` (`HeadPose`, `CameraBackpressure`, `PresenceMode`, `Continuity`)
    - `GazeRecognitionTests` (`Recognition`, `RecognitionMath`, `Enrollment`, `UnlockFlow`, `Liveness`, `ModelWarmup`, `SharedSpoofCrop`)
    - `GazeSecurityTests` (`Presence`, `PresenceLifecycle`, `AppLock`, `AdminPrompt`, `LockScreenSecurity`, `Hardening`, `SudoInstall`, `UnlockAttemptLog`)
    - `GazeUpdatesTests` (`UpdateLifecycle` & GitHub Releases API parsing, trust policy, arch matching, SHA-256 & un-notarized verification)
    - `GazeUITests` (pure headless logic, geometry, state machines, and source invariants: `Notch` geometry/metrics/appearance logic, `Onboarding` history/sizing/motion math logic, `SetupBack` state machine, `Toolbar` layout logic, `SettingsUX` source invariants)
  - **Desktop-session / bundle-dependent / release scripts (`Tests/Scripts/`):**
    - `Tests/Scripts/Release/` (signing, `package.py` DMG verification, `check-build-space.py`, source-archive, artifact verification)
    - `Tests/Scripts/MultiFace/` (opt-in external image fixture download)
    - `Tests/Scripts/AppIntegration/` (desktop-session / `.app`-bundle / Metal-window harnesses that cannot run headless in `swiftpm-testing-helper`: `SettingsLaunch` multi-process handoff, `SettingsInteraction` UI capture, `ProductBoundary` bundle check, `Onboarding` live Metal cadence `LessonMotionTests`/`scene-probe.sh` & PNG/`--review` harness, `Notch` Metal PNG renders, `Toolbar` `.app`-bundle artwork PNG renders)
  - `Tests/run.sh` runs `swift test` first, followed by local non-network verification scripts (with flags to run headless-only vs full desktop integration).

---

## 6. Design Calls Made vs. User Decisions

- **User-decided:**
  - Transition completely to `https://github.com/pearleseed/Gaze` with GitHub Releases distribution.
  - Full clean-break rebrand to `com.pearleseed.Gaze` (App, Finder extension, App Group, Keychain, DynamicLake).
  - Approach B: Multi-module Swift Package workspace, Swift Testing migration, deletion of legacy `Plugin/`, full performance optimization, Swift 6 modernization, and dependency upgrades.
  - Un-notarized release posture (`1B`): canonical `Tools/Release/DMG/package.py` with `.sha256` sidecars, optional notarization, retiring duplicate `BuildDMG.sh`, keeping Homebrew quarantine-clearing `postflight_steps` and README Gatekeeper guidance.
  - Complete removal of `GazeBrowser` (`2A`).
  - Execution via `subagent-driven-development`.
- **Our calls (check while reading; override if you prefer otherwise):**
  - Keep `Package.swift` at repository root with `package` access level between local targets so `swift build` and `swift test` work out of the box, while `Gaze.xcodeproj` consumes it locally for `.app`/`.appex`/Metal/CoreML/PAM/AppIntents bundling.
  - Keep `GazeTourKit` vendored locally (zero external network SPM deps) so Gaze's custom resting Liquid Glass controls and offline build determinism are preserved.
  - Treat HTTP 404 from `api.github.com/repos/pearleseed/Gaze/releases/latest` as `.upToDate` so a newly forked repo with no releases yet never displays a false error banner in Settings.
  - In `UpdateInstaller.verify`, enforce team-matched `SecCodeCopyDesignatedRequirement` whenever the running app has an Apple Team ID, and fall back to strict nested signature validity + mandatory SHA-256 + bundle ID + version matching for ad-hoc signed releases.
  - Preserve the 108 uncommitted working-tree edits as the starting baseline commit on an isolated development branch/worktree before starting task-by-task implementation.
  - Split `Onboarding`, `Notch`, and `Toolbar` cleanly so headless logic/geometry/policy/invariant assertions run fast and in parallel inside `GazeUITests` (`swift test`), while live Metal display-cadence tests, `.app`-bundle artwork PNG snapshots, and the `--review` app stay under `Tests/Scripts/AppIntegration/` — keeping `swift test` CI/SSH-safe with zero lost coverage and zero artificial DI churn in production views.

---

## 7. Left to the Builder / Implementation Plan

- Exact internal helper decomposition and private method names inside split modules (`LockWatcher`, `NotchCapsule`, `LivenessChallenge`).
- Exact Swift Testing `@Suite` and `@Test` naming/organization inside the 6 SPM test targets, provided every assertion from the legacy headless suites is ported without loss.
- Exact task ordering and commit boundaries in the implementation plan.
- Exact `build.sh` invocation flags to bridge `xcodebuild` / SwiftPM cleanly for both local native and `DIST=1` per-architecture release builds.
